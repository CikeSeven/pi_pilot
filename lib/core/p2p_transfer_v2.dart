import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'p2p_frame_v2.dart';

/// chunk-v2 传输层(Dart 镜像,与 bridge/src/p2p_transfer_v2.ts 逻辑一致):
/// 二进制分页 + gzip + 发送方留存(NACK 重发/断线续传)+ 接收方重组。
///
/// - SCTP 有序可靠,连接内不丢帧;NACK 的真实场景是断线续传——发送方把
///   transfer 留存 v2RetentionMs,重连后接收方凭 transferId+缺失页表
///   发 NACK{resume:true},发送方补 BEGIN(让接收方重建元信息)+缺失页+DONE。
/// - 留存与重组都有 TTL + 字节上限,防内存膨胀。
/// - gzip 阈值 16KB:JSON 文本压缩率高,小帧不值得压。
const v2PageBytes = 36 * 1024;
const v2DirectBytes = 48 * 1024;
const v2MaxMessageBytes = 16 * 1024 * 1024;
const v2GzipMinBytes = 16 * 1024;
const v2RetentionMs = 60 * 1000;
const v2RetentionMaxBytes = 32 * 1024 * 1024;
const v2MaxAssemblies = 8;
const v2AssemblyMaxBytes = 32 * 1024 * 1024;
const v2AssemblyIdleMs = 30 * 1000;

/// 单次 NACK 最多受理的缺页数。上限按「最大消息能拆出的页数」给足余量,
/// 再多就是重复/越界索引造成的重发放大,直接截断。
const v2MaxNackPages = (v2MaxMessageBytes + v2PageBytes - 1) ~/ v2PageBytes + 1;

/// 接收方允许的 encoding 白名单。未知 encoding 必须直接拒绝,而不是当成
/// identity 继续拼 —— 否则交付上层的是一堆二进制垃圾。
const v2AllowedEncodings = <String>{'identity', 'gzip'};

/// 单个 DATA 页 payload 硬上限。发送方按 v2PageBytes 分页,给少量宽容;
/// 超过就是对端违规(或恶意超大页),必须在计入累计字节前拦下。
const v2MaxPagePayloadBytes = v2PageBytes + 4 * 1024;

/// 声明的原始大小上限(即解压后字节数上限)。gzip 解压必须带着这个上限,
/// 无上限解压面对 gzip bomb 会直接吃空内存。
const v2MaxInflatedBytes = v2MaxMessageBytes;

final _random = Random.secure();

class EncodedTransfer {
  EncodedTransfer({
    required this.transferId,
    required this.frames,
    required this.bytes,
  });

  final Uint8List transferId;

  /// [BEGIN, DATA×pageCount, DONE] 完整线帧序列。
  final List<Uint8List> frames;

  /// 留存体积近似值。
  final int bytes;
}

/// 完整 JSON 文本 → v2 线帧序列(>16KB 且划算时 gzip)。
EncodedTransfer encodeTransferV2(String text) {
  final raw = Uint8List.fromList(utf8.encode(text));
  if (raw.length > v2MaxMessageBytes) {
    throw StateError('P2P message exceeds 16MB');
  }
  var payload = raw;
  var encoding = 'identity';
  if (raw.length >= v2GzipMinBytes) {
    final compressed = Uint8List.fromList(gzip.encode(raw));
    if (compressed.length < raw.length) {
      payload = compressed;
      encoding = 'gzip';
    }
  }
  final pageCount = max(1, (payload.length + v2PageBytes - 1) ~/ v2PageBytes);
  final transferId = Uint8List.fromList(
    List<int>.generate(16, (_) => _random.nextInt(256)),
  );
  final frames = <Uint8List>[
    P2pFrameV2(
      type: P2pFrameV2Type.begin,
      transferId: transferId,
      pageCount: pageCount,
      meta: {
        'pageBytes': v2PageBytes,
        'encoding': encoding,
        'payloadType': 'json',
        'size': raw.length,
        // 端到端完整性:接收方在 ACK 前比对。分页拼接 + 解压 任一环节出错
        // 都会产生"能解析但内容错"的 JSON,比直接失败难查得多。
        'sha256': sha256HexOf(raw),
      },
    ).encode(),
  ];
  for (var i = 0; i < pageCount; i++) {
    final start = i * v2PageBytes;
    final end = min(payload.length, (i + 1) * v2PageBytes);
    frames.add(
      P2pFrameV2(
        type: P2pFrameV2Type.data,
        transferId: transferId,
        pageIndex: i,
        pageCount: pageCount,
        payload: Uint8List.fromList(payload.sublist(start, end)),
      ).encode(),
    );
  }
  frames.add(
    P2pFrameV2(
      type: P2pFrameV2Type.done,
      transferId: transferId,
      pageCount: pageCount,
    ).encode(),
  );
  return EncodedTransfer(
    transferId: transferId,
    frames: frames,
    bytes: payload.length + frames.length * 30,
  );
}

