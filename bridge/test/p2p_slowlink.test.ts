import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { DataChannelSocket } from "../src/p2p_host.js";
import {
  P2P_CREDIT_MIN_BYTES,
  P2P_CREDIT_TARGET_MS,
} from "../src/p2p_transport.js";

/**
 * 弱网夹具:按固定字节/秒真实排空 bufferedAmount。
 *
 * 为什么用真实定时器而不是假时钟:DataChannelSocket 的发送泵内部用真实
 * setTimeout 轮询信用、用 Date.now() 记推进,注入时钟改不动它。要测「控制帧
 * 在慢链路上要排多久」就必须让时间真的流动。所以负载取小(几百 KB),
 * 保证单条测试几秒内结束。
 */
class SlowLinkChannel extends EventEmitter {
  readyState = "open";
  bufferedAmountLowThreshold = 0;
  onclose?: () => void;
  /// 每帧交给 SCTP 的时刻(相对夹具启动),用于算控制帧排队延迟。
  readonly sentAt: { data: string | Buffer; atMs: number }[] = [];
  private buffered = 0;
  private readonly startedAt = Date.now();
  private readonly timer: NodeJS.Timeout;

  readonly onMessage = { subscribe: () => ({ unsubscribe: () => {} }) };
  readonly stateChanged = { subscribe: () => ({ unsubscribe: () => {} }) };

  constructor(private readonly bytesPerSecond: number) {
    super();
    // 20ms 一拍排空,贴近真实 SCTP 的「小步下降」形态。
    const perTick = Math.max(1, Math.floor((bytesPerSecond * 20) / 1000));
    this.timer = setInterval(() => {
      this.buffered = Math.max(0, this.buffered - perTick);
    }, 20);
    this.timer.unref();
  }

  get bufferedAmount(): number {
    return this.buffered;
  }

  send(data: string | Buffer): void {
    const bytes = typeof data === "string" ? Buffer.byteLength(data) : data.length;
    this.buffered += bytes;
    this.sentAt.push({ data, atMs: Date.now() - this.startedAt });
  }

  close(): void {
    this.readyState = "closed";
    clearInterval(this.timer);
  }

  elapsedMs(): number {
    return Date.now() - this.startedAt;
  }
}

const bulkFrame = (bytes: number): string =>
  JSON.stringify({ type: "response", command: "get_entries", data: "x".repeat(bytes) });

test("弱网基准: 50KB/s 下控制帧不会被埋在 bulk 后面数十秒", async () => {
  const link = new SlowLinkChannel(50 * 1024);
  const socket = new DataChannelSocket(
    link as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  // 必须启用分片才能对齐生产:手机在 auth 里声明 p2p-chunk-v1。
  // 不启用时一条 300KB 是**不可分割的单帧**,send() 的空闲快路径直接整条
  // 交给 SCTP,信用窗口没有任何可调度对象 —— 实测控制帧要排 4.8s。
  socket.enableChunking();

  try {
    // 先压入一批 bulk:300KB 在 50KB/s 上需要 ~6s 才能排完。
    // 信用窗口若失效(误判成 MB/s 级),这 300KB 会一次全压进 SCTP,
    // 控制帧就得等 6s 以上 —— bridge 心跳只给约 10s,叠加 RTT 就会误杀。
    socket.send(bulkFrame(300 * 1024));

    // 让泵先跑几拍,确保 bulk 已经开始占用缓冲。
    await new Promise((resolve) => setTimeout(resolve, 300));

    const pingEnqueuedAt = link.elapsedMs();
    socket.ping(); // control 类:走 sendPriority,应插到剩余 bulk 之前

    // 等控制帧真正被交给通道。
    const deadline = Date.now() + 15_000;
    let pingSentAt: number | undefined;
    while (Date.now() < deadline) {
      const hit = link.sentAt.find(
        (record) =>
          typeof record.data === "string" && record.data.includes('"bridge_ping"'),
      );
      if (hit) {
        pingSentAt = hit.atMs;
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }

    assert.ok(pingSentAt !== undefined, "控制帧必须在 15s 内发出");
    const waitedMs = pingSentAt! - pingEnqueuedAt;

    // 信用窗口的设计目标:控制帧前方最多约 P2P_CREDIT_TARGET_MS 的数据
    // 加一片 bulk。50KB/s 下信用下限 48KB ≈ 1s,给到 4s 容差覆盖调度抖动。
    assert.ok(
      waitedMs < 4_000,
      `控制帧排队 ${waitedMs}ms,应远小于心跳窗口(信用目标 ${P2P_CREDIT_TARGET_MS}ms,` +
        `下限 ${P2P_CREDIT_MIN_BYTES}B);过大说明信用窗口没收住,健康慢链路会被心跳误杀`,
    );
  } finally {
    socket.close(1000, "done");
    link.close();
  }
});

test("弱网基准: 信用窗口把在飞字节压在下限附近,不会一次灌爆缓冲", async () => {
  const link = new SlowLinkChannel(50 * 1024);
  const socket = new DataChannelSocket(
    link as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );

  socket.enableChunking();

  try {
    socket.send(bulkFrame(400 * 1024));

    // 采样峰值在飞字节:信用生效时应稳定在下限量级(48KB)附近,
    // 而不是把 400KB 一次全压进去。
    let peak = 0;
    const until = Date.now() + 2_500;
    while (Date.now() < until) {
      peak = Math.max(peak, link.bufferedAmount);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }

    assert.ok(
      peak <= P2P_CREDIT_MIN_BYTES * 4,
      `峰值在飞 ${peak}B 应压在信用下限量级(${P2P_CREDIT_MIN_BYTES}B)的几倍内;` +
        `一次灌爆缓冲会把控制帧埋到最后`,
    );
    assert.ok(peak > 0, "应当确实发出了数据");
  } finally {
    socket.close(1000, "done");
    link.close();
  }
});

test("弱网基准: 慢链路上健康连接不被判定为无进度", async () => {
  const link = new SlowLinkChannel(50 * 1024);
  const socket = new DataChannelSocket(
    link as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  socket.enableChunking();
  let closedCode: number | undefined;
  socket.on("close", (code: number) => (closedCode = code));

  try {
    socket.send(bulkFrame(250 * 1024));
    await new Promise((resolve) => setTimeout(resolve, 3_000));

    // 只要缓冲在持续下降,就必须判定为「在推进」——不得因为慢而杀链。
    assert.equal(
      closedCode,
      undefined,
      `慢但有推进的链路不得被关闭(实际 code=${closedCode})`,
    );
    assert.ok(link.sentAt.length > 1, "应当已经发出多片");
  } finally {
    socket.close(1000, "done");
    link.close();
  }
});
