import crypto from "node:crypto";

/// 业务事件类型。只有这三种会变成用户可见通知。
/// 「连接中断」不在此列 —— 那是 installation 的本地状态,不是 Bridge 业务事件,
/// 写成全局事件会让每台手机的网络波动污染所有设备的 cursor。
export type NotificationEventType = "task_completed" | "input_required" | "input_resolved";

export type NotificationPriority = "high" | "normal";

/// 通知正文的隐私级别。默认 generic:锁屏上只说「有新事件」。
export type NotificationPrivacy = "generic" | "session_name";

export interface NotificationPresentation {
  title: string;
  body?: string;
  privacy: NotificationPrivacy;
}

/// 不可变业务事件。一旦 fsync 就永不修改 —— 投递状态(发了没、显示了没)
/// 单独记在 InstallationDelivery 里,避免「改一次投递状态就重写一条事件」
/// 把 append-only 日志变成可变存储。
export interface NotificationEventV1 {
  schema: 1;
  bridgeInstallationId: string;
  eventEpoch: string;
  /// 永久去重键。所有投递路径(LAN/FCM/Dart)共用它,这样重叠投递只显示一次。
  eventId: string;
  /// eventEpoch 内单调递增。cursor 靠它做连续前缀推进。
  sequence: number;
  /// 同一轮 agent_start/end/settled 共用,防 end 与 settled 生成两条完成通知。
  taskGenerationId?: string;
  sourceId?: string;
  sessionId?: string;
  type: NotificationEventType;
  createdAt: string;
  /// 相对 TTL 而非绝对 expiresAt:Android 侧不能信任自己的时钟(用户改时间、
  /// 时区错误、重启未同步都会让刚生成的事件被判过期而静默丢弃)。
  /// 客户端以「本地接收时刻」为基准计算剩余有效期。见 stable-plan.md §5.4。
  ttlSeconds: number;
  priority: NotificationPriority;
  collapseKey?: string;
  presentation: NotificationPresentation;
}

/// 每个 installation 的投递状态。可变、可重试,不污染业务事件。
export interface InstallationDeliveryV1 {
  eventId: string;
  installationId: string;
  /// 单飞与竞态仲裁用。见 stable-plan.md §8.2。
  deliveryGeneration: number;
  lan: {
    state: "not_connected" | "queued" | "sent" | "received" | "displayed";
    sentAt?: string;
    receiptAt?: string;
  };
  push: {
    state: "disabled" | "not_needed" | "pending" | "accepted" | "failed" | "expired";
    keyId?: string;
    attempts: number;
    nextAttemptAt?: string;
  };
}

/// 客户端回报的显示结果。`display_requested` 只代表调用了 notify(),
/// 不代表用户看见了 —— 渠道被关、权限被撤、系统限流都可能让它不可见。
/// 所以 SLO 分子只认 display_confirmed。见 stable-plan.md §2.3。
export type ReceiptState =
  | "received"
  | "display_requested"
  | "display_confirmed"
  | "suppressed_duplicate"
  | "blocked_permission"
  | "blocked_channel";

export const RECEIPT_STATES: readonly ReceiptState[] = [
  "received",
  "display_requested",
  "display_confirmed",
  "suppressed_duplicate",
  "blocked_permission",
  "blocked_channel",
];

export function isReceiptState(value: unknown): value is ReceiptState {
  return typeof value === "string" && (RECEIPT_STATES as readonly string[]).includes(value);
}

/// 默认 TTL。等待输入比任务完成更短 —— 一个小时后再提醒「有人在等你输入」
/// 已经没有意义,而任务完成的结果隔天看仍然有用。
export const DEFAULT_TTL_SECONDS: Record<NotificationEventType, number> = {
  task_completed: 24 * 60 * 60,
  input_required: 60 * 60,
  input_resolved: 60 * 60,
};

/// 单条事件的编码上限。超过就不该走推送通道,只能靠 cursor 补齐。
export const MAX_EVENT_BYTES = 8 * 1024;
export const MAX_TITLE_CHARS = 200;
export const MAX_BODY_CHARS = 500;

export function newEventId(): string {
  return crypto.randomUUID();
}

export interface CreateEventInput {
  bridgeInstallationId: string;
  eventEpoch: string;
  sequence: number;
  type: NotificationEventType;
  taskGenerationId?: string;
  sourceId?: string;
  sessionId?: string;
  priority?: NotificationPriority;
  collapseKey?: string;
  presentation: NotificationPresentation;
  ttlSeconds?: number;
  eventId?: string;
  createdAt?: string;
}

