import 'dart:convert';
import 'dart:typed_data';

/// P2P 二进制传输帧 v2(chunk-v2)。与 v1(JSON+base64 文本帧)共存,
/// 由 `p2p-chunk-v2` 能力位门控:双方都声明才启用,否则回退 v1。
///
/// 帧布局(大端):
/// ```
/// 偏移  大小  字段
/// 0     2     magic "P2" (0x50 0x32)
/// 2     1     version = 2
/// 3     1     type(见 P2pFrameV2Type)
/// 4     16    transferId(UUID 二进制,无连字符)
/// 20    4     pageIndex(u32)
/// 24    4     pageCount(u32)
/// 28    2     headerExtLen(u16)
/// 30    N     headerExt(JSON meta,可为空)
/// 30+N  M     payload(原始字节,仅 DATA 帧使用)
/// ```
///
/// 语义:
/// - BEGIN:transfer 元信息(pageCount、pageBytes、encoding),payload 为空
/// - DATA:一页原始载荷,headerExt 为空
/// - DONE:发送方声明最后一页已发,headerExt 可带 {"sha256":"..."}
/// - ACK:接收方确认,headerExt {"ranges":[[s,e],...]}(已收页区间,闭区间)
/// - NACK:接收方报告缺口,headerExt {"missing":[i,...]}
/// - ABORT:任一中止,headerExt {"reason":"..."}
///
/// 该文件与 bridge/src/p2p_frame_v2.ts 必须逐字节镜像,
/// 双端单测跑 protocol/p2p_frame_v2_vectors.json 同一组向量。
const p2pChunkV2Capability = 'p2p-chunk-v2';

class P2pFrameV2Type {
  static const begin = 0x01;
  static const data = 0x02;
  static const done = 0x03;
  static const ack = 0x04;
  static const nack = 0x05;
  static const abort = 0x06;
}

const _headerBytes = 30;
const _maxHeaderExtBytes = 4096;

class P2pFrameV2 {
  P2pFrameV2({
    required this.type,
    required this.transferId,
    this.pageIndex = 0,
    this.pageCount = 0,
    this.meta,
    this.payload,
  });

  final int type;

  /// 16 字节传输标识(UUID 二进制)。
  final Uint8List transferId;
  final int pageIndex;
  final int pageCount;

  /// JSON 元信息(BEGIN/ACK/NACK/ABORT 用)。
  final Map<String, dynamic>? meta;

  /// 原始载荷(仅 DATA)。
  final Uint8List? payload;

  static Uint8List transferIdFromUuid(String uuid) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length != 32) {
      throw ArgumentError.value(uuid, 'uuid', 'expect 32 hex chars');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String transferIdToUuid(Uint8List bytes) {
    if (bytes.length != 16) {
      throw ArgumentError.value(bytes.length, 'bytes', 'expect 16 bytes');
    }
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  Uint8List encode() {
    if (transferId.length != 16) {
      throw StateError('transferId must be 16 bytes');
    }
    final metaBytes = meta == null
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(jsonEncode(meta)));
    if (metaBytes.length > _maxHeaderExtBytes) {
      throw StateError('headerExt exceeds $_maxHeaderExtBytes bytes');
    }
    final body = payload ?? Uint8List(0);
    final out = Uint8List(_headerBytes + metaBytes.length + body.length);
    final view = ByteData.sublistView(out);
    out[0] = 0x50; // 'P'
    out[1] = 0x32; // '2'
    view.setUint8(2, 2); // version
    view.setUint8(3, type);
    out.setRange(4, 20, transferId);
    view.setUint32(20, pageIndex);
    view.setUint32(24, pageCount);
    view.setUint16(28, metaBytes.length);
    out.setRange(_headerBytes, _headerBytes + metaBytes.length, metaBytes);
    out.setRange(_headerBytes + metaBytes.length, out.length, body);
    return out;
  }

  static P2pFrameV2 decode(Uint8List bytes) {
    if (bytes.length < _headerBytes) {
      throw FormatException('frame too short: ${bytes.length}');
    }
    if (bytes[0] != 0x50 || bytes[1] != 0x32) {
      throw const FormatException('bad magic');
    }
    final view = ByteData.sublistView(bytes);
    final version = view.getUint8(2);
    if (version != 2) {
      throw FormatException('unsupported version: $version');
    }
    final type = view.getUint8(3);
    final transferId = Uint8List.fromList(bytes.sublist(4, 20));
    final pageIndex = view.getUint32(20);
    final pageCount = view.getUint32(24);
    final extLen = view.getUint16(28);
    if (extLen > _maxHeaderExtBytes ||
        _headerBytes + extLen > bytes.length) {
      throw FormatException('bad headerExtLen: $extLen');
    }
    Map<String, dynamic>? meta;
    if (extLen > 0) {
      final decoded = jsonDecode(
        utf8.decode(bytes.sublist(_headerBytes, _headerBytes + extLen)),
      );
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('headerExt must be a JSON object');
      }
      meta = decoded;
    }
    final payload = bytes.length > _headerBytes + extLen
        ? Uint8List.fromList(bytes.sublist(_headerBytes + extLen))
        : null;
    return P2pFrameV2(
      type: type,
      transferId: transferId,
      pageIndex: pageIndex,
      pageCount: pageCount,
      meta: meta,
      payload: payload,
    );
  }
}
