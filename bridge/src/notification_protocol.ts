import {
  isReceiptState,
  type NotificationEventType,
  type NotificationEventV1,
  type ReceiptState,
} from "./notification_event.js";
import type { NotificationEventStore } from "./notification_event_store.js";

/// 单页上限。条数与字节双重约束:100 条小事件没问题,但 100 条带长会话名的
/// 事件可能撑爆手机端单帧解析预算,所以字节先到就先停。
export const MAX_PAGE_EVENTS = 100;
export const MAX_PAGE_BYTES = 64 * 1024;
/// live buffer 上限。溢出必须显式 resync,不能静默丢头部 ——
/// 静默丢头部会让客户端的 cursor 越过未处理事件。
export const MAX_LIVE_BUFFER = 256;
export const MAX_LIVE_BUFFER_BYTES = 1024 * 1024;

export interface NotificationScopes {
  sourceIds?: string[];
  eventTypes?: NotificationEventType[];
}

export interface NotificationCursor {
  eventEpoch: string;
  sequence: number;
}

export interface SubscribeRequest {
  id: string;
  installationId: string;
  cursor: NotificationCursor | null;
  scopes: NotificationScopes;
  scopeVersion: number;
  pageLimit?: number;
}

export interface SkippedRange {
  from: number;
  through: number;
}

export interface NotificationEventsPage {
  type: "notification_events";
  id: string;
  eventEpoch: string;
  scopeVersion: number;
  /// Bridge 当前时间。客户端用它校准相对 TTL,而不是相信自己的时钟。
  bridgeNow: string;
  fromExclusive: number;
  through: number;
  /// 固定上界。分页期间新产生的事件不得改变它。
  tip: number;
  events: NotificationEventV1[];
  /// 被 scope 排除的 sequence 区间。events + skippedRanges 必须连续覆盖
  /// (fromExclusive, through],否则客户端无法区分「被过滤」和「丢包」。
  skippedRanges: SkippedRange[];
  hasMore: boolean;
  oldestAvailable: number;
}

export type CursorExpiredReason = "retention" | "store_reset" | "identity_changed";

export interface CursorExpiredFrame {
  type: "notification_cursor_expired";
  id?: string;
  eventEpoch: string;
  oldestAvailable: number;
  currentTip: number;
  reason: CursorExpiredReason;
}

export interface ScopeChangedFrame {
  type: "notification_scope_changed";
  id: string;
  expectedScopeVersion: number;
}

export interface ResyncRequiredFrame {
  type: "notification_resync_required";
  id: string;
  reason: "live_buffer_overflow";
}

export interface ReadyFrame {
  type: "notification_ready";
  id: string;
  subscriptionId: string;
  bridgeInstallationId: string;
  eventEpoch: string;
  through: number;
  generation: number;
}

export type SubscribeResult =
  | NotificationEventsPage
  | CursorExpiredFrame
  | ScopeChangedFrame
  | ResyncRequiredFrame;

// ---------------------------------------------------------------------------
// 请求解析
// ---------------------------------------------------------------------------

const EVENT_TYPES: readonly string[] = ["task_completed", "input_required", "input_resolved"];

function parseScopes(value: unknown): NotificationScopes | undefined {
  if (value === undefined || value === null) return {};
  if (typeof value !== "object") return undefined;
  const record = value as { sourceIds?: unknown; eventTypes?: unknown };
  const scopes: NotificationScopes = {};
  if (record.sourceIds !== undefined) {
    if (!Array.isArray(record.sourceIds)) return undefined;
    if (!record.sourceIds.every((item) => typeof item === "string")) return undefined;
    scopes.sourceIds = record.sourceIds as string[];
  }
  if (record.eventTypes !== undefined) {
    if (!Array.isArray(record.eventTypes)) return undefined;
    if (!record.eventTypes.every((item) => typeof item === "string" && EVENT_TYPES.includes(item))) {
      return undefined;
    }
    scopes.eventTypes = record.eventTypes as NotificationEventType[];
  }
  return scopes;
}

