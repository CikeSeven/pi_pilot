import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";

type Frame = Record<string, any>;

/// 这条回归锁住一个真机才暴露的缺陷:Bridge 在任务中途重启后,
/// 那个任务的完成通知整个消失。
///
/// 缺陷链条:
///  1. noteStreamingFromEvent 用内存 Map streamingBySource 做边沿去重,
///     Bridge 重启即清空,且缺失值 ?? false 默认为「未在工作」。
///  2. pi 重连后只补发快照(带 isStreaming: true),不会重发 agent_start,
///     所以 detector 的代次表里没有这个源的在飞代次。
///  3. 随后 agent_end 到达,onTaskEnd 找不到在飞代次,按约定返回 undefined
///     (绝不凭空造完成事件),于是事件压根没生成。
///
/// 为什么单元测试测不出来:notification_detector.test.ts 已经覆盖了
/// adoptStreamingSource 本身,但 server.ts 从未调用它。模块对、接线漏,
/// 与 notification_* 帧路由那次缺陷同一类,只有真实进程能验出来。
///
/// 用户可观测的症状很具误导性:常驻通知的「工作中」计数直读快照
/// (isSourceStreaming),与 detector 无关,所以会话状态会如实更新成空闲,
/// 只有完成通知不来 —— 看起来像投递失败,实际是生成端从未产出。

