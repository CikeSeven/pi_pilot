import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import { RTCPeerConnection, type RTCDataChannel } from "werift";
import {
  encodeP2pFrames,
  P2P_CHUNK_CAPABILITY,
  P2pChunkDecoder,
} from "../src/p2p_chunking.js";
import {
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

  private constructor(private readonly ws: WebSocket) {
    // 帧收集必须在 open 之前挂上:rendezvous 连接瞬间就发 welcome,
    // 晚挂监听会丢帧,await 永远等不到(本次挂死就是这么来的)。
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Frame;
      this.wsFrames.push(msg);
      if (msg.type !== "signal") return;
      const payload = msg.data as Frame;
      if (payload.kind === "answer") {
        void this.pc.setRemoteDescription({
          type: "answer",
          sdp: payload.sdp as string,
        });
      } else if (payload.kind === "candidate" && payload.candidate) {
        void this.pc.addIceCandidate(payload.candidate as never);
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
    } = {},
  ): Promise<void> {
    this.holdCandidates = options.candidateBeforeOffer === true;
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
