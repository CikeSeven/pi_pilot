import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/hub_channel.dart';
import 'package:pi_pilot/core/p2p_chunking.dart';
import 'package:pi_pilot/core/pi_connection.dart';

class _HandshakeChannel implements HubChannel {
  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<String> sent = <String>[];
  Map<String, dynamic>? appliedHello;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  void Function()? onActivity;

  @override
  void Function()? onDataProgress;

  /// implements HubChannel 要求实现全部成员(即便基类给了默认体)。
  @override
  Future<String?> telemetry() async => null;

  @override
  List<String> get transportCapabilities => const <String>[p2pChunkCapability];

  @override
  void applyHandshake(Map<String, dynamic> hello) {
    appliedHello = hello;
  }

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() => controller.close();
}

void main() {
  test('小帧保持原样,大 UTF-8 帧分片后可乱序重组', () {
    const small = '{"type":"bridge_ping"}';
    expect(encodeP2pFrames(small), <String>[small]);

    final original = jsonEncode(<String, Object>{
      'type': 'response',
      'content': '消息快照' * 100000,
    });
    final frames = encodeP2pFrames(original);
    expect(frames.length, greaterThan(1));
    for (final frame in frames) {
      expect(utf8.encode(frame).length, lessThan(65536));
    }

    final decoder = P2pChunkDecoder();
    String? decoded;
    for (final frame in frames.reversed) {
      decoded = decoder.add(frame) ?? decoded;
    }
    expect(decoded, original);
    decoder.close();
  });

  test('损坏分片被丢弃,超过 16MB 的消息被拒绝', () {
    final decoder = P2pChunkDecoder();
    expect(decoder.add('~pipilot-chunk-v1~bad'), isNull);
    expect(
      () => encodeP2pFrames('x' * (16 * 1024 * 1024 + 1)),
      throwsStateError,
    );
    decoder.close();
  });

  test('慢链路持续收到新分片时,总耗时超过空闲窗口仍能重组', () async {
    final original = '慢链路快照' * 7000;
    final frames = encodeP2pFrames(original);
    expect(frames.length, greaterThan(2));

    final decoder = P2pChunkDecoder(idleTimeout: const Duration(seconds: 1));
    String? decoded;
    for (var i = 0; i < frames.length; i++) {
      decoded = decoder.add(frames[i]) ?? decoded;
      if (i < frames.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }

    expect(decoded, original);
    decoder.close();
  });

  test('分片真正停滞超过空闲窗口后会被回收', () async {
    final original = '停滞快照' * 7000;
    final frames = encodeP2pFrames(original);
    expect(frames.length, greaterThan(2));

    final decoder = P2pChunkDecoder(
      idleTimeout: const Duration(milliseconds: 100),
    );
    expect(decoder.add(frames.first), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    String? decoded;
    for (final frame in frames.skip(1)) {
      decoded = decoder.add(frame) ?? decoded;
    }
    expect(decoded, isNull);
    decoder.close();
  });

  test('P2P auth 声明分片能力,bridge_hello 回来后应用握手', () async {
    final channel = _HandshakeChannel();
    final connection = PiConnection();
    final connecting = connection.connectViaChannel(
      channel,
      token: 'mobile-token',
      clientId: 'stable-client',
    );

    expect(channel.sent, hasLength(1));
    final auth = jsonDecode(channel.sent.single) as Map<String, dynamic>;
    expect(auth['type'], 'auth');
    expect(auth['capabilities'], contains(p2pChunkCapability));

    final hello = <String, dynamic>{
      'type': 'bridge_hello',
      'version': 3,
      'hubId': 'hub-1',
      'capabilities': <String>[p2pChunkCapability],
    };
    channel.controller.add(jsonEncode(hello));
    expect(await connecting, hello);
    expect(channel.appliedHello, hello);

    connection.disconnect(notify: false);
  });
}