class _Retained {
  _Retained({
    required this.begin,
    required this.pages,
    required this.done,
    required this.bytes,
    required this.at,
  });

  final Uint8List begin;
  final List<Uint8List> pages;
  final Uint8List done;
  final int bytes;
  int at;
}

/// 发送方留存:按 transferId 供 NACK 重发与断线续传。TTL + 总量上限。
class TransferRetainedStore {
  /// 时钟可注入:TTL 语义必须能被确定性测试。真实时间下无法验证
  /// 「60s 后 resendFrames 必须返回 null」,而这正是已确认过的缺陷。
  TransferRetainedStore({int Function()? clockMs})
    : _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _clockMs;

  final _map = <String, _Retained>{};
  int _totalBytes = 0;

  void add(EncodedTransfer transfer) {
    final key = _hexOf(transfer.transferId);
    _drop(key);
    _map[key] = _Retained(
      begin: transfer.frames.first,
      pages: transfer.frames.sublist(1, transfer.frames.length - 1),
      done: transfer.frames.last,
      bytes: transfer.bytes,
      at: _clockMs(),
    );
    _totalBytes += transfer.bytes;
    _sweep();
  }

  /// NACK → 需要重发的线帧;resume 时先补 BEGIN,末尾始终补 DONE
  /// (接收方收齐页后要靠 DONE 触发交付)。未知 transfer 返回 null。
  List<Uint8List>? resendFrames(
    String transferIdHex,
    List<int> missing,
    bool includeBegin,
  ) {
    final retained = _map[transferIdHex];
    if (retained == null) return null;
    // 过期判定必须在这里做:_sweep 只在 add 时触发,长时间没有新 transfer 时
    // 一条早已超过 TTL 的留存仍会被取出并刷新 at,等于 TTL 永不生效。
    if (_clockMs() - retained.at > v2RetentionMs) {
      _drop(transferIdHex);
      return null;
    }
    retained.at = _clockMs();
    final out = <Uint8List>[if (includeBegin) retained.begin];
    for (final index in missing) {
      if (index >= 0 && index < retained.pages.length) {
        out.add(retained.pages[index]);
      }
    }
    out.add(retained.done);
    return out;
  }

  void ack(String transferIdHex) {
    _drop(transferIdHex);
  }

  /// 发送侧撚回:整条消息被队列拒绝时必须把留存也撚掉。
  /// 否则对端永远不会为一条根本没发出去的 transfer 发 NACK,
  /// 这份留存就只能等 TTL 超时,白占几十 MB 预算。
  void dropTransfer(String transferIdHex) {
    _drop(transferIdHex);
  }

  /// 主动到期回收。_sweep 原本只在 add 时触发,空闲期(没有新 transfer)
  /// 留存会一直占着预算,所以需要一个可被定时器调用的入口。
  void sweepExpired() {
    _sweep();
  }

