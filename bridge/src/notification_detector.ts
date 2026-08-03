import crypto from "node:crypto";
import {
  createNotificationEvent,
  type NotificationEventV1,
  type NotificationPrivacy,
} from "./notification_event.js";
import type { NotificationEventStore } from "./notification_event_store.js";

/// 事件探测器的输出。`persisted:false` 表示落盘失败 ——
/// 调用方不得把它交给任何发送队列,也不得对客户端宣称 persisted。
export interface DetectResult {
  event: NotificationEventV1;
  persisted: boolean;
}

export interface DetectorOptions {
  bridgeInstallationId: string;
  eventEpoch: string;
  store: NotificationEventStore;
  /// 通知正文的隐私级别。默认 generic:锁屏上只说「有新事件」。
  privacy?: NotificationPrivacy;
  now?: () => number;
}

/// 会话名解析器。Bridge 侧不一定拿得到会话名(headless / 未命名),
/// 拿不到时退化为通用文案而不是拼一个空标题。
export type SessionNameResolver = (sourceId: string, sessionId?: string) => string | undefined;

function completionTitle(sessionName: string | undefined, privacy: NotificationPrivacy): string {
  if (privacy === "session_name" && sessionName !== undefined && sessionName.length > 0) {
    return `${sessionName} 任务完成`;
  }
  return "任务完成";
}

function inputTitle(sessionName: string | undefined, privacy: NotificationPrivacy): string {
  if (privacy === "session_name" && sessionName !== undefined && sessionName.length > 0) {
    return `${sessionName} 等待输入`;
  }
  return "等待输入";
}

/// 从 Bridge 权威状态生成通知事件。
///
/// 为什么必须在 Bridge 侧判定而不是信手机上报:手机的 isStreaming 会因为
/// 进程被冻结、socket 半开、状态防抖而落后甚至永久错位。Bridge 的
/// noteStreamingFromEvent(server.ts:623) 是唯一权威的 streaming 边沿来源。
///
/// 关键去重不变量(stable-plan.md §5.2/§5.3):
///  - agent_end 与 agent_settled 对同一 taskGenerationId 只生成一个完成事件。
///  - 重复的 desktop/source 事件不得生成新 eventId。
///  - Bridge 重启后 in-flight generation 从 journal 恢复,结束事件沿用原 generation。
export class NotificationDetector {
  private readonly store: NotificationEventStore;
  private readonly bridgeInstallationId: string;
  private readonly eventEpoch: string;
  private readonly privacy: NotificationPrivacy;
  private readonly now: () => number;

  /// sourceId -> 当前 in-flight 的 taskGenerationId。
  private readonly activeGeneration = new Map<string, string>();
  /// sourceId -> 最近一次任务开始时刻(ms)。完成事件的「新鲜度」靠它判定:
  /// 有更新任务开跑后才送达的 task_completed 全是过期通知 —— 用户已经在等
  /// 下一轮,这时弹「任务完成」只会被当成误报(2026-08-02 事故:断链积压的
  /// 完成通知迟到 51s,撞进新任务开始后的第 4 秒)。
  private readonly latestStartedAt = new Map<string, number>();
  /// requestId -> eventId。input_required 与 input_resolved 靠它配对,
  /// 让 resolved 能更新/取消原来那条通知而不是新弹一条。
  private readonly inputRequests = new Map<string, string>();

  constructor(options: DetectorOptions) {
    this.store = options.store;
    this.bridgeInstallationId = options.bridgeInstallationId;
    this.eventEpoch = options.eventEpoch;
    this.privacy = options.privacy ?? "generic";
    this.now = options.now ?? Date.now;
    this.restoreGenerations();
  }

  /// 从 journal 恢复 in-flight generation。重启后紧接着到达的 agent_end
  /// 必须沿用原 generation,否则会被当成一个新任务而重复通知。
  private restoreGenerations(): void {
    for (const gen of this.store.inFlightGenerations()) {
      if (gen.sourceId.length === 0) continue;
      this.activeGeneration.set(gen.sourceId, gen.taskGenerationId);
      // in_flight 记录的 at 就是开始时刻(at 只在完成时被改写),据此恢复新鲜度判定。
      const startedAt = Date.parse(gen.at);
      if (Number.isFinite(startedAt)) {
        const known = this.latestStartedAt.get(gen.sourceId);
        if (known === undefined || startedAt > known) {
          this.latestStartedAt.set(gen.sourceId, startedAt);
        }
      }
    }
  }

  /// 任务开始。创建并持久化新的 taskGenerationId。
  onTaskStart(sourceId: string): string {
    const existing = this.activeGeneration.get(sourceId);
    // 重复 agent_start(relay 重连重放)不该开新代次。
    if (existing !== undefined) return existing;
    const generationId = crypto.randomUUID();
    this.activeGeneration.set(sourceId, generationId);
    this.latestStartedAt.set(sourceId, this.now());
    this.store.beginGeneration(sourceId, generationId);
    return generationId;
  }

  /// 任务被用户中断(电脑端 Esc / 手机端停止)。轮次确实结束,但这不是
  /// 「完成」——不产事件,只把在飞代次取消掉。不取消的话 journal 里的
  /// in_flight 会在重启后复活,被下一个 agent_end 补发成过期完成通知。
  onTaskAborted(sourceId: string): void {
    const generationId = this.activeGeneration.get(sourceId);
    if (generationId === undefined) return;
    this.store.cancelGeneration(generationId);
    this.activeGeneration.delete(sourceId);
  }

