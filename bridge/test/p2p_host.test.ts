import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import { RTCPeerConnection, type RTCDataChannel } from "werift";

type Frame = Record<string, any>;

/// 测试内迷你信令服:实现与 rendezvous/ 相同的协议面
/// (welcome/hello/ok/peer_joined/signal 转发/peer_left),
/// 让 bridge 的 P2P host 与测试内 guest 能完整走一遍握手。
class MiniRendezvous {
  readonly wss: WebSocketServer;
  host?: WebSocket;
  readonly guests = new Map<string, WebSocket>();

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
              ws.send(JSON.stringify({ type: "error", reason: "host_offline" }));
              ws.close();
              return;
            }
            role = "guest";
            myPeerId = crypto.randomBytes(4).toString("hex");
            this.guests.set(myPeerId, ws);
            ws.send(JSON.stringify({ type: "ok", peerId: myPeerId }));
            this.host.send(JSON.stringify({ type: "peer_joined", peerId: myPeerId }));
          }
          return;
        }
        if (msg.type === "signal") {
          if (role === "guest") {
            this.host?.send(JSON.stringify({ type: "signal", from: myPeerId, data: msg.data }));
          } else {
            this.guests.get(msg.peerId as string)?.send(
              JSON.stringify({ type: "signal", data: msg.data }),
            );
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
          this.host?.send(JSON.stringify({ type: "peer_left", peerId: myPeerId }));
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
      if (Date.now() - started > timeoutMs) throw new Error("P2P host never registered");
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
  private readonly wsFrames: Frame[] = [];

  private constructor(private readonly ws: WebSocket) {
    // 帧收集必须在 open 之前挂上:rendezvous 连接瞬间就发 welcome,
    // 晚挂监听会丢帧,await 永远等不到(本次挂死就是这么来的)。
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Frame;
      this.wsFrames.push(msg);
      if (msg.type !== "signal") return;
      const payload = msg.data as Frame;
      if (payload.kind === "answer") {
        void this.pc.setRemoteDescription({ type: "answer", sdp: payload.sdp as string });
      } else if (payload.kind === "candidate" && payload.candidate) {
        void this.pc.addIceCandidate(payload.candidate as never);
      }
    });
    this.channel = this.pc.createDataChannel("hub");
    this.channel.onMessage.subscribe((data) => this.messages.push(String(data)));
    this.pc.onIceCandidate.subscribe((candidate) => {
      if (!candidate) return;
      this.sendSignal({
        kind: "candidate",
        candidate: {
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
          usernameFragment: candidate.usernameFragment,
        },
      });
    });
  }

  static async connect(rendezvousUrl: string, deviceId: string, secret: string): Promise<GuestPeer> {
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
    ws.send(JSON.stringify({ type: "hello", role: "guest", deviceId, response }));
    const hello = await peer.waitWsFrame((f) => f.type === "ok" || f.type === "error");
    assert.equal(hello.type, "ok", `guest hello failed: ${JSON.stringify(hello)}`);
    return peer;
  }

  private async waitWsFrame(predicate: (frame: Frame) => boolean, timeoutMs = 5_000): Promise<Frame> {
    const started = Date.now();
    for (;;) {
      const hit = this.wsFrames.find(predicate);
      if (hit) return hit;
      if (Date.now() - started > timeoutMs) {
        throw new Error(`ws frame timed out; got ${JSON.stringify(this.wsFrames)}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  sendSignal(data: Frame): void {
    this.ws.send(JSON.stringify({ type: "signal", data }));
  }

  async offer(): Promise<void> {
    const offer = await this.pc.createOffer();
    // setLocalDescription 是 async:不 await 的话 localDescription 还没就位,
    // 且后续拒绝会变成 unhandled rejection(werift API 语义由探针确认)。
    await this.pc.setLocalDescription(offer);
    const local = this.pc.localDescription;
    assert.ok(local);
    this.sendSignal({ kind: "offer", sdp: local.sdp });
  }

  async waitChannelOpen(timeoutMs = 10_000): Promise<void> {
    const started = Date.now();
    while (this.channel.readyState !== "open") {
      if (Date.now() - started > timeoutMs) {
        throw new Error(`DataChannel never opened (state=${this.channel.readyState})`);
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  async waitMessage(predicate: (frame: Frame) => boolean, timeoutMs = 5_000): Promise<Frame> {
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
        throw new Error(`message timed out; got ${JSON.stringify(this.messages)}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  async close(): Promise<void> {
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
    if (child.exitCode !== null) throw new Error(`hub exited early with ${child.exitCode}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {
      // Still binding.
    }
    if (Date.now() - started > 10_000) throw new Error("hub health check timed out");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function onceExit(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => child.once("exit", () => resolve()));
}

test("手机经打洞 DataChannel 接入:鉴权、bridge_hello、hub 指令全通", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawn(path.join(bridgeRoot, "node_modules", ".bin", "tsx"), ["src/server.ts"], {
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
  });
  // 不 drain stderr 会让子进程管道撑满、套件退出时挂住(既有测试的教训)。
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

    // 正确 token:接入后应收到 bridge_hello,随后 hub 指令正常。
    guest.channel.send(
      JSON.stringify({ type: "auth", token: "mobile-test-token", clientId: "p2p-test-client" }),
    );
    const hello = await guest.waitMessage((frame) => frame.type === "bridge_hello");
    assert.equal(hello.clientId, "p2p-test-client");

    guest.channel.send(JSON.stringify({ type: "hub_list_sources", id: "r1" }));
    const sources = await guest.waitMessage((frame) => frame.type === "response" && frame.id === "r1");
    assert.equal(sources.success, true);
  } finally {
    await guest.close();
    rendezvous.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise<void>((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit: ${stderr}`)), 3_000),
      ),
    ]);
  }
});

test("打洞通道上错误 token 被拒:bridge_error 后关闭", async () => {
  const rendezvous = new MiniRendezvous("test-dev", "s3cret");
  const rendezvousUrl = await rendezvous.url();
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawn(path.join(bridgeRoot, "node_modules", ".bin", "tsx"), ["src/server.ts"], {
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
  });
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
    guest.channel.send(JSON.stringify({ type: "auth", token: "wrong-token", clientId: "p2p-bad" }));
    const error = await guest.waitMessage((frame) => frame.type === "bridge_error");
    assert.equal(error.error, "unauthorized");
  } finally {
    await guest.close();
    rendezvous.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise<void>((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit: ${stderr}`)), 3_000),
      ),
    ]);
  }
});
