import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import { MAX_ENTRIES_PAGE_BYTES } from "../src/hub_protocol.js";
import { RTCPeerConnection, type RTCDataChannel } from "werift";
import {
  encodeP2pFrames,
  P2P_CHUNK_CAPABILITY,
  P2pChunkDecoder,
} from "../src/p2p_chunking.js";
import {
  decodeFrameV2,
  encodeFrameV2,
  P2P_CHUNK_V2_CAPABILITY,
  P2P_FRAME_V2_TYPE,
} from "../src/p2p_frame_v2.js";
import {
  TransferRetainedStore,
  TransferV2Assembler,
  V2_PAGE_BYTES,
} from "../src/p2p_transfer_v2.js";
import {
  DataChannelSocket,
  iceServersForMode,
  isAllowedP2pSignalingUrl,
  normalizeIceServers,
  normalizeP2pSignalingUrl,
  P2pHost,
  turnCredentialRefreshDelay,
} from "../src/p2p_host.js";

type Frame = Record<string, any>;

/// 测试内迷你信令服:实现与 rendezvous/ 相同的协议面
/// (welcome/hello/ok/peer_joined/signal 转发/peer_left),
/// 让 bridge 的 P2P host 与测试内 guest 能完整走一遍握手。
class MiniRendezvous {
  readonly wss: WebSocketServer;
  host?: WebSocket;
  readonly guests = new Map<string, WebSocket>();
  readonly guestSignals: Frame[] = [];

  constructor(
    readonly deviceId: string,
    readonly secret: string,
  ) {
    this.wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    this.wss.on("connection", (ws) => {
      const nonce = crypto.randomBytes(8).toString("hex");
      let role: "host" | "guest" | undefined;
      let myPeerId: string | undefined;
      ws.send(JSON.stringify({ type: "welcome", nonce }));
      ws.on("message", (data) => {
        const msg = JSON.parse(data.toString()) as Frame;
        if (msg.type === "hello") {
          const expected = crypto
            .createHash("sha256")
            .update(`${nonce}:${this.secret}`)
            .digest("hex");
          if (msg.deviceId !== this.deviceId || msg.response !== expected) {
            ws.send(JSON.stringify({ type: "error", reason: "bad_secret" }));
            ws.close();
            return;
          }
          if (msg.role === "host") {
            role = "host";
            this.host = ws;
            ws.send(JSON.stringify({ type: "ok" }));
          } else {
            if (!this.host) {
              ws.send(
                JSON.stringify({ type: "error", reason: "host_offline" }),
              );
              ws.close();
              return;
            }
            role = "guest";
            myPeerId = crypto.randomBytes(4).toString("hex");
            this.guests.set(myPeerId, ws);
            ws.send(JSON.stringify({ type: "ok", peerId: myPeerId }));
            this.host.send(
              JSON.stringify({ type: "peer_joined", peerId: myPeerId }),
            );
          }
          return;
        }
        if (msg.type === "signal") {
          if (role === "guest") {
            this.guestSignals.push(msg.data as Frame);
            this.host?.send(
              JSON.stringify({
                type: "signal",
                from: myPeerId,
                data: msg.data,
              }),
            );
          } else {
            this.guests
              .get(msg.peerId as string)
              ?.send(JSON.stringify({ type: "signal", data: msg.data }));
          }
        }
      });
      ws.on("close", () => {
        if (role === "host") {
          this.host = undefined;
          for (const guest of this.guests.values()) guest.terminate();
          this.guests.clear();
        } else if (myPeerId) {
          this.guests.delete(myPeerId);
          this.host?.send(
            JSON.stringify({ type: "peer_left", peerId: myPeerId }),
          );
        }
      });
    });
  }

  async url(): Promise<string> {
    // address() 在 listen 完成前返回 null;先判再等,避免 once("listening") 错过已发完的事件。
    if (!this.wss.address()) {
      await new Promise<void>((resolve) => this.wss.once("listening", resolve));
    }
    const address = this.wss.address();
    assert.ok(address && typeof address === "object");
    return `ws://127.0.0.1:${address.port}`;
  }

  async waitForHost(timeoutMs = 10_000): Promise<void> {
    const started = Date.now();
    while (!this.host) {
      if (Date.now() - started > timeoutMs)
        throw new Error("P2P host never registered");
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  close(): void {
    for (const guest of this.guests.values()) guest.terminate();
    this.host?.terminate();
    this.wss.close();
  }
}

/// 测试内 guest:模拟手机的 WebRTC 端 + 信令客户端。
class GuestPeer {
  readonly pc = new RTCPeerConnection({ iceServers: [] });
  readonly channel: RTCDataChannel;
  readonly messages: string[] = [];
  rawDataFrames = 0;
  private readonly chunkDecoder = new P2pChunkDecoder();
  private readonly wsFrames: Frame[] = [];
  private readonly heldCandidates: Frame[] = [];
  private holdCandidates = false;
  /// answer 与 candidate 必须串行化:candidate 抢在 setRemoteDescription
  /// 完成前 addIceCandidate,ufrag 未注册会被 werift 拒(重启后候选到得
  /// 飞快,竞态必现)。与 Flutter 端信令处理的串行化保持一致。
  private signalChain: Promise<void> = Promise.resolve();

  private constructor(private readonly ws: WebSocket) {
    // 帧收集必须在 open 之前挂上:rendezvous 连接瞬间就发 welcome,
    // 晚挂监听会丢帧,await 永远等不到(本次挂死就是这么来的)。
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Frame;
      this.wsFrames.push(msg);
      if (msg.type !== "signal") return;
      const payload = msg.data as Frame;
      if (payload.kind === "answer") {
        this.signalChain = this.signalChain
          .then(() =>
            this.pc.setRemoteDescription({
              type: "answer",
              sdp: payload.sdp as string,
            }),
          )
          .catch(() => {});
      } else if (payload.kind === "candidate" && payload.candidate) {
        this.signalChain = this.signalChain
          .then(() => this.pc.addIceCandidate(payload.candidate as never))
          .catch(() => {});
      }
    });
    this.channel = this.pc.createDataChannel("hub");
    this.channel.bufferedAmountLowThreshold = 0;
    this.channel.onMessage.subscribe((data) => {
      this.rawDataFrames++;
      const decoded = this.chunkDecoder.add(String(data));
      if (decoded !== undefined) this.messages.push(decoded);
    });
    this.pc.onIceCandidate.subscribe((candidate) => {
      if (!candidate) return;
      const signal = {
        kind: "candidate",
        candidate: {
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
          usernameFragment: candidate.usernameFragment,
        },
      };
      if (this.holdCandidates) this.heldCandidates.push(signal);
      else this.sendSignal(signal);
    });
  }

