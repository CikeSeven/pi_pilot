import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { WebSocket, WebSocketServer } from "ws";
import { lanUrls, loadConfig, writeFileConfig } from "./config.js";
import { startAnnounce } from "./announce.js";
import {
  HUB_PROTOCOL_VERSION,
  MAX_BUFFERED_SOCKET_BYTES,
  MAX_CLIENT_MESSAGE_BYTES,
  MAX_DESKTOP_MESSAGE_BYTES,
  MAX_MOBILE_ENTRIES_BYTES,
  MAX_MOBILE_ENTRIES_BYTES_P2P,
  MAX_ENTRIES_PAGE_BYTES,
  MAX_EVENT_PAGE_BYTES,
  MOBILE_ENTRY_HARD_BYTES,
  MOBILE_ENTRY_TEXT_CAP,
  clampLeaseTtl,
  isDesktopMutationCommand,
  isReadOnlySourceCommand,
  parseCursor,
  translateCompactPrompt,
  withoutHubMetadata,
  type BridgeMessage,
  type JsonObject,
} from "./hub_protocol.js";
import { CommandQueue } from "./command_queue.js";
import { quiesceSourceForHandoff } from "./source_handoff.js";
import { PiPool, sourceIdForSession, type SessionSpec } from "./pi_pool.js";
import { listDirs, listSessions, SESSIONS_ROOT } from "./sessions.js";
import { readEntriesPage } from "./session_entries.js";
import { DataChannelSocket, P2pHost } from "./p2p_host.js";
import { P2P_INTERACTIVE_QUEUE_MAX_BYTES } from "./p2p_transport.js";
import { P2P_CHUNK_CAPABILITY } from "./p2p_chunking.js";
import { P2P_CHUNK_V2_CAPABILITY } from "./p2p_frame_v2.js";
import {
  SourceRegistry,
  type SequencedSourceEvent,
  type SourceDescriptor,
  type SourceSnapshot,
} from "./source_registry.js";
import { loadBridgeIdentity } from "./notification_identity.js";
import { NotificationEventStore } from "./notification_event_store.js";
import { NotificationDetector } from "./notification_detector.js";
import {
  mergeSkipped,
  NotificationSubscriptionManager,
  parseAckRequest,
  parseReceiptRequest,
  parseSubscribeRequest,
} from "./notification_protocol.js";
import { NotificationReceiptStore } from "./notification_receipts.js";
import type { NotificationEventV1 } from "./notification_event.js";

const config = loadConfig();
const sources = new SourceRegistry(config.replayCapacity, config.replayByteBudget);

// ---------------------------------------------------------------------------
// 通知事件层(stable-plan.md Phase 1)
//
// 与 hubId 严格分工:hubId 是进程级的,继续服务旧 source cursor;
// bridgeInstallationId 跨重启稳定,只给通知 cursor 用。两者并存,
// 避免升级即断链 —— 见 stable-plan.md §3.2。
//
// 本期是 shadow 模式:只生成事件与指标,不改变任何现有客户端行为。
// ---------------------------------------------------------------------------

const bridgeIdentity = loadBridgeIdentity().identity;
const notificationStore = new NotificationEventStore();
notificationStore.load();
const notificationDetector = new NotificationDetector({
  bridgeInstallationId: bridgeIdentity.bridgeInstallationId,
  eventEpoch: bridgeIdentity.eventEpoch,
  store: notificationStore,
});
const notificationSubscriptions = new NotificationSubscriptionManager(
  notificationStore,
  bridgeIdentity.bridgeInstallationId,
  bridgeIdentity.eventEpoch,
  Date.now,
  // 完成事件落盘后若断链积压、且更新的任务已开跑 —— 过期,投递时走 skippedRanges。
  (event) => notificationDetector.isStaleCompletion(event),
);
const notificationReceipts = new NotificationReceiptStore();

/// 声明给客户端的通知能力。旧客户端看不懂就忽略,
/// 新客户端靠它判定能不能发通知帧。
const NOTIFICATION_CAPABILITIES = ["notification_events_v1", "notification_receipts_v1"];

/// 事件已落盘后推给已 ready 的订阅。persisted 为 false 时绝不推 ——
/// 未落盘的事件不得进任何发送队列,否则客户端会 ack 一个
/// Bridge 重启后并不存在的 sequence。
function publishNotificationEvent(result: { event: NotificationEventV1; persisted: boolean } | undefined): void {
  if (result === undefined) return;
  if (!result.persisted) {
    console.error(
      `[notify] event ${result.event.eventId.slice(0, 8)} not persisted; withholding delivery`,
    );
    return;
  }
  const deliverable = notificationSubscriptions.onEvent(result.event);
  if (deliverable.size === 0) return;
  for (const client of mobileClients.values()) {
    const events = deliverable.get(notificationSubscriptionIdFor(client.clientId));
    if (events === undefined || events.length === 0) continue;
    sendObject(client.ws, {
      type: "notification_events",
      eventEpoch: bridgeIdentity.eventEpoch,
      bridgeNow: new Date().toISOString(),
      events,
      skippedRanges: [],
      live: true,
    });
  }
}

/// 订阅 id 绑 clientId:一个手机连接只维护一条通知订阅。
function notificationSubscriptionIdFor(clientId: string): string {
  return `notify:${clientId}`;
}
/// 兼容别名:老版 App 仍会选这个 sourceId,解析到引导会话。
const HEADLESS_SOURCE_ID = config.headlessSourceId;

let currentCwd = config.piCwd;
let currentSessionId = config.sessionId;
let shuttingDown = false;

/// 引导会话的 sourceId(HEADLESS_SOURCE_ID 的解析目标)。
let bootstrapSourceId = sourceIdForSession(config.sessionId);

/// 把老协议的 headless sourceId 映射到当前引导会话。
function resolveSourceId(sourceId: string): string {
  return sourceId === HEADLESS_SOURCE_ID ? bootstrapSourceId : sourceId;
}

interface MobileClient {
  clientId: string;
  ws: WebSocket;
  selectedSourceId?: string;
  /** 移动端声明的能力位(msg-delta 等);WS 走 query,P2P 走 auth 帧。 */
  caps: Set<string>;
}

interface DesktopClient {
  ws: WebSocket;
  sourceId?: string;
  registering?: boolean;
  /// 最近一次收到任何 desktop_* 帧的时间。Ctrl+Z(SIGTSTP)冻住 pi 进程时内核
  /// socket 仍是 ESTABLISHED、不发 FIN,close 事件永远不来,所以「还活着吗」
  /// 只能靠这个时间戳判断,不能靠连接状态。
  lastSeen: number;
  /// 登记 claim 时用的会话 id。**不能**在断开时从 descriptor 反推 ——
  /// 用户在 TUI 里切过会话之后,descriptor 早就是另一个 id 了,
  /// 于是旧 claim 永远泄漏,那个会话再也开不起来。
  claimedSessionId?: string;
}

interface PendingRequest {
  clientId: string;
  ws: WebSocket;
  sourceId: string;
  command: string;
  originalId?: string;
  timeout: NodeJS.Timeout;
  /** 命令互斥队列用:响应/超时/失败都要放行队尾。 */
  settle?: () => void;
}

const mobileClients = new Map<WebSocket, MobileClient>();
/// 同一稳定 clientId 当前生效的 socket。旧连接的 close 可能晚于替代连接,
/// close 清理必须先核对身份,否则会释放新连接正在使用的租约与 pending。
const activeMobileSocketByClientId = new Map<string, WebSocket>();
const desktopClients = new Set<DesktopClient>();
const desktopBySource = new Map<string, DesktopClient>();
/// 桌面源转为断开的时刻,用于延迟回收。只记桌面源:headless 的「断开」是
/// 休眠会话,必须留在列表里等用户发消息唤醒。
const desktopOfflineSince = new Map<string, number>();
const pending = new Map<string, PendingRequest>();

function labelForSession(spec: SessionSpec): string {
  const dir = spec.cwd.split("/").filter(Boolean).pop() ?? spec.cwd;
  return `${config.headlessSourceName} · ${dir}`;
}

/// 登记一个 headless 会话源。传输闭包捕获参数(而非可变的 bootstrapSourceId),
/// 这样切目录后老会话仍然发到自己的进程。
/// 休眠会话的 spec(descriptor 装不下 sessionPath;懒唤醒要靠它才不会
/// 用 `--session-id` 在默认目录新建一个空会话)。
const dormantSpecs = new Map<string, SessionSpec>();

/// `sessionPath` 只能是 `listSessions(cwd)` 枚举出来的路径。
/// 直接透传等于让客户端指定 pi 打开/写入宿主机上的任意文件。
function resolveSessionPath(
  cwd: string,
  sessionPath: unknown,
): { path: string; sessionId: string } | undefined {
  if (typeof sessionPath !== "string") return undefined;
  const match = listSessions(cwd).find((session) => session.path === sessionPath);
  if (!match) throw new Error("sessionPath is not an enumerated session for cwd");
  return { path: match.path, sessionId: match.id };
}

function registerHeadlessSource(sourceId: string, spec: SessionSpec): boolean {
  dormantSpecs.set(sourceId, spec);
  if (sources.get(sourceId)) return false;
  sources.register(
    {
      id: sourceId,
      kind: "headless",
      label: labelForSession(spec),
      connected: false,
      epoch: crypto.randomUUID(),
      cwd: spec.cwd,
      sessionId: spec.sessionId,
      capabilities: ["pi-rpc", "sessions", "directories"],
    },
    { send: (message) => pool.send(sourceId, message) },
  );
  return true;
}

/// 引导会话先以"离线"注册,让 App 一连上就能看到它;
/// 真正的进程等到有人选中(或显式打开)时才拉起。
registerHeadlessSource(bootstrapSourceId, { sessionId: currentSessionId, cwd: currentCwd });

/// P2P DataChannel 的极端积压上限:信用制流控下正常不会到达;
/// 真到了说明对端实现违规或链路事实上已死 —— 丢帧留痕而不是
/// close(1013),背压的终点是停泵,杀链只交给"连续无进度"判定。
const MAX_P2P_BUFFERED_SOCKET_BYTES = 16 * 1024 * 1024;

function sendRaw(ws: WebSocket, data: string): boolean {
  if (ws.readyState !== WebSocket.OPEN) return false;
  if (ws instanceof DataChannelSocket) {
    if (ws.bufferedAmount > MAX_P2P_BUFFERED_SOCKET_BYTES) {
      console.error(
        `[p2p] 积压 ${ws.bufferedAmount}B 超 ${MAX_P2P_BUFFERED_SOCKET_BYTES}B,丢帧留痕(不再 close 1013)`,
      );
      return false;
    }
    // trySend 会在 bulk 队列装不下整条消息时整条拒绝并返回 false,
    // 这里必须把这个结果传出去 —— 否则已生成的响应被静默丢弃,
    // 调用方只能干等到超时。
    return ws.trySend(data);
  }
  if (ws.bufferedAmount > MAX_BUFFERED_SOCKET_BYTES) {
    ws.close(1013, "client is too slow");
    return false;
  }
  ws.send(data);
  return true;
}

function sendObject(ws: WebSocket, value: unknown): boolean {
  return sendRaw(ws, JSON.stringify(value));
}

