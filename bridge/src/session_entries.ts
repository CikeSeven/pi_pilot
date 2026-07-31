/// 直接从会话文件流式分页读取 entries。
///
/// 存在的理由:pi 的 RPC `get_entries` **只有 `since`,没有 `limit`,也不认
/// `before`**(见 pi 的 rpc-types.d.ts)。于是无头源(手机打开一个没在电脑上
/// 跑的会话)有两个真机实测到的后果:
///
/// 1. 慢:每次 get_entries 都让 pi 序列化整个会话。50.40MB 的会话实测
///    52,845,816 字节 / 22.8 秒,bridge 再裁到 78KiB —— 99.85% 白算。
///    而且每翻一页都要付一次,翻 10 页 = 228 秒。
/// 2. 错:`before` 被 pi 忽略 → 返回全部 → bridge 裁尾巴 → 每页都是同一批
///    最新的 33 条。真机实测「第1页与上一页完全相同=true」,
///    也就是「加载更早」这个功能对无头源根本不成立。
///
/// 会话文件是 append-only jsonl,第 1 行是会话头,其后每行一条 entry,
/// 顺序与 get_entries 一致(实测 9555 行 = 1 头 + 9554 条,与 pi 返回的
/// 9554 条逐一匹配,id 全唯一)。所以直接流式读文件既正确又省:
/// 内存是 O(单页) 而不是 O(会话)(整份缓存下来实测仍有 30.77MB/会话)。
import fs from "node:fs";
import readline from "node:readline";
import type { JsonObject } from "./hub_protocol.js";

export type EntryPageMode = "tail" | "before" | "since";

export interface EntryPageQuery {
  mode: EntryPageMode;
  /** before / since 模式的游标 entry id。 */
  cursor?: string;
  /** 单页字节预算,按**封顶后**的形态计。 */
  budgetBytes: number;
  /**
   * 单条封顶回调。分页器不关心手机端的裁剪规则,由调用方注入 ——
   * 预算必须按封顶后的字节走,否则 33 条里混进一条 3MB 的图片就会
   * 把"96KiB 一页"变成谎话。
   */
  cap: (entry: JsonObject) => JsonObject;
  /** since 模式可选上边界:把一次翻页 run 绑到固定 tip,源继续增长也不漏不重。 */
  tipId?: string;
  /** 条数上限(可选)。 */
  limit?: number;
}

export interface EntryPageResult {
  entries: JsonObject[];
  leafId: string | null;
  oldestId: string | null;
  hasMore: boolean;
  /** since 模式:本页最后一条 id,调用方用作下一页游标。 */
  nextSinceId: string | null;
  tipId: string | null;
  /** 游标在文件里不存在(调用方应回错误,与 desktop 路径语义一致)。 */
  cursorNotFound: boolean;
  /** 诊断用。 */
  scannedEntries: number;
  scannedBytes: number;
  ms: number;
}

export async function readEntriesPage(
  sessionPath: string,
  query: EntryPageQuery,
): Promise<EntryPageResult> {
  const startedAt = Date.now();
  const stream = fs.createReadStream(sessionPath, { encoding: "utf8" });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

  const budget = Math.max(4096, query.budgetBytes);
  /// 滚动窗口:只保留当前候选页,总字节不超预算 → 内存 O(单页)。
  const win: { entry: JsonObject; bytes: number }[] = [];
  let winBytes = 0;
  let leafId: string | null = null;
  let scannedEntries = 0;
  let scannedBytes = 0;
  let lineNo = 0;
  let cursorSeen = false;
  let beforeCount = 0;
  let collecting = false;
  let stopped = false;
  let moreAfterPage = false;
  let tipReached = false;

  /// 尾向滚动:新的从后面进,超预算就从前面挤掉。
  /// 至少留一条 —— 巨型单条(实测 compaction 576KB)不能让页变空。
  const pushTail = (entry: JsonObject, bytes: number): void => {
    win.push({ entry, bytes });
    winBytes += bytes;
    while (win.length > 1 && winBytes > budget) {
      winBytes -= win.shift()!.bytes;
    }
    if (query.limit !== undefined) {
      while (win.length > query.limit) {
        winBytes -= win.shift()!.bytes;
      }
    }
  };

  try {
    for await (const line of rl) {
      lineNo++;
      if (line.length === 0) continue;
      scannedBytes += Buffer.byteLength(line);
      // 第 1 行是会话头(type:"session"),不是 entry。
      if (lineNo === 1) continue;
      let raw: JsonObject;
      try {
        raw = JSON.parse(line) as JsonObject;
      } catch {
        // pi 可能正在追加写,最后一行可能是半条。跳过且不计数。
        continue;
      }
      scannedEntries++;
      const id = typeof raw.id === "string" ? raw.id : null;
      if (id !== null) leafId = id;

      if (query.mode === "tail") {
        const capped = query.cap(raw);
        pushTail(capped, Buffer.byteLength(JSON.stringify(capped)));
        continue;
      }

      if (query.mode === "before") {
        // 游标之后的不要;游标本身也不含(与 desktop 的 slice(0, index) 一致)。
        if (cursorSeen) continue;
        if (id !== null && id === query.cursor) {
          cursorSeen = true;
          continue;
        }
        beforeCount++;
        const capped = query.cap(raw);
        pushTail(capped, Buffer.byteLength(JSON.stringify(capped)));
        continue;
      }

      // since:正向从游标之后取,直到预算/条数/tip 边界。
      if (!collecting) {
        if (id !== null && id === query.cursor) {
          cursorSeen = true;
          collecting = true;
        }
        continue;
      }
      if (stopped) continue;
      const capped = query.cap(raw);
      const bytes = Buffer.byteLength(JSON.stringify(capped));
      if (win.length > 0 && winBytes + bytes > budget) {
        stopped = true;
        moreAfterPage = true;
        continue;
      }
      if (query.limit !== undefined && win.length >= query.limit) {
        stopped = true;
        moreAfterPage = true;
        continue;
      }
      win.push({ entry: capped, bytes });
      winBytes += bytes;
      if (query.tipId !== undefined && id === query.tipId) {
        tipReached = true;
        stopped = true;
      }
    }
  } finally {
    rl.close();
    stream.destroy();
  }

  const entries = win.map((item) => item.entry);
  const first = entries[0];
  const last = entries[entries.length - 1];
  const hasMore =
    query.mode === "tail"
      ? scannedEntries > entries.length
      : query.mode === "before"
        ? beforeCount > entries.length
        : moreAfterPage;

  return {
    entries,
    leafId,
    oldestId: typeof first?.id === "string" ? first.id : null,
    hasMore,
    nextSinceId: typeof last?.id === "string" ? last.id : null,
    tipId: query.tipId ?? (tipReached ? (query.tipId ?? null) : leafId),
    cursorNotFound: query.mode !== "tail" && !cursorSeen,
    scannedEntries,
    scannedBytes,
    ms: Date.now() - startedAt,
  };
}
