import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { RTCPeerConnection, type RTCDataChannel } from "werift";

function sha256Hex(text: string): string {
  return crypto.createHash("sha256").update(text).digest("hex");
}

function isLoopbackHostname(hostname: string): boolean {
  const host = hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (host === "localhost" || host === "::1") return true;
  const octets = host.split(".").map(Number);
  return (
    octets.length === 4 &&
    octets[0] === 127 &&
    octets.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)
  );
}

/** 公网信令必须由 TLS 认证;明文 ws 只允许本机测试。 */
export function isAllowedP2pSignalingUrl(value: string): boolean {
  try {
    const url = new URL(value);
    if (!url.hostname || url.username || url.password) return false;
    if (url.protocol === "wss:") return true;
    return url.protocol === "ws:" && isLoopbackHostname(url.hostname);
  } catch {
    return false;
  }
}

export interface RelayIceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export type P2pIceMode = "auto" | "direct" | "relay";

function isTurnUrl(url: string): boolean {
  return url.startsWith("turn:") || url.startsWith("turns:");
}

export function iceServersForMode(
  servers: RelayIceServer[],
  mode: P2pIceMode,
): RelayIceServer[] {
  if (mode === "auto") return servers;
  const filtered: RelayIceServer[] = [];
  for (const server of servers) {
    const urls = server.urls.filter((url) =>
      mode === "relay" ? isTurnUrl(url) : url.startsWith("stun:"),
    );
    if (urls.length === 0) continue;
    filtered.push({
      urls,
      ...(server.username ? { username: server.username } : {}),
      ...(server.credential ? { credential: server.credential } : {}),
    });
  }
  return filtered;
}

const TURN_REFRESH_SAFETY_MS = 60_000;

/** coturn REST 用户名以 epoch 秒开头;提前刷新,避免常驻 host 复用过期凭据。 */
export function turnCredentialRefreshDelay(
  servers: RelayIceServer[],
  nowMs = Date.now(),
): number | undefined {
  let earliestExpiryMs: number | undefined;
  for (const server of servers) {
    if (!server.urls.some(isTurnUrl) || !server.username) continue;
    const expiryText = server.username.split(":", 1)[0];
    if (!expiryText || !/^\d+$/.test(expiryText)) continue;
    const expiryMs = Number(expiryText) * 1_000;
    if (!Number.isSafeInteger(expiryMs)) continue;
    earliestExpiryMs =
      earliestExpiryMs === undefined ? expiryMs : Math.min(earliestExpiryMs, expiryMs);
  }
  if (earliestExpiryMs === undefined) return undefined;
  const remainingMs = earliestExpiryMs - nowMs;
  if (remainingMs <= 0) return 0;
  const safetyMs = Math.min(
    TURN_REFRESH_SAFETY_MS,
    Math.max(1_000, Math.floor(remainingMs / 4)),
  );
  return Math.max(0, remainingMs - safetyMs);
}

export function normalizeIceServers(value: unknown): RelayIceServer[] {
  if (!Array.isArray(value)) return [];
  const servers: RelayIceServer[] = [];
  for (const item of value) {
    if (typeof item !== "object" || item === null) continue;
    const raw = item as Record<string, unknown>;
    const candidates = Array.isArray(raw.urls)
      ? raw.urls
      : typeof raw.urls === "string"
        ? [raw.urls]
        : [];
    const urls = Array.from(
      new Set(
        candidates
          .filter((candidate): candidate is string => typeof candidate === "string")
          .map((candidate) => candidate.trim())
          .filter(
            (candidate) =>
              candidate.length <= 512 &&
              (candidate.startsWith("stun:") ||
                candidate.startsWith("turn:") ||
                candidate.startsWith("turns:")),
          ),
      ),
    ).slice(0, 8);
    if (urls.length === 0) continue;
    const hasTurn = urls.some(
      (url) => url.startsWith("turn:") || url.startsWith("turns:"),
    );
    const username = typeof raw.username === "string" ? raw.username : undefined;
    const credential = typeof raw.credential === "string" ? raw.credential : undefined;
    if (hasTurn && (!username || !credential)) continue;
    servers.push({ urls, ...(username ? { username } : {}), ...(credential ? { credential } : {}) });
    if (servers.length === 4) break;
  }
  return servers;
}

function normalizeLegacyStunUrls(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return Array.from(
    new Set(
      value
        .filter((item): item is string => typeof item === "string")
        .map((item) => item.trim())
        .filter((item) => item.startsWith("stun:") && item.length <= 512),
    ),
  ).slice(0, 4);
}