function tokenMatches(candidate: string | null, expected: string): boolean {
  if (!candidate) return false;
  const left = Buffer.from(candidate);
  const right = Buffer.from(expected);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

/// 响应发送失败的累计计数:可观测指标,用于确认"静默丢响应"是否真的发生过。
let respondDropped = 0;

export function respondDroppedCount(): number {
  return respondDropped;
}

function respond(
  ws: WebSocket,
  msg: BridgeMessage,
  success: boolean,
  data?: unknown,
  error?: string,
): void {
  const ok = sendObject(ws, {
    type: "response",
    command: msg.type,
    ...(typeof msg.id === "string" ? { id: msg.id } : {}),
    success,
    ...(data !== undefined ? { data } : {}),
    ...(error !== undefined ? { error } : {}),
  });
  if (ok) return;

  // 响应没发出去。此前这里静默返回,调用方(手机)只能等到进度型超时,
  // 这是"很慢"的一个直接来源:一次被丢的 hub_sync 就是一整个超时周期。
  respondDropped++;
  const id = typeof msg.id === "string" ? msg.id : "(no id)";
  console.error(
    `[hub] 响应发送失败 command=${msg.type} id=${id} 累计=${respondDropped}`,
  );

  // 兜底:大响应挤不进 bulk 队列时,退化成一条极小的失败响应。
  // control/interactive 走独立队列,即使 bulk 满了这条通常仍能发出,
  // 让手机立刻拿到明确失败而不是干等超时。
  if (success) {
    const fallback = sendObject(ws, {
      type: "response",
      command: msg.type,
      ...(typeof msg.id === "string" ? { id: msg.id } : {}),
      success: false,
      error: "响应过大且发送队列已满,请重试或缩小请求范围",
    });
    if (!fallback) {
      console.error(`[hub] 兜底失败响应也未能发出 command=${msg.type} id=${id}`);
    }
  }
}

function eventFrame(event: SequencedSourceEvent): JsonObject {
  const { _hub: _ignored, ...payload } = event.payload;
  return {
    ...payload,
    _hub: {
      hubId: sources.hubId,
      sourceId: event.sourceId,
      sourceEpoch: event.sourceEpoch,
      seq: event.seq,
    },
  };
}

function broadcastSourceEvent(event: SequencedSourceEvent): void {
  const frame = eventFrame(event);
  for (const client of mobileClients.values()) {
    if (client.selectedSourceId === event.sourceId) {
      sendObject(client.ws, maybeDeltaFrame(client, event, frame));
    }
  }
}

/// msg-delta:流式 assistant message_update 的线体积削减。
/// 前提(由前缀校验保证):块数不变、前 n-1 块逐字节相同、末块同类型且
/// text/thinking 字段前缀扩展 —— 这是 pi 流式生成的实际形状。
/// 不满足就原样发全量并重建基线。每个 delta 仍带自己的 _hub seq,
/// 丢 delta = seq gap = 既有重同步路径,不产生静默分歧。
const MSG_DELTA_CAPABILITY = "msg-delta";
const DELTA_KEYS_PER_CLIENT = 8;
interface DeltaBase {
  rev: number;
  headJson: string;
  lastType: string;
  lastField: "text" | "thinking";
  lastText: string;
}
const deltaBaseByClient = new WeakMap<WebSocket, Map<string, DeltaBase>>();

function deltaFieldOf(block: Record<string, unknown>): "text" | "thinking" | null {
  if (typeof block.text === "string") return "text";
  if (typeof block.thinking === "string") return "thinking";
  return null;
}

function maybeDeltaFrame(
  client: MobileClient,
  event: SequencedSourceEvent,
  fullFrame: JsonObject,
): JsonObject {
  const payload = event.payload as Record<string, unknown>;
  if (payload.type !== "message_update" || !client.caps.has(MSG_DELTA_CAPABILITY)) {
    return fullFrame;
  }
  const message = payload.message as Record<string, unknown> | undefined;
  if (!message || message.role !== "assistant") return fullFrame;
  const content = message.content;
  if (!Array.isArray(content) || content.length === 0) return fullFrame;
  const key = `assistant:${String(message.timestamp ?? "")}`;

  let perClient = deltaBaseByClient.get(client.ws);
  if (!perClient) {
    perClient = new Map();
    deltaBaseByClient.set(client.ws, perClient);
  }
  const last = content[content.length - 1] as Record<string, unknown>;
  const lastField = last && typeof last === "object" ? deltaFieldOf(last) : null;
  const headJson = JSON.stringify(content.slice(0, -1));
  const base = perClient.get(key);

  if (
    base &&
    lastField &&
    base.headJson === headJson &&
    base.lastType === String(last.type ?? "") &&
    base.lastField === lastField
  ) {
    const newText = String(last[lastField] ?? "");
    if (newText.startsWith(base.lastText) && newText.length > base.lastText.length) {
      const rev = base.rev + 1;
      perClient.set(key, { ...base, rev, lastText: newText });
      return {
        type: "message_delta",
        key,
        rev,
        blockIndex: content.length - 1,
        field: lastField,
        appendText: newText.slice(base.lastText.length),
        _hub: fullFrame._hub,
      } as JsonObject;
    }
  }
  // 全量路径:重建基线。FIFO 逐出防内存膨胀。
  perClient.delete(key);
  if (lastField) {
    perClient.set(key, {
      rev: 0,
      headJson,
      lastType: String(last.type ?? ""),
      lastField,
      lastText: String(last[lastField] ?? ""),
    });
    while (perClient.size > DELTA_KEYS_PER_CLIENT) {
      const oldest = perClient.keys().next().value;
      if (oldest === undefined) break;
      perClient.delete(oldest);
    }
  }
  return fullFrame;
}

function broadcastHubEvent(type: string, data: JsonObject = {}): void {
  for (const client of mobileClients.values()) sendObject(client.ws, { type, ...data });
}

// ---------------------------------------------------------------------------
// 按需快照:桌面 relay 在流式期间不会自发足够频繁的快照,而重放环会把旧 baseSeq
// 之后的事件挤掉。发现不连续时向 relay 索要一份新的(不换 epoch)。
// ---------------------------------------------------------------------------

interface SnapshotWaiter {
  resolve: (ok: boolean) => void;
  timer: NodeJS.Timeout;
}

const snapshotRequests = new Map<string, { sourceId: string; waiters: SnapshotWaiter[] }>();
const snapshotInFlight = new Map<string, string>();

function settleSnapshotRequest(
  sourceId: string,
  requestId: string | undefined,
  ok: boolean,
): void {
  const id = requestId ?? snapshotInFlight.get(sourceId);
  if (!id) return;
  const entry = snapshotRequests.get(id);
  snapshotRequests.delete(id);
  if (snapshotInFlight.get(sourceId) === id) snapshotInFlight.delete(sourceId);
  if (!entry) return;
  for (const waiter of entry.waiters) {
    clearTimeout(waiter.timer);
    waiter.resolve(ok);
  }
}

function failSnapshotRequestsForSource(sourceId: string): void {
  const id = snapshotInFlight.get(sourceId);
  if (id) settleSnapshotRequest(sourceId, id, false);
}

const LIVE_TREE_CAPABILITY = "tree-summary-on-demand";

interface DesktopTreeResult {
  tree: JsonObject[];
  leafId: string | null;
}

/**
 * 失败必须带上原因。relay 侧 stale_epoch / stale_ctx / 超预算是完全不同的故障,
 * 全部塌缩成一句「不可用」时,手机和排查者都无从下手。
 */
type DesktopTreeOutcome =
  | ({ ok: true } & DesktopTreeResult)
  | { ok: false; reason: string };

interface TreeWaiter {
  resolve: (outcome: DesktopTreeOutcome) => void;
  timer: NodeJS.Timeout;
}

const treeRequests = new Map<string, { sourceId: string; waiters: TreeWaiter[] }>();
const treeInFlight = new Map<string, string>();

function settleTreeRequest(
  sourceId: string,
  requestId: string | undefined,
  outcome: DesktopTreeOutcome = { ok: false, reason: "桌面端超时未回应" },
): void {
  const id = requestId ?? treeInFlight.get(sourceId);
  if (!id) return;
  const entry = treeRequests.get(id);
  // 另一条桌面连接不能用猜到/拿错的 requestId 兑现本源请求。
  if (!entry || entry.sourceId !== sourceId) return;
  treeRequests.delete(id);
  if (treeInFlight.get(sourceId) === id) treeInFlight.delete(sourceId);
  for (const waiter of entry.waiters) {
    clearTimeout(waiter.timer);
    waiter.resolve(outcome);
  }
}

function failTreeRequestsForSource(sourceId: string): void {
  const id = treeInFlight.get(sourceId);
  if (id) settleTreeRequest(sourceId, id, { ok: false, reason: "桌面端已断开" });
}

// ---------------------------------------------------------------------------
// ask_user_question 转交
//
// 第三方插件 @juicesharp/rpiv-ask-user-question 把问卷画在电脑端 TUI 的覆盖层里,
// 不走 pi 的 extension_ui_request 协议,所以手机永远收不到,只能看着一个转不完的圈。
// relay 改用 `tool_call` 钩子在插件的 execute 之前把整次调用截下来,把题目发到这里,
// 由 hub 转给正在看这个源的手机作答,再把答案送回去。
//
// 两段超时(认领 / 作答)都在 relay 那侧计时 —— 它才是真正被阻塞的一方。hub 只负责
// 转发、按 requestId 认账、以及在没人看或断线时立刻回绝,让桌面尽快回落到插件自己
// 的问卷。
// ---------------------------------------------------------------------------

const LIVE_ASK_CAPABILITY = "ask-user-question-relay";

interface InFlightAsk {
  requestId: string;
  toolCallId: string;
  epoch: string;
  questions: JsonObject[];
  claimed: boolean;
}

/// 每个源最多一份在途问卷:桌面的 agent 循环卡在 beforeToolCall 上,
/// 同一个源不可能并发弹出第二份。
const asksBySource = new Map<string, InFlightAsk>();

/// 问卷帧走**带外**,不占源的 seq,也不进重放环。
///
/// 不能用 recordLocalEvent:它用 `++record.lastSeq`,而桌面源的事件走
/// recordDesktopEvent,那条路要求 `seq === lastSeq + 1`,且 seq 由 relay 自己
/// 独立递增。在桌面源上注入一条本地事件就把 lastSeq 顶偏了,relay 下一条
/// 事件立即被判 sequence_gap → hub 回 desktop_resync_required → relay 换 epoch
/// 重发全量快照 → App 整份重同步。而重同步后手机会再选一次源,若那时
/// 又重发一遍问卷,就又顶偏一次 —— 自己咬住尾巴,表现成答完题后永无止境
/// 地重连。headless 源没这个问题(它的事件本来就走 recordLocalEvent),
/// 但问卷只会来自桌面源。
///
/// 不进重放环的代价是断线重连拿不到它,由 republishAsk 在选源时补上。
function sendAskFrame(sourceId: string, frame: JsonObject): void {
  for (const client of mobileClients.values()) {
    if (client.selectedSourceId === sourceId) sendObject(client.ws, frame);
  }
}

function retractAsk(sourceId: string, requestId: string): void {
  sendAskFrame(sourceId, { type: "ask_user_question_retracted", requestId });
}

function clearAskForSource(sourceId: string, retract: boolean): void {
  const ask = asksBySource.get(sourceId);
  if (!ask) return;
  asksBySource.delete(sourceId);
  if (retract) retractAsk(sourceId, ask.requestId);
}

/// 选源时把还在途的问卷重新放一遍。
///
/// 问卷帧不进重放环(见 sendAskFrame),所以重连、换源、或 epoch 重置后手机
/// 没任何其他途径能重新看见它。不补的话电脑还在 beforeToolCall 上等,手机却
/// 只剩「这份问卷在电脑上作答」,谁也动不了,直到作答窗口超时。
/// requestId 不变,所以对已经看到过的客户端是幂等的。
function republishAsk(sourceId: string): void {
  const ask = asksBySource.get(sourceId);
  if (!ask) return;
  sendAskFrame(sourceId, {
    type: "ask_user_question_request",
    requestId: ask.requestId,
    toolCallId: ask.toolCallId,
    questions: ask.questions,
  });
}

function requestDesktopTree(
  sourceId: string,
  timeoutMs = config.snapshotRequestTimeoutMs,
): Promise<DesktopTreeOutcome> {
  const source = sources.get(sourceId);
  if (!source || source.kind !== "desktop" || !source.connected) {
    return Promise.resolve({ ok: false, reason: "桌面端未连接" });
  }
  if (!source.capabilities.includes(LIVE_TREE_CAPABILITY)) {
    // 老版 relay 只会把树塞在快照里,发这一帧只会白等一个超时。
    return Promise.resolve({
      ok: false,
      reason: "桌面端插件版本较旧,请在桌面 pi 里执行 /reload",
    });
  }
  const existing = treeInFlight.get(sourceId);
  if (existing) {
    return new Promise((resolve) => {
      const entry = treeRequests.get(existing);
      if (!entry) {
        resolve({ ok: false, reason: "桌面端请求已失效" });
        return;
      }
      const timer = setTimeout(
        () => resolve({ ok: false, reason: "桌面端超时未回应" }),
        timeoutMs,
      );
      timer.unref();
      entry.waiters.push({ resolve, timer });
    });
  }

  const requestId = `tree:${crypto.randomUUID()}`;
  const sent = sources.transport(sourceId)?.send({
    type: "desktop_tree_request",
    requestId,
    epoch: source.epoch,
  });
  if (sent !== true) return Promise.resolve({ ok: false, reason: "发送失败,桌面端连接不可用" });
  treeInFlight.set(sourceId, requestId);
  return new Promise((resolve) => {
    const timer = setTimeout(() => settleTreeRequest(sourceId, requestId), timeoutMs);
    timer.unref();
    treeRequests.set(requestId, { sourceId, waiters: [{ resolve, timer }] });
  });
}

function requestDesktopSnapshot(
  sourceId: string,
  timeoutMs = config.snapshotRequestTimeoutMs,
): Promise<boolean> {
  const source = sources.get(sourceId);
  if (!source || source.kind !== "desktop" || !source.connected) {
    return Promise.resolve(false);
  }
  const existing = snapshotInFlight.get(sourceId);
  if (existing) {
    // 同源并发请求合并到同一次往返
    return new Promise<boolean>((resolve) => {
      const entry = snapshotRequests.get(existing);
      if (!entry) {
        resolve(false);
        return;
      }
      const timer = setTimeout(() => resolve(false), timeoutMs);
      timer.unref();
      entry.waiters.push({ resolve, timer });
    });
  }
  const requestId = `snap:${crypto.randomUUID()}`;
  const sent = sources.transport(sourceId)?.send({
    type: "desktop_snapshot_request",
    requestId,
    epoch: source.epoch,
  });
  if (sent !== true) return Promise.resolve(false);
  snapshotInFlight.set(sourceId, requestId);
  return new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => settleSnapshotRequest(sourceId, requestId, false), timeoutMs);
    timer.unref();
    snapshotRequests.set(requestId, { sourceId, waiters: [{ resolve, timer }] });
  });
}

/** 小提示帧(不是负载):让卡住的客户端知道有新快照可拉。 */
function broadcastSnapshotAnnounce(sourceId: string, snapshot: SourceSnapshot): void {
  const state = snapshot.state;
  const frame = {
    type: "hub_source_snapshot",
    hubId: sources.hubId,
    sourceId,
    epoch: snapshot.epoch,
    baseSeq: snapshot.baseSeq,
    capturedAt: snapshot.capturedAt,
    leafId: snapshot.leafId,
    sessionId: typeof state.sessionId === "string" ? state.sessionId : null,
    isStreaming: state.isStreaming === true,
    hasInFlightMessage: snapshot.inFlightMessage !== undefined,
  };
  for (const client of mobileClients.values()) {
    if (client.selectedSourceId === sourceId) sendObject(client.ws, frame);
  }
}

// ---------------------------------------------------------------------------
// 流式守卫:客户端的 isStreaming 本身是坏的,服务端必须自己判定。
// ---------------------------------------------------------------------------

const SESSION_MUTATING_COMMANDS = new Set([
  "switch_session",
  "new_session",
  "fork",
  "clone",
  "compact",
]);

const streamingBySource = new Map<string, boolean>();

function noteStreamingFromEvent(sourceId: string, eventType: unknown): void {
  const next =
    eventType === "agent_start"
      ? true
      : eventType === "agent_end" || eventType === "agent_settled"
        ? false
        : undefined;
  if (next === undefined) return;
  // 值没真翻就不广播 —— 每个 desktop_event 都会过这里,不能每次都刷。
  if ((streamingBySource.get(sourceId) ?? false) === next) return;
  streamingBySource.set(sourceId, next);
  // 通知事件挂在这个权威边沿上,而不是相信手机上报的 isStreaming ——
  // 手机的状态会因进程冻结、socket 半开、状态防抖而落后甚至永久错位。
  // agent_end 与 agent_settled 都会走到这里,靠 taskGenerationId 去重成一条。
  if (next) {
    notificationDetector.onTaskStart(sourceId);
  } else {
    const snapshot = sources.getSnapshot(sourceId);
    const sessionId =
      typeof snapshot?.state.sessionId === "string" ? snapshot.state.sessionId : undefined;
    publishNotificationEvent(
      notificationDetector.onTaskEnd(sourceId, {
        ...(sessionId !== undefined ? { sessionId } : {}),
      }),
    );
  }
  // streaming 翻转要改变手机常驻通知上的「工作中」计数(也会刷新
  // App 侧 state.sessions 的 streaming 标记,后台会话完成检测靠它)。
  notifySessionsChanged();
}

/// 权威快照显示某个源正在工作时,同步内存边沿状态并让 detector 领养代次。
///
/// 为什么必须领养:noteStreamingFromEvent 只认 desktop_event 的
/// agent_start/agent_end,而 Bridge 在任务中途重启后,内存里的
/// streamingBySource 与 detector 代次表都是空的,pi 重连只补发快照、
/// 不会重发 agent_start。此时若不建立代次归属,后续 agent_end 到达时
/// onTaskEnd 找不到在飞代次,按约定返回 undefined(绝不凭空造完成事件),
/// 于是那条完成通知整个消失。
///
/// 症状极具误导性:常驻通知的「工作中」计数直读快照(见 isSourceStreaming),
/// 与 detector 无关,所以会话状态会如实更新成空闲,只有通知不来 ——
/// 看起来像投递失败,实际是生成端从未产出。
///
/// 领养只建立「recovery-」前缀的代次归属,自己不发通知;
/// 已有在飞代次时幂等(直接返回原代次 id)。
function adoptStreamingFromSnapshot(sourceId: string): void {
  streamingBySource.set(sourceId, true);
  notificationDetector.adoptStreamingSource(sourceId);
}

/// op 幂等注册表:clientId 级 opId → 状态。内存表 + 侧车 JSONL
/// (bridge/data/op-log.jsonl,10k 行 ring)。fire-and-forget 的 prompt/abort
/// 没有响应,断线重连后手机靠 hub_op_status 对账:查得到=已受理,
/// 查不到=unknown(禁止自动重放,宁要用户确认不可重复执行)。
const opRegistry = new Map<string, { status: string; at: number }>();
const OP_REGISTRY_CAP = 10_000;
const OP_LOG_FILE = new URL("../data/op-log.jsonl", import.meta.url);

function recordOp(opId: string, status: string): void {
  opRegistry.delete(opId);
  opRegistry.set(opId, { status, at: Date.now() });
  if (opRegistry.size > OP_REGISTRY_CAP) {
    const oldest = opRegistry.keys().next().value;
    if (oldest !== undefined) opRegistry.delete(oldest);
  }
  try {
    fs.mkdirSync(path.dirname(OP_LOG_FILE.pathname), { recursive: true });
    fs.appendFileSync(
      OP_LOG_FILE,
      JSON.stringify({ opId, status, at: Date.now() }) + "\n",
    );
  } catch {}
}

/// 启动时从侧车重建注册表(超 cap 截断重写,防无限增长)。
function loadOpRegistry(): void {
  try {
    const text = fs.readFileSync(OP_LOG_FILE, "utf8");
    const lines = text.split("\n").filter((line) => line.trim().length > 0);
    const kept = lines.slice(-OP_REGISTRY_CAP);
    for (const line of kept) {
      try {
        const rec = JSON.parse(line) as { opId?: string; status?: string; at?: number };
        if (typeof rec.opId === "string" && typeof rec.status === "string") {
          opRegistry.set(rec.opId, { status: rec.status, at: rec.at ?? 0 });
        }
      } catch {}
    }
    if (lines.length > kept.length) {
      fs.writeFileSync(OP_LOG_FILE, kept.join("\n") + "\n");
    }
  } catch {}
}
loadOpRegistry();

function sourceIsStreaming(sourceId: string): boolean {
  if (streamingBySource.get(sourceId) === true) return true;
  return sources.getSnapshot(sourceId)?.state.isStreaming === true;
}

function sourceForClient(client: MobileClient, sourceId: string) {
  return sources.list(client.clientId).find((source) => source.id === sourceId);
}

function notifySourcesChanged(): void {
  for (const client of mobileClients.values()) {
    sendObject(client.ws, {
      type: "hub_sources_changed",
      hubId: sources.hubId,
      sources: sources.list(client.clientId),
    });
  }
  for (const source of sources.list()) pushDesktopStatus(source.id);
  notifySessionsChanged();
}

/// 一个会话在 App 眼里的完整状态。`liveness` 取代了原来的"接管/观察"二元:
/// desktop = 在电脑上跑, headless = 在 bridge 上跑, dormant = 只在磁盘上。
function collectSessions(cwd?: string): JsonObject[] {
  const out = new Map<string, JsonObject>();
  for (const source of sources.list()) {
    const sessionId = source.sessionId;
    if (!sessionId) continue;
    const live = pool.get(source.id);
    out.set(sessionId, {
      sessionId,
      sourceId: source.id,
      cwd: source.cwd ?? null,
      name: source.label,
      liveness:
        source.kind === "desktop"
          ? "desktop"
          : live?.proc.alive
            ? "headless"
            : "dormant",
      connected: source.connected,
      streaming: sourceIsStreaming(source.id),
      pid: live?.proc.pid ?? null,
    });
  }
  // 目录覆盖:当前目录 + 历史已知目录 + 磁盘上真实存在会话的全部目录。
  // 只扫前两者会漏掉在别的目录里开过的会话(App 表现为"列表加载不出来")。
  const dirs = cwd
    ? [cwd]
    : [
        ...new Set([
          currentCwd,
          ...Object.keys(config.dirSessions),
          ...listDirs().map((dir) => dir.cwd),
        ]),
      ];
  for (const dir of dirs) {
    let listed: ReturnType<typeof listSessions>;
    try {
      listed = listSessions(dir);
    } catch {
      continue;
    }
    for (const session of listed) {
      const existing = out.get(session.id);
      const disk = {
        path: session.path,
        name: session.name ?? existing?.name ?? null,
        timestamp: session.timestamp,
        sizeBytes: session.sizeBytes,
      };
      if (existing) {
        Object.assign(existing, disk, { name: existing.name ?? disk.name });
        continue;
      }
      out.set(session.id, {
        sessionId: session.id,
        sourceId: sourceIdForSession(session.id),
        cwd: dir,
        liveness: "dormant",
        connected: false,
        streaming: false,
        pid: null,
        ...disk,
      });
    }
  }
  return [...out.values()];
}

