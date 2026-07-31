import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/p2p_frame_v2.dart';

void main() {
  group('chunk-v2 帧:跨端测试向量', () {
    final doc =
        jsonDecode(
              File('protocol/p2p_frame_v2_vectors.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final vectors = (doc['vectors'] as List).cast<Map<String, dynamic>>();

    test('encode/decode 与 bridge 端逐字节一致', () {
      for (final vector in vectors) {
        final name = vector['name'] as String;
        final frameDef = vector['frame'] as Map<String, dynamic>;
        final frame = P2pFrameV2(
          type: frameDef['type'] as int,
          transferId: P2pFrameV2.transferIdFromUuid(
            frameDef['transferIdUuid'] as String,
          ),
          pageIndex: frameDef['pageIndex'] as int,
          pageCount: frameDef['pageCount'] as int,
          meta: (frameDef['meta'] as Map?)?.cast<String, dynamic>(),
          payload: (frameDef['payloadHex'] as String).isEmpty
              ? null
              : _fromHex(frameDef['payloadHex'] as String),
        );
        expect(
          _toHex(frame.encode()),
          vector['hex'] as String,
          reason: '$name: encode hex mismatch',
        );
        final decoded = P2pFrameV2.decode(_fromHex(vector['hex'] as String));
        expect(decoded.type, frameDef['type'], reason: name);
        expect(
          P2pFrameV2.transferIdToUuid(decoded.transferId),
          frameDef['transferIdUuid'],
          reason: name,
        );
        expect(decoded.pageIndex, frameDef['pageIndex'], reason: name);
        expect(decoded.pageCount, frameDef['pageCount'], reason: name);
        expect(decoded.meta, frameDef['meta'], reason: name);
        expect(
          decoded.payload == null ? '' : _toHex(decoded.payload!),
          frameDef['payloadHex'],
          reason: name,
        );
      }
    });

    test('坏魔数/短帧/坏 headerExtLen 一律 FormatException', () {
      expect(
        () => P2pFrameV2.decode(Uint8List(10)),
        throwsFormatException,
      );
      final badMagic = Uint8List(30)..[0] = 0x50;
      expect(() => P2pFrameV2.decode(badMagic), throwsFormatException);
      final good = P2pFrameV2(
        type: P2pFrameV2Type.done,
        transferId: Uint8List(16),
      ).encode();
      final badExt = Uint8List.fromList(good);
      ByteData.sublistView(badExt).setUint16(28, 9999);
      expect(() => P2pFrameV2.decode(badExt), throwsFormatException);
    });

    test('UUID 十六进制往返', () {
      const uuid = '3f786850-e387-4b2f-9d4a-1c6f2a9e0b51';
      expect(
        P2pFrameV2.transferIdToUuid(P2pFrameV2.transferIdFromUuid(uuid)),
        uuid,
      );
    });
  });
}

String _toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
