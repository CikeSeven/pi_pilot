/**
 * chunk-v2 传输层:二进制分页 + gzip + 发送方留存(NACK 重发/断线续传)+ 接收方重组。
 * 与 lib/core/p2p_transfer_v2.dart 逻辑镜像。
 *
 * 设计要点:
 * - SCTP 有序可靠,连接内不丢帧;NACK 的真实场景是断线续传——发送方把
 *   transfer 留存 V2_RETENTION_MS,重连后接收方凭 transferId+缺失页表
 *   发 NACK{resume:true},发送方补 BEGIN(让接收方重建元信息)+缺失页。
 * - 留存与重组都有 TTL + 字节上限,防内存膨胀。
 * - gzip 阈值 16KB:JSON 文本压缩率高,小帧不值得压。
 */
import crypto from "node:crypto";
import { gunzipSync, gzipSync } from "node:zlib";
import {
  decodeFrameV2,
  encodeFrameV2,
  P2P_FRAME_V2_TYPE,
} from "./p2p_frame_v2.js";

export const V2_PAGE_BYTES = 36 * 1024;
export const V2_DIRECT_BYTES = 48 * 1024;
export const V2_MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
export const V2_GZIP_MIN_BYTES = 16 * 1024;
export const V2_RETENTION_MS = 60_000;
export const V2_RETENTION_MAX_BYTES = 32 * 1024 * 1024;
export const V2_MAX_ASSEMBLIES = 8;
export const V2_ASSEMBLY_MAX_BYTES = 32 * 1024 * 1024;
export const V2_ASSEMBLY_IDLE_MS = 30_000;
/// 单次 NACK 最多受理的缺页数。上限按「最大消息能拆出的页数」给足余量,
/// 再多就是重复/越界索引造成的重发放大,直接截断。
export const V2_MAX_NACK_PAGES =
  Math.ceil(V2_MAX_MESSAGE_BYTES / V2_PAGE_BYTES) + 1;

/// 接收方允许的 encoding 白名单。未知 encoding 必须直接拒绝,
/// 而不是当成 identity 继续拼 —— 否则交付的就是一堆二进制垃圾。
export const V2_ALLOWED_ENCODINGS = new Set(["identity", "gzip"]);

/// 单个 DATA 页 payload 硬上限。发送方按 V2_PAGE_BYTES 分页,给少量宽容;
/// 超过就是对端违规(或恶意超大页),必须在入队前拦下。
export const V2_MAX_PAGE_PAYLOAD_BYTES = V2_PAGE_BYTES + 4 * 1024;

/// BEGIN 里声明的原始大小上限(即解压后字节数上限)。
/// gunzip 必须带着这个上限调用:无上限的同步解压面对 gzip bomb 时
/// 会直接吃空内存并阻塞事件循环。
export const V2_MAX_INFLATED_BYTES = V2_MAX_MESSAGE_BYTES;

export interface EncodedTransfer {
  transferId: Buffer;
  /** [BEGIN, DATA×pageCount, DONE] 完整线帧序列。 */
  frames: Buffer[];
  /** 留存体积近似值。 */
  bytes: number;
}

/// 完整 JSON 文本 → v2 线帧序列(>16KB 且划算时 gzip)。
export function encodeTransferV2(text: string): EncodedTransfer {
  const raw = Buffer.from(text, "utf8");
  if (raw.length > V2_MAX_MESSAGE_BYTES) {
    throw new Error("P2P message exceeds 16MB");
  }
  let payload = raw;
  let encoding = "identity";
  if (raw.length >= V2_GZIP_MIN_BYTES) {
    const compressed = gzipSync(raw);
    if (compressed.length < raw.length) {
      payload = compressed;
      encoding = "gzip";
    }
  }
  const pageCount = Math.max(1, Math.ceil(payload.length / V2_PAGE_BYTES));
  const transferId = crypto.randomBytes(16);
  const frames: Buffer[] = [
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.begin,
      transferId,
      pageIndex: 0,
      pageCount,
      meta: {
        pageBytes: V2_PAGE_BYTES,
        encoding,
        payloadType: "json",
        size: raw.length,
        // 端到端完整性:接收方在 ACK 前比对。分页拼接 + 解压 任一环节出错
        // 都会产生"能解析但内容错"的 JSON,比直接失败难查得多。
        sha256: crypto.createHash("sha256").update(raw).digest("hex"),
      },
    }),
  ];
  for (let i = 0; i < pageCount; i++) {
    frames.push(
      encodeFrameV2({
        type: P2P_FRAME_V2_TYPE.data,
        transferId,
        pageIndex: i,
        pageCount,
        payload: payload.subarray(
          i * V2_PAGE_BYTES,
          Math.min(payload.length, (i + 1) * V2_PAGE_BYTES),
        ),
      }),
    );
  }
  frames.push(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.done,
      transferId,
      pageIndex: 0,
      pageCount,
    }),
  );
  return { transferId, frames, bytes: payload.length + frames.length * 30 };
}