/// P2P(打洞)主机:bridge 作为 WebRTC host,经信令服与手机交换 SDP/ICE,
/// 在 DataChannel 上跑与 WS 完全相同的 hub 协议。
/// - v6 / 普通 NAT 优先直连;困难 NAT 使用 TURN 转发 DTLS 密文。
/// - 信令断连不影响已建立的 DataChannel(P2P 通道不经过信令服),
///   信令服只是"电话簿",掉线后指数退避重连即可。
/// - hub token 在 DataChannel 内校验(首帧 auth),信令服永远见不到它。

const AUTH_TIMEOUT_MS = 10_000;
const RECONNECT_MIN_MS = 2_000;
const RECONNECT_MAX_MS = 60_000;
const MAX_PENDING_CANDIDATES = 64;

export interface P2pHostDeps {
  rendezvousUrl: string;
  deviceId: string;
  secret: string;
  validateMobileToken: (token: string | undefined) => boolean;
  /** 鉴权通过后把(伪装成 ws 的)DataChannel 交给 hub 的移动连接处理路径。 */
  acceptMobile: (socket: WebSocket, clientId: string | null) => void;
  log?: (line: string) => void;
}

/**
 * 把 RTCDataChannel 伪装成 server.ts 使用的那个 ws.WebSocket 子集:
 * EventEmitter("message"/"close"/"pong")、send、close、terminate、ping、
 * readyState、bufferedAmount。协议代码零改动,只有这里知道下面是 SCTP。
 */
export class DataChannelSocket extends EventEmitter {
  private closed = false;

  constructor(private readonly channel: RTCDataChannel) {
    super();
    channel.onMessage.subscribe((data) => {
      // server.ts 的处理器对入站做 data.toString(),与 ws 的 Buffer 行为对齐。
      this.emit("message", typeof data === "string" ? Buffer.from(data) : data);
    });
    const onClosed = () => {
      if (this.closed) return;
      this.closed = true;
      this.emit("close", 1000, Buffer.from(""));
    };
    channel.stateChanged.subscribe((state) => {
      if (state === "closed" || state === "closing") onClosed();
    });
    channel.onclose = onClosed;
  }

  get readyState(): number {
    if (this.closed) return WebSocket.CLOSED;
    return this.channel.readyState === "open" ? WebSocket.OPEN : WebSocket.CONNECTING;
  }

  get bufferedAmount(): number {
    return this.channel.bufferedAmount;
  }

  send(data: string): void {
    if (this.closed || this.channel.readyState !== "open") return;
    try {
      this.channel.send(data);
    } catch {
      // 对端已离开,close 事件会随后收拾。
    }
  }

  /** 给可靠 DataChannel 留出把最后一帧交付给 SCTP 的时间,再强制断开。 */
  sendThenTerminate(data: string, graceMs = 500): void {
    this.send(data);
    const timer = setTimeout(() => this.terminate(), graceMs);
    timer.unref();
  }

  ping(): void {
    // SCTP 自带心跳与断链检测;通道开着就视为活着,喂饱 hub 的 10s 活性检查。
    if (this.readyState === WebSocket.OPEN) queueMicrotask(() => this.emit("pong"));
  }

  close(code = 1000, reason?: string): void {
    this.shutdown(code, reason ?? "");
  }

  terminate(): void {
    this.shutdown(1001, "terminated");
  }

  private shutdown(code: number, reason: string): void {
    if (this.closed) return;
    this.closed = true;
    try {
      this.channel.close();
    } catch {}
    this.emit("close", code, Buffer.from(reason));
  }

  asWebSocket(): WebSocket {
    return this as unknown as WebSocket;
  }
}

interface SignalData {
  kind?: string;
  sdp?: string;
  candidate?: unknown;
  mode?: string;
  message?: string;
}

interface P2pPeerSession {
  pc: RTCPeerConnection;
  close: () => Promise<void>;
}

export class P2pHost {
  private ws?: WebSocket;
  private readonly peers = new Map<string, P2pPeerSession>();
  private readonly pendingCandidatesByPeer = new Map<string, unknown[]>();
  private stopped = false;
  private reconnectTimer?: NodeJS.Timeout;
  private credentialRefreshTimer?: NodeJS.Timeout;
  private backoffMs = RECONNECT_MIN_MS;
  private nonce?: string;
  private iceServers: RelayIceServer[] = [];

  constructor(private readonly deps: P2pHostDeps) {}

  start(): void {
    if (!isAllowedP2pSignalingUrl(this.deps.rendezvousUrl)) {
      this.log("拒绝不安全的 P2P 信令地址:公网必须使用 wss://");
      return;
    }
    this.connect();
  }

