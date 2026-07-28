import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { RelayConfig } from "./config.js";
import {
  navRuntimeFor,
  runNavigate,
  type NavCommandContextCache,
  type NavResult,
} from "./nav_commands.js";
import { executeRemoteCommand, SAFE_REMOTE_COMMANDS, type RemoteCommand } from "./remote_commands.js";
import { cloneForWire, encodeForWire, MAX_SNAPSHOT_BYTES } from "./serialization.js";

type JsonObject = Record<string, unknown>;

const MAX_SOCKET_BUFFER = 2 * 1024 * 1024;
const MAX_CAPTURE_BYTES = 64 * 1024 * 1024;
const HEARTBEAT_MS = 10_000;
const MAX_COMMAND_QUEUE = 32;
const MAX_COMMAND_RESULTS = 256;

function serializeModel(model: ExtensionContext["model"]): JsonObject | null {
  if (!model) return null;
  return {
    id: model.id,
    name: model.name,
    provider: model.provider,
    api: model.api,
    reasoning: model.reasoning,
    input: model.input,
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
    cost: model.cost,
  };
}

function sanitizeSourceId(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 128);
}

/** treeSummary 的字节预算;超出直接从快照剔除。 */
const TREE_SUMMARY_BYTE_BUDGET = 256 * 1024;

/// treeSummary 的节点数上限。字节预算之外还要限制**条数**,因为 app 侧
/// 解析(_normalizeTreeNode)和路径计算仍是按 children 递归的。
const MAX_TREE_SUMMARY_NODES = 1200;

/** 与 pi getSessionStats 同形状的统计(从 branch entries 汇总)。 */
export function computeSessionStats(
  entries: readonly unknown[],
  contextUsage: unknown,
): JsonObject {
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let cost = 0;
  let userMessages = 0;
  let assistantMessages = 0;
  let toolResults = 0;
  let toolCalls = 0;
  let totalMessages = 0;
  const add = (usage: any): void => {
    if (!usage) return;
    input += usage.input ?? 0;
    output += usage.output ?? 0;
    cacheRead += usage.cacheRead ?? 0;
    cacheWrite += usage.cacheWrite ?? 0;
    cost += usage.cost?.total ?? 0;
  };
  for (const raw of entries) {
    const entry = raw as any;
    if ((entry?.type === "branch_summary" || entry?.type === "compaction") && entry.usage) {
      add(entry.usage);
    }
    if (entry?.type !== "message") continue;
    totalMessages++;
    const message = entry.message;
    if (message?.role === "user") {
      userMessages++;
    } else if (message?.role === "toolResult") {
      toolResults++;
      add(message.usage);
    } else if (message?.role === "assistant") {
      assistantMessages++;
      if (Array.isArray(message.content)) {
        toolCalls += message.content.filter((c: any) => c?.type === "toolCall").length;
      }
      add(message.usage);
    }
  }
  return {
    userMessages,
    assistantMessages,
    toolCalls,
    toolResults,
    totalMessages,
    tokens: {
      input,
      output,
      cacheRead,
      cacheWrite,
      total: input + output + cacheRead + cacheWrite,
    },
    cost,
    contextUsage: contextUsage ?? null,
  };
}

/// 会话树节点的原始形态(pi sessionManager.getTree() 的元素)。
interface RawTreeNode {
  entry?: any;
  children?: RawTreeNode[];
  label?: string | null;
}

function treePreview(entry: any, limit: number): string {
  if (limit <= 0 || entry?.type !== "message") return "";
  const content = entry.message?.content;
  let preview = "";
  if (typeof content === "string") preview = content;
  else if (Array.isArray(content)) {
    preview = content
      .filter((c: any) => c?.type === "text")
      .map((c: any) => c.text)
      .join(" ");
  }
  return preview.length > limit ? `${preview.slice(0, limit)}…` : preview;
}

/// 单个节点的压缩形态(**不含子节点**,children 由调用方迭代填充)。
///
/// 为 null 的字段直接不输出 —— 千条规模下 `"label":null` 这类占位就是几十 KB,
/// 而 app 侧 `as String?` 对缺字段与 null 同义。
function summarizeTreeNode(node: RawTreeNode, previewLimit: number): JsonObject {
  const entry = node?.entry ?? {};
  const preview = treePreview(entry, previewLimit);
  const role = entry.type === "message" ? (entry.message?.role ?? null) : null;
  return {
    id: entry.id,
    ...(entry.parentId ? { parentId: entry.parentId } : {}),
    type: entry.type ?? "unknown",
    ...(entry.timestamp != null ? { timestamp: entry.timestamp } : {}),
    ...(role ? { role } : {}),
    ...(preview ? { preview } : {}),
    ...(node?.label ? { label: node.label } : {}),
    children: [] as JsonObject[],
  };
}

