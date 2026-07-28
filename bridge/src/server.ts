import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { WebSocket, WebSocketServer } from "ws";
import { lanUrls, loadConfig, writeFileConfig } from "./config.js";
import {
  HUB_PROTOCOL_VERSION,
  MAX_BUFFERED_SOCKET_BYTES,
  MAX_CLIENT_MESSAGE_BYTES,
  MAX_DESKTOP_MESSAGE_BYTES,
  clampLeaseTtl,
  isDesktopMutationCommand,
  isReadOnlySourceCommand,
  parseCursor,
  withoutHubMetadata,
  type BridgeMessage,
  type JsonObject,
} from "./hub_protocol.js";
import { CommandQueue } from "./command_queue.js";
import { quiesceSourceForHandoff } from "./source_handoff.js";
import { PiPool, sourceIdForSession, type SessionSpec } from "./pi_pool.js";
import { listDirs, listSessions, SESSIONS_ROOT } from "./sessions.js";
import {
  SourceRegistry,
  type SequencedSourceEvent,
  type SourceDescriptor,
  type SourceSnapshot,
} from "./source_registry.js";

const config = loadConfig();
const sources = new SourceRegistry(config.replayCapacity, config.replayByteBudget);
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

function sendRaw(ws: WebSocket, data: string): boolean {
  if (ws.readyState !== WebSocket.OPEN) return false;
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

function respond(
  ws: WebSocket,
  msg: BridgeMessage,
  success: boolean,
  data?: unknown,
  error?: string,
): void {
  sendObject(ws, {
    type: "response",
    command: msg.type,
    ...(typeof msg.id === "string" ? { id: msg.id } : {}),
    success,
    ...(data !== undefined ? { data } : {}),
    ...(error !== undefined ? { error } : {}),
  });
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
    if (client.selectedSourceId === event.sourceId) sendObject(client.ws, frame);
  }
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

/// 撤卡也要进重放环。否则断线重连的手机会从环里读出那条 ask 事件,
/// 把一份早就由电脑接手的问卷重新画出来。
function retractAsk(sourceId: string, requestId: string): void {
  const event = sources.recordLocalEvent(sourceId, {
    type: "ask_user_question_retracted",
    requestId,
  });
  if (event.ok) broadcastSourceEvent(event.event);
}

function clearAskForSource(sourceId: string, retract: boolean): void {
  const ask = asksBySource.get(sourceId);
  if (!ask) return;
  asksBySource.delete(sourceId);
  if (retract) retractAsk(sourceId, ask.requestId);
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
  if (eventType === "agent_start") streamingBySource.set(sourceId, true);
  else if (eventType === "agent_end" || eventType === "agent_settled") {
    streamingBySource.set(sourceId, false);
  }
}

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
  const dirs = cwd
    ? [cwd]
    : [...new Set([currentCwd, ...Object.keys(config.dirSessions)])];
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
    sendObject(request.ws, {
      type: "response",
      command: request.command,
      ...(request.originalId ? { id: request.originalId } : {}),
      success: result.success === true,
      ...(result.data !== undefined ? { data: result.data } : {}),
      ...(typeof result.error === "string" ? { error: result.error } : {}),
    });
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
      if (sourceIsStreaming(source.id)) {
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
      let entries = snapshot.entries;
      if (typeof msg.since === "string") {
        const index = entries.findIndex((entry) => entry.id === msg.since);
        if (index < 0) {
          respond(client.ws, msg, false, undefined, "entry cursor not found in desktop snapshot");
          return;
        }
        entries = entries.slice(index + 1);
      }
      respond(client.ws, msg, true, { entries, leafId: snapshot.leafId });
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
    else forwardSourceCommand(client, source, msg);
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
    switch (msg.type) {
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
        return;
      }

      case "hub_sync": {
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
        respond(client.ws, msg, true, {
          hubId: sources.hubId,
          sourceId: source.id,
          sourceEpoch: source.epoch,
          mode: sync.mode,
          continuous: sync.continuous,
          ...(sync.mode === "snapshot" ? { snapshot: sync.snapshot } : {}),
          ...(sync.mode === "rpc" ? { baseSeq: sync.baseSeq } : {}),
          events: sync.events.map(eventFrame),
        });
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
      case "bridge_ping":
        sendObject(client.ws, {
          type: "bridge_pong",
          t: Date.now(),
          // echo 原样回传,客户端据此计算 RTT
          ...(msg.echo !== undefined ? { echo: msg.echo } : {}),
        });
        return;

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
      if (snapshot.state.isStreaming === true) streamingBySource.set(sourceId, true);
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
      // 进重放环:断线重连的手机能从重放里拿到这份问卷,不依赖广播的时机。
      const event = sources.recordLocalEvent(sourceId, {
        type: "ask_user_question_request",
        requestId,
        toolCallId,
        questions,
      });
      if (event.ok) broadcastSourceEvent(event.event);
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
  // 稳定 clientId:App 持久化后重连仍是同一个"驱动者",
  // 断线重连不必等旧租约 TTL 过期(这是把最坏接管延迟压到即时的三条路径之一)。
  const requestedClientId = requestUrl(req).searchParams.get("clientId");
  const clientId =
    requestedClientId && /^[A-Za-z0-9._:-]{8,128}$/.test(requestedClientId)
      ? requestedClientId
      : crypto.randomUUID();
  // 同一个 clientId 的旧连接直接换掉,避免两个 socket 共享租约身份
  for (const [socket, existing] of mobileClients) {
    if (existing.clientId === clientId) socket.close(4010, "client replaced");
  }
  const client: MobileClient = { clientId, ws };
  mobileClients.set(ws, client);
  liveSockets.set(ws, true);
  ws.on("pong", () => liveSockets.set(ws, true));
  sendObject(ws, {
    type: "bridge_hello",
    version: HUB_PROTOCOL_VERSION,
    hubId: sources.hubId,
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
    if (msg.type.startsWith("hub_")) {
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
});

/// 半开连接(手机锁屏/掉网)不会触发 close,租约会一直挂着。
/// 10s 一次 ping,连丢两次就 terminate —— close 事件随即释放租约。
const liveSockets = new WeakMap<WebSocket, boolean>();

const pingTimer = setInterval(() => {
  for (const [socket] of mobileClients) {
    if (liveSockets.get(socket) === false) {
      socket.terminate();
      continue;
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

server.listen(config.port, config.host, () => {
  console.log("PiPilot Source Hub is up");
  console.log(`  hub id:        ${sources.hubId}`);
  console.log(`  headless cwd:  ${currentCwd}`);
  console.log(`  max sessions:  ${config.maxLiveSessions}`);
  console.log("  desktop relay: loopback /desktop (credential stored in bridge/config.json)");
  console.log("  mobile auth:   configured (token omitted from logs)");
  console.log("  connect urls:");
  for (const url of lanUrls(config)) console.log(`    ${url}`);
});

async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
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