interface Retained {
  begin: Buffer;
  pages: Buffer[];
  done: Buffer;
  bytes: number;
  at: number;
}

/// 发送方留存:按 transferId 供 NACK 重发与断线续传。TTL + 总量上限。
export class TransferRetainedStore {
  /// 时钟可注入:TTL 语义必须能被确定性测试。真实时间下无法验证
  /// 「60s 后 resendFrames 必须返回 null」,而这正是已确认过的缺陷。
  constructor(private readonly now: () => number = Date.now) {}

  private readonly map = new Map<string, Retained>();
  private totalBytes = 0;

  add(transfer: EncodedTransfer): void {
    const key = transfer.transferId.toString("hex");
    this.drop(key);
    this.map.set(key, {
      begin: transfer.frames[0]!,
      pages: transfer.frames.slice(1, -1),
      done: transfer.frames[transfer.frames.length - 1]!,
      bytes: transfer.bytes,
      at: this.now(),
    });
    this.totalBytes += transfer.bytes;
    this.sweep();
  }

  /** NACK → 需要重发的线帧;resume 时先补 BEGIN,末尾始终补 DONE
   *  (接收方收齐页后要靠 DONE 触发交付;重发 DONE 对已完成者无副作用)。
   *  未知/已过期 transfer 返回 null。 */
  resendFrames(
    transferIdHex: string,
    missing: readonly number[],
    includeBegin: boolean,
  ): Buffer[] | null {
    const retained = this.map.get(transferIdHex);
    if (!retained) return null;
    // 过期判定必须在这里做:sweep 只在 add 时触发,长时间没有新 transfer 时
    // 一条早已超过 TTL 的留存仍会被取出并刷新 at,等于 TTL 永不生效。
    if (this.now() - retained.at > V2_RETENTION_MS) {
      this.drop(transferIdHex);
      return null;
    }
    retained.at = this.now();
    const out: Buffer[] = includeBegin ? [retained.begin] : [];
    for (const index of missing) {
      const page = retained.pages[index];
      if (page) out.push(page);
    }
    out.push(retained.done);
    return out;
  }

  /// 主动到期回收。sweep 原本只在 add 时触发,空闲期(没有新 transfer)
  /// 留存会一直占着预算,所以需要一个可被定时器调用的入口。
  sweepExpired(): void {
    this.sweep();
  }

  /// 当前留存字节数(遥测/测试用)。
  get retainedBytes(): number {
    return this.totalBytes;
  }

  ack(transferIdHex: string): void {
    this.drop(transferIdHex);
  }

  private drop(key: string): void {
    const existing = this.map.get(key);
    if (existing) {
      this.map.delete(key);
      this.totalBytes -= existing.bytes;
    }
  }

  private sweep(): void {
    const now = this.now();
    for (const [key, retained] of this.map) {
      if (now - retained.at > V2_RETENTION_MS) this.drop(key);
    }
    // FIFO 逐出到字节上限内。
    for (const [key] of this.map) {
      if (this.totalBytes <= V2_RETENTION_MAX_BYTES) break;
      this.drop(key);
    }
  }
}

interface Assembly {
  pageCount: number;
  encoding: string;
  size: number;
  /// BEGIN 声明的端到端 sha256(可能缺失:老版本发送方没带)。
  sha256?: string;
  parts: (Buffer | undefined)[];
  received: number;
  bytes: number;
  lastActivity: number;
  doneSeen: boolean;
}

export interface AssemblerResult {
  /** 完整交付的 JSON 文本(已按需 gunzip)。 */
  message?: string;
  /** 需要回发给对端的帧(ACK/NACK)。 */
  replies: Buffer[];
  /** 断线续传用:未完成的 transferId 与缺失页。 */
  pending?: { transferIdHex: string; missing: number[] }[];
}

/// 接收方重组器。设计为可被连接层长期持有(P2pConnector/Hub 级),
/// 这样断线重连后原 assembly 还在,NACK{resume:true} 才有意义。
export class TransferV2Assembler {
  private readonly assemblies = new Map<string, Assembly>();
  private totalBytes = 0;

