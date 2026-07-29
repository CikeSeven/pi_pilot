import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { RTCPeerConnection, type RTCDataChannel } from "werift";

function sha256Hex(text: string): string {
  return crypto.createHash("sha256").update(text).digest("hex");
}

/// P2P(打洞)主机:bridge 作为 WebRTC host,经信令服与手机交换 SDP/ICE,
/// 在 DataChannel 上跑与 WS 完全相同的 hub 协议。
/// - v6 场景没有 NAT,host 候选即真实地址,iceServers 为空、不需要 STUN。
/// - 信令断连不影响已建立的 DataChannel(P2P 通道不经过信令服),
///   信令服只是"电话簿",掉线后指数退避重连即可。
/// - hub token 在 DataChannel 内校验(首帧 auth),信令服永远见不到它。

const AUTH_TIMEOUT_MS = 10_000;
const RECONNECT_MIN_MS = 2_000;
const RECONNECT_MAX_MS = 60_000;

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

  constructor(
    private readonly channel: RTCDataChannel,
    private readonly pc: RTCPeerConnection,
  ) {
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
    void this.pc.close().catch(() => {});
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
}

export class P2pHost {
  private ws?: WebSocket;
  private readonly peers = new Map<string, RTCPeerConnection>();
  private stopped = false;
  private reconnectTimer?: NodeJS.Timeout;
  private backoffMs = RECONNECT_MIN_MS;
  private nonce?: string;

  constructor(private readonly deps: P2pHostDeps) {}

  start(): void {
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.ws?.close();
    for (const pc of this.peers.values()) void pc.close().catch(() => {});
    this.peers.clear();
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
        this.backoffMs = RECONNECT_MIN_MS;
        this.log(`已在信令服注册为 ${this.deps.deviceId}`);
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
        const pc = this.peers.get(peerId);
        if (pc) {
          this.peers.delete(peerId);
          void pc.close().catch(() => {});
        }
        return;
      }
      default:
        return;
    }
  }

  private sendSignal(peerId: string, data: SignalData): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "signal", peerId, data }));
    }
  }

  private async onSignal(peerId: string, data: SignalData): Promise<void> {
    try {
      if (data.kind === "offer" && typeof data.sdp === "string") {
        // 同一 peerId 重复 offer(重协商/重叫):旧连接作废重来。
        const stale = this.peers.get(peerId);
        if (stale) {
          this.peers.delete(peerId);
          void stale.close().catch(() => {});
        }
        const pc = this.createPeer(peerId);
        await pc.setRemoteDescription({ type: "offer", sdp: data.sdp });
        const answer = await pc.createAnswer();
        // async,必须 await:否则 localDescription 未就位就读、拒绝无人收。
        await pc.setLocalDescription(answer);
        const local = pc.localDescription;
        if (local) this.sendSignal(peerId, { kind: "answer", sdp: local.sdp });
        return;
      }
      if (data.kind === "candidate" && data.candidate) {
        const pc = this.peers.get(peerId);
        await pc?.addIceCandidate(data.candidate as never);
        return;
      }
    } catch (error) {
      this.log(`处理信令失败(${peerId}):${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private createPeer(peerId: string): RTCPeerConnection {
    const pc = new RTCPeerConnection({ iceServers: [] });
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
      this.attachChannel(peerId, pc, channel);
    });
    this.peers.set(peerId, pc);
    return pc;
  }

  /** DataChannel 建立后,第一帧必须是 auth;过了就交给 hub 的正常移动连接路径。 */
  private attachChannel(peerId: string, pc: RTCPeerConnection, channel: RTCDataChannel): void {
    const socket = new DataChannelSocket(channel, pc);
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
        socket.send(JSON.stringify({ type: "bridge_error", error: "unauthorized" }));
        socket.terminate();
        this.log(`P2P 客户端鉴权失败(${peerId})`);
        return;
      }
      this.log(`P2P 客户端接入(${peerId})`);
      this.deps.acceptMobile(socket.asWebSocket(), typeof msg.clientId === "string" ? msg.clientId : null);
    };
    socket.on("message", onFirstMessage);
    socket.on("close", () => {
      clearTimeout(authTimer);
      if (this.peers.get(peerId) === pc) this.peers.delete(peerId);
    });
  }
}

export function randomDeviceId(hostname: string): string {
  const suffix = crypto.randomBytes(3).toString("hex");
  return `${hostname || "desktop"}-${suffix}`;
}