/// 会话树是**一条长单链**(每回合一个节点,没有分叉时深度 == 节点数),
/// 所以任何按 children 递归的写法都会在千条会话上爆栈。爆栈会被
/// captureSnapshot 的 try/catch 吞成 `treeSummary = undefined`,
/// 表现和超预算一模一样:「会话树不可用」。这里全部改成显式栈迭代。
function buildSummaryTree(
  tree: RawTreeNode[],
  previewLimit: number,
  keep?: Set<RawTreeNode>,
): JsonObject[] {
  const roots: JsonObject[] = [];
  // omitted:从最近一个保留祖先到本节点之间被剔掉的节点数
  const stack: { node: RawTreeNode; sink: JsonObject[]; omitted: number }[] = [];
  for (let i = tree.length - 1; i >= 0; i--) {
    stack.push({ node: tree[i]!, sink: roots, omitted: 0 });
  }
  while (stack.length > 0) {
    const { node, sink, omitted } = stack.pop()!;
    const kept = !keep || keep.has(node);
    let childSink = sink;
    let childOmitted = omitted;
    if (kept) {
      const out = summarizeTreeNode(node, previewLimit);
      if (omitted > 0) out.collapsedBefore = omitted;
      sink.push(out);
      childSink = out.children as JsonObject[];
      childOmitted = 0;
    } else {
      // 被剔掉:子节点挂到同一个 sink 上,并累加折叠计数
      childOmitted = omitted + 1;
    }
    const children = node?.children ?? [];
    for (let i = children.length - 1; i >= 0; i--) {
      stack.push({ node: children[i]!, sink: childSink, omitted: childOmitted });
    }
  }
  return roots;
}

function countNodes(tree: RawTreeNode[]): number {
  let count = 0;
  const stack = [...tree];
  while (stack.length > 0) {
    const node = stack.pop()!;
    count++;
    for (const child of node?.children ?? []) stack.push(child);
  }
  return count;
}

/// 结构剪枝的保留集。
///
/// 会话树的用途是导航与回退,所以必需的是**结构**和**最近的位置**:分叉点、
/// 分支头、叶子、非 message 节点(压缩/分支摘要)、书签,以及尾部一段。
/// 中间那条长长的线性历史可以折叠 —— 那些节点既不是分叉,也不是人会回退到的目标。
function collectKeepSet(tree: RawTreeNode[], tailCount: number): Set<RawTreeNode> {
  const order: RawTreeNode[] = [];
  const stack: RawTreeNode[] = [];
  for (let i = tree.length - 1; i >= 0; i--) stack.push(tree[i]!);
  while (stack.length > 0) {
    const node = stack.pop()!;
    order.push(node);
    const children = node?.children ?? [];
    for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]!);
  }

  const keep = new Set<RawTreeNode>(tree);
  for (const node of order) {
    const children = node?.children ?? [];
    // 线性中间节点才是 children.length === 1;分叉点与叶子都要留
    if (children.length !== 1) keep.add(node);
    if (children.length > 1) for (const child of children) keep.add(child);
    if (node?.entry?.type && node.entry.type !== "message") keep.add(node);
    if (node?.label) keep.add(node);
  }
  for (const node of order.slice(-Math.max(0, tailCount))) keep.add(node);
  return keep;
}

/// 压缩会话树。
///
/// **逐级降级,而不是超预算就整体剔掉**。以前这里是全有或全无:一超预算就
/// 返回 undefined,`treeSummary` 从快照里消失,bridge 只能回
/// "desktop snapshot does not include a tree",app 显示「会话树不可用」。
/// 千条规模的会话必然超预算(每节点约 250 字节),于是会话树彻底不可用。
///
/// 预算不能直接调大:`treeSummary` 搭在**每一份快照**里,包括流式期间每秒一次的
/// 保活快照 —— 那等于每秒往手机推几百 KB。所以要让它变小,不是消失。
export function buildTreeSummary(tree: unknown[]): JsonObject[] | undefined {
  const raw = (tree ?? []) as RawTreeNode[];
  const fits = (summary: JsonObject[]) =>
    JSON.stringify(summary).length <= TREE_SUMMARY_BYTE_BUDGET;

  // 1) 全部节点,预览逐级缩短。节点数本身也要设上限:app 侧解析与渲染
  //    仍是按 children 递归的,几千层深度在 Dart 侧同样有栈风险。
  if (countNodes(raw) <= MAX_TREE_SUMMARY_NODES) {
    for (const previewLimit of [120, 40, 0]) {
      const summary = buildSummaryTree(raw, previewLimit);
      if (fits(summary)) return summary;
    }
  }
  // 2) 剪掉线性中间节点,尾部保留段逐步收紧
  for (const tail of [400, 200, 80, 30]) {
    const keep = collectKeepSet(raw, tail);
    const summary = buildSummaryTree(raw, 40, keep);
    if (fits(summary)) return summary;
  }
  // 3) 最后一招:只给骨架
  const keep = collectKeepSet(raw, 10);
  const skeleton = buildSummaryTree(raw, 0, keep);
  return fits(skeleton) ? skeleton : undefined;
}