let sessionsChangedTimer: NodeJS.Timeout | undefined;

/// 150ms 防抖:一次目录切换会连着触发注册/连接/元数据三次变更。
function notifySessionsChanged(): void {
  if (sessionsChangedTimer) return;
  sessionsChangedTimer = setTimeout(() => {
    sessionsChangedTimer = undefined;
    const sessions = collectSessions();
    for (const client of mobileClients.values()) {
      sendObject(client.ws, {
        type: "hub_sessions_changed",
        hubId: sources.hubId,
        sessions,
      });
    }
  }, 150);
  sessionsChangedTimer.unref();
}

function notifyOwnerChanged(sourceId: string): void {
  for (const client of mobileClients.values()) {
    sendObject(client.ws, {
      type: "hub_owner_changed",
      sourceId,
      source: sourceForClient(client, sourceId),
    });
  }
  pushDesktopStatus(sourceId);
}

/** 当前有多少手机客户端正在看这个源(闲置回收要用)。 */
function watchersOf(sourceId: string): number {
  let count = 0;
  for (const client of mobileClients.values()) {
    if (client.selectedSourceId === sourceId) count++;
  }
  return count;
}

/** 控制被强制抢走时通知原持有者,让它立刻作废在途命令而不是傻等超时。 */
function broadcastControlMoved(sourceId: string, from: string, to: string): void {
  for (const client of mobileClients.values()) {
    if (client.clientId !== from && client.clientId !== to) continue;
    sendObject(client.ws, {
      type: "hub_control_moved",
      sourceId,
      from,
      to,
      youAreDriving: client.clientId === to,
    });
  }
}

function pushDesktopStatus(sourceId: string): void {
  const desktop = desktopBySource.get(sourceId);
  if (!desktop) return;
  const source = sources.list().find((item) => item.id === sourceId);
  if (!source) return;
  const selectedClients = [...mobileClients.values()].filter(
    (client) => client.selectedSourceId === sourceId,
  ).length;
  sendObject(desktop.ws, {
    type: "desktop_status",
    selectedClients,
    owner: source.owner,
  });
}

function failPendingForSource(sourceId: string, error: string): void {
  for (const [requestId, request] of pending) {
    if (request.sourceId !== sourceId) continue;
    clearTimeout(request.timeout);
    pending.delete(requestId);
    try {
      sendObject(request.ws, {
        type: "response",
        command: request.command,
        ...(request.originalId ? { id: request.originalId } : {}),
        success: false,
        error,
      });
    } finally {
      request.settle?.();
    }
  }
}

/// 转发型只读响应的字节预算。
///
/// 为什么必须有这一层:`handleDesktopRead` 里的页预算与单条硬上限**只作用于
/// desktop 源**。无头源(从手机打开一个没在电脑上跑的会话)的 get_entries /
/// get_tree 等命令走 forwardSourceCommand → pi 进程 → resolvePending,
/// 把 pi 返回的原始 JSON 一字节不改地转给手机。
///
/// 真机实测的后果:打开 50.40MB 的无头会话时 get_entries 返回整个会话,
/// encodeTransferV2 抛 "P2P message exceeds 16MB",通道被 shutdown(1011),
/// 连超时响应都发不回去 —— 手机侧表现为「连上就断,这个会话永远打不开」。
function clipForwardedReadData(
  command: string,
  data: unknown,
  ws: WebSocket,
): unknown {
  if (data === null || typeof data !== "object" || Array.isArray(data)) return data;
  const obj = data as JsonObject;
  const entries = obj.entries;
  if (!Array.isArray(entries)) return data;

  const budget = entriesPageBudget(ws);
  const before = Buffer.byteLength(JSON.stringify(entries));
  if (before <= budget) {
    // 仍要逐条过硬上限:整页不超预算,但单条可能超(实测 compaction 单条 576KB)。
    const capped = entries.map((entry) =>
      entry && typeof entry === "object" && !Array.isArray(entry)
        ? hardCapEntryForMobile(entry as JsonObject)
        : entry,
    );
    const changed = capped.some((entry, i) => entry !== entries[i]);
    return changed ? { ...obj, entries: capped } : data;
  }

  const clipped = clipEntriesForMobile(entries as JsonObject[], budget);
  const out: JsonObject = { ...obj, entries: clipped.entries };
  // 分页协议:被裁就必须告诉客户端还有更早的,否则它以为已经到头。
  if (clipped.omitted > 0) {
    out.hasMore = true;
    if (clipped.oldestId !== undefined) out.oldestId = clipped.oldestId;
  }
  console.log(
    `[hub] 转发只读响应裁剪 command=${command} ` +
      `entries=${clipped.entries.length}/${entries.length} ` +
      `bytes=${Buffer.byteLength(JSON.stringify(out.entries))}/${before} ` +
      `budget=${budget}`,
  );
  return out;
}

function resolvePending(
  requestId: string,
  result: JsonObject,
  fromSourceId?: string,
): boolean {
  const request = pending.get(requestId);
  if (!request) return false;
  // 任何 relay / 任何 pi 进程都不能结算**别的源**的在途请求,
  // 否则客户端会收到一个伪造的成功响应。
  if (fromSourceId !== undefined && request.sourceId !== fromSourceId) return false;
  pending.delete(requestId);
  clearTimeout(request.timeout);
  try {
    const data =
      result.success === true && isReadOnlySourceCommand(request.command)
        ? clipForwardedReadData(request.command, result.data, request.ws)
        : result.data;
    const ok = sendObject(request.ws, {
      type: "response",
      command: request.command,
      ...(request.originalId ? { id: request.originalId } : {}),
      success: result.success === true,
      ...(data !== undefined ? { data } : {}),
      ...(typeof result.error === "string" ? { error: result.error } : {}),
    });
    if (!ok) {
      // 转发响应也可能发不出去(载荷过大/队列满)。此前这里静默丢弃,
      // 手机只能干等到超时 —— 与 respond() 保持同样的显式失败语义。
      respondDropped++;
      const oversized =
        request.ws instanceof DataChannelSocket &&
        request.ws.lastSendRejectedOversized;
      console.error(
        `[hub] 转发响应发送失败 command=${request.command} ` +
          `oversized=${oversized} 累计=${respondDropped}`,
      );
      sendObject(request.ws, {
        type: "response",
        command: request.command,
        ...(request.originalId ? { id: request.originalId } : {}),
        success: false,
        error: oversized
          ? "响应超出单条消息上限,请缩小请求范围(如减少 limit 或改用分页)"
          : "响应过大且发送队列已满,请重试或缩小请求范围",
      });
    }
  } finally {
    // settle 必须无条件执行:漏掉一次就会让该 source 的命令队列永久卡住
    request.settle?.();
  }
  return true;
}

// 长耗时命令的转发超时(毫秒);未列出的命令用默认 30s。
const SOURCE_COMMAND_TIMEOUTS: Record<string, number> = {
  compact: 300_000,
  export_html: 60_000,
};
const DEFAULT_SOURCE_COMMAND_TIMEOUT = 30_000;

/**
 * headless(`pi --mode rpc`)的命令翻译。
 *
 * pi 的 RPC 协议里没有 `navigate_tree`(只读的 `get_tree`,和另开文件的 `fork`),
 * 唯一能原地移动 leaf 的入口是扩展命令。RPC 的 `prompt` **会**展开扩展命令,
 * 而扩展在 rpc 模式下同样加载,所以这里翻译成一条斜杠命令。
 */
function translateForHeadless(command: JsonObject): JsonObject {
  if (command.type !== "navigate_tree") return command;
  const entryId = typeof command.entryId === "string" ? command.entryId : "";
  return {
    type: "prompt",
    message: entryId ? `/pipilot-nav ${entryId}` : "/pipilot-undo",
  };
}

/// 手机不能借 prompt 通道执行任意斜杠命令:pi 会静默把它当扩展命令跑掉。
/// 只放行 PiPilot 自己注册的两个。
const ALLOWED_SLASH_COMMANDS = /^\/(pipilot-nav|pipilot-undo)(\s|$)/;

const commandQueue = new CommandQueue();

/// 需要串行化的会话结构命令(并发执行会损坏 pi 的运行时状态)。
const SERIALIZED_COMMANDS = new Set([
  "fork",
  "clone",
  "switch_session",
  "new_session",
  "navigate_tree",
  "compact",
]);

function forwardSourceCommand(
  client: MobileClient,
  source: SourceDescriptor,
  msg: BridgeMessage,
): void {
  if (SERIALIZED_COMMANDS.has(msg.type ?? "")) {
    // 队头可能是一条 5 分钟的 compact。等它跑完时,租约可能已经被强制抢走、
    // 会话可能已经在生成 —— 入队时的检查早就过期了,必须在真正下发前复检。
    void commandQueue.run(source.id, async () => {
      if (!requireLease(client, source.id, msg)) return;
      // navigate_tree 豁免流式守卫:它的处理器(runNavigate)自己
      // abort()+waitForIdle() 再移动 leaf,生成中回退正是它的正经用法;
      // 拦在这里,手机端「撤销上一轮」在生成期间就永远失败。
      if (msg.type !== "navigate_tree" && sourceIsStreaming(source.id)) {
        respond(
          client.ws,
          msg,
          false,
          undefined,
          "streaming_guard: source is streaming; abort first",
        );
        return;
      }
      await dispatchSourceCommand(client, source, msg);
      // 这些命令可能换掉进程持有的会话文件 —— 立刻回读一次状态,
      // 让 onLine 的 get_state 分支重新绑定 claim 与 descriptor。
      if (source.kind === "headless") pool.send(source.id, { type: "get_state" });
    });
    return;
  }
  void dispatchSourceCommand(client, source, msg);
}

/** 转发一条命令,返回的 promise 在响应/超时/源失效时兑现(永不 reject)。 */
function dispatchSourceCommand(
  client: MobileClient,
  source: SourceDescriptor,
  msg: BridgeMessage,
): Promise<void> {
  const command = withoutHubMetadata(msg);
  delete command.id;
  // opId 幂等登记:先于真正下发,崩溃窗口内状态只能是 accepted 而不是
  // executed —— 配合手机端"at-most-once + 显式 unknown"语义。
  if (typeof msg.opId === "string" && msg.opId.length > 0) {
    recordOp(msg.opId, "accepted");
  }
  const requestId = `hub:${crypto.randomUUID()}`;
  const timeoutMs =
    SOURCE_COMMAND_TIMEOUTS[msg.type ?? ""] ?? DEFAULT_SOURCE_COMMAND_TIMEOUT;
  return new Promise<void>((resolve) => {
    let settled = false;
    const settle = (): void => {
      if (settled) return;
      settled = true;
      resolve();
    };
    const timeout = setTimeout(() => {
      const request = pending.get(requestId);
      if (!request) {
        settle();
        return;
      }
      pending.delete(requestId);
      respond(request.ws, msg, false, undefined, "source command timed out");
      settle();
    }, timeoutMs);
    timeout.unref();
    pending.set(requestId, {
      clientId: client.clientId,
      ws: client.ws,
      sourceId: source.id,
      command: msg.type!,
      originalId: msg.id,
      timeout,
      settle,
    });

    const transport = sources.transport(source.id);
    const sent =
      source.kind === "desktop"
        ? transport?.send({
            type: "remote_command",
            requestId,
            epoch: source.epoch,
            fence: msg._hub?.fence,
            command,
          })
        : transport?.send({ ...translateForHeadless(command), id: requestId });
    if (!sent) {
      clearTimeout(timeout);
      pending.delete(requestId);
      respond(client.ws, msg, false, undefined, "source is not available");
      settle();
    }
  });
}

async function handleDesktopTreeRead(
  client: MobileClient,
  source: SourceDescriptor,
  msg: BridgeMessage,
): Promise<void> {
  // treeSummary 是大快照里的兼容缓存。缓存存在就立即返回;缺失时实时向
  // relay 取树。用户主动打开会话树才付这 30~50ms,不再让每次历史同步
  // 背一棵深树,老版 relay 也不会让已有缓存白等 4 秒。
  const cached = sources.getSnapshot(source.id);
  if (cached?.treeSummary) {
    respond(client.ws, msg, true, {
      tree: cached.treeSummary,
      leafId: cached.leafId,
      summary: true,
    });
    return;
  }
  const live = await requestDesktopTree(source.id);
  if (live.ok) {
    respond(client.ws, msg, true, { tree: live.tree, leafId: live.leafId, summary: true });
    return;
  }
  respond(client.ws, msg, false, undefined, `会话树读取失败:${live.reason}`);
}

/// 发给手机的 entries 尾巴。
///
/// 长会话的全量 entries 实测到过 9.78MB / 4592 条,而手机套接字的缓冲上限是
/// 2MB。sendRaw 先判后发,所以巨包本身发得出去,但紧接着的任何一次发送都会
/// 看到 bufferedAmount 超限而 close(1013) —— 手机于是「连上→要快照→被关→重连」
/// 约 2 秒一轮地死循环。
///
/// 从尾向前收:聊天页要的就是最新那段。更早的靠 get_entries 的 before 分页补。
interface ClippedEntries {
  entries: JsonObject[];
  /// 被砍掉的条数(0 表示这就是全部)。
  omitted: number;
  /// 砍完之后最靠前那条的 id,App 用它作往前分页的游标。
  oldestId: string | null;
  /// 是否有 entry 被单条封顶改过(图片块替换/超长文本截断)。为 true 时
  /// 即便 omitted 为 0,调用方也必须用 entries 浅拷贝,不能用注册表原快照。
  capped: boolean;
}

/// 单条 entry 封顶:不改注册表里的原对象,真改了才返回新对象。
/// - image 等带大 data 的块:手机工具卡片不渲染 base64 图,整块换成占位文本;
/// - text/thinking/content 字符串超过 MOBILE_ENTRY_TEXT_CAP:截断留标记。
/// 实测 read 工具的截图结果单条 1.7MB、compaction 摘要 0.5MB,条数下限会把
/// 它们硬塞进快照,慢速链路上直接把 P2P 缓冲顶爆。
function capEntryForMobile(entry: JsonObject): JsonObject {
  const message = entry.message;
  if (!message || typeof message !== "object" || Array.isArray(message)) return entry;
  const msg = message as JsonObject;
  const content = msg.content;
  if (typeof content === "string") {
    if (content.length <= MOBILE_ENTRY_TEXT_CAP) return entry;
    return {
      ...entry,
      message: {
        ...msg,
        content: `${content.slice(0, MOBILE_ENTRY_TEXT_CAP)}\n…[过长内容已截断,完整内容在电脑上可见]`,
      },
    };
  }
  if (!Array.isArray(content)) return entry;
  let changed = false;
  const cappedContent = content.map((block) => {
    if (!block || typeof block !== "object" || Array.isArray(block)) return block;
    const b = block as JsonObject;
    // 图片等二进制块:base64 data 动辄上 MB,手机端省略。
    if (typeof b.data === "string" && b.data.length > 8192) {
      changed = true;
      return { type: "text", text: "[图片等内容已在手机端省略,请在电脑上查看]" };
    }
    let blockChanged = false;
    const out: JsonObject = { ...b };
    for (const key of ["text", "thinking"] as const) {
      const v = out[key];
      if (typeof v === "string" && v.length > MOBILE_ENTRY_TEXT_CAP) {
        out[key] = `${v.slice(0, MOBILE_ENTRY_TEXT_CAP)}\n…[过长内容已截断,完整内容在电脑上可见]`;
        blockChanged = true;
      }
    }
    if (blockChanged) {
      changed = true;
      return out;
    }
    return block;
  });
  if (!changed) return entry;
  return { ...entry, message: { ...msg, content: cappedContent } };
}

/// 降级后必须保留的结构性字段:App 靠它们定位、排序、建树、辨类型。
/// 丢掉任何一个都会让这条 entry 在聊天页或会话树里失去位置。
const ENTRY_STRUCTURAL_KEYS = new Set([
  "id",
  "type",
  "timestamp",
  "parentId",
  "role",
  "customType",
  "modelId",
  "name",
  "firstKeptEntryId",
  "tokensBefore",
  "fromHook",
  "contentRef",
  "contentTruncated",
]);

