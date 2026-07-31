import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { RTCPeerConnection, type RTCDataChannel } from "werift";
import {
  classifyFrame,
  CreditController,
  P2P_BULK_QUEUE_MAX_BYTES,
  P2P_NO_PROGRESS_CLOSE_MS,
  type P2pClass,
} from "./p2p_transport.js";
import {
  encodeP2pFrames,
  P2P_CHUNK_CAPABILITY,
  P2pChunkDecoder,
} from "./p2p_chunking.js";
import {
  decodeFrameV2,
  encodeFrameV2,
  P2P_CHUNK_V2_CAPABILITY,
  P2P_FRAME_V2_TYPE,
} from "./p2p_frame_v2.js";
import {
  type EncodedTransfer,
  encodeTransferV2,
  TransferRetainedStore,
  TransferV2Assembler,
  V2_DIRECT_BYTES,
  V2_MAX_NACK_PAGES,
} from "./p2p_transfer_v2.js";
import { isValidP2pDeviceId, isValidP2pPairingKey } from "./p2p_key_policy.js";
import {
  isAllowedP2pSignalingUrl,
  normalizeP2pSignalingUrl,
} from "./p2p_signaling_url.js";

export {
  isAllowedP2pSignalingUrl,
  normalizeP2pSignalingUrl,
} from "./p2p_signaling_url.js";

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

/// chunk-v2 owner 状态桶的主动回收周期。retained/assembler 的 sweep 原本只在
/// 收发帧时触发,空闲期已过期的状态会一直占着预算,所以要有定时入口。
const OWNER_SWEEP_MS = 10_000;
/// 同时保留的 owner 状态桶上限:否则伪造 clientId 就能无限新建桶。
const MAX_OWNER_STORES = 8;
/// 桶自身空闲多久后可回收(此时其 retained/assembler 必须都已空)。
const OWNER_STORE_IDLE_MS = 5 * 60_000;

export interface P2pHostDeps {
  rendezvousUrl: string;
  deviceId: string;
  secret: string;
  validateMobileToken: (token: string | undefined) => boolean;
  /** 鉴权通过后把(伪装成 ws 的)DataChannel 交给 hub 的移动连接处理路径。 */
  acceptMobile: (socket: WebSocket, clientId: string | null, caps?: readonly string[]) => void;
  log?: (line: string) => void;
}

/**
 * 把 RTCDataChannel 伪装成 server.ts 使用的那个 ws.WebSocket 子集:
 * EventEmitter("message"/"close"/"pong")、send、close、terminate、ping、
 * readyState、bufferedAmount。协议代码零改动,只有这里知道下面是 SCTP。
 */
export class DataChannelSocket extends EventEmitter {
  private closed = false;
  private chunkingEnabled = false;
  /// chunk-v2:二进制分页+gzip+NACK 重发+断线续传。retained/assembler
  /// 由 P2pHost 持有(跨 socket 共享),重连后新 socket 才能凭 transferId
  /// 应答续传 NACK;v1 路径原样保留作能力回退。
  private chunkingV2Enabled = false;
  private retainedStore?: TransferRetainedStore;
  private assembler?: TransferV2Assembler;
  private readonly decoder = new P2pChunkDecoder();
  /// 三级发送队列:control(ping/pong/ack)> interactive(≤8KB 响应/小广播)
  /// > bulk(分片/大响应/流式事件)。分片按 id/index 重组,类别间交错安全。
  /// frame 为 string(v1/文本)或 Buffer(v2 二进制线帧)。
  private readonly queues: Record<P2pClass, Array<{ frame: string | Buffer; bytes: number }>> = {
    control: [],
    interactive: [],
    bulk: [],
  };
  private queuedBytes = 0;
  private interactiveBytes = 0;
  private pumping = false;
  /// 自适应在飞信用:慢链路收缩信用,控制/交互帧前方最多 ~0.4s+1 片 bulk。
  private readonly credit = new CreditController();
  onLog?: (line: string) => void;

