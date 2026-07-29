import http from "node:http";
import crypto from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { WebSocketServer, WebSocket } from "ws";
import { loadConfig, type RendezvousConfig } from "./config.js";

const HELLO_TIMEOUT_MS = 10_000;
const PING_INTERVAL_MS = 30_000;
const MAX_MESSAGE_BYTES = 64 * 1024;

interface Client {
  ws: WebSocket;
  nonce: string;
  authed: boolean;
  alive: boolean;
  helloTimer: NodeJS.Timeout;
  role?: "host" | "guest";
  deviceId?: string;
  peerId?: string;
}

interface Room {
  host?: Client;
  guests: Map<string, Client>;
}

export interface RendezvousHandle {
  httpServer: http.Server;
  close: () => Promise<void>;
}

export function sha256Hex(text: string): string {
  return crypto.createHash("sha256").update(text).digest("hex");
}

/**
 * 信令服:按 deviceId 分房间,一个 host(桌面 bridge)加多个 guest(手机)。
 * 只转发 signal 帧(SDP/ICE 候选),不解析、不落地;配对密钥用
 * sha256(nonce:secret) 挑战-应答校验,明文密钥永不上行。
 */
export function createRendezvous(config: RendezvousConfig): RendezvousHandle {
  const rooms = new Map<string, Room>();
  const clients = new Set<Client>();

  const httpServer = http.createServer((req, res) => {
    if (req.url === "/health") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, rooms: rooms.size }));
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const wss = new WebSocketServer({ server: httpServer, maxPayload: MAX_MESSAGE_BYTES });

  function roomOf(deviceId: string): Room {
    let room = rooms.get(deviceId);
    if (!room) {
      room = { guests: new Map() };
      rooms.set(deviceId, room);
    }
    return room;
  }

  function send(client: Client, frame: Record<string, unknown>): void {
    if (client.ws.readyState === WebSocket.OPEN) client.ws.send(JSON.stringify(frame));
  }

  function fail(client: Client, reason: string): void {
    send(client, { type: "error", reason });
    client.ws.close(4000, reason);
  }

  function cleanup(client: Client): void {
    clearTimeout(client.helloTimer);
    clients.delete(client);
    if (!client.authed || !client.deviceId) return;
    const room = rooms.get(client.deviceId);
    if (!room) return;
    if (client.role === "host") {
      if (room.host === client) room.host = undefined;
      // host 掉了,所有 guest 一并断开,让手机走自己的重连/降级逻辑。
      for (const guest of room.guests.values()) {
        send(guest, { type: "peer_left" });
        guest.ws.close(4001, "host offline");
      }
      room.guests.clear();
    } else if (client.peerId && room.guests.get(client.peerId) === client) {
      room.guests.delete(client.peerId);
      if (room.host) send(room.host, { type: "peer_left", peerId: client.peerId });
    }
    if (!room.host && room.guests.size === 0) rooms.delete(client.deviceId);
  }

  function onHello(client: Client, msg: Record<string, unknown>): void {
    const deviceId = typeof msg.deviceId === "string" ? msg.deviceId : "";
    const secret = config.devices[deviceId];
    if (!secret) {
      fail(client, "unknown_device");
      return;
    }
    const expected = sha256Hex(`${client.nonce}:${secret}`);
    if (msg.response !== expected) {
      fail(client, "bad_secret");
      return;
    }
    const role = msg.role === "host" ? "host" : msg.role === "guest" ? "guest" : undefined;
    if (!role) {
      fail(client, "bad_role");
      return;
    }
    const room = roomOf(deviceId);
    if (role === "host") {
      if (room.host) {
        fail(client, "device_id_in_use");
        return;
      }
      room.host = client;
      client.role = role;
      client.deviceId = deviceId;
      client.authed = true;
      send(client, { type: "ok" });
      return;
    }
    if (!room.host) {
      fail(client, "host_offline");
      return;
    }
    const peerId = crypto.randomBytes(6).toString("hex");
    client.role = role;
    client.deviceId = deviceId;
    client.authed = true;
    client.peerId = peerId;
    room.guests.set(peerId, client);
    send(client, { type: "ok", peerId });
    send(room.host, { type: "peer_joined", peerId });
  }

  function onSignal(client: Client, msg: Record<string, unknown>): void {
    if (!client.authed || !client.deviceId) return;
    const room = rooms.get(client.deviceId);
    if (!room) return;
    if (client.role === "guest") {
      if (room.host) send(room.host, { type: "signal", from: client.peerId, data: msg.data });
    } else {
      const peerId = typeof msg.peerId === "string" ? msg.peerId : "";
      const guest = room.guests.get(peerId);
      if (guest) send(guest, { type: "signal", data: msg.data });
    }
  }

  wss.on("connection", (ws) => {
    const client: Client = {
      ws,
      nonce: crypto.randomBytes(16).toString("hex"),
      authed: false,
      alive: true,
      helloTimer: setTimeout(() => ws.close(4002, "hello timeout"), HELLO_TIMEOUT_MS),
    };
    clients.add(client);
    send(client, { type: "welcome", nonce: client.nonce });
    ws.on("pong", () => {
      client.alive = true;
    });
    ws.on("message", (raw) => {
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(String(raw)) as Record<string, unknown>;
      } catch {
        return;
      }
      if (msg.type === "hello" && !client.authed) {
        clearTimeout(client.helloTimer);
        onHello(client, msg);
        return;
      }
      if (msg.type === "signal") {
        onSignal(client, msg);
      }
    });
    ws.on("close", () => cleanup(client));
    ws.on("error", () => {});
  });

  const pingTimer = setInterval(() => {
    for (const client of clients) {
      if (!client.alive) {
        client.ws.terminate();
        continue;
      }
      client.alive = false;
      client.ws.ping();
    }
  }, PING_INTERVAL_MS);
  pingTimer.unref();

  return {
    httpServer,
    close: () =>
      new Promise((resolve) => {
        clearInterval(pingTimer);
        for (const client of clients) client.ws.terminate();
        wss.close(() => httpServer.close(() => resolve()));
      }),
  };
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (invokedDirectly) {
  const config = loadConfig();
  const handle = createRendezvous(config);
  handle.httpServer.listen(config.port, config.host, () => {
    console.log(`pipilot-rendezvous listening on ${config.host}:${config.port}`);
  });
}
