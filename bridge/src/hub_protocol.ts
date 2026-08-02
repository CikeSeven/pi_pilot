export const HUB_PROTOCOL_VERSION = 3;
export const MAX_CLIENT_MESSAGE_BYTES = 1024 * 1024;
export const MAX_DESKTOP_MESSAGE_BYTES = 16 * 1024 * 1024;
export const MAX_BUFFERED_SOCKET_BYTES = 2 * 1024 * 1024;

/**
 * 发给手机的一批 entries 的字节预算。
 *
 * 必须明显小于 [MAX_BUFFERED_SOCKET_BYTES]。sendRaw 是先判后发:一帧巨包本身
 * 发得出去,但会把 bufferedAmount 顶到包大小;紧接着任何一次发送(流式事件
 * 几毫秒就来一条)都会看到超限而 close(1013)。长会话的全量快照实测到过
 * 10.27MB(4592 条 entries 占 9.78MB),于是手机变成「连上→要快照→被关→重连」
 * 约 2 秒一轮的死循环。
 */
export const MAX_MOBILE_ENTRIES_BYTES = 1024 * 1024;

/**
 * P2P(DataChannel)通道的首载字节预算(硬上限)。
 *
 * 慢速 TURN(50KB/s)下线体积 ≈ 字节数,128KiB ≈ 2.6s 线耗。更早的历史一律
 * 靠 get_entries 分页补,首屏永远不承载完整历史。
 */
export const MAX_MOBILE_ENTRIES_BYTES_P2P = 128 * 1024;

/**
 * get_entries 单页字节预算(硬上限,P2P 与 WS 共用)。
 *
 * 原值 256KiB 在 50KB/s 上单页要 5s 以上;96KiB ≈ 2s,配合 tipId 游标可以
 * 稳定连续翻页而不触发请求超时。
 */
export const MAX_ENTRIES_PAGE_BYTES = 96 * 1024;

/** 事件重放页字节预算(硬上限)。事件比 entries 小,但也必须有界。 */
export const MAX_EVENT_PAGE_BYTES = 64 * 1024;

/**
 * 手机端单条文本字段(text/thinking/content 字符串)的**字符**上限。
 *
 * 实测 read 工具返回的截图 image 块单条 1.7MB、compaction 摘要 0.5MB。单条
 * 必须先自己瘦身,否则一条就能顶穿整页预算。
 *
 * 取 16K 字符而不是 64K:这是字符数,不是字节数。CJK 一字 3 字节,64K 字符
 * 最坏情况是 192KB —— 比整个首屏预算(128KiB)还大,字段级封顶等于没有上限。
 * 16K 字符最坏 48KB,稳定落在 [MOBILE_ENTRY_HARD_BYTES] 之内,字段级截断
 * (保留可读开头 + 截断标记)才真正生效,而不是被硬上限降级覆盖掉。
 */
export const MOBILE_ENTRY_TEXT_CAP = 16 * 1024;

/**
 * 单条 entry 的硬上限(序列化后字节)。
 *
 * 超过就换成 preview + contentRef:保留可读开头,完整内容按需用
 * `get_entry_content{entryId, field, offset, length}` 取。
 *
 * 没有这个上限时,「至少给 N 条」的规则会让巨型单条突破页预算 —— 这正是
 * 慢链路上首屏迟迟不来的原因之一。现在预算是硬的,单条超限只能被降级,
 * 不允许突破。
 */
export const MOBILE_ENTRY_HARD_BYTES = 64 * 1024;

/** 向桌面 relay 索要新快照的等待上限(远小于 App 的 20s 请求超时)。 */
export const SNAPSHOT_REQUEST_TIMEOUT_MS = 4_000;

export type JsonObject = Record<string, unknown>;

export interface HubCommandMeta {
  leaseId?: string;
  fence?: number;
}

export interface HubCursor {
  hubId: string;
  sourceId: string;
  sourceEpoch: string;
  seq: number;
}

export interface BridgeMessage extends JsonObject {
  type?: string;
  id?: string;
  _hub?: HubCommandMeta;
}

const READ_ONLY_SOURCE_COMMANDS = new Set([
  "get_state",
  "get_entries",
  "get_available_models",
  "get_available_thinking_levels",
  "get_session_stats",
  "get_tree",
  "get_commands",
  "get_fork_messages",
  "get_last_assistant_text",
]);

const DESKTOP_MUTATION_COMMANDS = new Set([
  "prompt",
  "abort",
  "set_model",
  "set_thinking_level",
  "set_session_name",
  // 压缩上下文是纯粹的会话内操作,不会把电脑上正在用的会话抽走
  "compact",
  // 会话内回退(会话树导航)。relay 侧 SAFE_REMOTE_COMMANDS 一直放行它,
  // 这张表漏了,手机回退全被 bridge 拦成 "not supported by the desktop relay"。
  // 注意**不要**顺手加进 server.ts 的 SESSION_MUTATING_COMMANDS:
  // runNavigate 自己 abort()+waitForIdle(),生成中回退就该走这条路,
  // 加过去反而被流式守卫提前拒掉。
  "navigate_tree",
]);

export function isReadOnlySourceCommand(type: string): boolean {
  return READ_ONLY_SOURCE_COMMANDS.has(type);
}

export function isDesktopMutationCommand(type: string): boolean {
  return DESKTOP_MUTATION_COMMANDS.has(type);
}

export function withoutHubMetadata(message: BridgeMessage): BridgeMessage {
  const { _hub: _ignored, ...command } = message;
  return command;
}

export function parseCursor(value: unknown): HubCursor | undefined {
  if (!value || typeof value !== "object") return undefined;
  const cursor = value as Partial<HubCursor>;
  if (
    typeof cursor.hubId !== "string" ||
    typeof cursor.sourceId !== "string" ||
    typeof cursor.sourceEpoch !== "string" ||
    typeof cursor.seq !== "number" ||
    !Number.isSafeInteger(cursor.seq) ||
    cursor.seq < 0
  ) {
    return undefined;
  }
  return cursor as HubCursor;
}

export function clampLeaseTtl(value: unknown, minMs: number, maxMs: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return maxMs;
  return Math.max(minMs, Math.min(maxMs, Math.floor(value)));
}