/** 读会话文件路径;陈旧 ctx 的 getter 会抛,这里吞掉。 */
function safeSessionFile(ctx: ExtensionContext): string | undefined {
  try {
    return ctx.sessionManager.getSessionFile() ?? undefined;
  } catch {
    return undefined;
  }
}

/// 队列镜像的上界:pi 消费排队消息不会回调扩展,镜像只能在回合边界收敛。
const MAX_QUEUE_MIRROR = 32;

export class DesktopRelay {
  private socket: WebSocket | undefined;
  private ctx: ExtensionContext | undefined;
  private active = false;
  private registered = false;
  private epoch = crypto.randomUUID();
  private seq = 0;
  private reconnectAttempt = 0;
  private reconnectTimer: NodeJS.Timeout | undefined;
  private heartbeatTimer: NodeJS.Timeout | undefined;
  private messageTimer: NodeJS.Timeout | undefined;
  private toolTimer: NodeJS.Timeout | undefined;
  private pendingMessageUpdate: JsonObject | undefined;
  private pendingToolUpdates = new Map<string, JsonObject>();
  private inFlightMessage: JsonObject | undefined;
  private highestFence = 0;
  private ownerActive = false;
  private ownerFence = 0;
  private ownerExpiresAt = 0;
  private controlGeneration = 0;
  private commandDepth = 0;
  private commandChain: Promise<void> = Promise.resolve();
  private activeRequests = new Set<string>();
  private commandResults = new Map<string, JsonObject>();
  private compacting = false;
  private streaming = false;
  private snapshotTimer: NodeJS.Timeout | undefined;
  /// 绑定的会话文件:ctx 对象每次 emit 都换,只有它是稳定的。
  private boundSessionFile: string | undefined;
  /// 合成队列镜像(pi 的 queue_update 不经过扩展事件流)。
  /// 有界:pi 消费一条排队消息不会通知扩展,所以镜像只能靠回合边界收敛,
  /// 中间必然偏大 —— 至少不能无界增长。
  private readonly steeringMirror: string[] = [];
  private readonly followUpMirror: string[] = [];
  private lastSnapshotAt = 0;
  private lastSnapshotSeq = 0;

  readonly sourceId = sanitizeSourceId(`${os.hostname()}:${process.pid}`);

  constructor(
    private readonly pi: ExtensionAPI,
    private readonly config: RelayConfig,
    private readonly navCache?: NavCommandContextCache,
  ) {}

  start(ctx: ExtensionContext): void {
    this.stopInternal(false);
    this.ctx = ctx;
    this.boundSessionFile = safeSessionFile(ctx);
    this.active = true;
    this.setStatus("PiPilot: connecting");
    this.connect();
  }

  stop(ctx: ExtensionContext): void {
    if (!this.isBound(ctx)) return;
    this.flushCoalesced();
    this.stopInternal(true);
  }

  dispose(): void {
    this.stopInternal(true);
  }

  /** session_before_compact / session_compact 事件驱动的压缩标志。 */
  setCompacting(value: boolean, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.compacting = value;
  }

  /// agent_start / agent_settled 驱动。流式期间定期自发快照,
  /// 这样中途加入的手机端拿到的快照带得上 isStreaming 与 inFlightMessage。
  setStreaming(value: boolean, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    if (this.streaming === value) return;
    this.streaming = value;
    if (!value) {
      this.clearSnapshotTimer();
      return;
    }
    this.lastSnapshotAt = Date.now();
    this.lastSnapshotSeq = this.seq;
    this.snapshotTimer = setInterval(() => this.streamSnapshotTick(), 1000);
    this.snapshotTimer.unref?.();
  }