/// 构造事件并做长度收敛。title/body 在这里就截断,不留给下游 —— 否则
/// 一条超长会话名会在 FCM envelope 那一层才炸,而那时已经无法回头补偿。
export function createNotificationEvent(input: CreateEventInput): NotificationEventV1 {
  const title = input.presentation.title.slice(0, MAX_TITLE_CHARS);
  const body = input.presentation.body?.slice(0, MAX_BODY_CHARS);
  const event: NotificationEventV1 = {
    schema: 1,
    bridgeInstallationId: input.bridgeInstallationId,
    eventEpoch: input.eventEpoch,
    eventId: input.eventId ?? newEventId(),
    sequence: input.sequence,
    type: input.type,
    createdAt: input.createdAt ?? new Date().toISOString(),
    ttlSeconds: input.ttlSeconds ?? DEFAULT_TTL_SECONDS[input.type],
    priority: input.priority ?? (input.type === "input_resolved" ? "normal" : "high"),
    presentation: { title, privacy: input.presentation.privacy, ...(body ? { body } : {}) },
  };
  if (input.taskGenerationId !== undefined) event.taskGenerationId = input.taskGenerationId;
  if (input.sourceId !== undefined) event.sourceId = input.sourceId;
  if (input.sessionId !== undefined) event.sessionId = input.sessionId;
  if (input.collapseKey !== undefined) event.collapseKey = input.collapseKey;
  return event;
}

function isPresentation(value: unknown): value is NotificationPresentation {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<NotificationPresentation>;
  if (typeof record.title !== "string") return false;
  if (record.body !== undefined && typeof record.body !== "string") return false;
  return record.privacy === "generic" || record.privacy === "session_name";
}

const EVENT_TYPES: readonly string[] = ["task_completed", "input_required", "input_resolved"];

/// 解析持久化记录。校验必须严格:replay 时读到一条结构不对的记录,
/// 宁可跳过并告警,也不能让它污染 sequence 或让 store 整体加载失败。
export function parseNotificationEvent(value: unknown): NotificationEventV1 | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Partial<NotificationEventV1>;
  if (record.schema !== 1) return undefined;
  if (typeof record.bridgeInstallationId !== "string" || record.bridgeInstallationId.length === 0) {
    return undefined;
  }
  if (typeof record.eventEpoch !== "string" || record.eventEpoch.length === 0) return undefined;
  if (typeof record.eventId !== "string" || record.eventId.length === 0) return undefined;
  if (
    typeof record.sequence !== "number" ||
    !Number.isSafeInteger(record.sequence) ||
    record.sequence < 1
  ) {
    return undefined;
  }
  if (typeof record.type !== "string" || !EVENT_TYPES.includes(record.type)) return undefined;
  if (typeof record.createdAt !== "string") return undefined;
  if (
    typeof record.ttlSeconds !== "number" ||
    !Number.isFinite(record.ttlSeconds) ||
    record.ttlSeconds <= 0
  ) {
    return undefined;
  }
  if (record.priority !== "high" && record.priority !== "normal") return undefined;
  if (!isPresentation(record.presentation)) return undefined;
  if (record.taskGenerationId !== undefined && typeof record.taskGenerationId !== "string") {
    return undefined;
  }
  if (record.sourceId !== undefined && typeof record.sourceId !== "string") return undefined;
  if (record.sessionId !== undefined && typeof record.sessionId !== "string") return undefined;
  if (record.collapseKey !== undefined && typeof record.collapseKey !== "string") return undefined;
  return record as NotificationEventV1;
}

/// 事件是否已过期。这是 Bridge 侧的判定(Bridge 时钟是权威时钟);
/// 客户端不做绝对时间比较,见 ttlSeconds 的注释。
export function isExpired(event: NotificationEventV1, now: number = Date.now()): boolean {
  const created = Date.parse(event.createdAt);
  if (!Number.isFinite(created)) return false;
  return now - created > event.ttlSeconds * 1000;
}

export function remainingTtlSeconds(
  event: NotificationEventV1,
  now: number = Date.now(),
): number {
  const created = Date.parse(event.createdAt);
  if (!Number.isFinite(created)) return event.ttlSeconds;
  const elapsed = (now - created) / 1000;
  return Math.max(0, Math.round(event.ttlSeconds - elapsed));
}