  /// 当前留存字节数(遥测/测试用)。
  int get retainedBytes => _totalBytes;

  void _drop(String key) {
    final existing = _map.remove(key);
    if (existing != null) _totalBytes -= existing.bytes;
  }

  void _sweep() {
    final now = _clockMs();
    for (final key in _map.keys.toList()) {
      if (now - _map[key]!.at > v2RetentionMs) _drop(key);
    }
    // FIFO 逐出到字节上限内。
    for (final key in _map.keys.toList()) {
      if (_totalBytes <= v2RetentionMaxBytes) break;
      _drop(key);
    }
  }
}

class _Assembly {
  _Assembly({
    required this.pageCount,
    required this.encoding,
    required this.size,
    this.sha256,
  }) : parts = List<Uint8List?>.filled(pageCount, null);

  final int pageCount;
  String encoding;
  int size;

  /// BEGIN 声明的端到端 sha256(可能缺失:老版本发送方没带)。
  String? sha256;
  final List<Uint8List?> parts;
  int received = 0;
  int bytes = 0;
  int lastActivity = DateTime.now().millisecondsSinceEpoch;
  bool doneSeen = false;
}

class AssemblerResult {
  AssemblerResult({this.message, required this.replies});

  /// 完整交付的 JSON 文本(已按需 gunzip)。
  final String? message;

  /// 需要回发给对端的帧(ACK/NACK)。
  final List<Uint8List> replies;
}

class PendingResume {
  PendingResume({
    required this.transferIdHex,
    required this.missing,
    required this.pageCount,
  });

  final String transferIdHex;
  final List<int> missing;
  final int pageCount;
}

/// 接收方重组器。由连接层(P2pConnector)长期持有,断线重连后原 assembly
/// 还在,NACK{resume:true} 才有意义。
class TransferV2Assembler {
  final _assemblies = <String, _Assembly>{};
  int _totalBytes = 0;

