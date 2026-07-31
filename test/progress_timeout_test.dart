import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/hub_channel.dart';
import 'package:pi_pilot/core/pi_connection.dart';

/// 最小 HubChannel 假体:能推入站帧、能触发分片级回调。
class _FakeChannel implements HubChannel {
  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<String> sent = <String>[];

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
  List<String> get transportCapabilities => const <String>[];

  @override
  void applyHandshake(Map<String, dynamic> hello) {}

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() => controller.close();

  /// 模拟传输层:分片到达既刷新活性,也算数据进度。
  void pushFragment() {
    onActivity?.call();
    onDataProgress?.call();
  }

  /// 模拟心跳:只刷新活性,不算数据进度。
  void pushHeartbeatActivity() {
    onActivity?.call();
  }
}

Future<PiConnection> _connected(_FakeChannel channel) async {
  final connection = PiConnection();
  final connecting = connection.connectViaChannel(channel, token: 't');
  channel.controller.add(
    jsonEncode(<String, dynamic>{
      'type': 'bridge_hello',
      'version': 3,
      'hubId': 'hub-1',
    }),
  );
  await connecting;
  return connection;
}

void main() {
  test('bridge_pong 刷新活性但不算数据进度', () async {
    final channel = _FakeChannel();
    final connection = await _connected(channel);
    addTearDown(() => connection.disconnect(notify: false));

    final ticks0 = connection.dataProgressTicks;
    final activity0 = connection.lastActivityAt;
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // 心跳帧走完整帧路径(WS 直连语义)。
    channel.controller.add(jsonEncode(<String, dynamic>{'type': 'bridge_pong'}));
    await Future<void>.delayed(Duration.zero);

    expect(
      connection.dataProgressTicks,
      ticks0,
      reason: '心跳不得推进数据进度——否则一个卡死的大 RPC 会被周期 pong 无限续命,'
          '这正是"心跳正常但数据永远不来"的根因',
    );
    // 对照:旧进度源(lastActivityAt)确实被心跳刷新了,所以它不能当进度依据。
    expect(
      connection.lastActivityAt.isAfter(activity0),
      isTrue,
      reason: 'lastActivityAt 会被心跳刷新,这就是它不能作为请求级进度源的原因',
    );
  });

  test('bridge_ping 也不算数据进度', () async {
    final channel = _FakeChannel();
    final connection = await _connected(channel);
    addTearDown(() => connection.disconnect(notify: false));

    final ticks0 = connection.dataProgressTicks;
    channel.controller.add(jsonEncode(<String, dynamic>{'type': 'bridge_ping'}));
    await Future<void>.delayed(Duration.zero);

    expect(connection.dataProgressTicks, ticks0);
  });

  test('普通响应帧推进数据进度', () async {
    final channel = _FakeChannel();
    final connection = await _connected(channel);
    addTearDown(() => connection.disconnect(notify: false));

    final ticks0 = connection.dataProgressTicks;
    channel.controller.add(
      jsonEncode(<String, dynamic>{
        'type': 'response',
        'id': 'r1',
        'success': true,
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.dataProgressTicks, greaterThan(ticks0));
  });

  test('分片级回调推进数据进度(大消息重组期间没有完整帧)', () async {
    final channel = _FakeChannel();
    final connection = await _connected(channel);
    addTearDown(() => connection.disconnect(notify: false));

    final ticks0 = connection.dataProgressTicks;
    channel.pushFragment();
    channel.pushFragment();

    expect(
      connection.dataProgressTicks,
      ticks0 + 2,
      reason: '重组期间上层看不到完整消息,只有分片级进度能证明请求在推进',
    );
  });

  test('只有心跳活性时数据进度保持不变', () async {
    final channel = _FakeChannel();
    final connection = await _connected(channel);
    addTearDown(() => connection.disconnect(notify: false));

    final ticks0 = connection.dataProgressTicks;
    for (var i = 0; i < 10; i++) {
      channel.pushHeartbeatActivity();
    }

    expect(connection.dataProgressTicks, ticks0);
  });
}
