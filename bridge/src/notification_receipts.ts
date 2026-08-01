import type { ReceiptRequest } from "./notification_protocol.js";
import type { ReceiptState } from "./notification_event.js";

/// 单个 installation 对单条事件的显示结果。
export interface ReceiptRecord {
  installationId: string;
  eventId: string;
  state: ReceiptState;
  at: string;
  /// 本地记录时间。客户端的 `at` 可能因设备时钟偏差而不可信,
  /// 仲裁与延迟统计一律用这个 Bridge 侧时间。
  recordedAt: number;
}

/// receipt 上限。receipt 只服务仲裁与指标,不参与 cursor 推进,
/// 所以是纯粹的有界缓存,满了就丢最老的,不影响正确性。
const MAX_RECEIPTS = 4_096;

/// 显示回执登记表。
///
/// 为什么 receipt 不推进 cursor(stable-plan.md §2.3/§4.3):
/// receipt 上传走 WorkManager,而 Android 16 起 FGS 内并发的 job 仍受
/// runtime quota 约束 —— 及时返回不是可依赖的行为。把 cursor 绑在 receipt 上
/// 会让「配额用尽」表现为「通知丢失」。cursor 只认 notification_ack。
///
/// receipt 的真正用途有两个:
///  1. LAN/FCM 仲裁:收到 display_requested/display_confirmed 就取消尚未
///     发出的 push fallback(已发出的不撤回,见 §8.2)。
///  2. 指标:区分 display_requested 与 display_confirmed,让「调用了 notify()」
///     不被当成「用户看见了」。
export class NotificationReceiptStore {
  /// `installationId + eventId` -> 最新回执。
  private readonly receipts = new Map<string, ReceiptRecord>();
  private readonly counts = new Map<ReceiptState, number>();

  constructor(private readonly now: () => number = Date.now) {}

  private key(installationId: string, eventId: string): string {
    return `${installationId}\u0000${eventId}`;
  }

  record(request: ReceiptRequest): ReceiptRecord {
    const record: ReceiptRecord = {
      installationId: request.installationId,
      eventId: request.eventId,
      state: request.state,
      at: request.at,
      recordedAt: this.now(),
    };
    const key = this.key(request.installationId, request.eventId);
    // 状态只向前:display_confirmed 之后再来一个 received(迟到的乱序回执)
    // 不能把它降级回去,否则仲裁会误判成「还没显示」而重发 push。
    const existing = this.receipts.get(key);
    if (existing !== undefined && this.rank(existing.state) > this.rank(record.state)) {
      return existing;
    }
    if (this.receipts.size >= MAX_RECEIPTS && !this.receipts.has(key)) {
      const oldest = this.receipts.keys().next().value;
      if (oldest !== undefined) this.receipts.delete(oldest);
    }
    this.receipts.delete(key);
    this.receipts.set(key, record);
    this.counts.set(record.state, (this.counts.get(record.state) ?? 0) + 1);
    return record;
  }

  /// 状态优先级。数值越大越「终态」。
  private rank(state: ReceiptState): number {
    switch (state) {
      case "received":
        return 1;
      case "display_requested":
        return 2;
      case "display_confirmed":
        return 4;
      case "suppressed_duplicate":
        return 3;
      case "blocked_permission":
      case "blocked_channel":
        // 被阻塞是明确的终态:再发 push 也不会显示,不该被当成「还没到」。
        return 4;
    }
  }

  get(installationId: string, eventId: string): ReceiptRecord | undefined {
    return this.receipts.get(this.key(installationId, eventId));
  }

  /// 该事件在这台设备上是否已经不需要 push fallback 了。
  /// 注意 blocked_* 也算「不需要」—— 权限被拒时发高优先级 push 只会
  /// 浪费配额并可能让 FCM 因看不到可见通知而降级后续投递。
  needsNoFallback(installationId: string, eventId: string): boolean {
    const record = this.get(installationId, eventId);
    if (record === undefined) return false;
    return (
      record.state === "display_requested" ||
      record.state === "display_confirmed" ||
      record.state === "suppressed_duplicate" ||
      record.state === "blocked_permission" ||
      record.state === "blocked_channel"
    );
  }

  stats(): Record<string, number> {
    const out: Record<string, number> = { tracked: this.receipts.size };
    for (const [state, count] of this.counts) out[state] = count;
    return out;
  }

  forgetInstallation(installationId: string): void {
    for (const [key, record] of [...this.receipts.entries()]) {
      if (record.installationId === installationId) this.receipts.delete(key);
    }
  }
}