  AssemblerResult onFrame(Uint8List frameBytes) {
    final replies = <Uint8List>[];
    _sweep();
    P2pFrameV2 frame;
    try {
      frame = P2pFrameV2.decode(frameBytes);
    } catch (_) {
      return AssemblerResult(replies: replies);
    }
    final key = _hexOf(frame.transferId);
    switch (frame.type) {
      case P2pFrameV2Type.begin:
        if (frame.pageCount <= 0 || frame.pageCount > v2MaxNackPages) {
          return AssemblerResult(replies: replies);
        }
        final meta = frame.meta;
        // encoding 白名单:未知 encoding 必须拒绝,不能当成 identity 继续拼。
        final encoding = (meta?['encoding'] as String?) ?? 'identity';
        if (!v2AllowedEncodings.contains(encoding)) {
          replies.add(
            P2pFrameV2(
              type: P2pFrameV2Type.abort,
              transferId: frame.transferId,
              pageCount: frame.pageCount,
              meta: const {'reason': 'unsupported encoding'},
            ).encode(),
          );
          _dropAssembly(key);
          return AssemblerResult(replies: replies);
        }
        // 声明的原始大小必须有界:BEGIN 是唯一能在收数据前判定总量的地方。
        final declaredSize = (meta?['size'] as num?)?.toInt() ?? 0;
        if (declaredSize < 0 || declaredSize > v2MaxInflatedBytes) {
          replies.add(
            P2pFrameV2(
              type: P2pFrameV2Type.abort,
              transferId: frame.transferId,
              pageCount: frame.pageCount,
              meta: const {'reason': 'declared size out of range'},
            ).encode(),
          );
          _dropAssembly(key);
          return AssemblerResult(replies: replies);
        }
        final rawHash = meta?['sha256'];
        final declaredHash =
            rawHash is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(rawHash)
            ? rawHash
            : null;
        final existing = _assemblies[key];
        if (existing != null && existing.pageCount == frame.pageCount) {
          // 续传补发的 BEGIN:保留已收页,只刷新元信息与活跃时间。
          existing.lastActivity = DateTime.now().millisecondsSinceEpoch;
          existing.encoding = encoding;
          existing.size = declaredSize;
          existing.sha256 = declaredHash ?? existing.sha256;
          return AssemblerResult(replies: replies);
        }
        _dropAssembly(key);
        _assemblies[key] = _Assembly(
          pageCount: frame.pageCount,
          encoding: encoding,
          size: declaredSize,
          sha256: declaredHash,
        );
        _enforceCaps(key);
        return AssemblerResult(replies: replies);
      case P2pFrameV2Type.data:
        final assembly = _assemblies[key];
        if (assembly == null ||
            frame.pageIndex < 0 ||
            frame.pageIndex >= assembly.pageCount) {
          return AssemblerResult(replies: replies);
        }
        final part = frame.payload ?? Uint8List(0);
        // 单页硬上限:超大页是对端违规或恶意构造,必须在计入累计字节前拦掉。
        if (part.length > v2MaxPagePayloadBytes) {
          replies.add(
            P2pFrameV2(
              type: P2pFrameV2Type.abort,
              transferId: frame.transferId,
              pageCount: assembly.pageCount,
              meta: const {'reason': 'page too large'},
            ).encode(),
          );
          _dropAssembly(key);
          return AssemblerResult(replies: replies);
        }
        if (assembly.parts[frame.pageIndex] == null) {
          // 累计压缩字节上限:即便每页都合规,页数×页长也可能超总预算。
          if (assembly.bytes + part.length > v2AssemblyMaxBytes) {
            replies.add(
              P2pFrameV2(
                type: P2pFrameV2Type.abort,
                transferId: frame.transferId,
                pageCount: assembly.pageCount,
                meta: const {'reason': 'assembly too large'},
              ).encode(),
            );
            _dropAssembly(key);
            return AssemblerResult(replies: replies);
          }
          assembly.parts[frame.pageIndex] = part;
          assembly.received++;
          assembly.bytes += part.length;
          _totalBytes += part.length;
          assembly.lastActivity = DateTime.now().millisecondsSinceEpoch;
          if (!_enforceCaps(key)) return AssemblerResult(replies: replies);
        }
        return AssemblerResult(replies: replies);
      case P2pFrameV2Type.done:
        final assembly = _assemblies[key];
        if (assembly == null) return AssemblerResult(replies: replies);
        assembly.doneSeen = true;
        assembly.lastActivity = DateTime.now().millisecondsSinceEpoch;
        final missing = _missingPages(assembly);
        if (missing.isNotEmpty) {
          replies.add(
            P2pFrameV2(
              type: P2pFrameV2Type.nack,
              transferId: frame.transferId,
              pageCount: assembly.pageCount,
              meta: {'missing': missing},
            ).encode(),
          );
          return AssemblerResult(replies: replies);
        }
        final message = _materialize(key, assembly);
        if (message == null) return AssemblerResult(replies: replies);
        replies.add(
          P2pFrameV2(
            type: P2pFrameV2Type.ack,
            transferId: frame.transferId,
            pageCount: assembly.pageCount,
            meta: {
              'ranges': [
                [0, assembly.pageCount - 1],
              ],
            },
          ).encode(),
        );
        return AssemblerResult(message: message, replies: replies);
      case P2pFrameV2Type.abort:
        _dropAssembly(key);
        return AssemblerResult(replies: replies);
      default:
        return AssemblerResult(replies: replies);
    }
  }

  /// 断线续传:返回所有未完成 assembly 的 transferId 与缺失页表。
  List<PendingResume> pendingResumes() {
    _sweep();
    return [
      for (final entry in _assemblies.entries)
        PendingResume(
          transferIdHex: entry.key,
          missing: _missingPages(entry.value),
          pageCount: entry.value.pageCount,
        ),
    ];
  }