  private streamSnapshotTick(): void {
    if (!this.registered || !this.liveCtx()) return;
    const grew = this.seq - this.lastSnapshotSeq;
    if (grew <= 0) return;
    if (
      grew >= this.config.streamSnapshotEvents ||
      Date.now() - this.lastSnapshotAt >= this.config.streamSnapshotMaxMs
    ) {
      this.sendSnapshot("streaming keepalive");
    }
  }

  private clearSnapshotTimer(): void {
    if (this.snapshotTimer) clearInterval(this.snapshotTimer);
    this.snapshotTimer = undefined;
  }

  emitBoundary(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.flushCoalesced();
    this.sendEvent(event);
  }

  /**
   * 桌面端即将换会话/开分支/回退。
   *
   * 这些操作会让 relay 短暂离线并换 epoch。发一个提示帧让手机知道"这是切换,
   * 不是掉线",避免它拆掉整个界面再重建。
   */
  emitSessionTransition(reason: string, ctx: ExtensionContext): void {
    this.emitEvent({ type: "pipilot_session_transition", reason }, ctx);
  }

  /**
   * 合成队列镜像。
   *
   * pi 的 `queue_update` **不经过扩展事件流**(它只发给 `session.subscribe`),
   * 所以桌面源上手机永远看不到队列。这里由 relay 自己维护:手机发来的消息
   * 明细我们知道,电脑端自己排的只能算个数 —— 所以帧上带 `partial: true`。
   */
  noteRemoteQueued(message: string, deliverAs: "steer" | "followUp", ctx: ExtensionContext): void {
    const queue = deliverAs === "steer" ? this.steeringMirror : this.followUpMirror;
    queue.push(message);
    if (queue.length > MAX_QUEUE_MIRROR) queue.splice(0, queue.length - MAX_QUEUE_MIRROR);
    this.emitQueueMirror(ctx);
  }

  /**
   * 中断:pi 会把未发送的排队消息**回填到电脑端输入框**,它们不再排队。
   * 镜像必须立刻清空,否则手机会一直显示一批根本不存在的待发消息。
   */
  noteAborted(ctx: ExtensionContext): void {
    this.clearQueueMirror(ctx);
  }

  clearQueueMirror(ctx: ExtensionContext): void {
    if (this.steeringMirror.length === 0 && this.followUpMirror.length === 0) return;
    this.steeringMirror.length = 0;
    this.followUpMirror.length = 0;
    this.emitQueueMirror(ctx);
  }

  private emitQueueMirror(ctx: ExtensionContext): void {
    this.emitEvent(
      {
        type: "queue_update",
        steering: [...this.steeringMirror],
        followUp: [...this.followUpMirror],
        partial: true,
      },
      ctx,
    );
  }

  emitEvent(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.sendEvent(event);
  }