/// 降级时给单个字段保留的可读开头长度。
const ENTRY_FIELD_PREVIEW_CHARS = 2048;

/// contentRef/contentTruncated 自身要占的余量,降级目标里先扣掉。
const ENTRY_DEGRADE_HEADROOM_BYTES = 512;

/// 与 entry 形状无关的兜底降级:按顶层字段体积从大到小逐个削,直到落进预算。
///
/// 为什么必须与形状无关:真机上冲破页预算的那条 entry 是 `compaction` 类型,
/// 它**根本没有 message 字段** —— 体积全在顶层 `summary`(单条实测 259KB 字符串)
/// 和 `details.observations/reflections`(实测 316KB 数组)里。只认 message 的
/// 封顶逻辑对它一个都不触发,于是 207KiB 单条从两道「上限」下面完整穿过去,
/// 把 96KiB 的页预算顶穿 2.2 倍(真机日志:entries:1/1728,bytes:212673)。
///
/// 削的顺序按体积降序,每削一个就重新量,够了就停 —— 尽量少破坏内容。
function degradeOversizedFields(entry: JsonObject, budget: number): JsonObject {
  const out: JsonObject = { ...entry };
  const sizeOf = (value: unknown): number =>
    value === undefined ? 0 : Buffer.byteLength(JSON.stringify(value) ?? "");
  const candidates = Object.keys(out)
    .filter((key) => !ENTRY_STRUCTURAL_KEYS.has(key))
    .map((key) => ({ key, bytes: sizeOf(out[key]) }))
    .sort((a, b) => b.bytes - a.bytes);

  for (const { key, bytes } of candidates) {
    if (Buffer.byteLength(JSON.stringify(out)) <= budget) break;
    const value = out[key];
    if (typeof value === "string") {
      // 字符串留可读开头:compaction 的 summary 是手机端唯一会显示的内容。
      if (value.length > ENTRY_FIELD_PREVIEW_CHARS) {
        out[key] =
          `${value.slice(0, ENTRY_FIELD_PREVIEW_CHARS)}` +
          `\n…[过长内容已截断(${bytes}B),完整内容在电脑上可见]`;
      }
      continue;
    }
    // 对象/数组整体换成标记:结构未知,逐层裁剪不可靠且没有收益,
    // 因为 App 对这些字段(如 compaction.details)本来就不渲染。
    out[key] = `[内容过大(${bytes}B)已省略,请在电脑上查看]`;
  }

  if (Buffer.byteLength(JSON.stringify(out)) <= budget) return out;
  // 兜底的兜底:仍然超限说明结构性字段本身异常大(或字段极多)。
  // 只留结构性字段,保证预算是真的硬。
  const skeleton: JsonObject = {};
  for (const key of Object.keys(out)) {
    if (ENTRY_STRUCTURAL_KEYS.has(key)) skeleton[key] = out[key];
  }
  return skeleton;
}

/// 单条 entry 的硬上限降级:字段级封顶之后仍然超限,就降级为 preview + contentRef。
///
/// 为什么必须有这一层:字段级封顶只处理已知字段(content/text/thinking/data)。
/// 一条 entry 可以靠几十个中等大小的块、未知结构的顶层字段、或者压根没有
/// message 的 entry 类型堆到几百 KB,字段级封顶一个都不触发。旧代码用
/// 「至少给 N 条」兜底,于是这种巨型单条直接突破页预算 —— 慢链路上首屏
/// 迟迟不来的原因之一。现在预算是硬的,超限单条只能降级,不允许突破。
function hardCapEntryForMobile(entry: JsonObject): JsonObject {
  const size = Buffer.byteLength(JSON.stringify(entry));
  if (size <= MOBILE_ENTRY_HARD_BYTES) return entry;
  const id = typeof entry.id === "string" ? entry.id : null;
  const message = entry.message;
  const msg =
    message && typeof message === "object" && !Array.isArray(message)
      ? (message as JsonObject)
      : undefined;

  let out: JsonObject;
  if (msg !== undefined) {
    // 保留可读开头:聊天页至少能看出这条是什么,点开再按需取全文。
    const preview = (() => {
      const content = msg.content;
      if (typeof content === "string") return content.slice(0, 2048);
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block && typeof block === "object" && !Array.isArray(block)) {
            const text = (block as JsonObject).text;
            if (typeof text === "string") return text.slice(0, 2048);
          }
        }
      }
      return "";
    })();
    out = {
      ...entry,
      message: {
        ...msg,
        content: [
          {
            type: "text",
            text: `${preview}\n…[单条内容过大(${size}B),已折叠。完整内容请在电脑上查看]`,
          },
        ],
      },
    };
  } else {
    // 没有 message 的 entry(compaction / branch_summary / 未知类型):
    // 不给它凭空造一个 message,交给形状无关的字段降级处理。
    out = { ...entry };
  }

  const budget = MOBILE_ENTRY_HARD_BYTES - ENTRY_DEGRADE_HEADROOM_BYTES;
  if (Buffer.byteLength(JSON.stringify(out)) > budget) {
    out = degradeOversizedFields(out, budget);
  }
  /// App 据此知道"这条被折叠过",可按需发起范围请求取全文。
  out.contentRef = id === null ? null : { entryId: id, bytes: size };
  out.contentTruncated = true;
  return out;
}

/// 从尾向前收集 entries,**字节预算是硬的**。
///
/// 旧实现有个「至少给 minEntries 条」的规则,允许突破 budgetBytes。后果:
/// 巨型单条(实测单条到过 1.16MB)会把首屏顶到几 MB,慢 TURN 上传输时间
/// 远超请求超时,表现为「连上→要快照→超时→重连」。现在改成:
/// - 单条先字段级封顶,再硬上限降级为 preview + contentRef;
/// - 预算不可突破,一条都放不下时也只放降级后的那一条(保证不是空卡)。
/// 单页 entries 的字节预算:按传输类型选。
///
/// P2P(慢 TURN)与 WS(局域网)的可用带宽差一个数量级,不能共用一个预算。
/// 真机实测端到端约 108KB/s:96KiB 一页约 0.9s,1MB 一页约 9.7s。
function entriesPageBudget(ws: WebSocket): number {
  return ws instanceof DataChannelSocket
    ? MAX_ENTRIES_PAGE_BYTES
    : MAX_MOBILE_ENTRIES_BYTES;
}

function clipEntriesForMobile(
  entries: JsonObject[],
  budgetBytes: number = MAX_MOBILE_ENTRIES_BYTES,
): ClippedEntries {
  let capped = false;
  const cappedEntries = entries.map((entry) => {
    const field = capEntryForMobile(entry);
    const next = hardCapEntryForMobile(field);
    if (next !== entry) capped = true;
    return next;
  });
  let bytes = 0;
  let start = cappedEntries.length;
  for (let i = cappedEntries.length - 1; i >= 0; i--) {
    // 预算必须按 UTF-8 字节而不是 UTF-16 字符数:中文/emoji 的字符数
    // 只有字节的 1/3,按字符放行会在分片后越过通道缓冲上限。
    const size = Buffer.byteLength(JSON.stringify(cappedEntries[i]));
    const taken = cappedEntries.length - i;
    // 预算硬约束。唯一例外是"最后一条也放不下":那就只放这一条(已降级到
    // ≤32KB),否则聊天页会是空的。
    if (bytes + size > budgetBytes && taken > 1) break;
    bytes += size;
    start = i;
    if (bytes >= budgetBytes) break;
  }
  const clipped = start === 0 ? cappedEntries : cappedEntries.slice(start);
  const first = clipped[0];
  // 压缩摘要卡是上下文边界的锚点:它位于 branch 头部,替代了被压缩掉的
  // 全部历史。从尾向前收会把它连同老历史一起砍掉,手机端于是「收到了
  // 压缩完成的提示,却怎么也看不到摘要卡」(得翻「加载更早」到顶才有)。
  // 把被砍部分里最近的一条 compaction/branch_summary 降级后保到结果最前 ——
  // 它已经过 hardCap(摘要留 2KB 开头),体积可控;分页游标 oldestId 仍指向
  // 窗口首条,这条锚点不参与分页,客户端按 id/timestamp 去重也不会重复渲染。
  if (start > 0) {
    for (let i = start - 1; i >= 0; i--) {
      const anchor = cappedEntries[i];
      if (anchor?.type === "compaction" || anchor?.type === "branch_summary") {
        clipped.unshift(anchor);
        break;
      }
    }
  }
  return {
    entries: clipped,
    omitted: start,
    oldestId: typeof first?.id === "string" ? first.id : null,
    capped,
  };
}

/// 无头源的会话文件绝对路径。descriptor 上的 sessionFile 由 get_state 回填,
/// 进程刚拉起时可能还没到,所以用 pool 里登记的 spec.sessionPath 兜底。
function headlessSessionPath(source: SourceDescriptor): string | undefined {
  if (typeof source.sessionFile === "string" && path.isAbsolute(source.sessionFile)) {
    return source.sessionFile;
  }
  const spec = pool.get(source.id)?.spec;
  if (spec?.sessionPath !== undefined && path.isAbsolute(spec.sessionPath)) {
    return spec.sessionPath;
  }
  return undefined;
}

/// 无头源的 get_entries:直接流式读会话文件,**不转发给 pi**。
///
/// 为什么必须绕开 pi:它的 RPC 没有 limit、也不认 before(只有 since)。
/// 真机实测后果是「慢」和「错」各一半:
/// - 慢:每次都序列化整个会话。50.40MB 实测 52,845,816B / 22.8s,
///   bridge 再裁到 78KiB,99.85% 白算,而且每翻一页都要付一次。
/// - 错:before 被忽略 → 返回全部 → 裁尾巴 → 每页都是同一批最新 33 条。
///   实测「第1页与上一页完全相同=true」,即「加载更早」对无头源不成立。
///
/// 会话文件是 append-only jsonl,顺序与 get_entries 一致(实测逐一匹配),
/// 所以本地分页既正确又省:内存 O(单页),一遍扫 50MB 约 0.3s。
async function handleHeadlessEntriesRead(
  client: MobileClient,
  source: SourceDescriptor,
  msg: BridgeMessage,
): Promise<void> {
  const sessionPath = headlessSessionPath(source);
  if (sessionPath === undefined) {
    // 拿不到路径就退回转发:宁可慢,也不能凭空报错。
    forwardSourceCommand(client, source, msg);
    return;
  }
  const budget = entriesPageBudget(client.ws);
  const cap = (entry: JsonObject): JsonObject =>
    hardCapEntryForMobile(capEntryForMobile(entry));
  const limit = Number.isSafeInteger(msg.limit)
    ? Math.max(1, Number(msg.limit))
    : undefined;

  const mode =
    typeof msg.before === "string"
      ? "before"
      : typeof msg.since === "string"
        ? "since"
        : "tail";
  const cursor =
    typeof msg.before === "string"
      ? msg.before
      : typeof msg.since === "string"
        ? msg.since
        : undefined;

  try {
    const page = await readEntriesPage(sessionPath, {
      mode,
      ...(cursor !== undefined ? { cursor } : {}),
      budgetBytes: budget,
      cap,
      ...(typeof msg.tipId === "string" ? { tipId: msg.tipId } : {}),
      ...(limit !== undefined ? { limit } : {}),
    });
    if (page.cursorNotFound) {
      respond(client.ws, msg, false, undefined, "entry cursor not found in session file");
      return;
    }
    const data: JsonObject =
      mode === "since" && msg.forward === true
        ? {
            entries: page.entries,
            leafId: page.leafId,
            nextSinceId: page.nextSinceId,
            tipId: page.tipId,
            hasMore: page.hasMore,
          }
        : {
            entries: page.entries,
            leafId: page.leafId,
            oldestId: page.oldestId,
            hasMore: page.hasMore,
          };
    respond(client.ws, msg, true, data);
    console.log(
      `[hub] entries_file{sourceId:${source.id},mode:${mode},` +
        `entries:${page.entries.length},bytes:${Buffer.byteLength(JSON.stringify(data))},` +
        `hasMore:${page.hasMore},scanned:${page.scannedEntries}/${(page.scannedBytes / 1048576).toFixed(1)}MB,` +
        `ms:${page.ms},p2p:${client.ws instanceof DataChannelSocket}}`,
    );
  } catch (error) {
    // 读文件失败(权限/被删/正在轮转)不能让请求悬着:退回转发给 pi。
    console.error(
      `[hub] 会话文件分页失败,退回转发 sourceId=${source.id} ` +
        `原因=${error instanceof Error ? error.message : String(error)}`,
    );
    forwardSourceCommand(client, source, msg);
  }
}

function handleDesktopRead(client: MobileClient, source: SourceDescriptor, msg: BridgeMessage): void {
  if (msg.type === "get_tree") {
    void handleDesktopTreeRead(client, source, msg);
    return;
  }
  const snapshot = sources.getSnapshot(source.id);
  if (!snapshot) {
    respond(client.ws, msg, false, undefined, "desktop snapshot is not available yet");
    return;
  }
  switch (msg.type) {
    case "get_state":
      respond(client.ws, msg, true, snapshot.state);
      return;
    case "get_entries": {
      const all = snapshot.entries;
      // 往前翻历史:返回游标之前那段的**尾巴**(最靠近游标的一批),
      // 才能与已显示的内容接上。
      if (typeof msg.before === "string") {
        const index = all.findIndex((entry) => entry.id === msg.before);
        if (index < 0) {
          respond(client.ws, msg, false, undefined, "entry cursor not found in desktop snapshot");
          return;
        }
        const older = all.slice(0, index);
        const limit = Number.isSafeInteger(msg.limit) ? Math.max(1, Number(msg.limit)) : undefined;
        const window = limit !== undefined ? older.slice(-limit) : older;
        // 往前翻历史必须按传输选预算。
        //
        // 这里原本用 clipEntriesForMobile 的默认值(1MB 的 WS 预算),对 P2P 也一样。
        // 真机 loopback 实测单页到过 1023.6KiB —— 按实测的约 108KB/s 端到端吞吐,
        // 一页要 9.7s;在 50KB/s 的慢 TURN 上约 20s,直接超过请求超时。
        // 「加载更早」于是表现为转圈很久然后失败。
        const clipped = clipEntriesForMobile(window, entriesPageBudget(client.ws));
        const pageData = {
          entries: clipped.entries,
          leafId: snapshot.leafId,
          oldestId: clipped.oldestId,
          // 还有更早的:要么本次窗口前面还剩,要么窗口内部又被字节预算砍了。
          hasMore: older.length > window.length || clipped.omitted > 0,
        };
        respond(client.ws, msg, true, pageData);
        console.log(
          `[hub] entries_before{sourceId:${source.id},entries:${clipped.entries.length}/${window.length},` +
            `bytes:${Buffer.byteLength(JSON.stringify(pageData))},hasMore:${pageData.hasMore},` +
            `p2p:${client.ws instanceof DataChannelSocket}}`,
        );
        return;
      }
      let entries = all;
      if (typeof msg.since === "string") {
        const index = entries.findIndex((entry) => entry.id === msg.since);
        if (index < 0) {
          respond(client.ws, msg, false, undefined, "entry cursor not found in desktop snapshot");
          return;
        }
        if (msg.forward === true) {
          // 正向翻页:从 since 之后**从头**取页(旧行为是尾部裁剪,会把
          // 排在前面的增量静默吞掉)。可选 tipId 把一次翻页 run 绑定到
          // 固定边界:翻页过程中源继续增长也不会漏/重,run 结束后
          // 调用方按 tipSeq 之后的实时事件对账。
          const tipId = typeof msg.tipId === "string" ? msg.tipId : undefined;
          let end = all.length;
          if (tipId !== undefined) {
            const tipIndex = all.findIndex((entry) => entry.id === tipId);
            if (tipIndex < 0) {
              respond(client.ws, msg, false, undefined, "tip cursor not found in desktop snapshot");
              return;
            }
            end = tipIndex + 1;
          }
          const window = all.slice(index + 1, end);
          const requested = Number.isSafeInteger(msg.limitBytes)
            ? Math.max(4096, Math.min(Number(msg.limitBytes), MAX_ENTRIES_PAGE_BYTES))
            : MAX_ENTRIES_PAGE_BYTES;
          const page: JsonObject[] = [];
          let pageBytes = 0;
          for (const entry of window) {
            const next = hardCapEntryForMobile(capEntryForMobile(entry));
            const size = Buffer.byteLength(JSON.stringify(next));
            // 至少放 1 条:巨型单条也不能把翻页卡死(降级后 ≤32KB)。
            if (page.length > 0 && pageBytes + size > requested) break;
            page.push(next);
            pageBytes += size;
          }
          const lastOfPage = page[page.length - 1];
          const resolvedTip =
            tipId ??
            (typeof all[all.length - 1]?.id === "string"
              ? (all[all.length - 1]!.id as string)
              : null);
          const pageData = {
            entries: page,
            leafId: snapshot.leafId,
            nextSinceId: typeof lastOfPage?.id === "string" ? lastOfPage.id : null,
            tipId: resolvedTip,
            hasMore: page.length < window.length,
          };
          respond(client.ws, msg, true, pageData);
          // 线上字节数:96KiB 硬上限是否真的生效,只能看这个数。
          console.log(
            `[hub] entries_page{sourceId:${source.id},entries:${page.length}/${window.length},` +
              `bytes:${Buffer.byteLength(JSON.stringify(pageData))},` +
              `hasMore:${pageData.hasMore},p2p:${client.ws instanceof DataChannelSocket}}`,
          );
          return;
        }
        entries = entries.slice(index + 1);
      }
      // 连增量都要封顶:手机离开很久后回来,since 之后的那段本身就可能几 MB。
      // 同样按传输选预算 —— P2P 慢链路上 1MB 一页是传不完的。
      const clipped = clipEntriesForMobile(entries, entriesPageBudget(client.ws));
      const incData = {
        entries: clipped.entries,
        leafId: snapshot.leafId,
        oldestId: clipped.oldestId,
        hasMore: clipped.omitted > 0,
      };
      respond(client.ws, msg, true, incData);
      console.log(
        `[hub] entries_since{sourceId:${source.id},entries:${clipped.entries.length},` +
          `bytes:${Buffer.byteLength(JSON.stringify(incData))},hasMore:${incData.hasMore},` +
          `p2p:${client.ws instanceof DataChannelSocket}}`,
      );
      return;
    }
    case "get_available_models":
      respond(client.ws, msg, true, { models: snapshot.models ?? [] });
      return;
    case "get_session_stats":
      if (!snapshot.stats) {
        respond(client.ws, msg, false, undefined, "desktop snapshot does not include stats");
        return;
      }
      respond(client.ws, msg, true, snapshot.stats);
      return;
    case "get_commands":
      respond(client.ws, msg, true, { commands: snapshot.commands ?? [] });
      return;
    case "get_available_thinking_levels":
      respond(client.ws, msg, true, {
        levels: snapshot.thinkingLevels ?? ["off", "minimal", "low", "medium", "high"],
      });
      return;
    default:
      respond(client.ws, msg, false, undefined, `${msg.type} is not available for desktop sources`);
  }
}

