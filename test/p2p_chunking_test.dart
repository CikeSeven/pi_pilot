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
