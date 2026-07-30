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
 * 即使字节预算已经用完,也至少给这么多条尾部 entries。
 *
 * 单条 entry 实测最大能到 1.16MB(大段工具输出),只按字节封顶会在这种条目面前
 * 退化成只发 1 条,聊天页就只剩一句话。所以条数下限优先于字节预算 ——
 * 超出部分宁可让它大于预算,也不能把会话截成空卡。
 */
export const MIN_MOBILE_ENTRIES = 80;

/**
 * 手机端单条文本字段(text/thinking/content 字符串)的字符上限。
 *
 * 条数下限优先于字节预算,所以巨型单条必须先自己瘦身:实测 read 工具返回的
 * 截图 image 块单条 1.7MB、compaction 摘要 0.5MB,80 条下限会把它们硬塞进快照,
 * 4MB JSON 经 base64 分片变 5.6MB,慢速链路上直接把 P2P 缓冲顶爆(1013)。
 */
export const MOBILE_ENTRY_TEXT_CAP = 64 * 1024;

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