function requireSelectedSource(client: MobileClient, msg: BridgeMessage): SourceDescriptor | undefined {
  if (!client.selectedSourceId) {
    respond(client.ws, msg, false, undefined, "select a source first");
    return undefined;
  }
  const source = sources.get(client.selectedSourceId);
  if (!source?.connected) {
    respond(client.ws, msg, false, undefined, "selected source is offline");
    return undefined;
  }
  return source;
}

function requireLease(
  client: MobileClient,
  sourceId: string,
  msg: BridgeMessage,
): { fence: number } | undefined {
  const result = sources.validate(sourceId, client.clientId, msg._hub?.leaseId, msg._hub?.fence);
  if (!result?.ok) {
    respond(client.ws, msg, false, undefined, result?.error ?? "source not found");
    return undefined;
  }
  return { fence: result.lease.fence };
}

/**
 * 手机侧的问卷三帧:认领 / 应答 / 交还。
 *
 * 认账一律按 `requestId` 走,不看谁发的:同一个源上的观看者都是同一个人
 * (手机与电脑前的是同一双手),而 requestId 只有 hub 推过去的那一份能对上。
 */
function handleAskFrame(client: MobileClient, msg: BridgeMessage): void {
  const sourceId = client.selectedSourceId;
  if (!sourceId) {
    respond(client.ws, msg, false, undefined, "select a source first");
    return;
  }
  const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
  const ask = asksBySource.get(sourceId);
  // 对不上就说清是「过期」而不是「失败」—— 电脑那侧很可能已经接手作答了。
  if (!requestId || !ask || ask.requestId !== requestId) {
    respond(client.ws, msg, false, undefined, "这份问卷已经结束或已由电脑接手");
    return;
  }
  const desktop = desktopBySource.get(sourceId);
  if (!desktop) {
    clearAskForSource(sourceId, true);
    respond(client.ws, msg, false, undefined, "桌面端已断开");
    return;
  }

  if (msg.type === "ask_claim") {
    // 卡片已经画在前台、有人在看。relay 收到后把秒级的认领窗口换成分钟级的作答窗口。
    if (!ask.claimed) {
      ask.claimed = true;
      sendObject(desktop.ws, { type: "desktop_ask_claimed", requestId });
    }
    respond(client.ws, msg, true, { claimed: true });
    return;
  }

  if (msg.type === "ask_decline") {
    // 用户点了「在电脑上作答」:立刻放行 relay,让插件在电脑上弹它那套完整问卷。
    const sent = sendObject(desktop.ws, { type: "desktop_ask_declined", requestId });
    clearAskForSource(sourceId, true);
    respond(
      client.ws,
      msg,
      sent,
      sent ? { declined: true } : undefined,
      sent ? undefined : "桌面端连接不可用",
    );
    return;
  }

  // ask_response
  const answers = Array.isArray(msg.answers)
    ? msg.answers.filter((item): item is JsonObject => Boolean(item) && typeof item === "object")
    : [];
  if (answers.length === 0) {
    respond(client.ws, msg, false, undefined, "answers is required");
    return;
  }
  const sent = sendObject(desktop.ws, {
    type: "desktop_ask_result",
    requestId,
    epoch: ask.epoch,
    answers,
  });
  if (!sent) {
    respond(client.ws, msg, false, undefined, "桌面端连接不可用");
    return;
  }
  // 撤卡:这一份已经答完,其他在看同一个源的客户端要同步收起卡片。
  clearAskForSource(sourceId, true);
  respond(client.ws, msg, true, { delivered: true });
}

function handleSourceCommand(client: MobileClient, msg: BridgeMessage): void {
  // 问卷三帧最先处理:它们只可能来自桌面源,绝不该触发下面的休眠唤醒
  // (那会为一份问卷 spawn 一个 pi 进程)。也不要求租约 —— 这份问卷是 hub
  // 主动推给这台手机的,谁先答谁算,按 requestId 认账就够;要租约反而会在
  // App 没自动取到控制权时,把「作答」变成一句「需要先取得控制」。
  if (
    msg.type === "ask_claim" ||
    msg.type === "ask_response" ||
    msg.type === "ask_decline"
  ) {
    handleAskFrame(client, msg);
    return;
  }
  // 新版 App 会在 sendPrompt 里拦住 /compact;旧版或漏网客户端仍可能把它
  // 当 prompt 发来。这里只翻译帧,继续走休眠唤醒、租约、流式守卫和串行队列。
  msg = translateCompactPrompt(msg) ?? msg;
  // headless 的 prompt 会展开扩展命令。用户以为自己在发一句话,pi 却执行了一条
  // 命令 —— 这是既有的静默 bug,在这里堵掉。
  if (
    msg.type === "prompt" &&
    typeof msg.message === "string" &&
    msg.message.startsWith("/") &&
    !ALLOWED_SLASH_COMMANDS.test(msg.message)
  ) {
    respond(
      client.ws,
      msg,
      false,
      undefined,
      "slash commands are not supported here; send plain text",
    );
    return;
  }
  // 休眠会话的懒唤醒:**只有写命令**才 attach/spawn 进程,只读命令仍如实回答"离线"。
  // 老版 App 没有 hub_open_session,靠这条路径继续工作;池不 kill 任何东西,
  // 所以唤醒 B 会话不会影响正在生成的 A 会话。
  if (typeof msg.type === "string" && !isReadOnlySourceCommand(msg.type) && client.selectedSourceId) {
    const dormant = sources.get(client.selectedSourceId);
    if (dormant?.kind === "headless" && !dormant.connected) {
      try {
        ensureSession({
          sessionId: dormant.sessionId ?? currentSessionId,
          cwd: dormant.cwd ?? currentCwd,
        });
      } catch (error) {
        respond(
          client.ws,
          msg,
          false,
          undefined,
          error instanceof Error ? error.message : String(error),
        );
        return;
      }
    }
  }
  const source = requireSelectedSource(client, msg);
  if (!source || typeof msg.type !== "string") return;

  // 扩展 UI 对话框应答:仅 owner、仅 headless。pi 对该帧不回响应,
  // 因此 fire-and-forget,并广播 extension_ui_answered 让其他客户端撤卡片。
  if (msg.type === "extension_ui_response") {
    if (!requireLease(client, source.id, msg)) return;
    if (source.kind !== "headless") {
      respond(client.ws, msg, false, undefined, "desktop dialogs must be answered in the TUI");
      return;
    }
    if (typeof msg.uiRequestId !== "string" || msg.uiRequestId.length === 0) {
      respond(client.ws, msg, false, undefined, "uiRequestId is required");
      return;
    }
    const frame: JsonObject = { type: "extension_ui_response", id: msg.uiRequestId };
    if (msg.value !== undefined) frame.value = msg.value;
    if (msg.confirmed !== undefined) frame.confirmed = msg.confirmed;
    if (msg.cancelled !== undefined) frame.cancelled = msg.cancelled;
    const sent = sources.transport(source.id)?.send(frame) === true;
    respond(
      client.ws,
      msg,
      sent,
      sent ? { delivered: true } : undefined,
      sent ? undefined : "source is not available",
    );
    if (sent) {
      const event = sources.recordLocalEvent(source.id, {
        type: "extension_ui_answered",
        requestId: msg.uiRequestId,
      });
      if (event.ok) broadcastSourceEvent(event.event);
    }
    return;
  }

  if (isReadOnlySourceCommand(msg.type)) {
    if (source.kind === "desktop") handleDesktopRead(client, source, msg);
    else if (msg.type === "get_entries" && headlessSessionPath(source) !== undefined) {
      void handleHeadlessEntriesRead(client, source, msg);
    } else forwardSourceCommand(client, source, msg);
    return;
  }

  if (!requireLease(client, source.id, msg)) return;
  // 服务端流式守卫:客户端的 isStreaming 本身可能是坏的,不能只信它
  if (SESSION_MUTATING_COMMANDS.has(msg.type) && sourceIsStreaming(source.id)) {
    respond(
      client.ws,
      msg,
      false,
      undefined,
      "streaming_guard: source is streaming; abort first",
    );
    return;
  }
  if (source.kind === "desktop" && !isDesktopMutationCommand(msg.type)) {
    respond(client.ws, msg, false, undefined, `${msg.type} is not supported by the desktop relay`);
    return;
  }
  if (source.kind === "desktop" && !source.capabilities.includes(msg.type)) {
    respond(client.ws, msg, false, undefined, `desktop source does not advertise ${msg.type}`);
    return;
  }
  forwardSourceCommand(client, source, msg);
}