  static async connect(
    rendezvousUrl: string,
    deviceId: string,
    secret: string,
  ): Promise<GuestPeer> {
    const ws = new WebSocket(rendezvousUrl);
    const peer = new GuestPeer(ws);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", resolve);
      ws.once("error", reject);
    });
    const welcome = await peer.waitWsFrame((f) => f.type === "welcome");
    const response = crypto
      .createHash("sha256")
      .update(`${welcome.nonce as string}:${secret}`)
      .digest("hex");
    ws.send(
      JSON.stringify({ type: "hello", role: "guest", deviceId, response }),
    );
    const hello = await peer.waitWsFrame(
      (f) => f.type === "ok" || f.type === "error",
    );
    assert.equal(
      hello.type,
      "ok",
      `guest hello failed: ${JSON.stringify(hello)}`,
    );
    return peer;
  }

  private async waitWsFrame(
    predicate: (frame: Frame) => boolean,
    timeoutMs = 5_000,
  ): Promise<Frame> {
    const started = Date.now();
    for (;;) {
      const hit = this.wsFrames.find(predicate);
      if (hit) return hit;
      if (Date.now() - started > timeoutMs) {
        throw new Error(
          `ws frame timed out; got ${JSON.stringify(this.wsFrames)}`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  sendSignal(data: Frame): void {
    this.ws.send(JSON.stringify({ type: "signal", data }));
  }

  async offer(
    options: {
      stripEmbeddedCandidates?: boolean;
      candidateBeforeOffer?: boolean;
      candidateImmediatelyAfterOffer?: boolean;
    } = {},
  ): Promise<void> {
    this.holdCandidates =
      options.candidateBeforeOffer === true ||
      options.candidateImmediatelyAfterOffer === true;
    const offer = await this.pc.createOffer();
    // setLocalDescription 是 async:不 await 的话 localDescription 还没就位,
    // 且后续拒绝会变成 unhandled rejection(werift API 语义由探针确认)。
    await this.pc.setLocalDescription(offer);
    const local = this.pc.localDescription;
    assert.ok(local);
    const sdp = options.stripEmbeddedCandidates
      ? local.sdp
          .split(/\r?\n/)
          .filter(
            (line) =>
              !line.startsWith("a=candidate:") &&
              line !== "a=end-of-candidates",
          )
          .join("\r\n")
      : local.sdp;
    if (options.candidateBeforeOffer) {
      const started = Date.now();
      while (this.heldCandidates.length === 0) {
        if (Date.now() - started > 2_000) {
          throw new Error("guest did not gather an early ICE candidate");
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
      for (const candidate of this.heldCandidates) this.sendSignal(candidate);
      this.heldCandidates.length = 0;
    }
    if (options.candidateImmediatelyAfterOffer) {
      // 先攒够候选,再把 offer 与 candidate 在同一拍连续发出:host 侧两帧会
      // 紧邻到达。若 host 不按 peer 串行化信令,offer 分支会先把 peer 注册进
      // map、然后才 await setRemoteDescription —— 紧跟的 candidate 看到 peer
      // 已存在就直接 addIceCandidate,此时 ufrag 尚未注册,候选被 werift 丢弃。
      // 配合 stripEmbeddedCandidates(SDP 里没有内嵌候选),连接将无法建立。
      const started = Date.now();
      while (this.heldCandidates.length === 0) {
        if (Date.now() - started > 2_000) {
          throw new Error("guest did not gather an ICE candidate");
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      this.sendSignal({ kind: "offer", sdp });
      for (const candidate of this.heldCandidates) this.sendSignal(candidate);
      this.heldCandidates.length = 0;
      this.holdCandidates = false;
      return;
    }
    this.sendSignal({ kind: "offer", sdp });
    this.holdCandidates = false;
  }

  async waitChannelOpen(timeoutMs = 10_000): Promise<void> {
    const started = Date.now();
    while (this.channel.readyState !== "open") {
      if (Date.now() - started > timeoutMs) {
        throw new Error(
          `DataChannel never opened (state=${this.channel.readyState})`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  async waitMessage(
    predicate: (frame: Frame) => boolean,
    timeoutMs = 5_000,
  ): Promise<Frame> {
    const started = Date.now();
    for (;;) {
      for (const raw of this.messages) {
        let frame: Frame;
        try {
          frame = JSON.parse(raw) as Frame;
        } catch {
          continue;
        }
        if (predicate(frame)) return frame;
      }
      if (Date.now() - started > timeoutMs) {
        throw new Error(
          `message timed out; rawDataFrames=${this.rawDataFrames}; got ${JSON.stringify(this.messages)}`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  async closeDataChannelOnly(): Promise<void> {
    this.channel.close();
  }

  /// 只关信令 WS(模拟手机信令抖动),DataChannel 保持打开。
  async closeSignalingOnly(): Promise<void> {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    await new Promise<void>((resolve) => {
      this.ws.once("close", () => resolve());
      this.ws.close();
    });
  }

  async close(): Promise<void> {
    this.chunkDecoder.close();
    this.ws.close();
    await this.pc.close().catch(() => {});
  }
}

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
    if (child.exitCode !== null)
      throw new Error(`hub exited early with ${child.exitCode}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {
      // Still binding.
    }
    if (Date.now() - started > 10_000)
      throw new Error("hub health check timed out");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function onceExit(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => child.once("exit", () => resolve()));
}

test("P2P 大 UTF-8 帧分片后可乱序重组,每片低于 64KB", () => {
  const original = JSON.stringify({
    type: "response",
    content: "消息快照".repeat(100_000),
  });
  const frames = encodeP2pFrames(original);
  assert.ok(frames.length > 1);
  assert.ok(frames.every((frame) => Buffer.byteLength(frame) < 65_536));

  const decoder = new P2pChunkDecoder();
  let decoded: string | undefined;
  for (const frame of frames.toReversed()) {
    decoded = decoder.add(frame) ?? decoded;
  }
  assert.equal(decoded, original);
  decoder.close();
});

test("P2P 分片拒绝 Node 默认会宽松解码的非法 Base64", () => {
  const frame = encodeP2pFrames("x".repeat(100_000))[0]!;
  const payloadStart = frame.lastIndexOf(":") + 1;
  const malformed = `${frame.slice(0, payloadStart)}!${frame.slice(payloadStart + 1)}`;
  const decoder = new P2pChunkDecoder();

  assert.equal(decoder.add(malformed), undefined);
  decoder.close();
});

test("P2P 慢链路持续有新分片时,总耗时超过空闲窗口仍能重组", async () => {
  const original = "慢链路快照".repeat(7_000);
  const frames = encodeP2pFrames(original);
  assert.ok(frames.length > 2);
  const decoder = new P2pChunkDecoder(100);
  let decoded: string | undefined;

  for (let index = 0; index < frames.length; index++) {
    decoded = decoder.add(frames[index]!) ?? decoded;
    if (index < frames.length - 1) {
      await new Promise((resolve) => setTimeout(resolve, 60));
    }
  }

  assert.equal(decoded, original);
  decoder.close();
});

test("P2P 分片真正停滞超过空闲窗口后会被回收", async () => {
  const original = "停滞快照".repeat(7_000);
  const frames = encodeP2pFrames(original);
  assert.ok(frames.length > 2);
  const decoder = new P2pChunkDecoder(40);
  assert.equal(decoder.add(frames[0]!), undefined);
  await new Promise((resolve) => setTimeout(resolve, 80));

  let decoded: string | undefined;
  for (const frame of frames.slice(1)) {
    decoded = decoder.add(frame) ?? decoded;
  }
  assert.equal(decoded, undefined);
  decoder.close();
});

test("P2P 裸域名自动补 WSS,显式 scheme 保持原样", () => {
  assert.equal(
    normalizeP2pSignalingUrl(" signal.example.com "),
    "wss://signal.example.com",
  );
  assert.equal(
    normalizeP2pSignalingUrl("signal.example.com:443/pipilot"),
    "wss://signal.example.com:443/pipilot",
  );
  assert.equal(
    normalizeP2pSignalingUrl("ws://127.0.0.1:9378"),
    "ws://127.0.0.1:9378",
  );
  assert.equal(
    normalizeP2pSignalingUrl("https://signal.example.com"),
    "https://signal.example.com",
  );
});

test("P2P 公网信令必须使用 wss,ws 只允许回环地址", () => {
  assert.equal(isAllowedP2pSignalingUrl("signal.example.com/p2p"), true);
  assert.equal(isAllowedP2pSignalingUrl("ws://127.0.0.1:9378"), true);
  assert.equal(isAllowedP2pSignalingUrl("ws://127.99.1.2:9378"), true);
  assert.equal(isAllowedP2pSignalingUrl("ws://localhost:9378"), true);
  assert.equal(isAllowedP2pSignalingUrl("ws://[::1]:9378"), true);
  assert.equal(isAllowedP2pSignalingUrl("ws://192.168.1.20:9378"), false);
  assert.equal(isAllowedP2pSignalingUrl("ws://signal.example.com:9378"), false);
  assert.equal(isAllowedP2pSignalingUrl("https://signal.example.com"), false);
  assert.equal(
    isAllowedP2pSignalingUrl("wss://user:pass@signal.example.com"),
    false,
  );
});

test("ICE 服务器只接受 STUN 或带凭据 TURN", () => {
  assert.deepEqual(
    normalizeIceServers([
      { urls: ["stun:one.example:3478", "https://invalid"] },
      {
        urls: "turn:relay.example:3478?transport=udp",
        username: "temporary-user",
        credential: "temporary-credential",
      },
      { urls: "turn:missing-credentials.example:3478" },
      42,
    ]),
    [
      { urls: ["stun:one.example:3478"] },
      {
        urls: ["turn:relay.example:3478?transport=udp"],
        username: "temporary-user",
        credential: "temporary-credential",
      },
    ],
  );
});

test("直连与 relay 使用互斥的 ICE 服务器集合", () => {
  const servers = normalizeIceServers([
    { urls: ["stun:one.example:3478"] },
    {
      urls: ["turn:relay.example:3479?transport=udp"],
      username: "temporary-user",
      credential: "temporary-credential",
    },
  ]);

  assert.deepEqual(iceServersForMode(servers, "direct"), [
    { urls: ["stun:one.example:3478"] },
  ]);
  assert.deepEqual(iceServersForMode(servers, "relay"), [
    {
      urls: ["turn:relay.example:3479?transport=udp"],
      username: "temporary-user",
      credential: "temporary-credential",
    },
  ]);
  assert.equal(iceServersForMode(servers, "auto"), servers);
});

test("TURN REST 凭据在过期前一分钟刷新", () => {
  const nowMs = 1_700_000_000_000;
  assert.equal(
    turnCredentialRefreshDelay(
      [
        {
          urls: ["turn:relay.example:3479?transport=udp"],
          username: "1700000600:pipilot:nonce",
          credential: "temporary-credential",
        },
      ],
      nowMs,
    ),
    540_000,
  );
  assert.equal(
    turnCredentialRefreshDelay(
      [
        {
          urls: ["turn:relay.example:3479?transport=udp"],
          username: "1700000060:pipilot:short-ttl",
          credential: "temporary-credential",
        },
      ],
      nowMs,
    ),
    45_000,
  );
  assert.equal(
    turnCredentialRefreshDelay([{ urls: ["stun:one.example:3478"] }], nowMs),
    undefined,
  );
  assert.equal(
    turnCredentialRefreshDelay(
      [
        {
          urls: ["turn:relay.example:3479?transport=udp"],
          username: "1699999999:pipilot:expired",
          credential: "temporary-credential",
        },
      ],
      nowMs,
    ),
    0,
  );
});

test("远端只关闭 DataChannel 时 host 也释放对应 PeerConnection", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const logs: string[] = [];
  const host = new P2pHost({
    rendezvousUrl,
    deviceId: "test-dev",
    secret: "s3cret",
    validateMobileToken: () => true,
    acceptMobile: () => {},
    log: (line) => logs.push(line),
  });
  host.start();
  let guest: GuestPeer | undefined;

  try {
    await rendezvous.waitForHost();
    guest = await GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
    await guest.offer();
    await guest.waitChannelOpen();
    assert.equal(host.activePeerCount, 1);

    // 信令连接保持打开,避免 peer_left 替 DataChannel close 路径做清理。
    await guest.closeDataChannelOnly();
    const started = Date.now();
    while (!logs.some((line) => line.startsWith("PeerConnection 已关闭("))) {
      if (Date.now() - started > 5_000) {
        throw new Error(
          `host peer was not closed; logs=${JSON.stringify(logs)}`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(host.activePeerCount, 0);
    assert.equal(rendezvous.guests.size, 1);
  } finally {
    await guest?.close();
    host.stop();
    rendezvous.close();
  }
});

test("peer_left 不杀已建链的 P2P 连接,通道仍可用", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const logs: string[] = [];
  let accepted: WebSocket | undefined;
  const host = new P2pHost({
    rendezvousUrl,
    deviceId: "test-dev",
    secret: "s3cret",
    validateMobileToken: () => true,
    acceptMobile: (socket) => {
      accepted = socket;
    },
    log: (line) => logs.push(line),
  });
  host.start();
  let guest: GuestPeer | undefined;
  const started = Date.now();
  const waitFor = async (
    predicate: () => boolean,
    what: string,
    timeoutMs = 30_000,
  ): Promise<void> => {
    for (;;) {
      if (predicate()) return;
      if (Date.now() - started > timeoutMs) {
        throw new Error(`${what} timed out; logs=${JSON.stringify(logs)}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  };

  try {
    await rendezvous.waitForHost();
    guest = await GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
    await guest.offer();
    await guest.waitChannelOpen();
    guest.channel.send(
      JSON.stringify({ type: "auth", token: "t", clientId: "keep-test" }),
    );
    await waitFor(() => accepted !== undefined, "acceptMobile");
    assert.equal(host.activePeerCount, 1);

    // 手机信令 WS 抖动断开:rendezvous 通知 peer_left,但已建链连接必须保留。
    await guest.closeSignalingOnly();
    await waitFor(
      () =>
        logs.some(
          (line) =>
            line.includes("peer 离开") && line.includes("已建链连接保留"),
        ),
      "peer_left 保留日志",
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(host.activePeerCount, 1);

    // 信令死了,媒体仍然活着:帧照常送达。
    const received: string[] = [];
    accepted!.on("message", (data: Buffer) => received.push(data.toString()));
    guest.channel.send(JSON.stringify({ type: "bridge_ping", echo: 1 }));
    await waitFor(() => received.length > 0, "信令断后 DataChannel 收帧");
    assert.equal(
      (JSON.parse(received[0]!) as { type?: string }).type,
      "bridge_ping",
    );
  } finally {
    await guest?.close();
    host.stop();
    rendezvous.close();
  }
});

test("建链未完成时 peer_left 仍清理对应 PeerConnection", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const logs: string[] = [];
  const host = new P2pHost({
    rendezvousUrl,
    deviceId: "test-dev",
    secret: "s3cret",
    validateMobileToken: () => true,
    acceptMobile: () => {},
    log: (line) => logs.push(line),
  });
  host.start();
  const pc = new RTCPeerConnection({ iceServers: [] });
  let ws: WebSocket | undefined;

  try {
    await rendezvous.waitForHost();
    // 手工 guest:发完 offer 不做 answer 处理,DataChannel 永远建不起来。
    ws = new WebSocket(rendezvousUrl);
    const wsFrames: Frame[] = [];
    ws.on("message", (data) => {
      wsFrames.push(JSON.parse(data.toString()) as Frame);
    });
    await new Promise<void>((resolve, reject) => {
      ws!.once("open", resolve);
      ws!.once("error", reject);
    });
    // 各阶段独立计时:全量并发时握手可能吃掉大部分预算,共享起点会假性超时。
    const waitFor = async (
      predicate: () => boolean,
      what: string,
      timeoutMs: number,
    ): Promise<void> => {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        if (predicate()) return;
        if (Date.now() > deadline) {
          throw new Error(`${what} 超时; logs=${JSON.stringify(logs)}`);
        }
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    };
    const waitFrame = async (type: string): Promise<Frame> => {
      const deadline = Date.now() + 5_000;
      for (;;) {
        const index = wsFrames.findIndex((frame) => frame.type === type);
        if (index >= 0) return wsFrames.splice(index, 1)[0]!;
        if (Date.now() > deadline) throw new Error(`${type} 超时`);
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    };
    const welcome = await waitFrame("welcome");
    ws.send(
      JSON.stringify({
        type: "hello",
        role: "guest",
        deviceId: "test-dev",
        response: crypto
          .createHash("sha256")
          .update(`${welcome.nonce as string}:s3cret`)
          .digest("hex"),
      }),
    );
    await waitFrame("ok");

    pc.createDataChannel("hub");
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    ws.send(
      JSON.stringify({
        type: "signal",
        data: { kind: "offer", sdp: pc.localDescription!.sdp },
      }),
    );
    await waitFor(() => host.activePeerCount === 1, "host 创建 peer", 8_000);

    ws.close();
    await waitFor(() => host.activePeerCount === 0, "peer_left 清理", 8_000);
    assert.ok(
      logs.some(
        (line) =>
          line.includes("peer 离开") && line.includes("建链未完成"),
      ),
    );
  } finally {
    ws?.close();
    await pc.close().catch(() => {});
    host.stop();
    rendezvous.close();
  }
});

/// 假 DataChannel:记录发出的每一帧,send 后异步排空缓冲,模拟 SCTP。
class FakeDataChannel extends EventEmitter {
  readyState = "open";
  bufferedAmountLowThreshold = 0;
  onclose?: () => void;
  readonly sent: string[] = [];
  private buffered = 0;
  readonly onMessage = {
    subscribe: () => ({ unsubscribe: () => {} }),
  };
  readonly stateChanged = {
    subscribe: () => ({ unsubscribe: () => {} }),
  };

  get bufferedAmount(): number {
    return this.buffered;
  }

  send(data: string): void {
    this.sent.push(data);
    this.buffered = Buffer.byteLength(data);
    setImmediate(() => {
      this.buffered = 0;
    });
  }

  close(): void {
    this.readyState = "closed";
  }
}

test("DataChannelSocket: 优先帧插到大消息剩余分片之前", async () => {
  const fake = new FakeDataChannel();
  const socket = new DataChannelSocket(
    fake as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  socket.enableChunking();
  const big = "快照内容".repeat(40_000); // >48KB,必分片
  const expectedChunks = encodeP2pFrames(big).length;
  assert.ok(expectedChunks > 2);

  const pong = JSON.stringify({ type: "bridge_pong", echo: 1 });
  socket.send(big);
  socket.sendPriority(pong);

  const started = Date.now();
  for (;;) {
    if (fake.sent.length === expectedChunks + 1) break;
    if (Date.now() - started > 5_000) {
      throw new Error(`pump 未完成,sent=${fake.sent.length}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }

  // chunk0 由 send(big) 同步发出;随后优先帧插队;其余分片按序跟上。
  const pongIndex = fake.sent.indexOf(pong);
  assert.ok(pongIndex > 0, "优先帧不应抢在首片之前(同步首片)");
  assert.ok(
    pongIndex < fake.sent.length - 1,
    "优先帧必须排在最后一片之前,而不是等整条大消息发完",
  );
  const chunkFrames = fake.sent.filter((frame) => frame !== pong);
  const decoder = new P2pChunkDecoder();
  let decoded: string | undefined;
  for (const frame of chunkFrames) {
    decoded = decoder.add(frame) ?? decoded;
  }
  assert.equal(decoded, big);
  decoder.close();
});

test("手机经打洞 DataChannel 接入:1MB hub_sync 快照分片后完整抵达", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawn(
    path.join(bridgeRoot, "node_modules", ".bin", "tsx"),
    ["src/server.ts"],
    {
      cwd: bridgeRoot,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PIPILOT_HOST: "127.0.0.1",
        PIPILOT_PORT: String(port),
        PIPILOT_TOKEN: "mobile-test-token",
        PIPILOT_DESKTOP_TOKEN: "desktop-test-token",
        PIPILOT_HEADLESS_AUTO_START: "false",
        PIPILOT_PI_BIN: process.execPath,
        PI_CWD: bridgeRoot,
        PIPILOT_P2P_RENDEZVOUS: rendezvousUrl,
        PIPILOT_P2P_DEVICE_ID: "test-dev",
        PIPILOT_P2P_SECRET: "s3cret",
      },
    },
  );
  // 不 drain stderr 会让子进程管道撑满、套件退出时挂住(既有测试的教训)。
  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  let desktop: WebSocket | undefined;
  let guest: GuestPeer | undefined;

  try {
    await waitForHealth(port, child);

    // 先注册一份大桌面快照。Hub 会按手机预算裁成约 1MB,仍远超
    // WebRTC 默认协商的 65,536 字节单消息上限。
    const desktopFrames: Frame[] = [];
    desktop = new WebSocket(
      `ws://127.0.0.1:${port}/desktop?token=desktop-test-token`,
    );
    desktop.on("message", (data) => {
      desktopFrames.push(JSON.parse(data.toString()) as Frame);
    });
    await new Promise<void>((resolve, reject) => {
      desktop!.once("open", resolve);
      desktop!.once("error", reject);
    });
    const waitDesktop = async (
      predicate: (frame: Frame) => boolean,
      timeoutMs = 5_000,
    ): Promise<Frame> => {
      const started = Date.now();
      for (;;) {
        const hit = desktopFrames.find(predicate);
        if (hit) return hit;
        if (Date.now() - started > timeoutMs)
          throw new Error("desktop frame timed out");
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    };
    await waitDesktop((frame) => frame.type === "desktop_hello");
    const filler = "x".repeat(8_000);
    const entries = Array.from({ length: 300 }, (_, index) => ({
      id: `entry-${index}`,
      type: "message",
      timestamp: index + 1,
      message: {
        role: index % 2 === 0 ? "user" : "assistant",
        content: filler,
        timestamp: index + 1,
      },
    }));
    desktop.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:p2p-big",
          label: "P2P big snapshot",
          cwd: "/tmp/pipilot-p2p-big",
          sessionId: "session-p2p-big",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-p2p-big",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: {
            sessionId: "session-p2p-big",
            cwd: "/tmp/pipilot-p2p-big",
            isStreaming: false,
          },
          entries,
          leafId: "entry-299",
        },
      }),
    );
    await waitDesktop((frame) => frame.type === "desktop_registered");

    await rendezvous.waitForHost();
    guest = await GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
    // candidate 故意先于 offer 上行,且从 SDP 中移除内嵌候选;
    // host 若不缓存 pre-offer candidate,这条连接无法建立。
    await guest.offer({
      stripEmbeddedCandidates: true,
      candidateBeforeOffer: true,
    });
    const signalStarted = Date.now();
    while (!rendezvous.guestSignals.some((frame) => frame.kind === "offer")) {
      if (Date.now() - signalStarted > 2_000) {
        throw new Error("rendezvous did not receive the guest offer");
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const signalKinds = rendezvous.guestSignals.map((frame) => frame.kind);
    assert.ok(signalKinds.indexOf("candidate") >= 0);
    assert.ok(signalKinds.indexOf("candidate") < signalKinds.indexOf("offer"));
    await guest.waitChannelOpen();

    guest.channel.send(
      JSON.stringify({
        type: "auth",
        token: "mobile-test-token",
        clientId: "p2p-test-client",
        capabilities: [P2P_CHUNK_CAPABILITY],
      }),
    );
    const hello = await guest.waitMessage(
      (frame) => frame.type === "bridge_hello",
    );
    assert.equal(hello.clientId, "p2p-test-client");
    assert.ok((hello.capabilities as unknown[]).includes(P2P_CHUNK_CAPABILITY));

    guest.channel.send(
      JSON.stringify({
        type: "hub_select_source",
        sourceId: "desktop:p2p-big",
        id: "select-big",
      }),
    );
    const selected = await guest.waitMessage(
      (frame) => frame.type === "response" && frame.id === "select-big",
    );
    assert.equal(selected.success, true);

    guest.channel.send(JSON.stringify({ type: "hub_sync", id: "sync-big" }));
    const sync = await guest.waitMessage(
      (frame) => frame.type === "response" && frame.id === "sync-big",
      60_000,
    );
    assert.equal(sync.success, true);
    assert.equal(sync.data.mode, "snapshot");
    assert.equal(sync.data.entriesHasMore, true);
    const sent = sync.data.snapshot.entries as Frame[];
    assert.ok(sent.length < entries.length);
    assert.equal(sent.at(-1)?.id, "entry-299");
    assert.ok(Buffer.byteLength(JSON.stringify(sync)) > 65_536);
    assert.ok(guest.rawDataFrames > 3, "大响应应拆成多个 DataChannel 消息");
  } finally {
    await guest?.close();
    desktop?.close();
    rendezvous.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise<void>((_, reject) =>
        setTimeout(
          () => reject(new Error(`hub did not exit: ${stderr}`)),
          3_000,
        ),
      ),
    ]);
  }
});

test("打洞通道上错误 token 被拒:bridge_error 后关闭", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawn(
    path.join(bridgeRoot, "node_modules", ".bin", "tsx"),
    ["src/server.ts"],
    {
      cwd: bridgeRoot,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PIPILOT_HOST: "127.0.0.1",
        PIPILOT_PORT: String(port),
        PIPILOT_TOKEN: "mobile-test-token",
        PIPILOT_DESKTOP_TOKEN: "desktop-test-token",
        PIPILOT_HEADLESS_AUTO_START: "false",
        PIPILOT_PI_BIN: process.execPath,
        PI_CWD: bridgeRoot,
        PIPILOT_P2P_RENDEZVOUS: rendezvousUrl,
        PIPILOT_P2P_DEVICE_ID: "test-dev",
        PIPILOT_P2P_SECRET: "s3cret",
      },
    },
  );
  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));

  const guest = await (async () => {
    await waitForHealth(port, child);
    await rendezvous.waitForHost();
    return GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
  })();

  try {
    await guest.offer();
    await guest.waitChannelOpen();
    guest.channel.send(
      JSON.stringify({
        type: "auth",
        token: "wrong-token",
        clientId: "p2p-bad",
      }),
    );
    const error = await guest.waitMessage(
      (frame) => frame.type === "bridge_error",
    );
    assert.equal(error.error, "unauthorized");
  } finally {
    await guest.close();
    rendezvous.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise<void>((_, reject) =>
        setTimeout(
          () => reject(new Error(`hub did not exit: ${stderr}`)),
          3_000,
        ),
      ),
    ]);
  }
});

/// 可注入入站帧的假通道:onMessage.subscribe 捕获回调,便于模拟对端发帧。
class InjectableFakeDataChannel extends EventEmitter {
  readyState = "open";
  bufferedAmountLowThreshold = 0;
  onclose?: () => void;
  readonly sent: string[] = [];
  private buffered = 0;
  private messageHandler?: (data: string | Buffer) => void;
  readonly onMessage = {
    subscribe: (handler: (data: string | Buffer) => void) => {
      this.messageHandler = handler;
      return { unsubscribe: () => {} };
    },
  };
  readonly stateChanged = {
    subscribe: () => ({ unsubscribe: () => {} }),
  };

  get bufferedAmount(): number {
    return this.buffered;
  }

  send(data: string): void {
    this.sent.push(data);
    setImmediate(() => {
      this.buffered = 0;
    });
  }

  pushInbound(frame: string): void {
    this.messageHandler?.(frame);
  }

  close(): void {
    this.readyState = "closed";
  }
}

test("DataChannelSocket: ping 走通道真发 bridge_ping,入站 bridge_pong 转成 pong 事件", async () => {
  const fake = new InjectableFakeDataChannel();
  const socket = new DataChannelSocket(
    fake as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );

  // 本地自答 pong 已废除:ping() 必须把 bridge_ping 写进通道。
  socket.ping();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(fake.sent.length, 1);
  const pingFrame = JSON.parse(fake.sent[0]!) as { type?: string; echo?: string };
  assert.equal(pingFrame.type, "bridge_ping");
  assert.ok(typeof pingFrame.echo === "string" && pingFrame.echo.length > 0);

  // 对端回 bridge_pong:socket 层拦截并转成 "pong" 事件,不往 hub 消息路径送。
  let pongs = 0;
  let messages = 0;
  socket.on("pong", () => pongs++);
  socket.on("message", () => messages++);
  fake.pushInbound(JSON.stringify({ type: "bridge_pong", echo: pingFrame.echo }));
  assert.equal(pongs, 1);
  assert.equal(messages, 0);

  // 普通消息照常送达。
  fake.pushInbound(JSON.stringify({ type: "bridge_hello" }));
  assert.equal(messages, 1);
});

test("DataChannelSocket: 远端主动断开记 1006,本地关闭保留语义码", async () => {
  const fake = new InjectableFakeDataChannel();
  const socket = new DataChannelSocket(
    fake as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    socket.on("close", (code: number, reason: Buffer) =>
      resolve({ code, reason: reason.toString("utf8") }),
    );
  });
  fake.onclose?.();
  const remote = await closed;
  assert.equal(remote.code, 1006, "远端断开必须区别于本地正常关闭(1000)");

  const fake2 = new InjectableFakeDataChannel();
  const socket2 = new DataChannelSocket(
    fake2 as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  const closed2 = new Promise<{ code: number }>((resolve) => {
    socket2.on("close", (code: number) => resolve({ code }));
  });
  socket2.close(4001, "unauthorized");
  assert.equal((await closed2).code, 4001, "本地语义码必须透传");
});

/// 双 fake 通道回环:A.send 异步喂给 B 的入站,反之亦然。
class LoopbackFakeDataChannel extends EventEmitter {
  readyState = "open";
  bufferedAmountLowThreshold = 0;
  onclose?: () => void;
  peer?: LoopbackFakeDataChannel;
  readonly sent: (string | Buffer)[] = [];
  private messageHandler?: (data: string | Buffer) => void;
  readonly onMessage = {
    subscribe: (handler: (data: string | Buffer) => void) => {
      this.messageHandler = handler;
      return { unsubscribe: () => {} };
    },
  };
  readonly stateChanged = {
    subscribe: () => ({ unsubscribe: () => {} }),
  };

  get bufferedAmount(): number {
    return 0;
  }

  send(data: string | Buffer): void {
    this.sent.push(data);
    const peer = this.peer;
    if (peer) {
      setImmediate(() => peer.messageHandler?.(data));
    }
  }

  pushInbound(data: string | Buffer): void {
    this.messageHandler?.(data);
  }

  close(): void {
    this.readyState = "closed";
  }
}

test("DataChannelSocket chunk-v2: 大消息二进制分页端到端送达,ACK 释放留存", async () => {
  const a = new LoopbackFakeDataChannel();
  const b = new LoopbackFakeDataChannel();
  a.peer = b;
  b.peer = a;
  const retainedA = new TransferRetainedStore();
  const retainedB = new TransferRetainedStore();
  const socketA = new DataChannelSocket(
    a as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  const socketB = new DataChannelSocket(
    b as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  socketA.enableChunkingV2(retainedA, new TransferV2Assembler());
  socketB.enableChunkingV2(retainedB, new TransferV2Assembler());

  const text = JSON.stringify({
    type: "hub_sync",
    payload: "x".repeat(200 * 1024),
  });
  const received = new Promise<Buffer>((resolve) =>
    socketB.on("message", resolve),
  );
  socketA.send(text);
  const message = await received;
  assert.equal(message.toString(), text);

  // A 发出的帧应是 v2 二进制:首帧 BEGIN,gzip 压缩(高重复文本)。
  const binaryFrames = a.sent.filter((frame) => Buffer.isBuffer(frame));
  assert.ok(binaryFrames.length >= 3, `expect >=3 binary frames, got ${binaryFrames.length}`);
  const begin = decodeFrameV2(binaryFrames[0] as Buffer);
  assert.equal(begin.type, P2P_FRAME_V2_TYPE.begin);
  assert.equal(begin.meta?.encoding, "gzip");
  const transferIdHex = begin.transferId.toString("hex");

  // B 收齐后回 ACK → A 的留存应被释放(等两拍事件循环让 ACK 回路跑完)。
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(retainedA.resendFrames(transferIdHex, [0], false), null);
});

test("DataChannelSocket chunk-v2: 入站 NACK 触发留存重发,未知 transfer 回 ABORT", async () => {
  const a = new LoopbackFakeDataChannel();
  const retainedA = new TransferRetainedStore();
  const socketA = new DataChannelSocket(
    a as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  socketA.enableChunkingV2(retainedA, new TransferV2Assembler());

  // 不可压缩文本保证多页;直接驱动 A 发一条大消息。
  const text = crypto.randomBytes(V2_PAGE_BYTES * 3).toString("hex");
  socketA.send(text);
  // 泵是异步的:等到原始 transfer 的 DONE 帧发出为止。
  let binaryFrames: Buffer[] = [];
  for (let i = 0; i < 100; i++) {
    binaryFrames = a.sent.filter((frame) => Buffer.isBuffer(frame)) as Buffer[];
    const done = binaryFrames.some((frame) => {
      try {
        return decodeFrameV2(frame).type === P2P_FRAME_V2_TYPE.done;
      } catch {
        return false;
      }
    });
    if (done) break;
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.ok(binaryFrames.length >= 3);
  const begin = decodeFrameV2(binaryFrames[0]!);
  const pageCount = begin.pageCount;
  assert.ok(pageCount >= 2);
  const sentBefore = a.sent.length;

  // 对端 NACK 缺第 1 页 → A 应重发该 DATA 页 + DONE。
  const nackFrame = encodeFrameV2({
    type: P2P_FRAME_V2_TYPE.nack,
    transferId: begin.transferId,
    pageIndex: 0,
    pageCount,
    meta: { missing: [1] },
  });
  a.pushInbound(nackFrame);
  for (let i = 0; i < 5; i++) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  const resent = a.sent.slice(sentBefore).filter((frame) => Buffer.isBuffer(frame)) as Buffer[];
  assert.equal(resent.length, 2, `expect DATA+DONE resend, got ${resent.length}`);
  assert.equal(decodeFrameV2(resent[0]!).type, P2P_FRAME_V2_TYPE.data);
  assert.equal(decodeFrameV2(resent[0]!).pageIndex, 1);
  assert.equal(decodeFrameV2(resent[1]!).type, P2P_FRAME_V2_TYPE.done);

  // 未知 transferId 的 NACK → ABORT 回执。
  const unknownNack = encodeFrameV2({
    type: P2P_FRAME_V2_TYPE.nack,
    transferId: crypto.randomBytes(16),
    pageIndex: 0,
    pageCount: 1,
    meta: { missing: [0] },
  });
  const sentBefore2 = a.sent.length;
  a.pushInbound(unknownNack);
  await new Promise((resolve) => setImmediate(resolve));
  const abortFrames = a.sent.slice(sentBefore2).filter((frame) => Buffer.isBuffer(frame)) as Buffer[];
  assert.equal(abortFrames.length, 1);
  assert.equal(decodeFrameV2(abortFrames[0]!).type, P2P_FRAME_V2_TYPE.abort);
});

test("offer 紧跟 candidate 时 host 按 peer 串行化信令,候选不丢", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const logs: string[] = [];
  const host = new P2pHost({
    rendezvousUrl,
    deviceId: "test-dev",
    secret: "s3cret",
    validateMobileToken: () => true,
    acceptMobile: () => {},
    log: (line) => logs.push(line),
  });
  host.start();
  let guest: GuestPeer | undefined;

  try {
    await rendezvous.waitForHost();
    guest = await GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
    // SDP 内嵌候选被剥掉,连接只能靠 trickle 的 candidate 帧建立;
    // 且 candidate 紧跟 offer 同拍发出,落在 setRemoteDescription 的 await 窗口。
    // host 不串行化信令时,这条候选会在 remote description 就位前被投喂而丢失。
    await guest.offer({
      stripEmbeddedCandidates: true,
      candidateImmediatelyAfterOffer: true,
    });
    const signalStarted = Date.now();
    while (
      !rendezvous.guestSignals.some((frame) => frame.kind === "offer") ||
      !rendezvous.guestSignals.some((frame) => frame.kind === "candidate")
    ) {
      if (Date.now() - signalStarted > 3_000) {
        throw new Error(
          `rendezvous 未收到 offer+candidate;实际 ${JSON.stringify(
            rendezvous.guestSignals.map((frame) => frame.kind),
          )}`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const kinds = rendezvous.guestSignals.map((frame) => frame.kind);
    assert.ok(
      kinds.indexOf("offer") < kinds.indexOf("candidate"),
      `candidate 必须紧跟在 offer 之后,实际顺序 ${JSON.stringify(kinds)}`,
    );

    await guest.waitChannelOpen();
    assert.equal(host.activePeerCount, 1);
    assert.ok(
      !logs.some((line) => line.startsWith("处理信令失败(")),
      `信令处理不应报错;logs=${JSON.stringify(logs)}`,
    );
    // 确定性断言:串行化生效时,candidate 必然在 remote description 就位后
    // 才被投喂,这个计数恒为 0。并发派发时 candidate 会抢在 srd 完成前到达,
    // 计数 >0 —— werift 那时会静默丢弃候选(探针确认:不抛错),真实网络上
    // 只有单个 relay 候选就会建链失败。
    assert.equal(
      host.candidatesAwaitingRemoteDescription,
      0,
      "candidate 不得在 remote description 就位前到达",
    );
  } finally {
    await guest?.close();
    host.stop();
    rendezvous.close();
  }
});

/// bufferedAmount 恒高的 fake:泵一进信用等待就卡住,队列因此只出不进,
/// 可以稳定地把 bulk 队列堆到上限。
class StalledFakeDataChannel extends EventEmitter {
  readyState = "open";
  bufferedAmountLowThreshold = 0;
  onclose?: () => void;
  readonly sent: (string | Buffer)[] = [];
  readonly onMessage = {
    subscribe: () => ({ unsubscribe: () => {} }),
  };
  readonly stateChanged = {
    subscribe: () => ({ unsubscribe: () => {} }),
  };

  /// 永远高于任何信用目标:泵停在 _waitForCredit 里,不消费队列。
  get bufferedAmount(): number {
    return 100 * 1024 * 1024;
  }

  send(data: string | Buffer): void {
    this.sent.push(data);
  }

  close(): void {
    this.readyState = "closed";
  }
}

test("DataChannelSocket: bulk 队列按整条消息原子准入,拒绝不留半条", async () => {
  const fake = new StalledFakeDataChannel();
  const socket = new DataChannelSocket(
    fake as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );

  // 不启用 chunking:一条消息就是一帧,字节数可预测(gzip 会把重复内容压到
  // 几乎为零,那样永远填不满队列,测不到准入边界)。
  const bulk = (bytes: number): string =>
    JSON.stringify({
      type: "response",
      command: "get_entries",
      data: "x".repeat(bytes),
    });

  const eight = 8 * 1024 * 1024;
  // 不假设具体条数:首帧会被泵取走(队列归零后才卡在信用等待),
  // 所以边界落在第几条取决于 JSON 开销,循环到第一次被拒即可。
  let accepted = 0;
  let bytesBeforeReject = 0;
  let rejected = false;
  for (let i = 0; i < 12; i++) {
    bytesBeforeReject = socket.bulkQueuedByteCount;
    if (!socket.trySend(bulk(eight))) {
      rejected = true;
      break;
    }
    accepted++;
    await new Promise((resolve) => setImmediate(resolve));
  }

  assert.ok(rejected, `12 条 8MiB 之内必须触到 32MiB 上限,实际接受了 ${accepted} 条`);
  assert.ok(accepted >= 3, `上限前应能接受数条,实际 ${accepted}`);
  assert.equal(
    socket.bulkQueuedByteCount,
    bytesBeforeReject,
    "拒绝后队列字节数不得变化(不能留下半条 transfer)",
  );
  assert.equal(socket.bulkRejected, 1, "拒绝应被计数");

  socket.close(1000, "done");
});

test("chunk-v2 状态按 owner 隔离:两个 clientId 各有独立留存/重组桶", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const logs: string[] = [];
  const host = new P2pHost({
    rendezvousUrl,
    deviceId: "test-dev",
    secret: "s3cret",
    validateMobileToken: () => true,
    acceptMobile: () => {},
    log: (line) => logs.push(line),
  });
  host.start();
  let a: GuestPeer | undefined;
  let b: GuestPeer | undefined;

  try {
    await rendezvous.waitForHost();
    assert.equal(host.ownerStoreCount, 0, "未接入时不应有状态桶");

    a = await GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
    await a.offer();
    await a.waitChannelOpen();
    a.channel.send(
      JSON.stringify({
        type: "auth",
        token: "t",
        clientId: "phone-A",
        capabilities: [P2P_CHUNK_V2_CAPABILITY],
      }),
    );
    const started = Date.now();
    while (host.ownerStoreCount < 1) {
      if (Date.now() - started > 5_000) throw new Error("phone-A 未建立状态桶");
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(host.ownerStoreCount, 1);

    b = await GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
    await b.offer();
    await b.waitChannelOpen();
    b.channel.send(
      JSON.stringify({
        type: "auth",
        token: "t",
        clientId: "phone-B",
        capabilities: [P2P_CHUNK_V2_CAPABILITY],
      }),
    );
    const started2 = Date.now();
    while (host.ownerStoreCount < 2) {
      if (Date.now() - started2 > 5_000) {
        throw new Error(
          `phone-B 未获得独立状态桶,ownerStoreCount=${host.ownerStoreCount}`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }

    // 关键断言:两台设备必须各有一个桶。修复前是 host 级单例,这里会是 1 ——
    // transferId 只有 16 字节随机数、不带 owner 身份,A 的 ACK/NACK 能命中 B
    // 的留存,B 的残留分页也可能被 A 的 DONE 触发交付,多设备同时连接就串台。
    assert.equal(
      host.ownerStoreCount,
      2,
      "不同 clientId 必须各自持有独立的 retained/assembler",
    );
  } finally {
    await a?.close();
    await b?.close();
    host.stop();
    rendezvous.close();
  }
});

test("P2P 往前翻历史:单页落在 96KiB 预算内(不得用 WS 的 1MB 预算)", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawn(
    path.join(bridgeRoot, "node_modules", ".bin", "tsx"),
    ["src/server.ts"],
    {
      cwd: bridgeRoot,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PIPILOT_HOST: "127.0.0.1",
        PIPILOT_PORT: String(port),
        PIPILOT_TOKEN: "mobile-test-token",
        PIPILOT_DESKTOP_TOKEN: "desktop-test-token",
        PIPILOT_HEADLESS_AUTO_START: "false",
        PIPILOT_PI_BIN: process.execPath,
        PI_CWD: bridgeRoot,
        PIPILOT_P2P_RENDEZVOUS: rendezvousUrl,
        PIPILOT_P2P_DEVICE_ID: "test-dev",
        PIPILOT_P2P_SECRET: "s3cret",
      },
    },
  );
  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  let desktop: WebSocket | undefined;
  let guest: GuestPeer | undefined;

  try {
    await waitForHealth(port, child);

    const desktopFrames: Frame[] = [];
    desktop = new WebSocket(
      `ws://127.0.0.1:${port}/desktop?token=desktop-test-token`,
    );
    desktop.on("message", (data) => {
      desktopFrames.push(JSON.parse(data.toString()) as Frame);
    });
    await new Promise<void>((resolve, reject) => {
      desktop!.once("open", resolve);
      desktop!.once("error", reject);
    });
    const waitDesktop = async (
      predicate: (frame: Frame) => boolean,
      timeoutMs = 5_000,
    ): Promise<Frame> => {
      const started = Date.now();
      for (;;) {
        const hit = desktopFrames.find(predicate);
        if (hit) return hit;
        if (Date.now() - started > timeoutMs) {
          throw new Error("desktop frame timed out");
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    };
    await waitDesktop((frame) => frame.type === "desktop_hello");

    // 每条约 8KB:总量约 2.4MB,远超任何单页预算,保证首屏与每一页都会被裁。
    const filler = "p".repeat(8_000);
    const entries = Array.from({ length: 300 }, (_, index) => ({
      id: `hist-${index}`,
      type: "message",
      timestamp: index + 1,
      message: {
        role: index % 2 === 0 ? "user" : "assistant",
        content: filler,
        timestamp: index + 1,
      },
    }));

    desktop.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:p2p-page",
          label: "P2P paging",
          cwd: "/tmp/pipilot-p2p-page",
          sessionId: "session-p2p-page",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-p2p-page",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: {
            sessionId: "session-p2p-page",
            cwd: "/tmp/pipilot-p2p-page",
            isStreaming: false,
          },
          entries,
          leafId: "hist-299",
        },
      }),
    );
    await waitDesktop((frame) => frame.type === "desktop_registered");

    await rendezvous.waitForHost();
    guest = await GuestPeer.connect(rendezvousUrl, "test-dev", "s3cret");
    await guest.offer();
    await guest.waitChannelOpen();
    guest.channel.send(
      JSON.stringify({
        type: "auth",
        token: "mobile-test-token",
        clientId: "p2p-page-client",
        capabilities: [P2P_CHUNK_CAPABILITY],
      }),
    );
    await guest.waitMessage((frame) => frame.type === "bridge_hello");

    guest.channel.send(
      JSON.stringify({
        type: "hub_select_source",
        sourceId: "desktop:p2p-page",
        id: "sel",
      }),
    );
    const selected = await guest.waitMessage(
      (frame) => frame.type === "response" && frame.id === "sel",
    );
    assert.equal(selected.success, true);

    guest.channel.send(JSON.stringify({ type: "hub_sync", id: "sync" }));
    const sync = await guest.waitMessage(
      (frame) => frame.type === "response" && frame.id === "sync",
      60_000,
    );
    assert.equal(sync.success, true);
    assert.equal(sync.data.entriesHasMore, true, "首屏必须被裁,才有历史可翻");

    // 首屏整帧(含 state/events/元数据外壳)必须落进 128KiB 硬上限。
    // 真机实测过溢出:只给 entries 数组设预算时整帧是 148,217B,超限 13%。
    const firstScreenBytes = Buffer.byteLength(JSON.stringify(sync.data));
    assert.ok(
      firstScreenBytes <= 128 * 1024,
      `首屏整帧必须落进 128KiB,实际 ${firstScreenBytes}B`,
    );

    // 往前翻三页,每页都必须落在 96KiB 的 P2P 预算内。
    // 修复前这条路径用的是 clipEntriesForMobile 的默认值(1MB 的 WS 预算):
    // 真机 loopback 实测单页到过 1023.6KiB —— 按实测约 108KB/s 的端到端吞吐
    // 要 9.7s,在 50KB/s 的慢 TURN 上约 20s,直接超过请求超时。
    let cursor = sync.data.entriesOldestId as string;
    assert.ok(typeof cursor === "string" && cursor.length > 0);
    for (let round = 1; round <= 3; round++) {
      const rid = `page-${round}`;
      guest.channel.send(
        JSON.stringify({ type: "get_entries", before: cursor, id: rid }),
      );
      const page = await guest.waitMessage(
        (frame) => frame.type === "response" && frame.id === rid,
        60_000,
      );
      assert.equal(page.success, true, `第 ${round} 页应成功`);
      const pageBytes = Buffer.byteLength(JSON.stringify(page.data));
      assert.ok(
        pageBytes <= MAX_ENTRIES_PAGE_BYTES,
        `第 ${round} 页必须落在 ${MAX_ENTRIES_PAGE_BYTES}B 内,实际 ${pageBytes}B`,
      );
      const got = (page.data.entries as Frame[]).length;
      assert.ok(got > 0, `第 ${round} 页不得为空`);
      if (page.data.hasMore !== true) break;
      cursor = page.data.oldestId as string;
      assert.ok(typeof cursor === "string" && cursor.length > 0);
    }
  } finally {
    await guest?.close();
    desktop?.close();
    rendezvous.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise<void>((_, reject) =>
        setTimeout(
          () => reject(new Error(`hub did not exit: ${stderr}`)),
          3_000,
        ),
      ),
    ]);
  }
});

test("DataChannelSocket: 载荷过大只拒这条消息,不得关闭通道", async () => {
  const fake = new InjectableFakeDataChannel();
  const socket = new DataChannelSocket(
    fake as unknown as ConstructorParameters<typeof DataChannelSocket>[0],
  );
  socket.enableChunkingV2(new TransferRetainedStore(), new TransferV2Assembler());

  let closeCode: number | undefined;
  socket.on("close", (code: number) => {
    closeCode = code;
  });

  // 超过 chunk-v2 的 16MB 单条消息上限:encodeTransferV2 会抛。
  //
  // 真机实测的故障链(50.40MB 无头会话):get_entries 把整个会话原样返回 →
  // encodeTransferV2 抛 "P2P message exceeds 16MB" → 旧代码与通道故障共用
  // 一个 catch,直接 shutdown(1011,"p2p send failed") → 连超时响应都发不回去
  // → 手机重连 → 再次请求 → 循环。真机日志确认过 code=1011 与 300 秒零响应帧。
  const oversized = JSON.stringify({
    type: "response",
    command: "get_entries",
    data: { blob: "x".repeat(17 * 1024 * 1024) },
  });

  const accepted = socket.trySend(oversized);
  assert.equal(accepted, false, "过大的载荷必须被拒");
  assert.equal(
    socket.lastSendRejectedOversized,
    true,
    "必须标记为「载荷过大」,调用方据此回明确失败而不是当成连接坏了",
  );
  assert.equal(socket.oversizedRejectCount, 1);

  // 关键断言:通道必须还活着。
  assert.equal(fake.readyState, "open", "通道不得因为一条过大的载荷被关闭");
  assert.equal(closeCode, undefined, "不得触发 close 事件");

  // 通道仍然可用:紧接着的正常响应必须发得出去 —— 这才是「手机能拿到
  // 明确失败」的前提(否则失败响应本身也发不出去)。
  fake.sent.length = 0;
  const small = JSON.stringify({
    type: "response",
    command: "get_entries",
    success: false,
    error: "响应超出单条消息上限,请缩小请求范围",
  });
  assert.equal(socket.trySend(small), true, "过大载荷被拒后,通道必须仍可发送");
  assert.equal(
    socket.lastSendRejectedOversized,
    false,
    "成功发送后必须清掉「过大」标记,避免污染下一次判断",
  );
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(
    fake.sent.some((frame) => frame.includes("响应超出单条消息上限")),
    "明确失败响应必须真的写进通道",
  );
});