export function parseNotificationCursor(value: unknown): NotificationCursor | null | undefined {
  if (value === null || value === undefined) return null;
  if (typeof value !== "object") return undefined;
  const record = value as Partial<NotificationCursor>;
  if (typeof record.eventEpoch !== "string" || record.eventEpoch.length === 0) return undefined;
  if (
    typeof record.sequence !== "number" ||
    !Number.isSafeInteger(record.sequence) ||
    record.sequence < 0
  ) {
    return undefined;
  }
  return { eventEpoch: record.eventEpoch, sequence: record.sequence };
}

/// 解析 subscribe 请求。这里刻意不复用 hub_protocol.ts 的 parseCursor ——
/// 那个函数校验 hubId(进程级),而通知 cursor 绑 eventEpoch(跨重启稳定)。
/// 混用会让一次改动同时影响 UI 同步和通知补偿两条链路。
export function parseSubscribeRequest(value: unknown): SubscribeRequest | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  if (typeof record.id !== "string" || record.id.length === 0) return undefined;
  if (typeof record.installationId !== "string" || record.installationId.length === 0) {
    return undefined;
  }
  const cursor = parseNotificationCursor(record.cursor);
  if (cursor === undefined) return undefined;
  const scopes = parseScopes(record.scopes);
  if (scopes === undefined) return undefined;
  const scopeVersion = record.scopeVersion;
  if (typeof scopeVersion !== "number" || !Number.isSafeInteger(scopeVersion) || scopeVersion < 0) {
    return undefined;
  }
  const pageLimit =
    typeof record.pageLimit === "number" && Number.isSafeInteger(record.pageLimit)
      ? Math.min(Math.max(record.pageLimit, 1), MAX_PAGE_EVENTS)
      : MAX_PAGE_EVENTS;
  return {
    id: record.id,
    installationId: record.installationId,
    cursor,
    scopes,
    scopeVersion,
    pageLimit,
  };
}

export interface AckRequest {
  installationId: string;
  eventEpoch: string;
  through: number;
}

export function parseAckRequest(value: unknown): AckRequest | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  if (typeof record.installationId !== "string" || record.installationId.length === 0) {
    return undefined;
  }
  if (typeof record.eventEpoch !== "string" || record.eventEpoch.length === 0) return undefined;
  if (
    typeof record.through !== "number" ||
    !Number.isSafeInteger(record.through) ||
    record.through < 0
  ) {
    return undefined;
  }
  return {
    installationId: record.installationId,
    eventEpoch: record.eventEpoch,
    through: record.through,
  };
}

export interface ReceiptRequest {
  installationId: string;
  eventId: string;
  state: ReceiptState;
  at: string;
}

export function parseReceiptRequest(value: unknown): ReceiptRequest | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  if (typeof record.installationId !== "string" || record.installationId.length === 0) {
    return undefined;
  }
  if (typeof record.eventId !== "string" || record.eventId.length === 0) return undefined;
  if (!isReceiptState(record.state)) return undefined;
  const at = typeof record.at === "string" ? record.at : new Date().toISOString();
  return {
    installationId: record.installationId,
    eventId: record.eventId,
    state: record.state,
    at,
  };
}

// ---------------------------------------------------------------------------
// scope 过滤
// ---------------------------------------------------------------------------

export function matchesScope(event: NotificationEventV1, scopes: NotificationScopes): boolean {
  if (scopes.sourceIds !== undefined && scopes.sourceIds.length > 0) {
    if (event.sourceId === undefined) return false;
    if (!scopes.sourceIds.includes(event.sourceId)) return false;
  }
  if (scopes.eventTypes !== undefined && scopes.eventTypes.length > 0) {
    if (!scopes.eventTypes.includes(event.type)) return false;
  }
  return true;
}