async function handleHubCommand(client: MobileClient, msg: BridgeMessage): Promise<void> {
  try {
    // Q1 准入控制:交互队列已堵时,在执行前用小 control 帧拒答,
    // 而不是执行完再把响应塞进排不上的队列。响应永不丢,请求方可重试 ——
    // 静默拒答会制造"超时→重发→更堵"的回旋镖。
    if (
      client.ws instanceof DataChannelSocket &&
      client.ws.interactiveQueuedBytes > P2P_INTERACTIVE_QUEUE_MAX_BYTES
    ) {
      client.ws.sendPriority(
        JSON.stringify({
          type: "response",
          command: msg.type,
          ...(typeof msg.id === "string" ? { id: msg.id } : {}),
          success: false,
          error: "busy",
          retryAfterMs: 1000,
        }),
      );
      return;
    }
    switch (msg.type) {
      // --- 通知事件协议(stable-plan.md §7)------------------------------
      // 这条链路与 UI 的 hub_sync 完全独立:hub_sync 面向 source 状态,
      // 通知 cursor 面向「用户该被提醒什么」。混用会让一次改动同时
      // 影响两条链路,所以刻意不复用 parseCursor。
      case "notification_subscribe": {
        const request = parseSubscribeRequest({
          ...msg,
          id: notificationSubscriptionIdFor(client.clientId),
        });
        if (request === undefined) {
          respond(client.ws, msg, false, undefined, "invalid notification_subscribe");
          return;
        }
        const result = notificationSubscriptions.subscribe(request);
        respond(client.ws, msg, true, result);
        // catch-up 已在首页返回;若一次就追平,排空 live buffer 后立刻宣布 ready。
        // ready 绝不能在 socket 打开时就发 —— 那正是当前实现过早抑制兜底通知的缺陷。
        if (result.type === "notification_events" && !result.hasMore) {
          const drained = notificationSubscriptions.drainLiveBuffer(request.id);
          if ("events" in drained && (drained.events.length > 0 || drained.skipped.length > 0)) {
            sendObject(client.ws, {
              type: "notification_events",
              eventEpoch: bridgeIdentity.eventEpoch,
              bridgeNow: new Date().toISOString(),
              events: drained.events,
              skippedRanges: mergeSkipped(drained.skipped),
              live: true,
            });
          }
          const ready = notificationSubscriptions.markReady(request.id);
          if (ready !== undefined) sendObject(client.ws, ready);
        }
        return;
      }

      case "notification_next_page": {
        const subscriptionId = notificationSubscriptionIdFor(client.clientId);
        const scopeVersion =
          typeof msg.scopeVersion === "number" ? msg.scopeVersion : undefined;
        const page = notificationSubscriptions.nextPage(subscriptionId, scopeVersion);
        if (page === undefined) {
          respond(client.ws, msg, false, undefined, "no active notification subscription");
          return;
        }
        respond(client.ws, msg, true, page);
        if (page.type === "notification_events" && !page.hasMore) {
          const drained = notificationSubscriptions.drainLiveBuffer(subscriptionId);
          if ("events" in drained && (drained.events.length > 0 || drained.skipped.length > 0)) {
            sendObject(client.ws, {
              type: "notification_events",
              eventEpoch: bridgeIdentity.eventEpoch,
              bridgeNow: new Date().toISOString(),
              events: drained.events,
              skippedRanges: mergeSkipped(drained.skipped),
              live: true,
            });
          }
          const ready = notificationSubscriptions.markReady(subscriptionId);
          if (ready !== undefined) sendObject(client.ws, ready);
        }
        return;
      }

      case "notification_ack": {
        const request = parseAckRequest(msg);
        if (request === undefined) {
          respond(client.ws, msg, false, undefined, "invalid notification_ack");
          return;
        }
        const result = notificationSubscriptions.ack(request);
        if (result.ok) respond(client.ws, msg, true, { through: request.through });
        else respond(client.ws, msg, false, undefined, result.error);
        return;
      }

      case "notification_receipt": {
        const request = parseReceiptRequest(msg);
        if (request === undefined) {
          respond(client.ws, msg, false, undefined, "invalid notification_receipt");
          return;
        }
        // receipt 只服务仲裁与指标,不推进 cursor(§7.4)。允许显著延迟到达,
        // 所以这里只记录,不因它做任何状态推进。
        notificationReceipts.record(request);
        respond(client.ws, msg, true, { recorded: true });
        return;
      }

      case "hub_list_sources":
        respond(client.ws, msg, true, { hubId: sources.hubId, sources: sources.list(client.clientId) });
        return;

      case "hub_select_source": {
        const sourceId = resolveSourceId(typeof msg.sourceId === "string" ? msg.sourceId : "");
        const source = sources.get(sourceId);
        if (!source || (!source.connected && source.kind !== "headless")) {
          respond(client.ws, msg, false, undefined, "source is missing or offline");
          return;
        }
        const previous = client.selectedSourceId;
        // 先设选中,后续的 snapshot 广播才会送到这个客户端
        client.selectedSourceId = sourceId;
        // 仅在快照与事件流已经断层(或正在生成、快照必然过时)时才往返索要,
        // 否则空等一个 4s 超时。
        if (
          source.kind === "desktop" &&
          source.connected &&
          (!sources.snapshotIsContinuous(sourceId) || sourceIsStreaming(sourceId))
        ) {
          await requestDesktopSnapshot(sourceId);
        }
        respond(client.ws, msg, true, {
          hubId: sources.hubId,
          source: sourceForClient(client, sourceId),
          snapshotFresh: sources.snapshotIsContinuous(sourceId),
        });
        if (previous) pushDesktopStatus(previous);
        pushDesktopStatus(sourceId);
        // 电脑可能正卡在一份问卷上等人答 —— 重连/换源后要让手机重新看见它。
        republishAsk(sourceId);
        return;
      }

      case "hub_op_status": {
        // 写操作对账:手机断线重连后逐条确认 pending 的 opId。
        const opId = typeof msg.opId === "string" ? msg.opId : "";
        const rec = opRegistry.get(opId);
        respond(client.ws, msg, true, { status: rec?.status ?? "unknown" });
        return;
      }

      case "hub_sync": {
        const syncStartedAt = Date.now();
        const source = requireSelectedSource(client, msg);
        if (!source) return;
        let sync = sources.sync(source.id, parseCursor(msg.cursor));
        if (!sync) {
          respond(client.ws, msg, false, undefined, "source not found");
          return;
        }
        // 快照与事件流断层时先索要一份新快照(4s 上限,远小于 App 的 20s 请求超时);
        // 桌面不在线或超时就照原样答复 continuous:false,迟到的快照会走广播自愈。
        if (sync.mode === "snapshot" && !sync.continuous && source.kind === "desktop" && source.connected) {
          if (await requestDesktopSnapshot(source.id)) {
            sync = sources.sync(source.id, parseCursor(msg.cursor)) ?? sync;
          }
        }
        // 只把 entries 的尾巴发给手机。全量快照实测到过 10.27MB,而套接字缓冲上限
        // 是 2MB —— 巨包本身发得出去,但紧接着的任何一次发送都会看到超限而
        // close(1013),手机于是约 2 秒一轮地重连。更早的历史由 get_entries 的
        // before 分页按需补齐。
        // 事件重放页也必须有界。手机离开很久后回来,cursor 之后那段事件本身
        // 就可能几 MB —— 和 entries 一样会把一帧顶到远超慢链路能承受的体积。
        //
        // 只能砍尾巴(保留自 cursor 起的连续前缀):砍头会让客户端从一个不连续
        // 的序号开始应用,状态直接错乱。砍尾后客户端的 cursor 前进到最后一条
        // 已应用事件,再发一次 hub_sync 继续取,分多轮补齐。
        const allEventFrames = sync.events.map(eventFrame);
        const eventPage: JsonObject[] = [];
        let eventBytes = 0;
        for (const frame of allEventFrames) {
          const size = Buffer.byteLength(JSON.stringify(frame));
          // 至少放 1 条:单条超预算也要给出去,否则客户端 cursor 永远推不动。
          if (eventPage.length > 0 && eventBytes + size > MAX_EVENT_PAGE_BYTES) break;
          eventPage.push(frame);
          eventBytes += size;
        }
        const eventsTruncated = eventPage.length < allEventFrames.length;

        const payload: JsonObject = {
          hubId: sources.hubId,
          sourceId: source.id,
          sourceEpoch: source.epoch,
          mode: sync.mode,
          continuous: sync.continuous,
          events: eventPage,
        };
        if (eventsTruncated) {
          // 告诉客户端"还有,请再来一次":它按已应用的最后一条事件推进 cursor
          // 后立刻再 hub_sync,而不是以为已经追平。
          payload.eventsTruncated = true;
          payload.eventsRemaining = allEventFrames.length - eventPage.length;
        }
        if (sync.mode === "rpc") payload.baseSeq = sync.baseSeq;
        if (sync.mode === "snapshot") {
          // P2P 慢链路首载必须小(~2.6s 线耗);WS 局域网保持 1MB。
          const isP2p = client.ws instanceof DataChannelSocket;
          const totalBudget = isP2p
            ? MAX_MOBILE_ENTRIES_BYTES_P2P
            : MAX_MOBILE_ENTRIES_BYTES;
          // 预算必须扣掉响应外壳,否则"硬上限"是假的。
          //
          // 真机实测:只给 entries 数组设 128KiB 预算时,整帧实际是 148,217B ——
          // 超限 13%。因为 state(会话状态、模型、统计)、events、元数据都不在
          // entries 里,但它们同样要过线。慢链路上多出来的每 KB 都是真实延迟。
          const envelope: JsonObject = {
            ...payload,
            snapshot: { ...sync.snapshot, entries: [] },
          };
          const envelopeBytes = Buffer.byteLength(JSON.stringify(envelope));
          // 外壳本身可能就很大(state 里有大字段):至少留 16KiB 给 entries,
          // 否则会退化成一条都发不出去的空卡。
          const entriesBudget = Math.max(
            16 * 1024,
            totalBudget - envelopeBytes,
          );
          const clipped = clipEntriesForMobile(
            sync.snapshot.entries,
            entriesBudget,
          );
          // 浅拷贝:注册表里那份必须保持完整,别的客户端和往前分页都还要用。
          // omitted 为 0 但有 entry 被封顶时同样要用改过的新数组。
          payload.snapshot =
            clipped.omitted > 0 || clipped.capped
              ? { ...sync.snapshot, entries: clipped.entries }
              : sync.snapshot;
          if (clipped.omitted > 0) {
            payload.entriesOmitted = clipped.omitted;
            payload.entriesOldestId = clipped.oldestId;
            payload.entriesHasMore = true;
          }
        }
        // 线上字节数是诊断"慢"的核心量:50KB/s 的 TURN 上,128KiB 首屏 ≈ 2.6s
        // 线耗。只看服务端处理耗时(ms)会得出"很快"的错误结论 —— 那只是
        // 组包时间,不含传输时间。
        const payloadBytes = Buffer.byteLength(JSON.stringify(payload));
        respond(client.ws, msg, true, payload);
        const syncEntries =
          sync.mode === "snapshot" ? (payload.snapshot as { entries?: unknown[] })?.entries?.length ?? 0 : 0;
        console.log(
          `[hub] hub_sync{sourceId:${source.id},mode:${sync.mode},continuous:${sync.continuous},` +
            `entries:${syncEntries},events:${eventPage.length}/${allEventFrames.length},` +
            `eventsTruncated:${eventsTruncated},p2p:${client.ws instanceof DataChannelSocket},` +
            `bytes:${payloadBytes},omitted:${payload.entriesOmitted ?? 0},` +
            `ms:${Date.now() - syncStartedAt}}`,
        );
        return;
      }

      case "hub_list_sessions": {
        const cwd = typeof msg.cwd === "string" ? msg.cwd : undefined;
        respond(client.ws, msg, true, {
          hubId: sources.hubId,
          sessions: collectSessions(cwd),
          cwd: cwd ?? currentCwd,
        });
        return;
      }

      case "hub_open_session": {
        // 打开 = 订阅 + 按需 attach/spawn。**从不 kill 任何进程**,
        // 所以电脑端或另一个会话正在生成时,这个调用完全无感。
        const cwd =
          typeof msg.cwd === "string" && path.isAbsolute(msg.cwd) ? msg.cwd : currentCwd;
        const requestedId = typeof msg.sessionId === "string" ? msg.sessionId : undefined;
        const spawn = msg.spawn !== false;

        // 已经在电脑端跑的会话:只订阅,绝不为它另开进程(会写坏同一个会话文件)
        const desktop = requestedId
          ? sources
              .list()
              .find((item) => item.kind === "desktop" && item.sessionId === requestedId)
          : undefined;
        let sourceId: string;
        if (desktop) {
          sourceId = desktop.id;
        } else {
          let resolvedPath: { path: string; sessionId: string } | undefined;
          try {
            resolvedPath = resolveSessionPath(cwd, msg.sessionPath);
          } catch (error) {
            respond(
              client.ws,
              msg,
              false,
              undefined,
              error instanceof Error ? error.message : String(error),
            );
            return;
          }
          // 会话 id 以**文件里写的**为准,不信客户端声明的 —— 否则 claim 表会用
          // 一个假 id 做键,同一个文件就能被两个进程打开。
          const sessionId = resolvedPath?.sessionId ?? requestedId ?? PiPool.newSessionId();
          const spec: SessionSpec = {
            sessionId,
            cwd,
            ...(resolvedPath ? { sessionPath: resolvedPath.path } : {}),
          };
          try {
            if (spawn) {
              sourceId = ensureSession(spec);
            } else {
              sourceId = sourceIdForSession(sessionId);
              if (registerHeadlessSource(sourceId, spec)) notifySourcesChanged();
            }
          } catch (error) {
            respond(
              client.ws,
              msg,
              false,
              undefined,
              error instanceof Error ? error.message : String(error),
            );
            return;
          }
          if (!requestedId) {
            config.dirSessions[cwd] = sessionId;
            writeFileConfig({ dirSessions: config.dirSessions });
          }
        }

        const previous = client.selectedSourceId;
        client.selectedSourceId = sourceId;
        const source = sources.get(sourceId);
        if (
          source?.kind === "desktop" &&
          source.connected &&
          (!sources.snapshotIsContinuous(sourceId) || sourceIsStreaming(sourceId))
        ) {
          await requestDesktopSnapshot(sourceId);
        }
        respond(client.ws, msg, true, {
          hubId: sources.hubId,
          sourceId,
          source: sourceForClient(client, sourceId),
          snapshotFresh: sources.snapshotIsContinuous(sourceId),
        });
        if (previous && previous !== sourceId) pushDesktopStatus(previous);
        pushDesktopStatus(sourceId);
        notifySessionsChanged();
        return;
      }

      case "hub_close_session": {
        const sourceId = resolveSourceId(
          typeof msg.sourceId === "string" ? msg.sourceId : (client.selectedSourceId ?? ""),
        );
        const source = sources.get(sourceId);
        if (!source) {
          respond(client.ws, msg, false, undefined, "source not found");
          return;
        }
        if (source.kind !== "headless") {
          respond(client.ws, msg, false, undefined, "only headless sessions can be closed here");
          return;
        }
        if (sourceIsStreaming(sourceId)) {
          respond(
            client.ws,
            msg,
            false,
            undefined,
            "streaming_guard: source is streaming; abort first",
          );
          return;
        }
        await pool.close(sourceId, "closed by client");
        sources.setConnected(sourceId, false);
        broadcastHubEvent("hub_source_offline", { sourceId, reason: "closed" });
        notifySourcesChanged();
        respond(client.ws, msg, true, { sourceId, closed: true });
        return;
      }

      case "hub_acquire_owner": {
        // 租约现在只做 fencing 与归因:**没有任何进程副作用**。
        // 拿租约不再启动/停止 pi,也不再因为桌面 TUI 在线而被拒绝
        // ——两端本来就应该能同时驱动各自的会话。
        const sourceId = client.selectedSourceId;
        const source = sourceId ? sources.get(sourceId) : undefined;
        if (!source) {
          respond(client.ws, msg, false, undefined, "select a source first");
          return;
        }
        if (source.kind === "desktop" && !source.connected) {
          respond(client.ws, msg, false, undefined, "selected desktop source is offline");
          return;
        }
        const ttlMs = clampLeaseTtl(msg.ttlMs, config.leaseMinTtlMs, config.leaseMaxTtlMs);
        // 默认强制抢占:死客户端的租约不该让活人等一个 TTL。
        const force = msg.force !== false;
        const result = sources.acquire(source.id, client.clientId, ttlMs, { force });
        if (!result?.ok) {
          respond(client.ws, msg, false, undefined, result?.error ?? "source not found");
          return;
        }
        respond(client.ws, msg, true, { ...result.lease, sourceId: source.id });
        if (result.stolenFrom && result.stolenFrom !== client.clientId) {
          // 告诉被抢的一端"控制已转移",它据此作废在途命令而不是傻等超时
          broadcastControlMoved(source.id, result.stolenFrom, client.clientId);
        }
        notifyOwnerChanged(source.id);
        return;
      }

      case "hub_renew_owner": {
        const source = requireSelectedSource(client, msg);
        if (!source) return;
        if (
          typeof msg.leaseId !== "string" ||
          typeof msg.fence !== "number" ||
          !Number.isSafeInteger(msg.fence)
        ) {
          respond(client.ws, msg, false, undefined, "invalid lease identity");
          return;
        }
        const ttlMs = clampLeaseTtl(msg.ttlMs, config.leaseMinTtlMs, config.leaseMaxTtlMs);
        const result = sources.renew(
          source.id,
          client.clientId,
          msg.leaseId,
          msg.fence,
          ttlMs,
        );
        if (!result?.ok) {
          respond(client.ws, msg, false, undefined, result?.error ?? "source not found");
          return;
        }
        respond(client.ws, msg, true, { ...result.lease, sourceId: source.id });
        notifyOwnerChanged(source.id);
        return;
      }

      case "hub_release_owner": {
        const source = requireSelectedSource(client, msg);
        if (!source) return;
        const released = sources.release(
          source.id,
          client.clientId,
          typeof msg.leaseId === "string" ? msg.leaseId : undefined,
          typeof msg.fence === "number" ? msg.fence : undefined,
        );
        respond(client.ws, msg, released, released ? { released: true } : undefined, released ? undefined : "lease not held");
        if (released) notifyOwnerChanged(source.id);
        return;
      }

      default:
        respond(client.ws, msg, false, undefined, `unknown hub command: ${msg.type}`);
    }
  } catch (error) {
    respond(client.ws, msg, false, undefined, error instanceof Error ? error.message : String(error));
  }
}

async function handleBridgeCommand(client: MobileClient, msg: BridgeMessage): Promise<void> {
  try {
    switch (msg.type) {
      case "bridge_ping": {
        const pong = JSON.stringify({
          type: "bridge_pong",
          t: Date.now(),
          // echo 原样回传,客户端据此计算 RTT
          ...(msg.echo !== undefined ? { echo: msg.echo } : {}),
        });
        // P2P 慢链路上 pong 不能排在 MB 级快照分片后面,否则手机 45s
        // 收不到 pong 会把健康连接误判成半开。
        if (client.ws instanceof DataChannelSocket) client.ws.sendPriority(pong);
        else sendRaw(client.ws, pong);
        return;
      }

      case "bridge_list_dirs":
        respond(client.ws, msg, true, { dirs: listDirs(), sessionsRoot: SESSIONS_ROOT });
        return;

      case "bridge_list_sessions": {
        const selected = client.selectedSourceId ? sources.get(client.selectedSourceId) : undefined;
        const cwd = typeof msg.cwd === "string" ? msg.cwd : (selected?.cwd ?? currentCwd);
        respond(client.ws, msg, true, { cwd, sessions: listSessions(cwd) });
        return;
      }

      case "bridge_switch_dir": {
        const source = requireSelectedSource(client, msg);
        if (!source || source.kind !== "headless") {
          if (source) respond(client.ws, msg, false, undefined, "directory switching requires the headless source");
          return;
        }
        if (!requireLease(client, source.id, msg)) return;
        if (typeof msg.cwd !== "string" || !path.isAbsolute(msg.cwd)) {
          respond(client.ws, msg, false, undefined, "cwd must be an absolute path");
          return;
        }
        const cwd = fs.realpathSync(msg.cwd);
        if (!fs.statSync(cwd).isDirectory()) {
          respond(client.ws, msg, false, undefined, "cwd is not a directory");
          return;
        }
        let requestedSession: { path: string; sessionId: string } | undefined;
        try {
          requestedSession = resolveSessionPath(cwd, msg.sessionPath);
        } catch (error) {
          respond(
            client.ws,
            msg,
            false,
            undefined,
            error instanceof Error ? error.message : String(error),
          );
          return;
        }
        const sessionId =
          requestedSession?.sessionId ?? config.dirSessions[cwd] ?? crypto.randomUUID();
        if (config.dirSessions[cwd] !== sessionId) {
          config.dirSessions[cwd] = sessionId;
          writeFileConfig({ dirSessions: config.dirSessions });
        }
        // 换目录 = 打开另一个会话,**不再重启当前进程**。
        // 正在生成的会话继续生成,所以这里也不再需要 streaming 守卫。
        let targetSourceId: string;
        try {
          targetSourceId = ensureSession({
            sessionId,
            cwd,
            sessionPath: requestedSession?.path,
          });
        } catch (error) {
          respond(
            client.ws,
            msg,
            false,
            undefined,
            error instanceof Error ? error.message : String(error),
          );
          return;
        }
        currentCwd = cwd;
        currentSessionId = sessionId;
        bootstrapSourceId = targetSourceId;
        // 老版 App 认为切目录后仍停在原 sourceId 上,这里替它改选中
        client.selectedSourceId = targetSourceId;
        const event = sources.recordLocalEvent(targetSourceId, {
          type: "bridge_dir_switched",
          cwd,
          sessionId,
        });
        if (event.ok) broadcastSourceEvent(event.event);
        notifySourcesChanged();
        respond(client.ws, msg, true, { cwd, sessionId, sourceId: targetSourceId });
        pushDesktopStatus(targetSourceId);
        return;
      }

      case "bridge_get_config":
        respond(client.ws, msg, true, {
          piCwd: currentCwd,
          sessionId: currentSessionId,
          port: config.port,
          sessionsRoot: SESSIONS_ROOT,
          tokenPinned: !config.tokenGenerated,
          hubId: sources.hubId,
        });
        return;

      case "bridge_set_config": {
        const source = requireSelectedSource(client, msg);
        if (!source || !requireLease(client, source.id, msg)) return;
        if (typeof msg.token === "string" && msg.token.length >= 8) {
          config.token = msg.token;
          config.tokenGenerated = false;
          writeFileConfig({ token: msg.token });
          respond(client.ws, msg, true, { tokenUpdated: true });
        } else {
          respond(client.ws, msg, false, undefined, "unsupported field or weak token (min 8 chars)");
        }
        return;
      }

      default:
        respond(client.ws, msg, false, undefined, `unknown bridge command: ${msg.type}`);
    }
  } catch (error) {
    respond(client.ws, msg, false, undefined, error instanceof Error ? error.message : String(error));
  }
}

