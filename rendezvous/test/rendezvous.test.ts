import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import crypto from "node:crypto";
import WebSocket from "ws";
import { normalizeStunUrls, normalizeTurnConfig } from "../src/config.js";
import {
  buildClientIceServers,
  createRendezvous,
  type RendezvousHandle,
} from "../src/server.js";
import {
  pairingKeyPolicy,
  validateDeviceId,
  validatePairingKey,
} from "../src/key_policy.js";

interface Running {
  url: string;
  close: () => Promise<void>;
}

const TEST_DEVICE_ID = "dev1";
const TEST_PAIRING_KEY = "S3cret-Key-2026!";

async function startRendezvous(): Promise<Running> {
  const handle: RendezvousHandle = createRendezvous({
    port: 0,
    host: "127.0.0.1",
    stunUrls: ["stun:stun.example.test:3478"],
    turn: {
      urls: ["turn:turn.example.test:3478?transport=udp"],
      secret: "turn-rest-secret-for-tests",
      ttlSeconds: 600,
    },
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
    const peer = new Peer(ws);
    await once(ws, "open");
    return peer;
  }

  send(frame: Frame): void {
    this.ws.send(JSON.stringify(frame));
  }

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
    await this.waitFor((f) => f.type === "welcome");
    this.send({ type: "hello", role, deviceId, secret });
    return this.waitFor((f) => f.type === "ok" || f.type === "error");
  }
}

test("pairing key policy accepts strong ASCII keys and rejects weak inputs", () => {
  assert.equal(validatePairingKey(TEST_PAIRING_KEY), true);
  assert.equal(validatePairingKey("short"), false);
  assert.equal(validatePairingKey("alllowercaseletters"), false);
  assert.equal(validatePairingKey("NO-SPACES-ALLOWED 2026"), false);
  assert.equal(validatePairingKey("A".repeat(pairingKeyPolicy.maxLength + 1)), false);
});

test("device id policy restricts names to safe room identifiers", () => {
  assert.equal(validateDeviceId(TEST_DEVICE_ID), true);
  assert.equal(validateDeviceId("ab"), false);
  assert.equal(validateDeviceId("bad/id"), false);
  assert.equal(validateDeviceId("contains space"), false);
});

test("STUN 配置只接受 stun:地址并去重限量", () => {
  assert.deepEqual(
    normalizeStunUrls([
      " stun:one.example:3478 ",
      "turn:relay.example:3478",
      "stun:one.example:3478",
      42,
      "stun:two.example:3478",
    ]),
    ["stun:one.example:3478", "stun:two.example:3478"],
  );
});

test("TURN 配置严格校验并签发 coturn REST 短期凭据", () => {
  assert.equal(
    normalizeTurnConfig({ urls: ["https://invalid"], secret: "long-enough-secret" }),
    undefined,
  );
  const turn = normalizeTurnConfig({
    urls: [" turn:relay.example:3478?transport=udp ", "turn:relay.example:3478?transport=udp"],
    secret: "long-enough-secret",
    ttlSeconds: 10,
  });
  assert.deepEqual(turn, {
    urls: ["turn:relay.example:3478?transport=udp"],
    secret: "long-enough-secret",
    ttlSeconds: 60,
  });
  const servers = buildClientIceServers(
    {
      port: 0,
      host: "127.0.0.1",
      stunUrls: ["stun:stun.example:3478"],
      turn: {
        urls: ["turn:relay.example:3478?transport=udp"],
        secret: "long-enough-secret",
        ttlSeconds: 600,
      },
    },
    1_000,
    "client-id",
  );
  assert.deepEqual(servers[0], { urls: ["stun:stun.example:3478"] });
  assert.equal(servers[1]?.username, "1600:pipilot:client-id");
  assert.equal(
    servers[1]?.credential,
    crypto
      .createHmac("sha1", "long-enough-secret")
      .update("1600:pipilot:client-id")
      .digest("base64"),
  );
});