/// 把连续的排除 sequence 合并成区间。逐个上报会让一次大范围过滤
/// 产生上千条 skippedRanges,把响应本身撑爆。
export function mergeSkipped(sequences: number[]): SkippedRange[] {
  if (sequences.length === 0) return [];
  const sorted = [...sequences].sort((a, b) => a - b);
  const ranges: SkippedRange[] = [];
  let start = sorted[0] as number;
  let prev = start;
  for (let i = 1; i < sorted.length; i++) {
    const current = sorted[i] as number;
    if (current === prev + 1) {
      prev = current;
      continue;
    }
    ranges.push({ from: start, through: prev });
    start = current;
    prev = current;
  }
  ranges.push({ from: start, through: prev });
  return ranges;
}

/// 校验 events + skippedRanges 是否连续覆盖 (fromExclusive, through]。
/// 客户端也要做同样的校验;这里导出是为了让 Bridge 侧测试能直接断言。
export function coversContinuously(
  fromExclusive: number,
  through: number,
  events: NotificationEventV1[],
  skipped: SkippedRange[],
): boolean {
  if (through <= fromExclusive) return events.length === 0 && skipped.length === 0;
  const seen = new Set<number>();
  for (const event of events) seen.add(event.sequence);
  for (const range of skipped) {
    for (let seq = range.from; seq <= range.through; seq++) seen.add(seq);
  }
  for (let seq = fromExclusive + 1; seq <= through; seq++) {
    if (!seen.has(seq)) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 订阅
// ---------------------------------------------------------------------------

interface SubscriptionState {
  id: string;
  installationId: string;
  scopes: NotificationScopes;
  scopeVersion: number;
  /// 固定 tip。subscribe 时捕获,catch-up 全程不变。
  tip: number;
  /// 已发到哪。分页游标。
  delivered: number;
  pageLimit: number;
  /// catch-up 完成前新产生的事件先进这里,排空后才发 ready。
  liveBuffer: NotificationEventV1[];
  liveBufferBytes: number;
  overflowed: boolean;
  caughtUp: boolean;
  ready: boolean;
  generation: number;
}

/// drainLiveBuffer 的产出:可投递事件 + 因过期被跳过的 sequence。
/// 跳过的 sequence 必须进 live 帧的 skippedRanges,覆盖连续性才不破。
export interface DrainedLiveEvents {
  events: NotificationEventV1[];
  skipped: number[];
}

/// 通知订阅管理器。
///
/// 关键不变量(stable-plan.md §7.2):
///  - subscribe 时先捕获固定 tip,再注册 live buffer,两者之间不留空窗。
///  - 分页期间新事件进 live buffer,绝不插入当前分页中间改变上界。
///  - hasMore=false 后先排空 live buffer,再发 ready。
///  - live buffer 溢出返回 resync_required,不静默丢头部。
export class NotificationSubscriptionManager {
  private readonly subscriptions = new Map<string, SubscriptionState>();
  private generationCounter = 0;

  constructor(
    private readonly store: NotificationEventStore,
    private readonly bridgeInstallationId: string,
    private readonly eventEpoch: string,
    private readonly now: () => number = Date.now,
    /// 投递前判定事件是否已过期(典型:完成通知积压期间新任务已开跑)。
    /// 过期事件进 skippedRanges,不推给客户端。
    private readonly isStaleEvent: (event: NotificationEventV1) => boolean = () => false,
  ) {}

  /// 建立订阅并返回第一页。cursor 早于保留窗口时返回 cursor_expired。
  subscribe(request: SubscribeRequest): SubscribeResult {
    // epoch 不匹配意味着事件库被重置过,客户端必须 rebase 而不是接着旧 sequence 读。
    if (request.cursor !== null && request.cursor.eventEpoch !== this.eventEpoch) {
      return {
        type: "notification_cursor_expired",
        id: request.id,
        eventEpoch: this.eventEpoch,
        oldestAvailable: this.store.oldestAvailable(),
        currentTip: this.store.tip(),
        reason: "store_reset",
      };
    }

    const tip = this.store.tip();
    const oldest = this.store.oldestAvailable();
    // cursor 落在保留窗口之前:中间那段已经被 TTL 回收了,无法补齐。
    // 必须显式告知并让客户端 rebase,不能静默跳过。
    if (request.cursor !== null && tip > 0 && request.cursor.sequence + 1 < oldest) {
      return {
        type: "notification_cursor_expired",
        id: request.id,
        eventEpoch: this.eventEpoch,
        oldestAvailable: oldest,
        currentTip: tip,
        reason: "retention",
      };
    }

    const state: SubscriptionState = {
      id: request.id,
      installationId: request.installationId,
      scopes: request.scopes,
      scopeVersion: request.scopeVersion,
      tip,
      delivered: request.cursor?.sequence ?? Math.max(0, oldest - 1),
      pageLimit: request.pageLimit ?? MAX_PAGE_EVENTS,
      liveBuffer: [],
      liveBufferBytes: 0,
      overflowed: false,
      caughtUp: tip === 0,
      ready: false,
      generation: ++this.generationCounter,
    };
    this.subscriptions.set(request.id, state);
    return this.nextPage(request.id, request.scopeVersion) ?? this.emptyPage(state);
  }

  private emptyPage(state: SubscriptionState): NotificationEventsPage {
    return {
      type: "notification_events",
      id: state.id,
      eventEpoch: this.eventEpoch,
      scopeVersion: state.scopeVersion,
      bridgeNow: new Date(this.now()).toISOString(),
      fromExclusive: state.delivered,
      through: state.delivered,
      tip: state.tip,
      events: [],
      skippedRanges: [],
      hasMore: false,
      oldestAvailable: this.store.oldestAvailable(),
    };
  }

  /// 取下一页。scopeVersion 不一致时返回 scope_changed ——
  /// 用旧过滤规则推进 cursor 会让新 scope 该收到的事件被永久跳过。
  nextPage(subscriptionId: string, scopeVersion?: number): SubscribeResult | undefined {
    const state = this.subscriptions.get(subscriptionId);
    if (state === undefined) return undefined;
    if (scopeVersion !== undefined && scopeVersion !== state.scopeVersion) {
      return {
        type: "notification_scope_changed",
        id: state.id,
        expectedScopeVersion: state.scopeVersion,
      };
    }
    if (state.overflowed) {
      return {
        type: "notification_resync_required",
        id: state.id,
        reason: "live_buffer_overflow",
      };
    }

    const fromExclusive = state.delivered;
    const events: NotificationEventV1[] = [];
    const skipped: number[] = [];
    let bytes = 0;
    let cursor = fromExclusive;

    while (cursor < state.tip && events.length < state.pageLimit) {
      const next = cursor + 1;
      const event = this.store.eventBySequence(next);
      if (event === undefined) {
        // 已被 TTL 回收或从未存在(sequence 空洞)。标为 skipped 让覆盖保持连续,
        // 否则客户端会误判成丢包并拒绝 ack。
        skipped.push(next);
        cursor = next;
        continue;
      }
      // 过期事件(典型:完成通知落盘后断链积压,新任务已开跑)不投递 ——
      // 标为 skipped,覆盖连续性不破,客户端也不会再弹误导通知。
      if (this.isStaleEvent(event)) {
        skipped.push(next);
        cursor = next;
        continue;
      }
      if (!matchesScope(event, state.scopes)) {
        skipped.push(next);
        cursor = next;
        continue;
      }
      const size = JSON.stringify(event).length;
      if (events.length > 0 && bytes + size > MAX_PAGE_BYTES) break;
      events.push(event);
      bytes += size;
      cursor = next;
    }

    state.delivered = cursor;
    const hasMore = cursor < state.tip;
    if (!hasMore) state.caughtUp = true;

    return {
      type: "notification_events",
      id: state.id,
      eventEpoch: this.eventEpoch,
      scopeVersion: state.scopeVersion,
      bridgeNow: new Date(this.now()).toISOString(),
      fromExclusive,
      through: cursor,
      tip: state.tip,
      events,
      skippedRanges: mergeSkipped(skipped),
      hasMore,
      oldestAvailable: this.store.oldestAvailable(),
    };
  }

  /// 新事件到达。catch-up 未完成时进 live buffer,完成后可直接推送。
  /// 返回可立即发送的事件列表(已 catch-up 且匹配 scope 时非空)。
  onEvent(event: NotificationEventV1): Map<string, NotificationEventV1[]> {
    const deliverable = new Map<string, NotificationEventV1[]>();
    for (const state of this.subscriptions.values()) {
      if (!matchesScope(event, state.scopes)) continue;
      if (state.ready) {
        deliverable.set(state.id, [event]);
        state.delivered = Math.max(state.delivered, event.sequence);
        continue;
      }
      // 还在分页中:进 buffer,绝不插入当前页改变固定 tip。
      const size = JSON.stringify(event).length;
      if (
        state.liveBuffer.length >= MAX_LIVE_BUFFER ||
        state.liveBufferBytes + size > MAX_LIVE_BUFFER_BYTES
      ) {
        state.overflowed = true;
        continue;
      }
      state.liveBuffer.push(event);
      state.liveBufferBytes += size;
    }
    return deliverable;
  }

  /// 排空 live buffer。必须在 hasMore=false 之后、发 ready 之前调用,
  /// 保证 catch-up 与实时流之间没有空窗。
  drainLiveBuffer(subscriptionId: string): DrainedLiveEvents | ResyncRequiredFrame {
    const state = this.subscriptions.get(subscriptionId);
    if (state === undefined) return { events: [], skipped: [] };
    if (state.overflowed) {
      return { type: "notification_resync_required", id: state.id, reason: "live_buffer_overflow" };
    }
    const events: NotificationEventV1[] = [];
    const skipped: number[] = [];
    for (const event of state.liveBuffer) {
      if (event.sequence <= state.delivered) continue;
      // 过期事件剔除出投递,但 sequence 必须上报 —— 否则覆盖出现缺口。
      if (this.isStaleEvent(event)) {
        skipped.push(event.sequence);
      } else {
        events.push(event);
      }
      state.delivered = Math.max(state.delivered, event.sequence);
    }
    state.liveBuffer = [];
    state.liveBufferBytes = 0;
    return { events, skipped };
  }

  /// 标记 ready。只有 catch-up 完成且 buffer 已排空才允许 ——
  /// socket.onOpen 不是 ready,这正是当前实现的缺陷所在。
  markReady(subscriptionId: string): ReadyFrame | undefined {
    const state = this.subscriptions.get(subscriptionId);
    if (state === undefined) return undefined;
    if (!state.caughtUp) return undefined;
    if (state.liveBuffer.length > 0) return undefined;
    if (state.overflowed) return undefined;
    state.ready = true;
    return {
      type: "notification_ready",
      id: state.id,
      subscriptionId: state.id,
      bridgeInstallationId: this.bridgeInstallationId,
      eventEpoch: this.eventEpoch,
      through: state.delivered,
      generation: state.generation,
    };
  }

  isReady(subscriptionId: string): boolean {
    return this.subscriptions.get(subscriptionId)?.ready === true;
  }

  /// 处理 ack。返回错误码而不是布尔,让调用方能回具体原因 ——
  /// 「越界」和「epoch 不匹配」需要客户端做完全不同的动作。
  ack(request: AckRequest): { ok: true } | { ok: false; error: string } {
    if (request.eventEpoch !== this.eventEpoch) return { ok: false, error: "epoch_mismatch" };
    if (request.through > this.store.tip()) return { ok: false, error: "ack_beyond_tip" };
    const persisted = this.store.recordAck(request.installationId, request.eventEpoch, request.through);
    if (!persisted) return { ok: false, error: "ack_not_persisted" };
    return { ok: true };
  }

  unsubscribe(subscriptionId: string): void {
    this.subscriptions.delete(subscriptionId);
  }

  /// 客户端断开时清掉它的所有订阅。
  unsubscribeInstallation(installationId: string): void {
    for (const [id, state] of [...this.subscriptions.entries()]) {
      if (state.installationId === installationId) this.subscriptions.delete(id);
    }
  }

  activeCount(): number {
    return this.subscriptions.size;
  }

  readyCount(): number {
    let count = 0;
    for (const state of this.subscriptions.values()) if (state.ready) count++;
    return count;
  }
}
