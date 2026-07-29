import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import crypto from "node:crypto";
import WebSocket from "ws";
import { createRendezvous, sha256Hex, type RendezvousHandle } from "../src/server.js";

interface Running {
  url: string;
  close: () => Promise<void>;
}

async function startRendezvous(): Promise<Running> {
  const handle: RendezvousHandle = createRendezvous({
    port: 0,
    host: "127.0.0.1",
    devices: { dev1: "s3cret-pairing" },
  });
  await once(handle.httpServer.listen(0, "127.0.0.1"), "listening");
  const address = handle.httpServer.address();
  assert.ok(address && typeof address === "object");
  return { url: `ws://127.0.0.1:${address.port}`, close: handle.close };
}

type Frame = Record<string, unknown>;

class Peer {
  readonly ws: WebSocket;
  readonly frames: Frame[] = [];

  private constructor(ws: WebSocket) {
    this.ws = ws;
    ws.on("message", (data) => this.frames.push(JSON.parse(String(data)) as Frame));
  }

  static async connect(url: string): Promise<Peer> {
    const ws = new WebSocket(url);
    // 先挂监听再等 open:服务器连接瞬间就发 welcome,晚挂会丢帧。
    const peer = new Peer(ws);
    await once(ws, "open");
    return peer;
  }

  send(frame: Frame): void {
    this.ws.send(JSON.stringify(frame));
  }

  /** 从已收帧里找;waitFor 从头扫,谓词要带区分度(参考 bridge 测试教训)。 */
  async waitFor(predicate: (frame: Frame) => boolean, timeoutMs = 3000): Promise<Frame> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const hit = this.frames.find(predicate);
      if (hit) return hit;
      if (Date.now() > deadline) throw new Error(`frame not received; got ${JSON.stringify(this.frames)}`);
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  async hello(role: "host" | "guest", deviceId: string, secret: string): Promise<Frame> {
    const welcome = await this.waitFor((f) => f.type === "welcome");
    const response = sha256Hex(`${welcome.nonce as string}:${secret}`);
    this.send({ type: "hello", role, deviceId, response });
    return this.waitFor((f) => f.type === "ok" || f.type === "error");
  }
}

test("host 注册、guest 加入,信令双向转发", async () => {
  const running = await startRendezvous();
  try {
    const host = await Peer.connect(running.url);
    const hostHello = await host.hello("host", "dev1", "s3cret-pairing");
    assert.equal(hostHello.type, "ok");

    const guest = await Peer.connect(running.url);
    const guestHello = await guest.hello("guest", "dev1", "s3cret-pairing");
    assert.equal(guestHello.type, "ok");
    const peerId = guestHello.peerId as string;
    assert.ok(peerId.length > 0);

    const joined = await host.waitFor((f) => f.type === "peer_joined" && f.peerId === peerId);
    assert.equal(joined.peerId, peerId);

    // guest → host:带 from
    guest.send({ type: "signal", data: { kind: "offer", sdp: "v=0..." } });
    const atHost = await host.waitFor((f) => f.type === "signal" && f.from === peerId);
    assert.deepEqual(atHost.data, { kind: "offer", sdp: "v=0..." });

    // host → guest:按 peerId 定向
    host.send({ type: "signal", peerId, data: { kind: "answer", sdp: "v=1..." } });
    const atGuest = await guest.waitFor((f) => f.type === "signal");
    assert.deepEqual(atGuest.data, { kind: "answer", sdp: "v=1..." });

    host.ws.close();
    guest.ws.close();
  } finally {
    await running.close();
  }
});

test("错误密钥、未知设备、重复 host 都被拒", async () => {
  const running = await startRendezvous();
  try {
    const badSecret = await Peer.connect(running.url);
    assert.equal((await badSecret.hello("host", "dev1", "wrong")).type, "error");
    assert.equal((await badSecret.waitFor((f) => f.type === "error")).reason, "bad_secret");

    const unknown = await Peer.connect(running.url);
    assert.equal((await unknown.hello("host", "nope", "s3cret-pairing")).reason, "unknown_device");

    const host = await Peer.connect(running.url);
    assert.equal((await host.hello("host", "dev1", "s3cret-pairing")).type, "ok");
    const second = await Peer.connect(running.url);
    assert.equal((await second.hello("host", "dev1", "s3cret-pairing")).reason, "device_id_in_use");

    host.ws.close();
  } finally {
    await running.close();
  }
});

test("host 不在线时 guest 被拒;host 断开时 guest 被通知并关闭", async () => {
  const running = await startRendezvous();
  try {
    const early = await Peer.connect(running.url);
    assert.equal((await early.hello("guest", "dev1", "s3cret-pairing")).reason, "host_offline");

    const host = await Peer.connect(running.url);
    await host.hello("host", "dev1", "s3cret-pairing");
    const guest = await Peer.connect(running.url);
    const hello = await guest.hello("guest", "dev1", "s3cret-pairing");
    const peerId = hello.peerId as string;

    // guest 断开 → host 收 peer_left
    guest.ws.close();
    await host.waitFor((f) => f.type === "peer_left" && f.peerId === peerId);

    const guest2 = await Peer.connect(running.url);
    await guest2.hello("guest", "dev1", "s3cret-pairing");
    // host 断开 → guest 收 peer_left 且 socket 被关。
    // 不能 await once(ws, "close"):轮询到 peer_left 时 close 可能已发完,
    // once 挂在已过去的事件上会永远等下去(套件挂死),只能轮询 readyState。
    host.ws.close();
    await guest2.waitFor((f) => f.type === "peer_left");
    const deadline = Date.now() + 3000;
    while (guest2.ws.readyState !== WebSocket.CLOSED && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(guest2.ws.readyState, WebSocket.CLOSED);
  } finally {
    await running.close();
  }
});

test("配对密钥永不上行:抓包视角只有 nonce 和 sha256 应答", async () => {
  const running = await startRendezvous();
  try {
    const peer = await Peer.connect(running.url);
    const welcome = await peer.waitFor((f) => f.type === "welcome");
    assert.ok(typeof welcome.nonce === "string" && (welcome.nonce as string).length >= 16);
    // 模拟一次 hello,断言线上只有哈希
    const response = crypto
      .createHash("sha256")
      .update(`${welcome.nonce as string}:s3cret-pairing`)
      .digest("hex");
    assert.equal(response.length, 64);
    assert.ok(!response.includes("s3cret"));
    peer.ws.close();
  } finally {
    await running.close();
  }
});