  emitMessageUpdate<T extends { message?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx)) return;
    try {
      const cloned = cloneForWire(event) as JsonObject;
      this.pendingMessageUpdate = cloned;
      if (cloned.message && typeof cloned.message === "object") {
        this.inFlightMessage = cloned.message as JsonObject;
      }
    } catch {
      this.resnapshot("message update too large");
      return;
    }
    if (!this.messageTimer) {
      this.messageTimer = setTimeout(() => {
        this.messageTimer = undefined;
        const pending = this.pendingMessageUpdate;
        this.pendingMessageUpdate = undefined;
        if (pending) this.sendEvent(pending);
      }, 25);
      this.messageTimer.unref();
    }
  }

  emitMessageEnd(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.flushMessageUpdate();
    this.sendEvent(event);
    this.inFlightMessage = undefined;
  }

  emitToolUpdate<T extends { toolCallId?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx) || typeof event.toolCallId !== "string") return;
    try {
      this.pendingToolUpdates.set(event.toolCallId, cloneForWire(event) as JsonObject);
    } catch {
      this.resnapshot("tool update too large");
      return;
    }
    if (!this.toolTimer) {
      this.toolTimer = setTimeout(() => {
        this.toolTimer = undefined;
        this.flushToolUpdates();
      }, 100);
      this.toolTimer.unref();
    }
  }

  emitToolEnd<T extends { toolCallId?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx)) return;
    if (typeof event.toolCallId === "string") {
      const pending = this.pendingToolUpdates.get(event.toolCallId);
      if (pending) {
        this.pendingToolUpdates.delete(event.toolCallId);
        this.sendEvent(pending);
      }
    }
    this.sendEvent(event);
  }

  snapshot(ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.sendSnapshot("state changed");
  }

  private connect(): void {
    if (!this.active || this.socket) return;
    const socket = new WebSocket(this.config.url, { handshakeTimeout: 5_000 });
    this.socket = socket;

    socket.on("open", () => {
      if (this.socket !== socket || !this.active) return;
      this.reconnectAttempt = 0;
      this.registered = false;
      this.newEpoch();
      this.sendRegistration();
    });
    socket.on("message", (data) => this.handleHubMessage(data.toString()));
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.registered = false;
      this.clearHeartbeat();
      if (this.active) {
        this.setStatus("PiPilot: reconnecting");
        this.scheduleReconnect();
      }
    });
    socket.on("error", () => socket.close());
  }

  private handleHubMessage(text: string): void {
    let msg: JsonObject;
    try {
      msg = JSON.parse(text) as JsonObject;
    } catch {
      return;
    }
    switch (msg.type) {
      case "desktop_registered":
        if (msg.epoch !== this.epoch) return;
        this.registered = true;
        this.setStatus("PiPilot: synced");
        this.startHeartbeat();
        this.sendSnapshot("registration barrier");
        return;

      case "desktop_status": {
        const selected = typeof msg.selectedClients === "number" ? msg.selectedClients : 0;
        const owner = msg.owner && typeof msg.owner === "object" ? (msg.owner as JsonObject) : {};
        const nextOwnerActive = owner.owned === true;
        const nextOwnerFence =
          nextOwnerActive && typeof owner.fence === "number" && Number.isSafeInteger(owner.fence)
            ? owner.fence
            : 0;
        const nextOwnerExpiresAt =
          nextOwnerActive &&
          typeof owner.expiresAt === "number" &&
          Number.isSafeInteger(owner.expiresAt)
            ? owner.expiresAt
            : 0;
        if (nextOwnerActive !== this.ownerActive || nextOwnerFence !== this.ownerFence) {
          this.controlGeneration++;
        }
        this.ownerActive = nextOwnerActive;
        this.ownerFence = nextOwnerFence;
        this.ownerExpiresAt = nextOwnerExpiresAt;
        this.highestFence = Math.max(this.highestFence, nextOwnerFence);
        this.setStatus(
          nextOwnerActive
            ? `PiPilot: controlled (${selected})`
            : `PiPilot: synced (${selected})`,
        );
        return;
      }

      case "desktop_snapshot_request": {
        // 按需快照:hub 发现快照与事件流不连续时索要。
        // 绝不能走 resnapshot()——那会 newEpoch,清空重放环并摧毁租约。
        const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
        if (!requestId) return;
        if (!this.registered || !this.liveCtx()) {
          this.sendFrame({
            type: "desktop_snapshot_unavailable",
            requestId,
            reason: this.registered ? "stale_ctx" : "not_registered",
          });
          return;
        }
        this.sendSnapshot("hub request", requestId);
        return;
      }

      case "desktop_resync_required":
        this.resnapshot(typeof msg.reason === "string" ? msg.reason : "hub requested resync");
        return;

      case "remote_command":
        this.queueRemoteCommand(msg);
        return;

      case "desktop_heartbeat_ack":
      case "desktop_ack":
      case "desktop_hello":
        return;
    }
  }

  private queueRemoteCommand(msg: JsonObject): void {
    const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
    if (!requestId) return;
    const cached = this.commandResults.get(requestId);
    if (cached) {
      this.sendFrame(cached);
      return;
    }
    if (this.activeRequests.has(requestId)) return;
    if (this.commandDepth >= MAX_COMMAND_QUEUE) {
      this.sendCommandResult(requestId, false, undefined, "desktop command queue is full");
      return;
    }
    if (msg.epoch !== this.epoch) {
      this.sendCommandResult(requestId, false, undefined, "stale desktop session epoch");
      return;
    }
    if (typeof msg.fence !== "number" || !Number.isSafeInteger(msg.fence)) {
      this.sendCommandResult(requestId, false, undefined, "missing fencing token");
      return;
    }
    if (msg.fence < this.highestFence) {
      this.sendCommandResult(requestId, false, undefined, "stale fencing token");
      return;
    }
    if (!this.hasActiveOwner(msg.fence)) {
      this.sendCommandResult(requestId, false, undefined, "owner lease is not active or has expired");
      return;
    }
    if (!msg.command || typeof msg.command !== "object") {
      this.sendCommandResult(requestId, false, undefined, "invalid command");
      return;
    }

    this.highestFence = Math.max(this.highestFence, msg.fence);
    this.activeRequests.add(requestId);
    this.commandDepth++;
    const command = cloneForWire(msg.command) as RemoteCommand;
    const queuedEpoch = this.epoch;
    const queuedFence = msg.fence;
    const queuedGeneration = this.controlGeneration;
    this.commandChain = this.commandChain
      .then(async () => {
        const ctx = this.ctx;
        if (!this.active || !ctx) throw new Error("desktop runtime is shutting down");
        if (
          queuedEpoch !== this.epoch ||
          queuedGeneration !== this.controlGeneration ||
          !this.hasActiveOwner(queuedFence) ||
          queuedFence < this.highestFence
        ) {
          throw new Error("queued command has a stale owner lease");
        }
        const result = await executeRemoteCommand(command, {
          pi: this.pi,
          ctx,
          navigate: (entryId) => this.navigate(entryId, ctx),
        });
        const delivery = (result as { delivery?: unknown } | undefined)?.delivery;
        if (delivery === "steer" || delivery === "followUp") {
          this.noteRemoteQueued(String(command.message), delivery, ctx);
        }
        return result;
      })
      .then(
        (data) => this.sendCommandResult(requestId, true, data),
        (error) =>
          this.sendCommandResult(
            requestId,
            false,
            undefined,
            error instanceof Error ? error.message : String(error),
          ),
      )
      .finally(() => {
        this.activeRequests.delete(requestId);
        this.commandDepth--;
      });
  }

  /**
   * 执行一次会话回退。
   *
   * 用缓存的命令上下文(远程命令自己的 ctx 上没有 `navigateTree`)。
   * 从没在电脑上跑过 `/pipilot-nav` 时缓存是空的,这时如实报错并提示用户
   * 在电脑上跑一次 —— 比悄悄失败或伪装成功要好。
   */
  private async navigate(entryId: string | undefined, ctx: ExtensionContext): Promise<unknown> {
    const cached = this.navCache?.get(this.boundSessionFile ?? "");
    if (!cached) {
      if (ctx.mode === "tui") {
        ctx.ui.notify(
          "手机请求回退会话:请先在这里执行一次 /pipilot-undo 以启用远程回退",
          "warning",
        );
      }
      throw new Error(
        "rollback needs the desktop command context; run /pipilot-undo once on the computer",
      );
    }
    const result = await runNavigate(navRuntimeFor(cached), entryId);
    if (!result.ok) throw new Error(result.error ?? "rollback was cancelled");
    return result;
  }

  /** 回退结果广播给手机:两端都靠随后的 `session_tree` 事件收敛。 */
  emitNavResult(result: NavResult, ctx: ExtensionContext): void {
    this.emitEvent(
      {
        type: "pipilot_nav_result",
        ok: result.ok,
        ...(result.editorText !== undefined ? { editorText: result.editorText } : {}),
        ...(result.error !== undefined ? { error: result.error } : {}),
      },
      ctx,
    );
    this.snapshot(ctx);
  }

  private sendCommandResult(
    requestId: string,
    success: boolean,
    data?: unknown,
    error?: string,
  ): void {
    const result: JsonObject = {
      type: "remote_result",
      requestId,
      success,
      ...(data !== undefined ? { data } : {}),
      ...(error ? { error } : {}),
    };
    this.commandResults.set(requestId, result);
    while (this.commandResults.size > MAX_COMMAND_RESULTS) {
      const oldest = this.commandResults.keys().next().value as string | undefined;
      if (!oldest) break;
      this.commandResults.delete(oldest);
    }
    this.sendFrame(result);
  }

  private sendRegistration(): void {
    const ctx = this.liveCtx();
    if (!ctx) return;
    const snapshot = this.captureSnapshot();
    if (!snapshot) return;
    this.sendFrame(
      {
        type: "desktop_register",
        source: {
          sourceId: this.sourceId,
          label:
            this.config.label ?? `${path.basename(ctx.cwd) || ctx.cwd} · PID ${process.pid}`,
          cwd: ctx.cwd,
          sessionId: ctx.sessionManager.getSessionId(),
          sessionFile: ctx.sessionManager.getSessionFile(),
          sessionName: ctx.sessionManager.getSessionName(),
          capabilities: [...SAFE_REMOTE_COMMANDS],
        },
        snapshot,
      },
      MAX_SNAPSHOT_BYTES,
    );
  }

  private sendSnapshot(reason: string, requestId?: string): void {
    if (!this.registered) return;
    // 顺序是关键:先把 25ms/100ms 合批计时器排空(各自 ++seq),再取快照,
    // 这样 baseSeq 恰好等于线上最后一个事件——既不留洞也不重复。
    this.flushCoalesced();
    const snapshot = this.captureSnapshot();
    if (!snapshot) return;
    this.lastSnapshotAt = Date.now();
    this.lastSnapshotSeq = this.seq;
    this.sendFrame(
      {
        type: "desktop_snapshot",
        reason,
        ...(requestId ? { requestId } : {}),
        snapshot,
      },
      MAX_SNAPSHOT_BYTES,
    );
  }

  private captureSnapshot(): JsonObject | undefined {
    const ctx = this.liveCtx();
    if (!ctx) return undefined;
    const branch = ctx.sessionManager.getBranch();
    let entries = cloneForWire(branch, MAX_CAPTURE_BYTES) as unknown as JsonObject[];
    const models = ctx.modelRegistry.getAvailable().map((model) => serializeModel(model));
    const contextUsage = ctx.getContextUsage();
    const state: JsonObject = {
      model: serializeModel(ctx.model),
      thinkingLevel: this.pi.getThinkingLevel(),
      isStreaming: !ctx.isIdle(),
      isCompacting: this.compacting,
      steeringMode: "one-at-a-time",
      followUpMode: "one-at-a-time",
      sessionFile: ctx.sessionManager.getSessionFile() ?? null,
      sessionId: ctx.sessionManager.getSessionId(),
      sessionName: ctx.sessionManager.getSessionName() ?? null,
      cwd: ctx.cwd,
      // 扩展 API 不暴露 auto-compaction 状态,发 null 让客户端显示「未知」
      autoCompactionEnabled: null,
      messageCount: entries.length,
      pendingMessageCount: ctx.hasPendingMessages() ? 1 : 0,
      contextUsage: contextUsage ?? null,
    };

    let stats: JsonObject | undefined;
    try {
      stats = computeSessionStats(branch, contextUsage);
    } catch {
      stats = undefined;
    }
    let commands: JsonObject[] | undefined;
    try {
      commands = this.pi.getCommands().map((command) => ({
        name: command.name,
        description: command.description ?? null,
        source: command.source,
      }));
    } catch {
      commands = undefined;
    }
    let treeSummary: JsonObject[] | undefined;
    try {
      treeSummary = buildTreeSummary(ctx.sessionManager.getTree());
    } catch {
      treeSummary = undefined;
    }

    const makeSnapshot = (): JsonObject => ({
      epoch: this.epoch,
      baseSeq: this.seq,
      capturedAt: Date.now(),
      state,
      entries,
      leafId: ctx.sessionManager.getLeafId(),
      models,
      thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
      ...(this.inFlightMessage ? { inFlightMessage: this.inFlightMessage } : {}),
      ...(stats ? { stats } : {}),
      ...(commands ? { commands } : {}),
      ...(treeSummary ? { treeSummary } : {}),
    });

    // 超限丢弃顺序:treeSummary → commands → 截断 entries
    let snapshot = makeSnapshot();
    for (;;) {
      try {
        encodeForWire(snapshot, MAX_SNAPSHOT_BYTES);
        return snapshot;
      } catch {
        if (treeSummary) {
          treeSummary = undefined;
        } else if (commands) {
          commands = undefined;
        } else if (entries.length > 1) {
          const removeCount = Math.max(1, Math.floor(entries.length / 4));
          entries = entries.slice(removeCount);
          state.snapshotTruncated = true;
          state.messageCount = entries.length;
        } else {
          break;
        }
        snapshot = makeSnapshot();
      }
    }
    encodeForWire(snapshot, MAX_SNAPSHOT_BYTES);
    return snapshot;
  }

  private sendEvent(event: unknown): void {
    if (!this.registered) return;
    try {
      const cloned = cloneForWire(event) as JsonObject;
      this.sendFrame({
        type: "desktop_event",
        epoch: this.epoch,
        seq: ++this.seq,
        event: cloned,
      });
    } catch {
      this.resnapshot("event serialization failed");
    }
  }

  private sendFrame(frame: JsonObject, maxBytes?: number): boolean {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    if (socket.bufferedAmount > MAX_SOCKET_BUFFER) {
      socket.close(1013, "relay backpressure");
      return false;
    }
    try {
      socket.send(encodeForWire(frame, maxBytes));
      return true;
    } catch {
      socket.close(1011, "relay serialization failure");
      return false;
    }
  }

  private resnapshot(_reason: string): void {
    if (!this.active || !this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.newEpoch();
    this.registered = true;
    this.sendSnapshot("epoch reset");
  }

  private newEpoch(): void {
    this.cancelCoalesced();
    this.epoch = crypto.randomUUID();
    this.seq = 0;
    this.controlGeneration++;
    this.ownerActive = false;
    this.ownerFence = 0;
    this.ownerExpiresAt = 0;
    this.commandResults.clear();
    this.highestFence = 0;
  }

  private scheduleReconnect(): void {
    if (!this.active || this.reconnectTimer) return;
    const base = Math.min(
      this.config.reconnectMaxMs,
      this.config.reconnectMinMs * 2 ** this.reconnectAttempt++,
    );
    const delay = Math.round(base * (0.8 + Math.random() * 0.4));
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, delay);
    this.reconnectTimer.unref();
  }

  private startHeartbeat(): void {
    this.clearHeartbeat();
    this.heartbeatTimer = setInterval(
      () => this.sendFrame({ type: "desktop_heartbeat", t: Date.now() }),
      HEARTBEAT_MS,
    );
    this.heartbeatTimer.unref();
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = undefined;
  }

  private flushMessageUpdate(): void {
    if (this.messageTimer) clearTimeout(this.messageTimer);
    this.messageTimer = undefined;
    const pending = this.pendingMessageUpdate;
    this.pendingMessageUpdate = undefined;
    if (pending) this.sendEvent(pending);
  }

  private flushToolUpdates(): void {
    if (this.toolTimer) clearTimeout(this.toolTimer);
    this.toolTimer = undefined;
    for (const event of this.pendingToolUpdates.values()) this.sendEvent(event);
    this.pendingToolUpdates.clear();
  }

  private flushCoalesced(): void {
    this.flushMessageUpdate();
    this.flushToolUpdates();
  }

  private cancelCoalesced(): void {
    if (this.messageTimer) clearTimeout(this.messageTimer);
    if (this.toolTimer) clearTimeout(this.toolTimer);
    this.messageTimer = undefined;
    this.toolTimer = undefined;
    this.pendingMessageUpdate = undefined;
    this.pendingToolUpdates.clear();
  }

  private stopInternal(clearStatus: boolean): void {
    this.active = false;
    this.registered = false;
    this.controlGeneration++;
    this.ownerActive = false;
    this.ownerFence = 0;
    this.ownerExpiresAt = 0;
    this.streaming = false;
    this.clearSnapshotTimer();
    this.cancelCoalesced();
    this.clearHeartbeat();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    const socket = this.socket;
    this.socket = undefined;
    socket?.close(1000, "desktop runtime stopped");
    if (clearStatus) this.setStatus(undefined);
    this.ctx = undefined;
  }

  private setStatus(text: string | undefined): void {
    // The captured ctx goes stale after session replacement/reload; accessing
    // any of its getters (including ctx.ui) then throws. Async socket/timer
    // callbacks can run after that, so swallow the stale-ctx error here.
    try {
      this.ctx?.ui.setStatus("pipilot-sync", text);
    } catch {
      // stale ctx after session replacement; nothing to update
    }
  }

  private liveCtx(): ExtensionContext | undefined {
    const ctx = this.ctx;
    if (!ctx) return undefined;
    try {
      void ctx.cwd; // any getter throws when the ctx is stale
      return ctx;
    } catch {
      return undefined;
    }
  }

  private hasActiveOwner(fence: number): boolean {
    return (
      this.ownerActive &&
      this.ownerFence === fence &&
      this.ownerExpiresAt > Date.now()
    );
  }

  /**
   * 这个 ctx 属于当前会话吗?
   *
   * **不能用对象身份比。** pi 的 `ExtensionRunner.emit()` 每次都
   * `createContext()` 新建一个对象(runner.js:570),所以 `this.ctx === ctx`
   * 只在 `session_start` 那一次成立 —— 用身份比等于把之后的**每一个**事件、
   * 每一次快照、每一次流式标志全部静默丢掉,桌面源看起来在线却永远不更新。
   *
   * 真正要判的是"这个 ctx 指向的还是我们绑定的那个会话"。顺便把 `this.ctx`
   * 刷新成最新的活 ctx,免得后续异步发送用到一个已经失效的旧对象。
   */
  private isCurrent(ctx: ExtensionContext): boolean {
    if (!this.active || !this.ctx) return false;
    if (this.ctx === ctx) return true;
    try {
      const file = ctx.sessionManager.getSessionFile();
      if (file !== this.boundSessionFile) return false;
      this.ctx = ctx;
      return true;
    } catch {
      // 陈旧 ctx 的 getter 会抛 assertActive()
      return false;
    }
  }

  /** 与 `isCurrent` 同源的判据,给 `stop()` 用。 */
  private isBound(ctx: ExtensionContext): boolean {
    if (this.ctx === ctx) return true;
    try {
      return ctx.sessionManager.getSessionFile() === this.boundSessionFile;
    } catch {
      return false;
    }
  }
}