  constructor(private readonly channel: RTCDataChannel) {
    super();
    channel.bufferedAmountLowThreshold = 0;
    channel.onMessage.subscribe((data) => {
      if (typeof data !== "string") {
        this.onBinaryFrame(data);
        return;
      }
      const decoded = this.decoder.add(data);
      if (decoded === undefined) return;
      // 手机对 bridge_ping 的应答是应用层帧:在 socket 层拦截转成 "pong" 事件
      // (喂饱 hub 的活性检查),不再往 hub 协议路径上送。
      if (decoded.includes('"bridge_pong"')) {
        try {
          const parsed = JSON.parse(decoded) as { type?: string };
          if (parsed.type === "bridge_pong") {
            this.emit("pong");
            return;
          }
        } catch {
          // 解析失败按普通消息处理。
        }
      }
      this.emit("message", Buffer.from(decoded));
    });
    const onClosed = () => {
      if (this.closed) return;
      this.closed = true;
      this.decoder.close();
      this.queues.control.length = 0;
      this.queues.interactive.length = 0;
      this.queues.bulk.length = 0;
      this.queuedBytes = 0;
      this.interactiveBytes = 0;
      // DataChannel 没有 close code 概念:远端主动断开一律记 1006(异常关闭),
      // 与本地 shutdown 的语义码区分开,日志才看得出连接死在哪一侧。
      this.emit("close", 1006, Buffer.from("remote closed"));
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
    return this.channel.bufferedAmount + this.queuedBytes;
  }

  get supportsChunking(): boolean {
    return this.chunkingEnabled;
  }

  /** Q1(交互)应用层排队字节数:server 的准入控制据此在执行前拒答。 */
  get interactiveQueuedBytes(): number {
    return this.interactiveBytes;
  }

  enableChunking(): void {
    this.chunkingEnabled = true;
  }

  /// 启用 chunk-v2。retained/assembler 由 P2pHost 持有并跨 socket 共享:
  /// 重连后新 socket 仍能凭 transferId 应答续传 NACK。
  enableChunkingV2(
    retained: TransferRetainedStore,
    assembler: TransferV2Assembler,
  ): void {
    this.chunkingEnabled = true;
    this.chunkingV2Enabled = true;
    this.retainedStore = retained;
    this.assembler = assembler;
  }

  /// 入站二进制帧 = chunk-v2。ACK/NACK 在 socket 层处理(发送方语义),
  /// BEGIN/DATA/DONE/ABORT 喂重组器;交付的 JSON 走与 v1 相同的 message 事件。
  private onBinaryFrame(buffer: Buffer): void {
    let frame;
    try {
      frame = decodeFrameV2(buffer);
    } catch {
      return;
    }
    const transferIdHex = frame.transferId.toString("hex");
    if (frame.type === P2P_FRAME_V2_TYPE.ack) {
      this.retainedStore?.ack(transferIdHex);
      return;
    }
    if (frame.type === P2P_FRAME_V2_TYPE.nack) {
      // NACK 去重 + 限页数:恶意或故障对端可以发一份塞满重复索引的 missing 表,
      // 逐个 push 会把留存页放大成几十倍重发量(放大攻击)。去重后按页数硬上限截断,
      // 并且重发帧仍要走 bulk 原子准入,不得绕过总积压检查。
      const rawMissing = Array.isArray(frame.meta?.missing)
        ? (frame.meta.missing as unknown[])
        : [];
      const seen = new Set<number>();
      for (const value of rawMissing) {
        if (!Number.isInteger(value)) continue;
        const index = value as number;
        if (index < 0 || index >= frame.pageCount) continue;
        seen.add(index);
        if (seen.size >= V2_MAX_NACK_PAGES) break;
      }
      const missing = [...seen].sort((a, b) => a - b);
      if (missing.length !== rawMissing.length) {
        this.onLog?.(
          `NACK missing 表已规整:${rawMissing.length} → ${missing.length}(去重/越界/限页)`,
        );
      }
      const resume = frame.meta?.resume === true;
      const resends = this.retainedStore?.resendFrames(
        transferIdHex,
        missing,
        resume,
      );
      if (!resends) {
        // 未知/已过期 transfer:回 ABORT 让接收方别傻等(走重同步)。
        this.sendBinaryControl(
          encodeFrameV2({
            type: P2P_FRAME_V2_TYPE.abort,
            transferId: frame.transferId,
            pageIndex: 0,
            pageCount: frame.pageCount,
            meta: { reason: "unknown transfer" },
          }),
        );
        return;
      }
      // 重发同样走 bulk 原子准入:队列装不下就整批拒绝,不留半条 transfer。
      if (!this.admitFrames(resends, "bulk")) {
        this.onLog?.(`NACK 重发 ${resends.length} 帧被 bulk 准入拒绝`);
        return;
      }
      void this.pumpSendQueue();
      return;
    }
    if (!this.assembler) return;
    const result = this.assembler.onFrame(buffer);
    for (const reply of result.replies) this.sendBinaryControl(reply);
    if (result.message !== undefined) {
      this.emit("message", Buffer.from(result.message, "utf8"));
    }
  }

  /// ACK/NACK/ABORT 回执:极小帧直发(控制语义,不挤 bulk 队列)。
  private sendBinaryControl(frame: Buffer): void {
    if (this.closed || this.channel.readyState !== "open") return;
    try {
      this.channel.send(frame);
    } catch {
      this.shutdown(1011, "p2p send failed");
    }
  }

  private enqueueFrame(frame: string | Buffer, cls: P2pClass): void {
    const bytes = typeof frame === "string" ? Buffer.byteLength(frame) : frame.length;
    this.queues[cls].push({ frame, bytes });
    this.queuedBytes += bytes;
    if (cls === "interactive") this.interactiveBytes += bytes;
    else if (cls === "bulk") this.bulkQueuedBytes += bytes;
  }

  /// 整条逻辑消息的原子准入。
  ///
  /// 逐帧丢弃会留下"半条 transfer":丢掉 DONE 时接收方连 NACK 都不会发(它不知道
  /// 该等多少页),只能干等到超时;丢掉中间页又会触发一轮无谓的 NACK 放大。所以
  /// 容量判定必须在入队前对整条消息做一次,要么全进要么全不进。
  ///
  /// 返回 false 表示这条消息被拒,调用方必须把失败传播出去(而不是假装发出去了)。
  private admitFrames(frames: readonly (string | Buffer)[], cls: P2pClass): boolean {
    if (cls !== "bulk") {
      for (const frame of frames) this.enqueueFrame(frame, cls);
      return true;
    }
    let total = 0;
    for (const frame of frames) {
      total += typeof frame === "string" ? Buffer.byteLength(frame) : frame.length;
    }
    if (this.bulkQueuedBytes + total > P2P_BULK_QUEUE_MAX_BYTES) {
      this.bulkRejectedCount++;
      this.onLog?.(
        `bulk 队列已占 ${this.bulkQueuedBytes}B,整条消息 ${total}B 会超 ${P2P_BULK_QUEUE_MAX_BYTES}B,整条拒绝(累计 ${this.bulkRejectedCount} 次)`,
      );
      return false;
    }
    for (const frame of frames) this.enqueueFrame(frame, cls);
    return true;
  }

  /// bulk 整条拒绝的累计次数:server 的可观测计数,用于确认背压是否真的发生过。
  private bulkRejectedCount = 0;

  get bulkRejected(): number {
    return this.bulkRejectedCount;
  }

  get bulkQueuedByteCount(): number {
    return this.bulkQueuedBytes;
  }

  send(data: string): void {
    void this.trySend(data);
  }

  /// 本次 trySend 被拒是因为载荷本身过大(而非通道故障)。
  /// 调用方据此把它当成"这条响应发不出去",而不是"连接坏了"。
  private lastRejectOversized = false;

  /// 上一次 trySend 返回 false 是否因为载荷过大。
  get lastSendRejectedOversized(): boolean {
    return this.lastRejectOversized;
  }

  private oversizedRejects = 0;
  get oversizedRejectCount(): number {
    return this.oversizedRejects;
  }

  /// 返回 false = 这条消息没有被接受(载荷过大/队列满/通道已关),
  /// 调用方必须传播失败。
  trySend(data: string): boolean {
    this.lastRejectOversized = false;
    if (this.closed || this.channel.readyState !== "open") return false;

    // 编码单独 try:载荷过大是**这条消息**的问题,不是通道的问题。
    //
    // 真机实测的故障链:从手机打开 50MB 的无头会话 → get_entries 把整个会话
    // 原样返回 → encodeTransferV2 抛 "P2P message exceeds 16MB" → 旧代码与
    // 通道故障共用一个 catch,直接 shutdown(1011) → 连超时响应都发不回去 →
    // 手机重连 → 再次请求 → 循环。表现就是「连上就断,永远打不开」。
    const cls = classifyFrame(data);
    const useV2 =
      this.chunkingV2Enabled && Buffer.byteLength(data) > V2_DIRECT_BYTES;
    let transfer: EncodedTransfer | undefined;
    let frames: (string | Buffer)[];
    try {
      frames = useV2
        ? (() => {
            transfer = encodeTransferV2(data);
            return transfer.frames;
          })()
        : this.chunkingEnabled
          ? encodeP2pFrames(data)
          : [data];
    } catch (error) {
      this.lastRejectOversized = true;
      this.oversizedRejects++;
      this.onLog?.(
        `[p2p] 载荷过大被拒(不关闭通道) bytes=${Buffer.byteLength(data)} ` +
          `累计=${this.oversizedRejects} 原因=${
            error instanceof Error ? error.message : String(error)
          }`,
      );
      return false;
    }

    try {

      // 先做准入再留存:被拒的 transfer 不能留在 retained store 里,
      // 否则接收方永远不会为它发 NACK,那份留存就是纯泄漏。
      const idle =
        !this.pumping &&
        this.queues.control.length === 0 &&
        this.queues.interactive.length === 0 &&
        this.queues.bulk.length === 0;

      if (idle && cls !== "bulk") {
        // 空转时首帧同步直发(保持可预期的首片语义,也省一跳延迟)。
        // 仅限非 bulk:bulk 必须整条准入,不能先发一片再判容量。
        this.channel.send(frames[0]!);
        this.credit.noteSent();
        if (frames.length > 1) {
          if (!this.admitFrames(frames.slice(1), cls)) return false;
          void this.pumpSendQueue();
        }
        if (transfer) this.retainedStore?.add(transfer);
        return true;
      }

      if (!this.admitFrames(frames, cls)) return false;
      if (transfer) this.retainedStore?.add(transfer);
      void this.pumpSendQueue();
      return true;
    } catch {
      this.shutdown(1011, "p2p send failed");
      return false;
    }
  }

  /** control 类(ping/pong/ack):插到任何排队中的交互/批量帧之前。 */
  sendPriority(data: string): void {
    if (this.closed || this.channel.readyState !== "open") return;
    try {
      const bytes = Buffer.byteLength(data);
      this.queues.control.push({ frame: data, bytes });
      this.queuedBytes += bytes;
      void this.pumpSendQueue();
    } catch {
      this.shutdown(1011, "p2p send failed");
    }
  }

  private bulkQueuedBytes = 0;

  private async pumpSendQueue(): Promise<void> {
    if (this.pumping || this.closed) return;
    this.pumping = true;
    try {
      for (;;) {
        if (this.closed || this.channel.readyState !== "open") return;
        let next: { frame: string | Buffer; bytes: number } | undefined;
        let cls: P2pClass;
        if (this.queues.control.length > 0) {
          next = this.queues.control.shift();
          cls = "control";
        } else if (this.queues.interactive.length > 0) {
          next = this.queues.interactive.shift();
          cls = "interactive";
        } else {
          next = this.queues.bulk.shift();
          cls = "bulk";
        }
        if (!next) return;
        this.queuedBytes = Math.max(0, this.queuedBytes - next.bytes);
        if (cls === "interactive") {
          this.interactiveBytes = Math.max(0, this.interactiveBytes - next.bytes);
        } else if (cls === "bulk") {
          this.bulkQueuedBytes = Math.max(0, this.bulkQueuedBytes - next.bytes);
        }
        // 信用制流控:只在 SCTP 缓冲超过信用目标时等它回落,
        // 不再逐片等 0(那会把吞吐钉死在 48KB/RTT)。
        for (;;) {
          const buffered = this.channel.bufferedAmount;
          this.credit.sample(buffered);
          if (buffered <= this.credit.target) break;
          if (this.closed || this.channel.readyState !== "open") {
            throw new Error("DataChannel closed while sending");
          }
          if (this.credit.noProgressMs > P2P_NO_PROGRESS_CLOSE_MS) {
            // 背压的终点是停泵;只有连续无推进才判定链路死亡。
            this.shutdown(4000, "no send progress");
            return;
          }
          await new Promise<void>((resolve) => setTimeout(resolve, 5));
        }
        this.channel.send(next.frame);
        this.credit.noteSent();
        // 帧间让出一拍事件循环:让后到的 control/interactive 帧有机会
        // 插在剩余 bulk 分片之前(分片按 id/index 重组,交错安全),
        // 也让 bufferedAmount 的异步回落能被采样到。
        await new Promise<void>((resolve) => setImmediate(resolve));
      }
    } catch {
      this.shutdown(1011, "p2p send failed");
    } finally {
      this.pumping = false;
      if (
        !this.closed &&
        (this.queues.control.length > 0 ||
          this.queues.interactive.length > 0 ||
          this.queues.bulk.length > 0)
      ) {
        void this.pumpSendQueue();
      }
    }
  }

  /** 给可靠 DataChannel 留出把最后一帧交付给 SCTP 的时间,再强制断开。 */
  sendThenTerminate(data: string, graceMs = 500): void {
    this.send(data);
    const timer = setTimeout(() => this.terminate(), graceMs);
    timer.unref();
  }

  ping(): void {
    // 真 ping:经通道发应用层 bridge_ping(优先队列),等手机对称回 bridge_pong。
    // 本地自答 pong 会让 hub 的 10s 活性扫描对 P2P 完全失效(半开连接永远活着)。
    if (this.readyState !== WebSocket.OPEN) return;
    this.sendPriority(
      JSON.stringify({ type: "bridge_ping", t: Date.now(), echo: `hub-${Date.now()}` }),
    );
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
    this.decoder.close();
    this.queues.control.length = 0;
    this.queues.interactive.length = 0;
    this.queues.bulk.length = 0;
    this.queuedBytes = 0;
    this.interactiveBytes = 0;
    this.bulkQueuedBytes = 0;
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
  /** DataChannel 是否已建立。已建链的连接不再依赖信令,peer_left 不杀。 */
  channelOpen: boolean;
  close: () => Promise<void>;
}

export class P2pHost {
  private ws?: WebSocket;
  private readonly peers = new Map<string, P2pPeerSession>();
  private readonly pendingCandidatesByPeer = new Map<string, unknown[]>();
  /// 每 peerId 一条信号串行链。trickle ICE 的 offer 与紧跟的 candidate 是两帧
  /// 独立信号,若各自 `void onSignal(...)` 并发跑,offer 分支会先把 peer 注册
  /// 进 `peers`,然后才 await `setRemoteDescription`——落在这个窗口的 candidate
  /// 看到 peer 已存在,会直接 `addIceCandidate`,既不进 pre-offer 缓冲也可能报错丢弃。
  /// 后果是同一网络时成时败。Flutter 端已在 GuestSignaling 里串行化,host 必须对称。
  private readonly signalChains = new Map<string, Promise<void>>();
  /// 诊断计数:peer 已存在但 remote description 尚未就位时到达的候选数。
  /// 信号已按 peer 串行化后这个值应恒为 0;非 0 就说明串行化被绕过了。
  private candidatesBufferedAwaitingRemote = 0;
  /// chunk-v2 的发送方留存与接收方重组:**按认证 owner(clientId)隔离**。
  ///
  /// 原实现是 host 级单例,所有 guest socket 共享同一份 retained/assembler:
  /// transferId 只有 16 字节随机数,不带 owner 身份,于是 A 手机的 ACK/NACK 能
  /// 命中 B 手机的留存,B 的残留分页也可能被 A 的 DONE 触发交付 —— 多设备
  /// 同时连接时会串台。按 owner 分桶后,每个 clientId 只能看见自己的状态。
  ///
  /// 跨重连续传仍然可用(同一 clientId 重连命中同一桶),但跨设备不再可见。
  private readonly ownerStores = new Map<
    string,
    { retained: TransferRetainedStore; assembler: TransferV2Assembler; at: number }
  >();
  private sweepTimer?: NodeJS.Timeout;
  private stopped = false;
  private reconnectTimer?: NodeJS.Timeout;
  private credentialRefreshTimer?: NodeJS.Timeout;
  private backoffMs = RECONNECT_MIN_MS;
  private iceServers: RelayIceServer[] = [];
  private readonly rendezvousUrl: string;

  constructor(private readonly deps: P2pHostDeps) {
    this.rendezvousUrl = normalizeP2pSignalingUrl(deps.rendezvousUrl);
  }

  start(): boolean {
    if (!isAllowedP2pSignalingUrl(this.rendezvousUrl)) {
      this.log("拒绝不安全的 P2P 信令地址:公网必须使用 wss://");
      return false;
    }
    if (!isValidP2pDeviceId(this.deps.deviceId)) {
      this.log("拒绝无效的 P2P 设备名:需为 3-64 位英文字母、数字、点、下划线或连字符");
      return false;
    }
    if (!isValidP2pPairingKey(this.deps.secret)) {
      this.log("拒绝无效的 P2P 配对 Key:需为 16-128 位可打印 ASCII 且至少包含三类字符");
      return false;
    }
    // 主动到期回收:retained/assembler 的 sweep 原本只在收发帧时触发,
    // 空闲期(没有新 transfer)已过期的状态会一直占着几十 MB 预算。
    this.sweepTimer = setInterval(() => this.sweepOwnerStores(), OWNER_SWEEP_MS);
    this.sweepTimer.unref();
    this.connect();
    return true;
  }

  /// 取得该 owner 的 chunk-v2 状态桶(不存在则创建)。
  private ownerStore(clientId: string | null): {
    retained: TransferRetainedStore;
    assembler: TransferV2Assembler;
  } {
    // clientId 缺失时退化为按 peer 隔离的匿名桶,仍然不与其他 owner 共享。
    const key = clientId ?? `anon:${crypto.randomBytes(8).toString("hex")}`;
    const existing = this.ownerStores.get(key);
    if (existing) {
      existing.at = Date.now();
      return existing;
    }
    const created = {
      retained: new TransferRetainedStore(),
      assembler: new TransferV2Assembler(),
      at: Date.now(),
    };
    this.ownerStores.set(key, created);
    // 桶数量有界:否则伪造 clientId 就能无限制地新建状态桶。
    while (this.ownerStores.size > MAX_OWNER_STORES) {
      let oldestKey: string | undefined;
      let oldestAt = Number.POSITIVE_INFINITY;
      for (const [k, v] of this.ownerStores) {
        if (k === key) continue;
        if (v.at < oldestAt) {
          oldestAt = v.at;
          oldestKey = k;
        }
      }
      if (oldestKey === undefined) break;
      this.ownerStores.delete(oldestKey);
    }
    return created;
  }

  private sweepOwnerStores(): void {
    const now = Date.now();
    for (const [key, store] of [...this.ownerStores]) {
      store.retained.sweepExpired();
      store.assembler.sweepExpired();
      // 桶自身也要回收:长期没有活动且状态已空,留着只是内存碎片。
      if (
        now - store.at > OWNER_STORE_IDLE_MS &&
        store.retained.retainedBytes === 0 &&
        store.assembler.assemblyBytes === 0
      ) {
        this.ownerStores.delete(key);
      }
    }
  }

  get activePeerCount(): number {
    return this.peers.size;
  }

  /// owner 隔离的可观测指标:当前活跃的 chunk-v2 状态桶数量。
  /// 两个不同 clientId 接入后必须是 2 —— 若为 1 就说明又退回了共享单例。
  get ownerStoreCount(): number {
    return this.ownerStores.size;
  }

  /// 信号串行化的可观测指标:remote description 就位前到达的候选计数。
  get candidatesAwaitingRemoteDescription(): number {
    return this.candidatesBufferedAwaitingRemote;
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.credentialRefreshTimer) clearTimeout(this.credentialRefreshTimer);
    this.ws?.close();
    for (const peer of [...this.peers.values()]) void peer.close();
    this.pendingCandidatesByPeer.clear();
    this.signalChains.clear();
    if (this.sweepTimer) clearInterval(this.sweepTimer);
    this.sweepTimer = undefined;
    this.ownerStores.clear();
  }

  private log(line: string): void {
    this.deps.log?.(line);
  }

  private connect(): void {
    if (this.stopped) return;
    const ws = new WebSocket(this.rendezvousUrl);
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
        const legacyStunUrls = normalizeLegacyStunUrls(msg.stunUrls);
        this.iceServers = legacyStunUrls.length > 0 ? [{ urls: legacyStunUrls }] : [];
        ws.send(
          JSON.stringify({
            type: "hello",
            role: "host",
            deviceId: this.deps.deviceId,
            secret: this.deps.secret,
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
          `已在信令服建立房间 ${this.deps.deviceId},ICE=${this.iceServers.length},TURN=${hasTurn ? "on" : "off"}`,
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
        if (from) this.enqueueSignal(from, (msg.data ?? {}) as SignalData);
        return;
      }
      case "peer_left": {
        const peerId = typeof msg.peerId === "string" ? msg.peerId : "";
        this.pendingCandidatesByPeer.delete(peerId);
        const peer = this.peers.get(peerId);
        if (peer) {
          if (peer.channelOpen) {
            // 已建链的 DataChannel 不经过信令服:信令断 ≠ 媒体断。
            // 手机的信令 WS 在运营商/VPN 路径上很脆,不能让它株连健康连接;
            // 真死掉的媒体由 ICE 活性检测自行收尾。
            this.log(`信令服通知 peer 离开(${peerId}),已建链连接保留`);
          } else {
            this.log(`信令服通知 peer 离开(${peerId}),建链未完成,关闭`);
            void peer.close();
          }
        }
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

  /// 按 peerId 串行派发信号:同一 peer 的 offer/candidate 严格按到达顺序处理,
  /// 不同 peer 仍然并发。单条信号抛错不得毒化后续信号(catch 在链内收口)。
  private enqueueSignal(peerId: string, data: SignalData): void {
    const prev = this.signalChains.get(peerId) ?? Promise.resolve();
    const next = prev.then(() => this.onSignal(peerId, data));
    this.signalChains.set(peerId, next);
    // 链尾自清:只有当前链尾仍是自己时才删,避免误删后续已接上的信号。
    void next.finally(() => {
      if (this.signalChains.get(peerId) === next) this.signalChains.delete(peerId);
    });
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
        // 同一 peerId 重复 offer(重叫):旧连接作废重来。
        // 注:曾经尝试过"活链路上的重 offer 走同 pc 重协商"以支持 ICE 重启,
        // 但集成测试证明 werift 在重协商后的 ICE 重启周期里会 CPU 自旋冻死
        // 整个进程(30s 硬超时都无法触发)。保留该路径等于给远端一个冻结
        // bridge 的开关,故否决:ICE 重启一律降级为全量重连。
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
        // remote description 未就位时必须缓冲。探针确认:werift 在这种情况下
        // addIceCandidate 会静默 resolve,候选被无声丢弃且不报错。本机 loopback
        // 能靠 peer-reflexive 候选救回来(只是变慢),但真实网络上如果只有一个
        // relay 候选,丢了就是建链失败 —— 表现为同一网络时成时败。
        if (peer && peer.pc.remoteDescription) {
          await peer.pc.addIceCandidate(data.candidate as never);
          return;
        }
        if (peer) this.candidatesBufferedAwaitingRemote++;
        const pending = this.pendingCandidatesByPeer.get(peerId) ?? [];
        if (pending.length < MAX_PENDING_CANDIDATES) {
          pending.push(data.candidate);
          this.pendingCandidatesByPeer.set(peerId, pending);
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
      channelOpen: false,
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
    peer.channelOpen = true;
    const socket = new DataChannelSocket(channel);
    const authTimer = setTimeout(() => {
      this.log(`P2P 客户端 ${AUTH_TIMEOUT_MS / 1000}s 未鉴权(${peerId})`);
      socket.terminate();
    }, AUTH_TIMEOUT_MS);
    authTimer.unref();
    const onFirstMessage = (data: Buffer) => {
      socket.off("message", onFirstMessage);
      clearTimeout(authTimer);
      let msg: {
        type?: string;
        token?: string;
        clientId?: string;
        capabilities?: unknown;
      };
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
      const mobileCaps = Array.isArray(msg.capabilities)
        ? msg.capabilities.filter(
            (value): value is string => typeof value === "string",
          )
        : [];
      if (mobileCaps.includes(P2P_CHUNK_CAPABILITY)) {
        socket.enableChunking();
      }
      if (mobileCaps.includes(P2P_CHUNK_V2_CAPABILITY)) {
        // 按认证 owner 取状态桶:跨设备不共享 retained/assembler。
        const store = this.ownerStore(
          typeof msg.clientId === "string" ? msg.clientId : null,
        );
        socket.enableChunkingV2(store.retained, store.assembler);
      }
      this.log(`P2P 客户端接入(${peerId})`);
      this.deps.acceptMobile(
        socket.asWebSocket(),
        typeof msg.clientId === "string" ? msg.clientId : null,
        mobileCaps,
      );
    };
    socket.on("message", onFirstMessage);
    socket.on("close", (code: number, reason: Buffer) => {
      clearTimeout(authTimer);
      const why = reason.length > 0 ? ` ${reason.toString("utf8")}` : "";
      this.log(
        `DataChannel 关闭(${peerId}) code=${code}${why} buffered=${socket.bufferedAmount}`,
      );
      void peer.close();
    });
  }
}

export function randomDeviceId(hostname: string): string {
  const suffix = crypto.randomBytes(3).toString("hex");
  return `${hostname || "desktop"}-${suffix}`;
}