function pendingCountFor(sourceId: string): number {
  let count = 0;
  for (const request of pending.values()) {
    if (request.sourceId === sourceId) count++;
  }
  return count;
}

const pool = new PiPool(config, {
  watchers: watchersOf,
  pendingCount: pendingCountFor,

  onSpawn(entry) {
    streamingBySource.delete(entry.sourceId);
    // 每次 spawn 换 epoch:进程重启后事件序号从头开始
    sources.setConnected(entry.sourceId, true, crypto.randomUUID());
    sources.updateMetadata(entry.sourceId, {
      cwd: entry.spec.cwd,
      sessionId: entry.spec.sessionId,
    });
    const event = sources.recordLocalEvent(entry.sourceId, {
      type: "bridge_pi_start",
      pid: entry.proc.pid,
    });
    if (event.ok) broadcastSourceEvent(event.event);
    notifySourcesChanged();
  },

  onExit(entry, code, signal) {
    streamingBySource.delete(entry.sourceId);
    sources.setConnected(entry.sourceId, false);
    failPendingForSource(entry.sourceId, "headless pi process exited");
    broadcastHubEvent("hub_source_offline", {
      sourceId: entry.sourceId,
      code,
      signal,
    });
    notifySourcesChanged();
  },

  onClosing(entry, reason) {
    streamingBySource.delete(entry.sourceId);
    failPendingForSource(entry.sourceId, reason);
  },

  onDead(entry, reason) {
    streamingBySource.delete(entry.sourceId);
    // 明确告诉 App「这个会话死了」,而不是让它对着一个永远离线的源等下去
    broadcastHubEvent("hub_session_died", {
      sourceId: entry.sourceId,
      sessionId: entry.spec.sessionId,
      reason,
      stderr: entry.proc.stderrTail.slice(-800),
    });
    notifySourcesChanged();
  },

  onLine(entry, line) {
    let message: JsonObject;
    try {
      message = JSON.parse(line) as JsonObject;
    } catch {
      return;
    }
    if (message.type === "response" && typeof message.id === "string") {
      const request = pending.get(message.id);
      if (
        request &&
        message.command === "get_state" &&
        message.data &&
        typeof message.data === "object"
      ) {
        const state = message.data as JsonObject;
        sources.updateMetadata(entry.sourceId, {
          cwd: typeof state.cwd === "string" ? state.cwd : entry.spec.cwd,
          sessionId:
            typeof state.sessionId === "string"
              ? state.sessionId
              : entry.spec.sessionId,
          sessionFile:
            typeof state.sessionFile === "string" ? state.sessionFile : undefined,
          sessionName:
            typeof state.sessionName === "string" ? state.sessionName : undefined,
        });
        pool.noteHealthy(entry.sourceId);
        // switch_session / fork / clone / new_session 会让这个进程换掉会话文件。
        // 不重绑 claim 的话,别人能为"它已经不再持有"的那个会话再开一个 pi。
        if (typeof state.sessionId === "string") {
          try {
            pool.rebind(
              entry.sourceId,
              state.sessionId,
              typeof state.sessionFile === "string" ? state.sessionFile : undefined,
            );
          } catch (error) {
            console.error("[bridge] failed to rebind session claim:", error);
          }
        }
      }
      resolvePending(message.id, message, entry.sourceId);
      return;
    }
    noteStreamingFromEvent(entry.sourceId, message.type);
    pool.setStreaming(entry.sourceId, sourceIsStreaming(entry.sourceId));
    const event = sources.recordLocalEvent(entry.sourceId, message);
    if (event.ok) broadcastSourceEvent(event.event);
  },
});

/// 确保某个 headless 会话有活着的进程(attach 或 spawn),并登记为 source。
function ensureSession(spec: SessionSpec): string {
  const sourceId = sourceIdForSession(spec.sessionId);
  // 懒唤醒的调用方只知道 sessionId/cwd —— 把之前登记的 sessionPath 补回来
  const known = dormantSpecs.get(sourceId);
  if (!spec.sessionPath && known?.sessionPath) {
    spec = { ...spec, sessionPath: known.sessionPath };
  }
  // 顺序是硬要求:`proc.start()` 会**同步**触发 onSpawn,那时 source 必须已经
  // 在 registry 里,否则换 epoch 和 bridge_pi_start 事件都会静默丢掉。
  const registered = registerHeadlessSource(sourceId, spec);
  try {
    pool.open(spec);
  } catch (error) {
    // 开不起来就撤回这次注册,免得留下一个永远离线的幽灵 source
    if (registered) sources.remove(sourceId);
    throw error;
  }
  if (registered) notifySourcesChanged();
  return sourceId;
}

/// 闲置回收:只回收没人看、不在生成、没有在途请求的会话。
const idleSweeper = setInterval(() => {
  if (shuttingDown) return;
  for (const sourceId of pool.idleCandidates(Date.now())) {
    void pool.close(sourceId, "idle timeout");
  }
}, 60_000);
idleSweeper.unref();

function parseSnapshot(value: unknown): SourceSnapshot | undefined {
  if (!value || typeof value !== "object") return undefined;
  const snapshot = value as Partial<SourceSnapshot>;
  if (
    typeof snapshot.epoch !== "string" ||
    typeof snapshot.baseSeq !== "number" ||
    !Number.isSafeInteger(snapshot.baseSeq) ||
    !snapshot.state ||
    typeof snapshot.state !== "object" ||
    !Array.isArray(snapshot.entries) ||
    !(typeof snapshot.leafId === "string" || snapshot.leafId === null)
  ) {
    return undefined;
  }
  return {
    epoch: snapshot.epoch,
    baseSeq: snapshot.baseSeq,
    capturedAt: typeof snapshot.capturedAt === "number" ? snapshot.capturedAt : Date.now(),
    state: snapshot.state as JsonObject,
    entries: snapshot.entries.filter(
      (entry): entry is JsonObject => Boolean(entry) && typeof entry === "object",
    ),
    leafId: snapshot.leafId,
    models: Array.isArray(snapshot.models)
      ? snapshot.models.filter((model): model is JsonObject => Boolean(model) && typeof model === "object")
      : undefined,
    thinkingLevels: Array.isArray(snapshot.thinkingLevels)
      ? snapshot.thinkingLevels.filter((level): level is string => typeof level === "string")
      : undefined,
    inFlightMessage:
      snapshot.inFlightMessage && typeof snapshot.inFlightMessage === "object"
        ? (snapshot.inFlightMessage as JsonObject)
        : undefined,
    stats:
      snapshot.stats && typeof snapshot.stats === "object"
        ? (snapshot.stats as JsonObject)
        : undefined,
    commands: Array.isArray(snapshot.commands)
      ? snapshot.commands.filter(
          (command): command is JsonObject => Boolean(command) && typeof command === "object",
        )
      : undefined,
    treeSummary: Array.isArray(snapshot.treeSummary)
      ? snapshot.treeSummary.filter(
          (node): node is JsonObject => Boolean(node) && typeof node === "object",
        )
      : undefined,
  };
}

/**
 * 桌面 relay 接管某个会话时的调和:
 * 两个 pi 进程绝不能打开同一个会话文件(会互相覆写),所以池里若有同一会话
 * 的 headless 进程就必须让位——**这是唯一会关掉别人进程的路径**,而且只关
 * 冲突的那一个,其余会话照常运行。
 */
async function reconcileDesktopClaim(sourceId: string, sessionId: string | undefined): Promise<void> {
  if (!sessionId) return;
  const conflicting = pool
    .list()
    .find((entry) => entry.spec.sessionId === sessionId && entry.sourceId !== sourceId);
  if (conflicting) {
    const victim = conflicting.sourceId;
    // 顺序很重要:先断连(挡住新命令)→ 失败在途 → 广播离线 → 才等进程退出。
    // 否则这段等待窗口里转发的命令会写进一个正在死掉的进程。
    await quiesceSourceForHandoff({
      isConnected: () => sources.get(victim)?.connected === true,
      blockNewCommands: () => sources.setConnected(victim, false),
      failPending: () => failPendingForSource(victim, "desktop TUI took over this session"),
      notifyOffline: () => {
        broadcastHubEvent("hub_source_offline", { sourceId: victim, reason: "desktop_handoff" });
        notifySourcesChanged();
      },
      stopOwner: () => pool.close(victim, "desktop TUI took over this session"),
    });
  }
  pool.claimExternal(sessionId, sourceId);
}

async function handleDesktopMessage(desktop: DesktopClient, text: string): Promise<void> {
  let msg: JsonObject;
  try {
    msg = JSON.parse(text) as JsonObject;
  } catch {
    sendObject(desktop.ws, { type: "desktop_error", error: "invalid JSON" });
    return;
  }

  if (msg.type === "desktop_register") {
    const source = msg.source;
    const snapshot = parseSnapshot(msg.snapshot);
    if (!source || typeof source !== "object" || !snapshot) {
      sendObject(desktop.ws, { type: "desktop_error", error: "invalid registration or snapshot" });
      return;
    }
    const raw = source as JsonObject;
    const sourceId = typeof raw.sourceId === "string" ? raw.sourceId : "";
    const label = typeof raw.label === "string" ? raw.label : sourceId;
    // `s:` 是会话池的保留前缀。允许 relay 注册 `s:<uuid>` 会直接顶掉池内同名
    // 源的 transport,于是 headless pi 与桌面 TUI 同时持有一个会话,claim 表却
    // 看不出异常。
    if (
      !/^[A-Za-z0-9._:-]{1,128}$/.test(sourceId) ||
      sourceId.startsWith("s:") ||
      !label
    ) {
      sendObject(desktop.ws, { type: "desktop_error", error: "invalid source identity" });
      return;
    }
    if (desktop.registering) {
      sendObject(desktop.ws, { type: "desktop_error", error: "registration already in progress" });
      return;
    }
    desktop.registering = true;
    try {
      const claimedSessionId =
        typeof snapshot.state.sessionId === "string" ? snapshot.state.sessionId : undefined;
      await reconcileDesktopClaim(sourceId, claimedSessionId);
      desktop.claimedSessionId = claimedSessionId;
    } catch (error) {
      sendObject(desktop.ws, {
        type: "desktop_error",
        error: error instanceof Error ? error.message : String(error),
      });
      return;
    } finally {
      desktop.registering = false;
    }
    if (desktop.ws.readyState !== WebSocket.OPEN) return;

    const previous = desktopBySource.get(sourceId);
    if (previous && previous !== desktop) previous.ws.close(4009, "source replaced");
    desktop.sourceId = sourceId;
    desktopBySource.set(sourceId, desktop);
    const capabilities = Array.isArray(raw.capabilities)
      ? raw.capabilities.filter((value): value is string => typeof value === "string")
      : [];
    sources.register(
      {
        id: sourceId,
        kind: "desktop",
        label,
        connected: true,
        epoch: snapshot.epoch,
        cwd: typeof raw.cwd === "string" ? raw.cwd : undefined,
        sessionId: typeof raw.sessionId === "string" ? raw.sessionId : undefined,
        sessionFile: typeof raw.sessionFile === "string" ? raw.sessionFile : undefined,
        sessionName: typeof raw.sessionName === "string" ? raw.sessionName : undefined,
        capabilities,
      },
      { send: (message) => sendObject(desktop.ws, message) },
    );
    sources.setSnapshot(sourceId, snapshot);
    desktopOfflineSince.delete(sourceId);
    // 注册路径同样要领养。Bridge 在任务中途重启后,pi 重连走的是
    // desktop_register(不是 desktop_snapshot),这才是现实中最常见的入口。
    if (snapshot.state.isStreaming === true) adoptStreamingFromSnapshot(sourceId);
    sendObject(desktop.ws, {
      type: "desktop_registered",
      hubId: sources.hubId,
      sourceId,
      epoch: snapshot.epoch,
    });
    notifySourcesChanged();
    return;
  }

  const sourceId = desktop.sourceId;
  if (!sourceId) {
    sendObject(desktop.ws, { type: "desktop_error", error: "register first" });
    return;
  }

  switch (msg.type) {
    case "desktop_snapshot": {
      const requestId = typeof msg.requestId === "string" ? msg.requestId : undefined;
      const snapshot = parseSnapshot(msg.snapshot);
      if (!snapshot || !sources.setSnapshot(sourceId, snapshot)) {
        sendObject(desktop.ws, { type: "desktop_error", error: "invalid snapshot" });
        settleSnapshotRequest(sourceId, requestId, false);
        return;
      }
      sendObject(desktop.ws, { type: "desktop_ack", epoch: snapshot.epoch, seq: snapshot.baseSeq });
      settleSnapshotRequest(sourceId, requestId, true);
      // 用户在 TUI 里换了会话:claim 必须跟着走。旧 claim 不释放会把那个会话
      // 永久锁死;新会话不登记又能被池二次打开。
      const nextSessionId =
        typeof snapshot.state.sessionId === "string" ? snapshot.state.sessionId : undefined;
      if (nextSessionId && nextSessionId !== desktop.claimedSessionId) {
        if (desktop.claimedSessionId) pool.releaseExternal(desktop.claimedSessionId);
        desktop.claimedSessionId = nextSessionId;
        void reconcileDesktopClaim(sourceId, nextSessionId);
      }
      if (snapshot.state.isStreaming === true) adoptStreamingFromSnapshot(sourceId);
      broadcastSnapshotAnnounce(sourceId, snapshot);
      notifySourcesChanged();
      return;
    }

    case "desktop_snapshot_unavailable":
      settleSnapshotRequest(
        sourceId,
        typeof msg.requestId === "string" ? msg.requestId : undefined,
        false,
      );
      return;

    case "desktop_tree": {
      const requestId = typeof msg.requestId === "string" ? msg.requestId : undefined;
      const source = sources.get(sourceId);
      const tree = Array.isArray(msg.tree)
        ? msg.tree.filter(
            (node): node is JsonObject => Boolean(node) && typeof node === "object",
          )
        : undefined;
      const leafId =
        typeof msg.leafId === "string" || msg.leafId === null ? msg.leafId : undefined;
      if (!requestId || msg.epoch !== source?.epoch || !tree || leafId === undefined) {
        settleTreeRequest(sourceId, requestId, {
          ok: false,
          reason:
            msg.epoch !== source?.epoch
              ? "桌面端会话已重建(epoch 不一致),请重新进入会话树"
              : "桌面端返回的树结构无效",
        });
        return;
      }
      settleTreeRequest(sourceId, requestId, { ok: true, tree, leafId });
      return;
    }

    case "desktop_tree_unavailable":
      settleTreeRequest(
        sourceId,
        typeof msg.requestId === "string" ? msg.requestId : undefined,
        {
          ok: false,
          reason: typeof msg.reason === "string" && msg.reason ? msg.reason : "桌面端无法生成会话树",
        },
      );
      return;

    case "desktop_ask_request": {
      // relay 拦下了一次 ask_user_question,把题目转给正在看这个源的手机。
      const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
      const toolCallId = typeof msg.toolCallId === "string" ? msg.toolCallId : "";
      const source = sources.get(sourceId);
      const questions = Array.isArray(msg.questions)
        ? msg.questions.filter(
            (item): item is JsonObject => Boolean(item) && typeof item === "object",
          )
        : [];
      if (!requestId) return;
      if (typeof msg.epoch !== "string" || msg.epoch !== source?.epoch) {
        sendObject(desktop.ws, { type: "desktop_ask_declined", requestId });
        return;
      }
      if (questions.length === 0) {
        sendObject(desktop.ws, { type: "desktop_ask_declined", requestId });
        return;
      }
      // relay 已经按 selectedClients 门控过,但那个计数是推送的快照。手机恰好在
      // 推送与本帧之间离开时就会落到这里 —— 立刻回绝,别让桌面白等一个认领超时。
      if (watchersOf(sourceId) === 0) {
        sendObject(desktop.ws, { type: "desktop_ask_declined", requestId });
        return;
      }
      // 同一源的旧问卷(理论上不应存在)先撤干净,免得手机上叠两张卡。
      clearAskForSource(sourceId, true);
      asksBySource.set(sourceId, {
        requestId,
        toolCallId,
        epoch: msg.epoch,
        questions,
        claimed: false,
      });
      // 带外下发(不占 seq,见 sendAskFrame)。重连后靠选源时的 republishAsk 补上。
      sendAskFrame(sourceId, {
        type: "ask_user_question_request",
        requestId,
        toolCallId,
        questions,
      });
      return;
    }

    case "desktop_ask_cancel": {
      // relay 超时或作废了这次转交(已经回落到桌面问卷)。
      const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
      const ask = asksBySource.get(sourceId);
      if (!requestId || !ask || ask.requestId !== requestId) return;
      clearAskForSource(sourceId, true);
      return;
    }

    case "desktop_event": {
      if (
        typeof msg.epoch !== "string" ||
        typeof msg.seq !== "number" ||
        !msg.event ||
        typeof msg.event !== "object"
      ) {
        sendObject(desktop.ws, { type: "desktop_error", error: "invalid event" });
        return;
      }
      const result = sources.recordDesktopEvent(
        sourceId,
        msg.epoch,
        msg.seq,
        msg.event as JsonObject,
      );
      if (!result.ok) {
        sendObject(desktop.ws, {
          type: "desktop_resync_required",
          reason: result.error,
        });
        return;
      }
      noteStreamingFromEvent(sourceId, (msg.event as JsonObject).type);
      broadcastSourceEvent(result.event);
      sendObject(desktop.ws, { type: "desktop_ack", epoch: msg.epoch, seq: msg.seq });
      return;
    }

    case "remote_result":
      if (typeof msg.requestId === "string" && desktop.sourceId) {
        resolvePending(msg.requestId, msg, desktop.sourceId);
      }
      return;

    case "desktop_heartbeat":
      sendObject(desktop.ws, { type: "desktop_heartbeat_ack", t: Date.now() });
      return;

    default:
      // 未知 desktop_* 帧静默忽略:新版 relay 连到旧版 hub 时不能被错误刷屏
      return;
  }
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        ok: true,
        hubId: sources.hubId,
        name: config.p2p.deviceId,
        mobileClients: mobileClients.size,
        desktopSources: sources.list().filter((source) => source.kind === "desktop" && source.connected).length,
        cwd: currentCwd,
        pool: {
          live: pool.size,
          max: config.maxLiveSessions,
          sessions: pool.list().map((entry) => ({
            sourceId: entry.sourceId,
            sessionId: entry.spec.sessionId,
            cwd: entry.spec.cwd,
            alive: entry.proc.alive,
            pid: entry.proc.pid ?? null,
            streaming: entry.streaming,
            restarts: entry.restartCount,
          })),
        },
      }),
    );
    return;
  }
  // 诊断用:列出每条手机连接的身份与订阅目标。
  // 需要 token —— 这个端点会暴露 sourceId/会话归属,不能像 /health 那样裸奔。
  if (req.url?.startsWith("/clients")) {
    if (!tokenMatches(requestUrl(req).searchParams.get("token"), config.token)) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "unauthorized" }));
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        ok: true,
        hubId: sources.hubId,
        clients: [...mobileClients.values()].map((client) => ({
          clientId: client.clientId,
          selectedSourceId: client.selectedSourceId ?? null,
        })),
      }),
    );
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, maxPayload: MAX_DESKTOP_MESSAGE_BYTES });