  get activePeerCount(): number {
    return this.peers.size;
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.credentialRefreshTimer) clearTimeout(this.credentialRefreshTimer);
    this.ws?.close();
    for (const peer of [...this.peers.values()]) void peer.close();
    this.pendingCandidatesByPeer.clear();
  }

  private log(line: string): void {
    this.deps.log?.(line);
  }

  private connect(): void {
    if (this.stopped) return;
    const ws = new WebSocket(this.deps.rendezvousUrl);
    this.ws = ws;
    ws.on("message", (data) => {
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(data.toString()) as Record<string, unknown>;
      } catch {
        return;
      }
      this.onRendezvousMessage(ws, msg);
    });
    ws.on("close", () => {
      if (this.ws !== ws) return;
      this.ws = undefined;
      if (this.credentialRefreshTimer) {
        clearTimeout(this.credentialRefreshTimer);
        this.credentialRefreshTimer = undefined;
      }
      // 信令断开不影响已建立的 P2P 通道,只影响新手机叫进来。退避重连。
      if (this.stopped) return;
      this.log(`信令服连接断开,${this.backoffMs / 1000}s 后重连`);
      this.reconnectTimer = setTimeout(() => {
        this.backoffMs = Math.min(this.backoffMs * 2, RECONNECT_MAX_MS);
        this.connect();
      }, this.backoffMs);
      this.reconnectTimer.unref();
    });
    ws.on("error", () => {});
  }

  private onRendezvousMessage(ws: WebSocket, msg: Record<string, unknown>): void {
    switch (msg.type) {
      case "welcome": {
        this.nonce = String(msg.nonce ?? "");
        const legacyStunUrls = normalizeLegacyStunUrls(msg.stunUrls);
        this.iceServers = legacyStunUrls.length > 0 ? [{ urls: legacyStunUrls }] : [];
        ws.send(
          JSON.stringify({
            type: "hello",
            role: "host",
            deviceId: this.deps.deviceId,
            response: sha256Hex(`${this.nonce}:${this.deps.secret}`),
          }),
        );
        return;
      }
      case "ok": {
        const authenticatedServers = normalizeIceServers(msg.iceServers);
        if (authenticatedServers.length > 0) this.iceServers = authenticatedServers;
        this.backoffMs = RECONNECT_MIN_MS;
        const hasTurn = this.iceServers.some((server) =>
          server.urls.some((url) => url.startsWith("turn:") || url.startsWith("turns:")),
        );
        this.log(
          `已在信令服注册为 ${this.deps.deviceId},ICE=${this.iceServers.length},TURN=${hasTurn ? "on" : "off"}`,
        );
        this.armCredentialRefresh(ws);
        return;
      }
      case "error": {
        this.log(`信令服拒绝:${String(msg.reason ?? "unknown")}`);
        ws.close();
        return;
      }
      case "signal": {
        const from = typeof msg.from === "string" ? msg.from : "";
        if (from) void this.onSignal(from, (msg.data ?? {}) as SignalData);
        return;
      }
      case "peer_left": {
        const peerId = typeof msg.peerId === "string" ? msg.peerId : "";
        this.pendingCandidatesByPeer.delete(peerId);
        const peer = this.peers.get(peerId);
        if (peer) void peer.close();
        return;
      }
      default:
        return;
    }
  }

  private armCredentialRefresh(ws: WebSocket): void {
    if (this.credentialRefreshTimer) clearTimeout(this.credentialRefreshTimer);
    const delay = turnCredentialRefreshDelay(this.iceServers);
    if (delay === undefined) {
      this.credentialRefreshTimer = undefined;
      return;
    }
    this.credentialRefreshTimer = setTimeout(() => {
      this.credentialRefreshTimer = undefined;
      if (this.ws !== ws || ws.readyState !== WebSocket.OPEN) return;
      this.log("TURN 凭据即将到期,刷新信令认证");
      ws.close(1000, "refresh TURN credentials");
    }, delay);
    this.credentialRefreshTimer.unref();
  }

  private sendSignal(peerId: string, data: SignalData): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "signal", peerId, data }));
    }
  }

  private async onSignal(peerId: string, data: SignalData): Promise<void> {
    try {
      if (data.kind === "client_error") {
        const mode = data.mode === "relay" ? "relay" : "direct";
        const message =
          typeof data.message === "string"
            ? data.message.replace(/[\r\n]+/g, " ").slice(0, 500)
            : "unknown";
        this.log(`手机 WebRTC 错误(${peerId},${mode}):${message}`);
        return;
      }
      if (data.kind === "offer" && typeof data.sdp === "string") {
        // 同一 peerId 重复 offer(重协商/重叫):旧连接作废重来。
        const stale = this.peers.get(peerId);
        if (stale) void stale.close();
        const mode: P2pIceMode =
          data.mode === "direct" || data.mode === "relay" ? data.mode : "auto";
        const peer = this.createPeer(peerId, mode);
        const pc = peer.pc;
        try {
          await pc.setRemoteDescription({ type: "offer", sdp: data.sdp });
          const pendingCandidates = this.pendingCandidatesByPeer.get(peerId) ?? [];
          this.pendingCandidatesByPeer.delete(peerId);
          for (const candidate of pendingCandidates) {
            await pc.addIceCandidate(candidate as never);
          }
          const answer = await pc.createAnswer();
          // async,必须 await:否则 localDescription 未就位就读、拒绝无人收。
          await pc.setLocalDescription(answer);
          const local = pc.localDescription;
          if (local) this.sendSignal(peerId, { kind: "answer", sdp: local.sdp });
        } catch (error) {
          await peer.close();
          throw error;
        }
        return;
      }
      if (data.kind === "candidate" && data.candidate) {
        const peer = this.peers.get(peerId);
        if (peer) {
          await peer.pc.addIceCandidate(data.candidate as never);
        } else {
          const pending = this.pendingCandidatesByPeer.get(peerId) ?? [];
          if (pending.length < MAX_PENDING_CANDIDATES) {
            pending.push(data.candidate);
            this.pendingCandidatesByPeer.set(peerId, pending);
          }
        }
        return;
      }
    } catch (error) {
      this.log(`处理信令失败(${peerId}):${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private createPeer(peerId: string, mode: P2pIceMode): P2pPeerSession {
    const pc = new RTCPeerConnection({
      iceServers: iceServersForMode(this.iceServers, mode),
      ...(mode === "relay" ? { iceTransportPolicy: "relay" as const } : {}),
    });
    let closePromise: Promise<void> | undefined;
    const peer: P2pPeerSession = {
      pc,
      close: () => {
        if (closePromise) return closePromise;
        if (this.peers.get(peerId) === peer) this.peers.delete(peerId);
        this.pendingCandidatesByPeer.delete(peerId);
        // 先保存 Promise 再调用 pc.close(),避免 DataChannel 的同步 close 回调重入。
        closePromise = Promise.resolve()
          .then(() => pc.close())
          .catch(() => {})
          .then(() => this.log(`PeerConnection 已关闭(${peerId})`));
        return closePromise;
      },
    };
    pc.onIceCandidate.subscribe((candidate) => {
      if (!candidate) return;
      this.sendSignal(peerId, {
        kind: "candidate",
        candidate: {
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
          usernameFragment: candidate.usernameFragment,
        },
      });
    });
    pc.onDataChannel.subscribe((channel) => {
      if (channel.label !== "hub") return;
      this.attachChannel(peerId, peer, channel);
    });
    this.peers.set(peerId, peer);
    return peer;
  }

  /** DataChannel 建立后,第一帧必须是 auth;过了就交给 hub 的正常移动连接路径。 */
  private attachChannel(
    peerId: string,
    peer: P2pPeerSession,
    channel: RTCDataChannel,
  ): void {
    this.log(`DataChannel 已开(${peerId})`);
    const socket = new DataChannelSocket(channel);
    const authTimer = setTimeout(() => socket.terminate(), AUTH_TIMEOUT_MS);
    authTimer.unref();
    const onFirstMessage = (data: Buffer) => {
      socket.off("message", onFirstMessage);
      clearTimeout(authTimer);
      let msg: { type?: string; token?: string; clientId?: string };
      try {
        msg = JSON.parse(data.toString()) as typeof msg;
      } catch {
        socket.terminate();
        return;
      }
      if (msg.type !== "auth" || !this.deps.validateMobileToken(msg.token)) {
        socket.sendThenTerminate(JSON.stringify({ type: "bridge_error", error: "unauthorized" }));
        this.log(`P2P 客户端鉴权失败(${peerId})`);
        return;
      }
      this.log(`P2P 客户端接入(${peerId})`);
      this.deps.acceptMobile(socket.asWebSocket(), typeof msg.clientId === "string" ? msg.clientId : null);
    };
    socket.on("message", onFirstMessage);
    socket.on("close", () => {
      clearTimeout(authTimer);
      void peer.close();
    });
  }
}

export function randomDeviceId(hostname: string): string {
  const suffix = crypto.randomBytes(3).toString("hex");
  return `${hostname || "desktop"}-${suffix}`;
}
