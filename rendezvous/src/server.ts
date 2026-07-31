import http from "node:http";
import crypto from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { WebSocketServer, WebSocket } from "ws";
import { loadConfig, type RendezvousConfig } from "./config.js";
import { validateDeviceId, validatePairingKey } from "./key_policy.js";

const HELLO_TIMEOUT_MS = 10_000;
const PING_INTERVAL_MS = 30_000;
const MAX_MESSAGE_BYTES = 64 * 1024;

interface Client {
  ws: WebSocket;
  authed: boolean;
  alive: boolean;
  helloTimer: NodeJS.Timeout;
  role?: "host" | "guest";
  deviceId?: string;
  peerId?: string;
}

interface Room {
  host?: Client;
  pairingKeyHash?: Buffer;
  guests: Map<string, Client>;
}

export interface RendezvousHandle {
  httpServer: http.Server;
  close: () => Promise<void>;
}

export function pairingKeyHash(secret: string): Buffer {
  return crypto.createHash("sha256").update(secret).digest();
}

export interface ClientIceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export function buildClientIceServers(
  config: RendezvousConfig,
  nowSeconds = Math.floor(Date.now() / 1_000),
  credentialId = crypto.randomBytes(6).toString("hex"),
): ClientIceServer[] {
  const servers: ClientIceServer[] = [];
  if (config.stunUrls && config.stunUrls.length > 0) {
    servers.push({ urls: [...config.stunUrls] });
  }
  if (config.turn) {
    const username = `${nowSeconds + config.turn.ttlSeconds}:pipilot:${credentialId}`;
    const credential = crypto
      .createHmac("sha1", config.turn.secret)
      .update(username)
      .digest("base64");
    servers.push({ urls: [...config.turn.urls], username, credential });
  }
  return servers;
}

/**
 * 信令服:按 deviceId 分房间,一个 host(桌面 bridge)加多个 guest(手机)。
 * 只转发 signal 帧(SDP/ICE 候选),不解析、不落地。手机和 bridge 在 WSS
 * hello 中携带相同的 pairing key;服务端校验 key 策略并只在房间内保存摘要,
 * 不写入磁盘或日志。TURN 凭据只在握手通过后签发,会话数据仍由 DTLS 端到端加密。
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
    const deviceId = msg.deviceId;
    if (!validateDeviceId(deviceId)) {
      fail(client, "bad_device_id");
      return;
    }
    const secret = msg.secret;
    if (!validatePairingKey(secret)) {
      fail(client, "weak_key");
      return;
    }
    const role = msg.role === "host" ? "host" : msg.role === "guest" ? "guest" : undefined;
    if (!role) {
      fail(client, "bad_role");
      return;
    }
    const keyHash = pairingKeyHash(secret);
    if (role === "host") {
      const room = roomOf(deviceId);
      if (room.host) {
        fail(client, "device_id_in_use");
        return;
      }
      room.host = client;
      room.pairingKeyHash = keyHash;
      client.role = role;
      client.deviceId = deviceId;
      client.authed = true;
      console.log(`[rdv] host 建立房间: ${deviceId}`);
      send(client, { type: "ok", iceServers: buildClientIceServers(config) });
      return;
    }

    const room = rooms.get(deviceId);
    if (!room?.host || !room.pairingKeyHash) {
      fail(client, "host_offline");
      return;
    }
    if (!crypto.timingSafeEqual(room.pairingKeyHash, keyHash)) {
      fail(client, "bad_key");
      return;
    }
    const peerId = crypto.randomBytes(6).toString("hex");
    client.role = role;
    client.deviceId = deviceId;
    client.authed = true;
    client.peerId = peerId;
    room.guests.set(peerId, client);
    console.log(`[rdv] guest 加入房间: ${deviceId} peer=${peerId}`);
    send(client, {
      type: "ok",
      peerId,
      iceServers: buildClientIceServers(config),
    });
    send(room.host, { type: "peer_joined", peerId });
  }

  function onSignal(client: Client, msg: Record<string, unknown>): void {
    if (!client.authed || !client.deviceId) return;
    const room = rooms.get(client.deviceId);
    if (!room) return;
    const kind =
      typeof (msg.data as Record<string, unknown> | undefined)?.kind === "string"
        ? ((msg.data as Record<string, unknown>).kind as string)
        : "?";
    if (client.role === "guest") {
      if (room.host) {
        console.log(`[rdv] 转发 ${client.peerId} → host: ${kind}`);
        send(room.host, { type: "signal", from: client.peerId, data: msg.data });
      }
    } else {
      const peerId = typeof msg.peerId === "string" ? msg.peerId : "";
      const guest = room.guests.get(peerId);
      if (guest) {
        console.log(`[rdv] 转发 host → ${peerId}: ${kind}`);
        send(guest, { type: "signal", data: msg.data });
      }
    }
  }

  wss.on("connection", (ws) => {
    const client: Client = {
      ws,
      authed: false,
      alive: true,
      helloTimer: setTimeout(() => ws.close(4002, "hello timeout"), HELLO_TIMEOUT_MS),
    };
    clients.add(client);
    send(client, { type: "welcome", stunUrls: config.stunUrls ?? [] });
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
