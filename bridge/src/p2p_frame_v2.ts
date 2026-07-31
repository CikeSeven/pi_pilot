/**
 * P2P 二进制传输帧 v2(chunk-v2)。与 v1(JSON+base64 文本帧)共存,
 * 由 `p2p-chunk-v2` 能力位门控:双方都声明才启用,否则回退 v1。
 *
 * 帧布局(大端,与 lib/core/p2p_frame_v2.dart 逐字节镜像):
 * ```
 * 偏移  大小  字段
 * 0     2     magic "P2" (0x50 0x32)
 * 2     1     version = 2
 * 3     1     type(见 P2P_FRAME_V2_TYPE)
 * 4     16    transferId(UUID 二进制,无连字符)
 * 20    4     pageIndex(u32)
 * 24    4     pageCount(u32)
 * 28    2     headerExtLen(u16)
 * 30    N     headerExt(JSON meta,可为空)
 * 30+N  M     payload(原始字节,仅 DATA 帧使用)
 * ```
 *
 * 语义:
 * - BEGIN:transfer 元信息(pageCount、pageBytes、encoding),payload 为空
 * - DATA:一页原始载荷,headerExt 为空
 * - DONE:发送方声明最后一页已发,headerExt 可带 {"sha256":"..."}
 * - ACK:接收方确认,headerExt {"ranges":[[s,e],...]}(已收页区间,闭区间)
 * - NACK:接收方报告缺口,headerExt {"missing":[i,...]}
 * - ABORT:任一中止,headerExt {"reason":"..."}
 *
 * 双端单测跑 protocol/p2p_frame_v2_vectors.json 同一组向量。
 */
export const P2P_CHUNK_V2_CAPABILITY = "p2p-chunk-v2";

export const P2P_FRAME_V2_TYPE = {
  begin: 0x01,
  data: 0x02,
  done: 0x03,
  ack: 0x04,
  nack: 0x05,
  abort: 0x06,
} as const;

const HEADER_BYTES = 30;
const MAX_HEADER_EXT_BYTES = 4096;

export interface P2pFrameV2 {
  type: number;
  /** 16 字节传输标识(UUID 二进制)。 */
  transferId: Buffer;
  pageIndex: number;
  pageCount: number;
  /** JSON 元信息(BEGIN/ACK/NACK/ABORT 用)。 */
  meta?: Record<string, unknown>;
  /** 原始载荷(仅 DATA)。 */
  payload?: Buffer;
}

export function transferIdFromUuid(uuid: string): Buffer {
  const hex = uuid.replaceAll("-", "");
  if (hex.length !== 32) {
    throw new Error(`expect 32 hex chars: ${uuid}`);
  }
  return Buffer.from(hex, "hex");
}

export function transferIdToUuid(bytes: Buffer): string {
  if (bytes.length !== 16) {
    throw new Error(`expect 16 bytes: ${bytes.length}`);
  }
  const hex = bytes.toString("hex");
  return (
    `${hex.slice(0, 8)}-${hex.slice(8, 12)}-` +
    `${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  );
}

export function encodeFrameV2(frame: P2pFrameV2): Buffer {
  if (frame.transferId.length !== 16) {
    throw new Error("transferId must be 16 bytes");
  }
  const metaBytes = frame.meta
    ? Buffer.from(JSON.stringify(frame.meta), "utf8")
    : Buffer.alloc(0);
  if (metaBytes.length > MAX_HEADER_EXT_BYTES) {
    throw new Error(`headerExt exceeds ${MAX_HEADER_EXT_BYTES} bytes`);
  }
  const body = frame.payload ?? Buffer.alloc(0);
  const out = Buffer.alloc(HEADER_BYTES + metaBytes.length + body.length);
  out[0] = 0x50; // 'P'
  out[1] = 0x32; // '2'
  out.writeUInt8(2, 2); // version
  out.writeUInt8(frame.type, 3);
  frame.transferId.copy(out, 4);
  out.writeUInt32BE(frame.pageIndex, 20);
  out.writeUInt32BE(frame.pageCount, 24);
  out.writeUInt16BE(metaBytes.length, 28);
  metaBytes.copy(out, HEADER_BYTES);
  body.copy(out, HEADER_BYTES + metaBytes.length);
  return out;
}

export function decodeFrameV2(bytes: Buffer): P2pFrameV2 {
  if (bytes.length < HEADER_BYTES) {
    throw new Error(`frame too short: ${bytes.length}`);
  }
  if (bytes[0] !== 0x50 || bytes[1] !== 0x32) {
    throw new Error("bad magic");
  }
  const version = bytes.readUInt8(2);
  if (version !== 2) {
    throw new Error(`unsupported version: ${version}`);
  }
  const type = bytes.readUInt8(3);
  const transferId = Buffer.from(bytes.subarray(4, 20));
  const pageIndex = bytes.readUInt32BE(20);
  const pageCount = bytes.readUInt32BE(24);
  const extLen = bytes.readUInt16BE(28);
  if (extLen > MAX_HEADER_EXT_BYTES || HEADER_BYTES + extLen > bytes.length) {
    throw new Error(`bad headerExtLen: ${extLen}`);
  }
  let meta: Record<string, unknown> | undefined;
  if (extLen > 0) {
    const decoded: unknown = JSON.parse(
      bytes.subarray(HEADER_BYTES, HEADER_BYTES + extLen).toString("utf8"),
    );
    if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) {
      throw new Error("headerExt must be a JSON object");
    }
    meta = decoded as Record<string, unknown>;
  }
  const payload =
    bytes.length > HEADER_BYTES + extLen
      ? Buffer.from(bytes.subarray(HEADER_BYTES + extLen))
      : undefined;
  return { type, transferId, pageIndex, pageCount, meta, payload };
}