async function freePort(): Promise<number> {
  const server = net.createServer();
  server.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const port = address.port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

async function waitForHealth(port: number, child: ChildProcess): Promise<void> {
  const started = Date.now();
  for (;;) {
    if (child.exitCode !== null) throw new Error(`hub exited early with ${child.exitCode}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {
      // 端口还没绑上。
    }
    if (Date.now() - started > 8_000) throw new Error("hub health check timed out");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

class Peer {
  readonly frames: Frame[] = [];
  private readonly pending = new Map<string, (frame: Frame) => void>();

  constructor(readonly ws: WebSocket) {
    ws.on("message", (data) => {
      const frame = JSON.parse(data.toString()) as Frame;
      this.frames.push(frame);
      if (frame.type === "response" && typeof frame.id === "string") {
        this.pending.get(frame.id)?.(frame);
        this.pending.delete(frame.id);
      }
    });
  }

  request(type: string, extra: Frame = {}, id = `req-${this.frames.length}-${type}`): Promise<Frame> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`request timed out: ${type}`));
      }, 5_000);
      this.pending.set(id, (frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
      this.ws.send(JSON.stringify({ type, id, ...extra }));
    });
  }

  send(payload: Frame): void {
    this.ws.send(JSON.stringify(payload));
  }

  async waitFor(predicate: (frame: Frame) => boolean, timeoutMs = 5_000): Promise<Frame> {
    const started = Date.now();
    for (;;) {
      const found = this.frames.find(predicate);
      if (found) return found;
      if (Date.now() - started > timeoutMs) throw new Error("frame timed out");
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
}

const SOURCE_ID = "restart-source";
const TOKEN = "restart-test-token";
const DESKTOP_TOKEN = "restart-desktop-token";

function snapshot(epoch: string, isStreaming: boolean): Frame {
  return {
    epoch,
    baseSeq: 0,
    state: { sessionId: "restart-session", isStreaming },
    entries: [],
    leafId: null,
  };
}

function spawnBridge(port: number, home: string, bridgeRoot: string): ChildProcess {
  return spawn(path.join(bridgeRoot, "node_modules", ".bin", "tsx"), ["src/server.ts"], {
    cwd: bridgeRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      HOME: home,
      USERPROFILE: home,
      PIPILOT_HOST: "127.0.0.1",
      PIPILOT_PORT: String(port),
      PIPILOT_TOKEN: TOKEN,
      PIPILOT_DESKTOP_TOKEN: DESKTOP_TOKEN,
      PIPILOT_P2P_DEVICE_ID: "restart-device",
      PIPILOT_HEADLESS_AUTO_START: "false",
      PI_CWD: bridgeRoot,
    },
  });
}

async function stopBridge(child: ChildProcess): Promise<void> {
  child.kill("SIGKILL");
  await new Promise<void>((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) return resolve();
    child.once("exit", () => resolve());
    setTimeout(resolve, 2_000);
  });
  child.stdout?.destroy();
  child.stderr?.destroy();
}

async function openDesktop(port: number, sockets: WebSocket[]): Promise<Peer> {
  const ws = new WebSocket(
    `ws://127.0.0.1:${port}/desktop?token=${DESKTOP_TOKEN}&clientId=restart-desktop`,
  );
  sockets.push(ws);
  const peer = new Peer(ws);
  await new Promise<void>((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  return peer;
}

test("完成通知在 Bridge 任务中途重启后仍然生成", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  // 两个实例共用同一个 HOME:身份文件与 outbox 必须延续,
  // 这才是「同一台机器上 Bridge 重启」而不是「换了一台 Bridge」。
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-restart-"));
  let first: ChildProcess | undefined;
  let second: ChildProcess | undefined;
  // socket 必须在 finally 里清:断言失败时走不到 try 末尾的 terminate,
  // 泄漏的句柄会把 node:test 的事件循环永久吊住,
  // 连失败摘要都打不出来(只能看到外部 timeout 的 exit=124)。
  const sockets: WebSocket[] = [];

  try {
    // ---- 第一个实例:任务开始 ----
    first = spawnBridge(port, home, bridgeRoot);
    await waitForHealth(port, first);
    let desktop = await openDesktop(port, sockets);
    // desktop_register 的成功应答是独立帧 desktop_registered,不过 response 信封,
    // 所以不能用 request() 等。失败则回 desktop_error。
    desktop.send({
      type: "desktop_register",
      source: {
        sourceId: SOURCE_ID,
        label: "restart",
        cwd: bridgeRoot,
        sessionId: "restart-session",
        capabilities: [],
      },
      snapshot: snapshot("e1", false),
    });
    const registered = await desktop.waitFor(
      (frame) => frame.type === "desktop_registered" || frame.type === "desktop_error",
    );
    assert.equal(
      registered.type,
      "desktop_registered",
      `desktop_register 失败: ${registered.error}`,
    );

    // agent_start 后立即 agent_end:让这一轮完整结束,
    // outbox 日志里不留任何在飞代次。
    //
    // 这一步是测试能否命中缺口的关键:若日志里留有在飞代次,
    // 第二个实例的 restoreGenerations() 会把它重建出来,
    // 于是即使不接线 adoptStreamingSource 也能生成事件 —— 测不出缺陷。
    // 真实故障正是「日志干净 + 快照说在工作」这个组合。
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 1, event: { type: "agent_start" } });
    await new Promise((resolve) => setTimeout(resolve, 200));
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 2, event: { type: "agent_end" } });
    await new Promise((resolve) => setTimeout(resolve, 250));

    desktop.ws.terminate();
    await stopBridge(first);
    first = undefined;

    // ---- 第二个实例:任务中途重启 ----
    // 内存里的 streamingBySource 与 detector 代次表都随进程消失了。
    second = spawnBridge(port, home, bridgeRoot);
    await waitForHealth(port, second);

    // 手机先连上订阅,才能观察到实时推送的完成事件。
    const phone = new WebSocket(
      `ws://127.0.0.1:${port}/?token=${TOKEN}&clientId=restart-phone`,
    );
    sockets.push(phone);
    const phonePeer = new Peer(phone);
    await new Promise<void>((resolve, reject) => {
      phone.once("open", resolve);
      phone.once("error", reject);
    });
    const hello = await phonePeer.waitFor((frame) => frame.type === "bridge_hello");
    const subscribed = await phonePeer.request("notification_subscribe", {
      installationId: "restart-install",
      scopeVersion: 1,
      pageLimit: 100,
    });
    assert.equal(subscribed.success, true, `订阅失败: ${subscribed.error}`);
    await phonePeer.waitFor((frame) => frame.type === "notification_ready");

    // pi 重连:只补发快照,且快照如实报告「仍在工作中」。
    // 关键 —— 这里**不会**重发 agent_start,现实中 pi 也不会。
    desktop = await openDesktop(port, sockets);
    desktop.send({
      type: "desktop_register",
      source: {
        sourceId: SOURCE_ID,
        label: "restart",
        cwd: bridgeRoot,
        sessionId: "restart-session",
        capabilities: [],
      },
      snapshot: snapshot("e2", true),
    });
    const reregistered = await desktop.waitFor(
      (frame) => frame.type === "desktop_registered" || frame.type === "desktop_error",
    );
    assert.equal(
      reregistered.type,
      "desktop_registered",
      `重新注册失败: ${reregistered.error}`,
    );
    await new Promise((resolve) => setTimeout(resolve, 250));

    // ---- 落下边沿 ----
    // 注意 seq 从 1 开始:上面重新注册用了新 epoch e2,序号随之重置。
    desktop.send({ type: "desktop_event", epoch: "e2", seq: 1, event: { type: "agent_end" } });

    // 修复前:register 路径不碰 streamingBySource 也不领养代次,
    // 此时 next=false 与 (get()??false)=false 相等,
    // noteStreamingFromEvent 的去重守卫直接 return,事件永不生成,这里会超时。
    const events = await phonePeer.waitFor(
      (frame) =>
        frame.type === "notification_events" &&
        Array.isArray(frame.events) &&
        frame.events.some((e: Frame) => e.type === "task_completed"),
      6_000,
    );
    const completed = (events.events as Frame[]).filter((e) => e.type === "task_completed");
    assert.equal(completed.length, 1, "中途重启的任务应当恰好产出一条完成事件");
    // 日志里没有可恢复的在飞代次,所以代次必须来自快照领养。
    assert.match(
      String(completed[0]?.taskGenerationId),
      /^recovery-/,
      "代次应当来自 adoptStreamingSource 的 recovery 领养",
    );

    // agent_settled 紧随 agent_end 时不得再产出第二条(代次去重)。
    desktop.send({ type: "desktop_event", epoch: "e2", seq: 2, event: { type: "agent_settled" } });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const allCompleted = phonePeer.frames
      .filter((f) => f.type === "notification_events" && Array.isArray(f.events))
      .flatMap((f) => f.events as Frame[])
      .filter((e) => e.type === "task_completed");
    assert.equal(allCompleted.length, 1, "agent_end + agent_settled 只应产出一条完成事件");

    phone.terminate();
    desktop.ws.terminate();
  } finally {
    for (const ws of sockets) {
      try {
        ws.terminate();
      } catch {
        // 已经关了就算了。
      }
    }
    if (first) await stopBridge(first);
    if (second) await stopBridge(second);
    fs.rmSync(home, { recursive: true, force: true });
  }
});
