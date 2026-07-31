import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/p2p_frame_v2.dart';
import 'package:pi_pilot/core/p2p_transfer_v2.dart';

/// 不可压缩文本(random hex):保证分页数不受 gzip 影响,测试确定性。
String incompressibleText(int pages) {
  final random = Random(42);
  final bytes = Uint8List.fromList(
    List<int>.generate(v2PageBytes * pages, (_) => random.nextInt(256)),
  );
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

({String? message, List<Uint8List> replies}) feedAll(
  TransferV2Assembler assembler,
  List<Uint8List> frames,
) {
  String? message;
  final replies = <Uint8List>[];
  for (final frame in frames) {
    final result = assembler.onFrame(frame);
    if (result.message != null) message = result.message;
    replies.addAll(result.replies);
  }
  return (message: message, replies: replies);
}

void main() {
  group('v2 transfer(Dart 镜像)', () {
    test('小消息 identity 完整往返', () {
      final text = jsonEncode({
        'type': 'hub_sync',
        'data': 'x' * 1000,
      });
      final transfer = encodeTransferV2(text);
      final assembler = TransferV2Assembler();
      final result = feedAll(assembler, transfer.frames);
      expect(result.message, text);
      // DONE 全齐 → 回 ACK
      expect(result.replies.length, 1);
      expect(P2pFrameV2.decode(result.replies[0]).type, P2pFrameV2Type.ack);
    });

    test('大消息 gzip 分页往返,线体积显著缩小', () {
      final text = jsonEncode({
        'entries': List.generate(
          2000,
          (i) => {'role': 'user', 'text': 'hello world ${i % 10} ' * 20},
        ),
      });
      expect(text.length, greaterThan(v2GzipMinBytes * 10));
      final transfer = encodeTransferV2(text);
      final wireBytes = transfer.frames.fold<int>(
        0,
        (sum, frame) => sum + frame.length,
      );
      expect(wireBytes, lessThan(text.length / 5));
      final begin = P2pFrameV2.decode(transfer.frames[0]);
      expect(begin.type, P2pFrameV2Type.begin);
      expect(begin.meta?['encoding'], 'gzip');
      final assembler = TransferV2Assembler();
      expect(feedAll(assembler, transfer.frames).message, text);
    });

    test('DONE 前丢页 → NACK,留存重发后完成', () {
      final text = incompressibleText(3);
      final transfer = encodeTransferV2(text);
      final dataFrames = transfer.frames
          .where((frame) => P2pFrameV2.decode(frame).type == P2pFrameV2Type.data)
          .toList();
      expect(dataFrames.length, greaterThanOrEqualTo(3));
      final dropped = P2pFrameV2.decode(dataFrames[1]).pageIndex;
      final framesWithout = transfer.frames.where((frame) {
        final decoded = P2pFrameV2.decode(frame);
        return !(decoded.type == P2pFrameV2Type.data &&
            decoded.pageIndex == dropped);
      }).toList();
      final assembler = TransferV2Assembler();
      final first = feedAll(assembler, framesWithout);
      expect(first.message, isNull);
      expect(first.replies.length, 1);
      final nack = P2pFrameV2.decode(first.replies[0]);
      expect(nack.type, P2pFrameV2Type.nack);
      expect(nack.meta?['missing'], [dropped]);

      final store = TransferRetainedStore()..add(transfer);
      final resends = store.resendFrames(
        transferIdHexOf(transfer.transferId),
        [dropped],
        false,
      );
      expect(resends, isNotNull);
      // DATA 页 + 末尾补发的 DONE
      expect(resends!.length, 2);
      final second = feedAll(assembler, resends);
      expect(second.message, text);
    });

    test('断线续传:pendingResumes + resume NACK + BEGIN 保留已收页', () {
      final text = incompressibleText(4);
      final transfer = encodeTransferV2(text);
      final pageCount = P2pFrameV2.decode(transfer.frames[0]).pageCount;
      expect(pageCount, greaterThanOrEqualTo(4));
      final assembler = TransferV2Assembler();
      // 只收到 BEGIN + 第 0 页就断线
      assembler.onFrame(transfer.frames[0]);
      assembler.onFrame(transfer.frames[1]);
      final pending = assembler.pendingResumes();
      expect(pending.length, 1);
      expect(
        pending[0].missing,
        List.generate(pageCount - 1, (i) => i + 1),
      );
      expect(pending[0].pageCount, pageCount);

      final resumeNack = TransferV2Assembler.resumeNackFrame(
        pending[0].transferIdHex,
        pending[0].missing,
        pending[0].pageCount,
      );
      expect(P2pFrameV2.decode(resumeNack).meta?['resume'], true);

      final store = TransferRetainedStore()..add(transfer);
      final resends = store.resendFrames(
        pending[0].transferIdHex,
        pending[0].missing,
        true,
      );
      expect(resends, isNotNull);
      // BEGIN + missing pages + 末尾补发的 DONE
      expect(resends!.length, 1 + (pageCount - 1) + 1);
      expect(P2pFrameV2.decode(resends[0]).type, P2pFrameV2Type.begin);
      final result = feedAll(assembler, resends);
      expect(result.message, text);
    });

    test('ACK 后留存释放', () {
      final text = jsonEncode({'data': 'z' * 100000});
      final transfer = encodeTransferV2(text);
      final store = TransferRetainedStore()..add(transfer);
      final hex = transferIdHexOf(transfer.transferId);
      expect(store.resendFrames(hex, [0], false), isNotNull);
      store.ack(hex);
      expect(store.resendFrames(hex, [0], false), isNull);
    });

    test('ABORT 丢弃 assembly,坏帧不炸', () {
      final text = incompressibleText(2);
      final transfer = encodeTransferV2(text);
      final assembler = TransferV2Assembler();
      assembler.onFrame(transfer.frames[0]);
      expect(assembler.pendingResumes().length, 1);
      // 坏帧直接忽略
      expect(
        assembler.onFrame(Uint8List.fromList([1, 2, 3])).replies,
        isEmpty,
      );
    });
  });

  group('v2 资源校验(Dart 镜像)', () {
    test('未知 encoding 直接 ABORT,不当成 identity 拼', () {
      final assembler = TransferV2Assembler();
      final transferId = Uint8List.fromList(List<int>.filled(16, 7));
      final result = assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.begin,
          transferId: transferId,
          pageCount: 1,
          meta: const {'encoding': 'brotli-evil', 'size': 10},
        ).encode(),
      );
      expect(result.replies, hasLength(1));
      final reply = P2pFrameV2.decode(result.replies.first);
      expect(reply.type, P2pFrameV2Type.abort);
      expect(reply.meta?['reason'], 'unsupported encoding');
    });

    test('声明 size 越界直接 ABORT', () {
      final assembler = TransferV2Assembler();
      final transferId = Uint8List.fromList(List<int>.filled(16, 8));
      final result = assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.begin,
          transferId: transferId,
          pageCount: 1,
          meta: const {'encoding': 'identity', 'size': 64 * 1024 * 1024},
        ).encode(),
      );
      final reply = P2pFrameV2.decode(result.replies.first);
      expect(reply.type, P2pFrameV2Type.abort);
      expect(reply.meta?['reason'], 'declared size out of range');
    });

    test('超大单页直接 ABORT,不计入累计字节', () {
      final assembler = TransferV2Assembler();
      final transferId = Uint8List.fromList(List<int>.filled(16, 9));
      assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.begin,
          transferId: transferId,
          pageCount: 2,
          meta: const {'encoding': 'identity', 'size': 1000},
        ).encode(),
      );
      final before = assembler.assemblyBytes;
      final result = assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.data,
          transferId: transferId,
          pageIndex: 0,
          pageCount: 2,
          payload: Uint8List(v2MaxPagePayloadBytes + 1),
        ).encode(),
      );
      final reply = P2pFrameV2.decode(result.replies.first);
      expect(reply.type, P2pFrameV2Type.abort);
      expect(reply.meta?['reason'], 'page too large');
      expect(assembler.assemblyBytes, before, reason: '越界页不得计入累计字节');
    });

    test('sha256 不符不交付', () {
      final assembler = TransferV2Assembler();
      final transferId = Uint8List.fromList(List<int>.filled(16, 10));
      final body = Uint8List.fromList(utf8.encode('{"type":"x"}'));
      assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.begin,
          transferId: transferId,
          pageCount: 1,
          meta: {
            'encoding': 'identity',
            'size': body.length,
            'sha256': '0' * 64,
          },
        ).encode(),
      );
      assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.data,
          transferId: transferId,
          pageIndex: 0,
          pageCount: 1,
          payload: body,
        ).encode(),
      );
      final done = assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.done,
          transferId: transferId,
          pageCount: 1,
        ).encode(),
      );
      expect(done.message, isNull, reason: 'hash 不符必须拒绝交付');
    });

    test('size 不符不交付(分页错位/重复页)', () {
      final assembler = TransferV2Assembler();
      final transferId = Uint8List.fromList(List<int>.filled(16, 11));
      assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.begin,
          transferId: transferId,
          pageCount: 1,
          meta: const {'encoding': 'identity', 'size': 999},
        ).encode(),
      );
      assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.data,
          transferId: transferId,
          pageIndex: 0,
          pageCount: 1,
          payload: Uint8List.fromList(utf8.encode('short')),
        ).encode(),
      );
      final done = assembler.onFrame(
        P2pFrameV2(
          type: P2pFrameV2Type.done,
          transferId: transferId,
          pageCount: 1,
        ).encode(),
      );
      expect(done.message, isNull);
    });

    test('正常 transfer 带 sha256 仍能往返', () {
      final text = jsonEncode({'type': 'hub_sync', 'data': 'y' * 50000});
      final transfer = encodeTransferV2(text);
      final begin = P2pFrameV2.decode(transfer.frames.first);
      expect(begin.meta?['sha256'], matches(r'^[0-9a-f]{64}$'));
      final assembler = TransferV2Assembler();
      expect(feedAll(assembler, transfer.frames).message, text);
    });
  });

  group('v2 留存 TTL(Dart 镜像,注入时钟)', () {
    test('过期后 resendFrames 返回 null,不再刷新时间戳复活', () {
      // 注入时钟:TTL 语义必须确定性可测。修复前过期留存会被取出并刷新 at,
      // 等于 TTL 永不生效,几十 MB 留存可无限期驻留。
      var now = 1000000;
      final store = TransferRetainedStore(clockMs: () => now);
      final transfer = encodeTransferV2(jsonEncode({'data': 'z' * 100000}));
      store.add(transfer);
      final hex = transferIdHexOf(transfer.transferId);
      expect(store.resendFrames(hex, [0], false), isNotNull);
      expect(store.retainedBytes, greaterThan(0));

      now += v2RetentionMs - 1;
      expect(
        store.resendFrames(hex, [0], false),
        isNotNull,
        reason: 'TTL 内必须仍可重发',
      );

      now += v2RetentionMs + 1;
      expect(
        store.resendFrames(hex, [0], false),
        isNull,
        reason: '过期留存必须返回 null',
      );
      expect(store.retainedBytes, 0, reason: '过期必须释放字节预算');
    });

    test('空闲期 sweepExpired 能主动回收(不依赖 add 触发)', () {
      var now = 5000000;
      final store = TransferRetainedStore(clockMs: () => now);
      store.add(encodeTransferV2(jsonEncode({'data': 'q' * 80000})));
      expect(store.retainedBytes, greaterThan(0));

      now += v2RetentionMs + 1;
      store.sweepExpired();
      expect(store.retainedBytes, 0, reason: '主动回收必须释放过期留存');
    });
  });
}