  /// 续传 NACK 帧(resume 标记让发送方补 BEGIN 重建元信息)。
  static Uint8List resumeNackFrame(
    String transferIdHex,
    List<int> missing,
    int pageCount,
  ) {
    return P2pFrameV2(
      type: P2pFrameV2Type.nack,
      transferId: _fromHex(transferIdHex),
      pageCount: pageCount,
      meta: {'missing': missing, 'resume': true},
    ).encode();
  }

  List<int> _missingPages(_Assembly assembly) {
    final missing = <int>[];
    for (var i = 0; i < assembly.pageCount; i++) {
      if (assembly.parts[i] == null) missing.add(i);
    }
    return missing;
  }

  /// 拼页 → 解压 → 校验。任一环节不过就返回 null(调用方不发 ACK)。
  String? _materialize(String key, _Assembly assembly) {
    final builder = BytesBuilder(copy: false);
    for (final part in assembly.parts) {
      builder.add(part ?? Uint8List(0));
    }
    _dropAssembly(key);
    List<int> raw;
    try {
      final joined = builder.takeBytes();
      raw = assembly.encoding == 'gzip' ? gzip.decode(joined) : joined;
    } catch (_) {
      return null;
    }
    // 解压输出上限:gzip bomb 能把几十 KB 膨胀到 GB 级。dart:io 的 gzip 没有
    // maxOutputLength 参数,只能解压后立刻判定并丢弃。
    if (raw.length > v2MaxInflatedBytes) return null;
    // 声明大小核对:分页拼接错位/重复页会产出"能解析但内容错"的 JSON。
    if (assembly.size > 0 && raw.length != assembly.size) return null;
    final expected = assembly.sha256;
    if (expected != null && sha256HexOf(raw) != expected) return null;
    try {
      return utf8.decode(raw);
    } catch (_) {
      return null;
    }
  }

  void _dropAssembly(String key) {
    final existing = _assemblies.remove(key);
    if (existing != null) _totalBytes -= existing.bytes;
  }

  void _sweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final key in _assemblies.keys.toList()) {
      if (now - _assemblies[key]!.lastActivity > v2AssemblyIdleMs) {
        _dropAssembly(key);
      }
    }
  }

  /// 主动到期回收。_sweep 原本只在 onFrame 时触发,空闲期未完成的 assembly
  /// 会一直占着预算,所以需要一个可被定时器调用的入口。
  void sweepExpired() {
    _sweep();
  }

  /// 当前重组占用字节(遥测/测试用)。
  int get assemblyBytes => _totalBytes;

  /// 超上限时逐出最旧的(被逐出的 transfer 后续只能等全量/重同步——宁缺毋假)。
  ///
  /// 返回 false 表示连被保护的 assembly 自己都放不下,已被丢弃。原实现里
  /// `continue` 跳过 protectedKey 后若没有其他可逐出者就直接 return,于是
  /// 当前 assembly 可以无限期超出总上限 —— 单条超大 transfer 就能绕过预算。
  bool _enforceCaps(String protectedKey) {
    while (_assemblies.length > v2MaxAssemblies ||
        _totalBytes > v2AssemblyMaxBytes) {
      String? oldestKey;
      var oldestAt = 1 << 62;
      for (final entry in _assemblies.entries) {
        if (entry.key == protectedKey) continue;
        if (entry.value.lastActivity < oldestAt) {
          oldestAt = entry.value.lastActivity;
          oldestKey = entry.key;
        }
      }
      if (oldestKey == null) {
        // 已经没有别的可逐出:说明超限来自当前这条,它也必须被丢掉。
        _dropAssembly(protectedKey);
        return false;
      }
      _dropAssembly(oldestKey);
    }
    return true;
  }
}

/// transferId 十六进制形式(留存/重组的键,NACK/ACK 处理用)。
String transferIdHexOf(Uint8List bytes) => _hexOf(bytes);

/// chunk-v2 端到端完整性校验用的 sha256 十六进制串。
String sha256HexOf(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

String _hexOf(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