test("host 注册、guest 加入,信令双向转发", async () => {
  const running = await startRendezvous();
  try {
    const host = await Peer.connect(running.url);
    const hostHello = await host.hello("host", TEST_DEVICE_ID, TEST_PAIRING_KEY);
    assert.equal(hostHello.type, "ok");
    const hostIceServers = hostHello.iceServers as Array<Record<string, unknown>>;
    assert.deepEqual(hostIceServers[0], { urls: ["stun:stun.example.test:3478"] });
    assert.deepEqual((hostIceServers[1]?.urls as string[] | undefined)?.[0], "turn:turn.example.test:3478?transport=udp");
    assert.match(String(hostIceServers[1]?.username), /^\d+:pipilot:[a-f0-9]{12}$/);
    assert.ok(String(hostIceServers[1]?.credential).length > 0);

    const guest = await Peer.connect(running.url);
    const guestHello = await guest.hello("guest", TEST_DEVICE_ID, TEST_PAIRING_KEY);
    assert.equal(guestHello.type, "ok");
    const peerId = guestHello.peerId as string;
    assert.ok(peerId.length > 0);

    const joined = await host.waitFor((f) => f.type === "peer_joined" && f.peerId === peerId);
    assert.equal(joined.peerId, peerId);

    guest.send({ type: "signal", data: { kind: "offer", sdp: "v=0..." } });
    const atHost = await host.waitFor((f) => f.type === "signal" && f.from === peerId);
    assert.deepEqual(atHost.data, { kind: "offer", sdp: "v=0..." });

    host.send({ type: "signal", peerId, data: { kind: "answer", sdp: "v=1..." } });
    const atGuest = await guest.waitFor((f) => f.type === "signal");
    assert.deepEqual(atGuest.data, { kind: "answer", sdp: "v=1..." });

    host.ws.close();
    guest.ws.close();
  } finally {
    await running.close();
  }
});

test("弱密钥、错误密钥、非法设备名、重复 host 都被拒", async () => {
  const running = await startRendezvous();
  try {
    const weak = await Peer.connect(running.url);
    assert.equal((await weak.hello("host", TEST_DEVICE_ID, "short")).reason, "weak_key");

    const badDevice = await Peer.connect(running.url);
    assert.equal((await badDevice.hello("host", "bad/id", TEST_PAIRING_KEY)).reason, "bad_device_id");

    const host = await Peer.connect(running.url);
    assert.equal((await host.hello("host", TEST_DEVICE_ID, TEST_PAIRING_KEY)).type, "ok");

    const badKey = await Peer.connect(running.url);
    assert.equal((await badKey.hello("guest", TEST_DEVICE_ID, "Wrong-Key-2026!!")).reason, "bad_key");

    const second = await Peer.connect(running.url);
    assert.equal((await second.hello("host", TEST_DEVICE_ID, TEST_PAIRING_KEY)).reason, "device_id_in_use");

    host.ws.close();
  } finally {
    await running.close();
  }
});

test("host 不在线时 guest 被拒;host 断开时 guest 被通知并关闭", async () => {
  const running = await startRendezvous();
  try {
    const early = await Peer.connect(running.url);
    assert.equal((await early.hello("guest", TEST_DEVICE_ID, TEST_PAIRING_KEY)).reason, "host_offline");

    const host = await Peer.connect(running.url);
    await host.hello("host", TEST_DEVICE_ID, TEST_PAIRING_KEY);
    const guest = await Peer.connect(running.url);
    const hello = await guest.hello("guest", TEST_DEVICE_ID, TEST_PAIRING_KEY);
    const peerId = hello.peerId as string;

    guest.ws.close();
    await host.waitFor((f) => f.type === "peer_left" && f.peerId === peerId);

    const guest2 = await Peer.connect(running.url);
    await guest2.hello("guest", TEST_DEVICE_ID, TEST_PAIRING_KEY);
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

test("welcome 不回显 TURN shared secret 或配对 key", async () => {
  const running = await startRendezvous();
  try {
    const peer = await Peer.connect(running.url);
    const welcome = await peer.waitFor((f) => f.type === "welcome");
    assert.deepEqual(welcome.stunUrls, ["stun:stun.example.test:3478"]);
    assert.equal(welcome.iceServers, undefined);
    assert.ok(!JSON.stringify(welcome).includes("turn-rest-secret-for-tests"));
    assert.ok(!JSON.stringify(welcome).includes(TEST_PAIRING_KEY));
    peer.ws.close();
  } finally {
    await running.close();
  }
});