  onFrame(frameBytes: Buffer): { message?: string; replies: Buffer[] } {
    const replies: Buffer[] = [];
    this.sweep();
    let frame;
    try {
      frame = decodeFrameV2(frameBytes);
    } catch {
      return { replies };
    }
    const key = frame.transferId.toString("hex");
    switch (frame.type) {
      case P2P_FRAME_V2_TYPE.begin: {
        if (frame.pageCount <= 0 || frame.pageCount > V2_MAX_NACK_PAGES) {
          return { replies };
        }
        const meta = frame.meta ?? {};
        // encoding 白名单:未知 encoding 必须拒绝,不能当成 identity 继续拼 ——
        // 否则交付上层的是一堆二进制垃圾,还会被当成合法 JSON 解析失败。
        const encoding = String(meta.encoding ?? "identity");
        if (!V2_ALLOWED_ENCODINGS.has(encoding)) {
          replies.push(
            encodeFrameV2({
              type: P2P_FRAME_V2_TYPE.abort,
              transferId: frame.transferId,
              pageIndex: 0,
              pageCount: frame.pageCount,
              meta: { reason: "unsupported encoding" },
            }),
          );
          this.dropAssembly(key);
          return { replies };
        }
        // 声明的原始大小必须有界:BEGIN 是唯一能在收数据前判定总量的地方。
        const declaredSize = Number(meta.size ?? 0);
        if (
          !Number.isFinite(declaredSize) ||
          declaredSize < 0 ||
          declaredSize > V2_MAX_INFLATED_BYTES
        ) {
          replies.push(
            encodeFrameV2({
              type: P2P_FRAME_V2_TYPE.abort,
              transferId: frame.transferId,
              pageIndex: 0,
              pageCount: frame.pageCount,
              meta: { reason: "declared size out of range" },
            }),
          );
          this.dropAssembly(key);
          return { replies };
        }
        const declaredHash =
          typeof meta.sha256 === "string" && /^[0-9a-f]{64}$/.test(meta.sha256)
            ? meta.sha256
            : undefined;
        const existing = this.assemblies.get(key);
        if (existing && existing.pageCount === frame.pageCount) {
          // 续传补发的 BEGIN:保留已收页,只刷新元信息与活跃时间。
          // (丢掉已收页会让 resume 永远缺第一页,无法完成。)
          existing.lastActivity = Date.now();
          existing.encoding = encoding;
          existing.size = declaredSize;
          existing.sha256 = declaredHash ?? existing.sha256;
          return { replies };
        }
        this.dropAssembly(key);
        this.assemblies.set(key, {
          pageCount: frame.pageCount,
          encoding,
          size: declaredSize,
          sha256: declaredHash,
          parts: new Array<Buffer | undefined>(frame.pageCount),
          received: 0,
          bytes: 0,
          lastActivity: Date.now(),
          doneSeen: false,
        });
        if (!this.enforceCaps(key)) return { replies };
        return { replies };
      }
      case P2P_FRAME_V2_TYPE.data: {
        const assembly = this.assemblies.get(key);
        if (
          !assembly ||
          frame.pageIndex < 0 ||
          frame.pageIndex >= assembly.pageCount
        ) {
          return { replies };
        }
        const part = frame.payload ?? Buffer.alloc(0);
        // 单页硬上限:超大页是对端违规或恶意构造,必须在计入累计字节前拦掉。
        if (part.length > V2_MAX_PAGE_PAYLOAD_BYTES) {
          replies.push(
            encodeFrameV2({
              type: P2P_FRAME_V2_TYPE.abort,
              transferId: frame.transferId,
              pageIndex: 0,
              pageCount: assembly.pageCount,
              meta: { reason: "page too large" },
            }),
          );
          this.dropAssembly(key);
          return { replies };
        }
        if (assembly.parts[frame.pageIndex] === undefined) {
          // 累计压缩字节上限:即便每页都合规,页数×页长也可能超总预算。
          if (assembly.bytes + part.length > V2_ASSEMBLY_MAX_BYTES) {
            replies.push(
              encodeFrameV2({
                type: P2P_FRAME_V2_TYPE.abort,
                transferId: frame.transferId,
                pageIndex: 0,
                pageCount: assembly.pageCount,
                meta: { reason: "assembly too large" },
              }),
            );
            this.dropAssembly(key);
            return { replies };
          }
          assembly.parts[frame.pageIndex] = part;
          assembly.received++;
          assembly.bytes += part.length;
          this.totalBytes += part.length;
          assembly.lastActivity = Date.now();
          if (!this.enforceCaps(key)) return { replies };
        }
        return { replies };
      }
      case P2P_FRAME_V2_TYPE.done: {
        const assembly = this.assemblies.get(key);
        if (!assembly) return { replies };
        assembly.doneSeen = true;
        assembly.lastActivity = Date.now();
        const missing = this.missingPages(assembly);
        if (missing.length > 0) {
          replies.push(
            encodeFrameV2({
              type: P2P_FRAME_V2_TYPE.nack,
              transferId: frame.transferId,
              pageIndex: 0,
              pageCount: assembly.pageCount,
              meta: { missing },
            }),
          );
          return { replies };
        }
        const message = this.materialize(key, assembly);
        if (message === undefined) return { replies };
        replies.push(
          encodeFrameV2({
            type: P2P_FRAME_V2_TYPE.ack,
            transferId: frame.transferId,
            pageIndex: 0,
            pageCount: assembly.pageCount,
            meta: {
              ranges: [[0, assembly.pageCount - 1]],
            },
          }),
        );
        return { message, replies };
      }
      case P2P_FRAME_V2_TYPE.abort: {
        this.dropAssembly(key);
        return { replies };
      }
      default:
        return { replies };
    }
  }