  /// 任务结束。返回 undefined 表示这一代已经通知过了 ——
  /// 这正是 agent_end 与 agent_settled 去重的落点。
  onTaskEnd(
    sourceId: string,
    context: { sessionId?: string; sessionName?: string } = {},
  ): DetectResult | undefined {
    const generationId = this.activeGeneration.get(sourceId);
    if (generationId === undefined) {
      // 没有 in-flight 代次:可能是 Bridge 在任务中途启动,只看到结束边沿。
      // 这种情况无法证明「任务确实在本机跑过」,记 recovery 代次而不是凭空造完成事件。
      return undefined;
    }
    const eventId = crypto.randomUUID();
    // completeGeneration 返回 false 表示已完成过,直接丢弃本次。
    if (!this.store.completeGeneration(generationId, eventId)) return undefined;
    this.activeGeneration.delete(sourceId);

    const event = createNotificationEvent({
      bridgeInstallationId: this.bridgeInstallationId,
      eventEpoch: this.eventEpoch,
      sequence: this.store.nextSequence(),
      eventId,
      type: "task_completed",
      taskGenerationId: generationId,
      sourceId,
      createdAt: new Date(this.now()).toISOString(),
      presentation: {
        title: completionTitle(context.sessionName, this.privacy),
        privacy: this.privacy,
      },
      ...(context.sessionId !== undefined ? { sessionId: context.sessionId } : {}),
    });
    return { event, persisted: this.store.appendEvent(event) };
  }

  /// Bridge 重启时只看到权威快照显示 streaming:创建带 recovery 标记的代次,
  /// 让后续的结束边沿有代次可归属,而不是被当成孤立事件丢掉。
  adoptStreamingSource(sourceId: string): string {
    const existing = this.activeGeneration.get(sourceId);
    if (existing !== undefined) return existing;
    const generationId = `recovery-${crypto.randomUUID()}`;
    this.activeGeneration.set(sourceId, generationId);
    this.latestStartedAt.set(sourceId, this.now());
    this.store.beginGeneration(sourceId, generationId);
    return generationId;
  }

  /// 等待输入。同一 requestId 重复到达复用原 eventId,不刷第二条通知。
  onInputRequired(
    requestId: string,
    context: { sourceId?: string; sessionId?: string; sessionName?: string } = {},
  ): DetectResult | undefined {
    if (this.inputRequests.has(requestId)) return undefined;
    const eventId = crypto.randomUUID();
    this.inputRequests.set(requestId, eventId);
    const event = createNotificationEvent({
      bridgeInstallationId: this.bridgeInstallationId,
      eventEpoch: this.eventEpoch,
      sequence: this.store.nextSequence(),
      eventId,
      type: "input_required",
      // collapseKey 绑 requestId:同一个请求的后续更新会替换而不是叠加。
      collapseKey: `input:${requestId}`,
      createdAt: new Date(this.now()).toISOString(),
      presentation: {
        title: inputTitle(context.sessionName, this.privacy),
        privacy: this.privacy,
      },
      ...(context.sourceId !== undefined ? { sourceId: context.sourceId } : {}),
      ...(context.sessionId !== undefined ? { sessionId: context.sessionId } : {}),
    });
    return { event, persisted: this.store.appendEvent(event) };
  }

  /// 输入已被回答/取消/过期。用原 collapseKey 让客户端更新或取消原通知。
  onInputResolved(
    requestId: string,
    context: { sourceId?: string; sessionId?: string } = {},
  ): DetectResult | undefined {
    // 没有对应的 input_required 就没有要撤销的通知,不生成噪声事件。
    if (!this.inputRequests.has(requestId)) return undefined;
    this.inputRequests.delete(requestId);
    const event = createNotificationEvent({
      bridgeInstallationId: this.bridgeInstallationId,
      eventEpoch: this.eventEpoch,
      sequence: this.store.nextSequence(),
      type: "input_resolved",
      collapseKey: `input:${requestId}`,
      priority: "normal",
      createdAt: new Date(this.now()).toISOString(),
      presentation: { title: "输入已处理", privacy: this.privacy },
      ...(context.sourceId !== undefined ? { sourceId: context.sourceId } : {}),
      ...(context.sessionId !== undefined ? { sessionId: context.sessionId } : {}),
    });
    return { event, persisted: this.store.appendEvent(event) };
  }

  /// source epoch 切换:显式作废旧代次,禁止串到新会话。
  onSourceEpochChanged(sourceId: string): void {
    const generationId = this.activeGeneration.get(sourceId);
    if (generationId === undefined) return;
    // 标记完成但不生成事件 —— 旧会话的任务结果已经不可能再送达了。
    this.store.completeGeneration(generationId, "");
    this.activeGeneration.delete(sourceId);
  }

  activeGenerationFor(sourceId: string): string | undefined {
    return this.activeGeneration.get(sourceId);
  }

  /// 这条完成事件是否已经过期:同 source 有更新的任务在它创建之后开跑。
  /// 订阅管理器在投递前调用 —— 过期事件走 skippedRanges,不推给手机。
  isStaleCompletion(event: NotificationEventV1): boolean {
    if (event.type !== "task_completed" || event.sourceId === undefined) return false;
    const startedAt = this.latestStartedAt.get(event.sourceId);
    if (startedAt === undefined) return false;
    const createdAt = Date.parse(event.createdAt);
    return Number.isFinite(createdAt) && startedAt > createdAt;
  }

  pendingInputCount(): number {
    return this.inputRequests.size;
  }
}