function requestUrl(req: http.IncomingMessage): URL {
  return new URL(req.url ?? "/", "http://localhost");
}

function extractToken(req: http.IncomingMessage): string | null {
  try {
    const fromQuery = requestUrl(req).searchParams.get("token");
    if (fromQuery) return fromQuery;
  } catch {
    // Header auth may still be valid.
  }
  const auth = req.headers.authorization;
  return auth?.startsWith("Bearer ") ? auth.slice("Bearer ".length) : null;
}

function isLoopback(req: http.IncomingMessage): boolean {
  const address = req.socket.remoteAddress;
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

wss.on("connection", (ws, req) => {
  const desktopEndpoint = requestUrl(req).pathname === "/desktop";
  if (desktopEndpoint) {
    if (!isLoopback(req) || !tokenMatches(extractToken(req), config.desktopToken)) {
      ws.close(4001, "unauthorized desktop source");
      return;
    }
    const desktop: DesktopClient = { ws, lastSeen: Date.now() };
    desktopClients.add(desktop);
    sendObject(ws, {
      type: "desktop_hello",
      version: HUB_PROTOCOL_VERSION,
      hubId: sources.hubId,
    });
    ws.on("message", (data) => {
      // 任何入站帧都算活着。心跳只是保底,流式期间的事件同样刷新时间戳。
      desktop.lastSeen = Date.now();
      void handleDesktopMessage(desktop, data.toString());
    });
    ws.on("close", () => {
      desktopClients.delete(desktop);
      const sourceId = desktop.sourceId;
      if (!sourceId || desktopBySource.get(sourceId) !== desktop) return;
      desktopBySource.delete(sourceId);
      sources.setConnected(sourceId, false);
      desktopOfflineSince.set(sourceId, Date.now());
      streamingBySource.delete(sourceId);
      failSnapshotRequestsForSource(sourceId);
      failTreeRequestsForSource(sourceId);
      // 桌面走了,那份问卷再也没人接答案 —— 撤掉手机上的卡片。
      clearAskForSource(sourceId, true);
      failPendingForSource(sourceId, "desktop source disconnected");
      // 释放会话占用:电脑端走了之后,这个会话应该能重新在 bridge 上打开。
      // (不释放的话 claim 表会永久堵住它。)
      if (desktop.claimedSessionId) pool.releaseExternal(desktop.claimedSessionId);
      notifySourcesChanged();
    });
    ws.on("error", () => {});
    return;
  }

  if (!tokenMatches(extractToken(req), config.token)) {
    ws.close(4001, "unauthorized");
    return;
  }
  acceptMobileClient(
    ws,
    requestUrl(req).searchParams.get("clientId"),
    (requestUrl(req).searchParams.get("caps") ?? "")
      .split(",")
      .map((cap) => cap.trim())
      .filter((cap) => cap.length > 0),
  );
});

/// 手机连接的公共接入点:WS 直连与 P2P DataChannel(由 DataChannelSocket
/// 伪装成 ws.WebSocket)都从这里进,协议处理路径完全一致。
function acceptMobileClient(
  ws: WebSocket,
  requestedClientId: string | null,
  caps: readonly string[] = [],
): void {
  // 稳定 clientId:App 持久化后重连仍是同一个"驱动者",
  // 断线重连不必等旧租约 TTL 过期(这是把最坏接管延迟压到即时的三条路径之一)。
  const clientId =
    requestedClientId && /^[A-Za-z0-9._:-]{8,128}$/.test(requestedClientId)
      ? requestedClientId
      : crypto.randomUUID();
  // 同一个 clientId 的旧连接直接换掉,避免两个 socket 共享租约身份。
  // 先登记新 socket 为 current,再关闭旧 socket:旧 close 即使立刻到达也只能
  // 清理自己的 map 项,不能释放 current client 的租约与 pending。
  const replacedSockets = [...mobileClients]
    .filter(([, existing]) => existing.clientId === clientId)
    .map(([socket]) => socket);
  const client: MobileClient = { clientId, ws, caps: new Set(caps) };
  activeMobileSocketByClientId.set(clientId, ws);
  mobileClients.set(ws, client);
  liveSockets.set(ws, true);
  for (const socket of replacedSockets) socket.close(4010, "client replaced");
  ws.on("pong", () => liveSockets.set(ws, true));
  sendObject(ws, {
    type: "bridge_hello",
    version: HUB_PROTOCOL_VERSION,
    hubId: sources.hubId,
    // 双字段过渡:hubId 保留给旧客户端与旧 source cursor,
    // bridgeInstallationId 跨重启稳定,只给通知 cursor 用。见 stable-plan.md §3.2。
    bridgeInstallationId: bridgeIdentity.bridgeInstallationId,
    eventEpoch: bridgeIdentity.eventEpoch,
    clientId: client.clientId,
    capabilities: [
      "sources",
      "replay",
      "snapshot",
      "owner-lease",
      "desktop-relay",
      "sessions",
      "concurrent-sessions",
      "navigate-tree",
      ...NOTIFICATION_CAPABILITIES,
      ...(ws instanceof DataChannelSocket && ws.supportsChunking
        ? [P2P_CHUNK_CAPABILITY, P2P_CHUNK_V2_CAPABILITY]
        : []),
    ],
  });

  ws.on("message", (data) => {
    const text = data.toString();
    if (Buffer.byteLength(text) > MAX_CLIENT_MESSAGE_BYTES) {
      ws.close(1009, "message too large");
      return;
    }
    let msg: BridgeMessage;
    try {
      msg = JSON.parse(text) as BridgeMessage;
    } catch {
      sendObject(ws, { type: "bridge_error", error: "invalid JSON" });
      return;
    }
    if (typeof msg.type !== "string") {
      respond(ws, msg, false, undefined, "message type is required");
      return;
    }
    if (msg.type.startsWith("hub_") || msg.type.startsWith("notification_")) {
      // notification_* 与 hub_* 同走 hub 分支。
      //
      // 通知链路刻意不依赖「已选 source」:它的作用域是整个 Bridge,
      // 手机在后台时根本没有选中的 source,而那正是最需要收到通知的时刻。
      // 漏掉这个前缀会让通知帧落到 handleSourceCommand,被
      // requireSelectedSource 以 "select a source first" 拒掉。
      void handleHubCommand(client, msg);
    } else if (msg.type.startsWith("bridge_")) {
      void handleBridgeCommand(client, msg);
    } else {
      handleSourceCommand(client, msg);
    }
  });

  ws.on("close", () => {
    mobileClients.delete(ws);
    liveSockets.delete(ws);
    if (activeMobileSocketByClientId.get(client.clientId) !== ws) return;
    activeMobileSocketByClientId.delete(client.clientId);
    const released = sources.releaseClient(client.clientId);
    for (const sourceId of released) notifyOwnerChanged(sourceId);
    for (const [requestId, request] of pending) {
      if (request.clientId !== client.clientId) continue;
      clearTimeout(request.timeout);
      pending.delete(requestId);
      request.settle?.();
    }
    if (client.selectedSourceId) pushDesktopStatus(client.selectedSourceId);
  });
  ws.on("error", () => {});
}

/// 半开连接(手机锁屏/掉网)不会触发 close,租约会一直挂着。
///
/// 10s 一次 ping。旧策略只有一个布尔:上一轮没回 pong 就直接 terminate,实际只
/// 给了一个约 10s 的窗口(注释所称「连丢两次」与代码不符)。慢 TURN 上一次大页
/// 排队就可能把 pong 挤到 10s 之后,健康链路被误杀 → 反复重连。改为按次计数:
/// 连续 MOBILE_PING_MAX_MISS 次没回 pong 才判死。
const MOBILE_PING_MAX_MISS = 3;
const pingMisses = new WeakMap<WebSocket, number>();
const liveSockets = new WeakMap<WebSocket, boolean>();

const pingTimer = setInterval(() => {
  for (const [socket] of mobileClients) {
    if (liveSockets.get(socket) === false) {
      const misses = (pingMisses.get(socket) ?? 0) + 1;
      pingMisses.set(socket, misses);
      if (misses >= MOBILE_PING_MAX_MISS) {
        console.error(
          `[hub] 手机连接连续 ${misses} 次未回 pong(约 ${misses * 10}s),判定半开并断开` +
            ` clientId=${mobileClients.get(socket)?.clientId ?? "?"}`,
        );
        socket.terminate();
        continue;
      }
    } else {
      pingMisses.set(socket, 0);
    }
    liveSockets.set(socket, false);
    try {
      socket.ping();
    } catch {
      socket.terminate();
    }
  }
}, 10_000);
pingTimer.unref();

/// 桌面 relay 的存活判定与陈旧源回收。
///
/// Ctrl+Z 发的是 SIGTSTP:pi 进程被冻住,但内核 socket 仍是 ESTABLISHED 且不发
/// FIN,于是 `ws.on("close")` 永远不触发,旧源会一直停在 `connected=true`。App
/// 因此既不认为它死了,也不会自动切走,抽屉里那一行也永远不消失。
///
/// 判定只能靠「多久没收到任何帧」:relay 每 10s 发一次 desktop_heartbeat,
/// 静默超过 desktopStaleMs(默认 30s = 3 次心跳)即判死并 terminate。terminate
/// 会触发 close,复用既有的断开清理(失败在途请求、释放 claim、广播源变化)。
/// 用户 fg 恢复后 relay 自己会重连,所以主动断开是安全的。
const desktopSweeper = setInterval(() => {
  if (shuttingDown) return;
  const now = Date.now();
  for (const desktop of [...desktopClients]) {
    if (now - desktop.lastSeen <= config.desktopStaleMs) continue;
    // terminate 而不是 close:对方已经不再运转,四次挥手等不到回应。
    desktop.ws.terminate();
  }
  // 断开的桌面源不立刻删,留一段重连窗口(同 epoch 重连可复用快照与重放环)。
  // 超过 desktopPruneMs 仍没回来就摘掉,否则每次 Ctrl+Z 都会永久留下一行。
  let pruned = false;
  for (const [sourceId, since] of [...desktopOfflineSince]) {
    if (now - since <= config.desktopPruneMs) continue;
    desktopOfflineSince.delete(sourceId);
    const source = sources.get(sourceId);
    if (!source || source.kind !== "desktop" || source.connected) continue;
    if (sources.remove(sourceId)) pruned = true;
  }
  if (pruned) notifySourcesChanged();
  // 扫描周期跟着判死阈值走:阈值调小(测试/排查)时扫描也要跟着变密,
  // 否则 30s 的固定周期会让「多久判死」实际上被扫描间隔支配。
}, Math.min(10_000, Math.max(250, Math.floor(config.desktopStaleMs / 3))));
desktopSweeper.unref();

const leaseTimer = setInterval(() => {
  for (const sourceId of sources.expireLeases()) notifyOwnerChanged(sourceId);
}, 1000);
leaseTimer.unref();

if (config.headlessAutoStart) {
  try {
    ensureSession({ sessionId: currentSessionId, cwd: currentCwd });
  } catch (error) {
    console.error("[bridge] failed to auto-start the bootstrap session:", error);
  }
}

const printBanner = () => {
  console.log("PiPilot Source Hub is up");
  console.log(`  hub id:        ${sources.hubId}`);
  console.log(`  headless cwd:  ${currentCwd}`);
  console.log(`  max sessions:  ${config.maxLiveSessions}`);
  console.log("  desktop relay: loopback /desktop (credential stored in bridge/config.json)");
  console.log("  mobile auth:   configured (token omitted from logs)");
  console.log("  connect urls:");
  for (const url of lanUrls(config)) console.log(`    ${url}`);
};

// 禁用了 IPv6 的机器上监听 "::" 会 EADDRNOTAVAIL/EAFNOSUPPORT —— 退回纯 v4
// 而不是让 hub 直接起不来。
server.on("error", (error) => {
  const code = (error as NodeJS.ErrnoException).code;
  if (config.host === "::" && (code === "EADDRNOTAVAIL" || code === "EAFNOSUPPORT")) {
    console.warn(`[bridge] IPv6 unavailable (${code}), falling back to IPv4-only 0.0.0.0`);
    server.listen(config.port, "0.0.0.0", printBanner);
    return;
  }
  throw error;
});

server.listen(config.port, config.host, printBanner);

// mDNS 自我宣告:让手机在局域网里「找得到」。只发布非机密元数据,
// token 不上广播。只听回环时没必要宣告(宣告了别人也够不着)。
const stopAnnounce =
  config.host === "127.0.0.1" || config.host === "localhost"
    ? () => {}
    : startAnnounce({
        port: config.port,
        hubId: sources.hubId,
        protocolVersion: HUB_PROTOCOL_VERSION,
        name: config.p2p.deviceId,
        bridgeInstallationId: bridgeIdentity.bridgeInstallationId,
        notificationEvents: true,
      });

// P2P(打洞)远程通道:作为 WebRTC host 挂到信令服,手机叫进来后在
// DataChannel 上跑与 WS 完全相同的 hub 协议。信令服只交换握手,不碰流量。
if (config.p2p.enabled && config.p2p.rendezvousUrl && config.p2p.secret) {
  const p2pHost = new P2pHost({
    rendezvousUrl: config.p2p.rendezvousUrl,
    deviceId: config.p2p.deviceId,
    secret: config.p2p.secret,
    validateMobileToken: (token) => tokenMatches(token ?? null, config.token),
    acceptMobile: (socket, clientId, caps) => acceptMobileClient(socket, clientId, caps),
    log: (line) => console.log(`[p2p] ${line}`),
  });
  if (p2pHost.start()) {
    console.log(`P2P 打洞已启用:信令服 ${config.p2p.rendezvousUrl},设备名 ${config.p2p.deviceId}`);
  }
}

async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  stopAnnounce();
  clearInterval(leaseTimer);
  clearInterval(pingTimer);
  clearInterval(desktopSweeper);
  clearInterval(idleSweeper);
  for (const client of [...mobileClients.keys(), ...[...desktopClients].map((item) => item.ws)]) {
    client.close(1001, "bridge shutting down");
  }
  await pool.shutdownAll();
  server.close(() => process.exit(0));
  const forceExit = setTimeout(() => process.exit(0), 2000);
  forceExit.unref();
}
process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
// 兜底:任何未走 shutdown() 的退出路径都不能留下孤儿 pi 进程
process.on("exit", () => pool.killAllSync());