  /** 断线续传:返回所有未完成 assembly 的 transferId 与缺失页表。 */
  pendingResumes(): { transferIdHex: string; missing: number[] }[] {
    this.sweep();
    const out: { transferIdHex: string; missing: number[] }[] = [];
    for (const [key, assembly] of this.assemblies) {
      out.push({ transferIdHex: key, missing: this.missingPages(assembly) });
    }
    return out;
  }

  /** 续传 NACK 帧(resume 标记让发送方补 BEGIN 重建元信息)。 */
  static resumeNackFrame(
    transferIdHex: string,
    missing: readonly number[],
    pageCount: number,
  ): Buffer {
    return encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.nack,
      transferId: Buffer.from(transferIdHex, "hex"),
      pageIndex: 0,
      pageCount,
      meta: { missing: [...missing], resume: true },
    });
  }

  private missingPages(assembly: Assembly): number[] {
    const missing: number[] = [];
    for (let i = 0; i < assembly.pageCount; i++) {
      if (assembly.parts[i] === undefined) missing.push(i);
    }
    return missing;
  }

  /// 拼页 → 解压 → 校验。任一环节不过就返回 undefined(调用方不发 ACK)。
  ///
  /// 解压必须带 maxOutputLength:无上限的同步 gunzip 面对 gzip bomb 会直接
  /// 吃空内存并阻塞事件循环(几十 KB 的压缩页能膨胀到 GB 级)。
  private materialize(key: string, assembly: Assembly): string | undefined {
    const joined = Buffer.concat(
      assembly.parts.map((part) => part ?? Buffer.alloc(0)),
    );
    this.dropAssembly(key);
    let raw: Buffer;
    try {
      raw =
        assembly.encoding === "gzip"
          ? gunzipSync(joined, { maxOutputLength: V2_MAX_INFLATED_BYTES })
          : joined;
    } catch {
      return undefined;
    }
    // 声明大小核对:分页拼接错位/重复页会产出"能解析但内容错"的 JSON,
    // 那比直接失败难查得多。
    if (assembly.size > 0 && raw.length !== assembly.size) {
      return undefined;
    }
    if (assembly.sha256 !== undefined) {
      const actual = crypto.createHash("sha256").update(raw).digest("hex");
      if (actual !== assembly.sha256) return undefined;
    }
    return raw.toString("utf8");
  }

  private dropAssembly(key: string): void {
    const existing = this.assemblies.get(key);
    if (existing) {
      this.assemblies.delete(key);
      this.totalBytes -= existing.bytes;
    }
  }

  private sweep(): void {
    const now = Date.now();
    for (const [key, assembly] of this.assemblies) {
      if (now - assembly.lastActivity > V2_ASSEMBLY_IDLE_MS) {
        this.dropAssembly(key);
      }
    }
  }

  /// 超上限时逐出最旧的(被逐出的 transfer 后续会走 NACK→unknown,
  /// 接收方只得等下一条全量/重同步——宁缺毋假)。
  ///
  /// 返回 false 表示连被保护的 assembly 自己都放不下,已被丢弃。原实现里
  /// `continue` 跳过 protectedKey 后若没有其他可逐出者就直接 return,于是
  /// 当前 assembly 可以无限期超出总上限 —— 单条超大 transfer 就能绕过预算。
  private enforceCaps(protectedKey: string): boolean {
    while (
      this.assemblies.size > V2_MAX_ASSEMBLIES ||
      this.totalBytes > V2_ASSEMBLY_MAX_BYTES
    ) {
      let oldestKey: string | undefined;
      let oldestAt = Number.POSITIVE_INFINITY;
      for (const [key, assembly] of this.assemblies) {
        if (key === protectedKey) continue;
        if (assembly.lastActivity < oldestAt) {
          oldestAt = assembly.lastActivity;
          oldestKey = key;
        }
      }
      if (oldestKey === undefined) {
        // 已经没有别的可逐出:说明超限来自当前这条,它也必须被丢掉。
        this.dropAssembly(protectedKey);
        return false;
      }
      this.dropAssembly(oldestKey);
    }
    return true;
  }

  /// 主动到期回收。sweep 原本只在 onFrame 时触发,空闲期未完成的 assembly
  /// 会一直占着预算,所以需要一个可被定时器调用的入口。
  sweepExpired(): void {
    this.sweep();
  }

  /// 当前重组占用字节(遥测/测试用)。
  get assemblyBytes(): number {
    return this.totalBytes;
  }
}
