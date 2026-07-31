import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/device_models.dart';
import 'package:pi_pilot/state/device_manager.dart';
import 'package:pi_pilot/state/notification_controller.dart';
import 'package:pi_pilot/state/pi_session.dart';

HubSession _session({
  required String sessionId,
  required bool connected,
  bool streaming = false,
  SessionLiveness liveness = SessionLiveness.desktop,
}) => HubSession(
  sessionId: sessionId,
  sourceId: 'src:$sessionId',
  liveness: liveness,
  connected: connected,
  streaming: streaming,
);

void main() {
  group('native watcher target', () {
    const first = DeviceProfile(
      id: 'dev-old',
      name: '旧设备',
      host: '192.168.1.2',
      port: 9377,
      token: 'old-token',
    );
    const active = DeviceProfile(
      id: 'dev-active',
      name: '当前设备',
      host: '192.168.1.9',
      port: 9488,
      token: 'active-token',
    );

    test('使用当前 roster 设备,不读取旧单设备连接配置', () {
      final target = resolveWatcherConnectionTarget(
        manager: const DeviceManagerState(
          devices: [first, active],
          activeDeviceId: 'dev-active',
          loaded: true,
        ),
        session: PiState.initial().copyWith(
          activeTransport: PiActiveTransport.lan,
          selectedSourceId: 'desktop:active',
          isStreaming: true,
        ),
      );

      expect(target, (
        deviceId: active.id,
        host: active.host,
        port: active.port,
        token: active.token,
        sourceId: 'desktop:active',
        wasStreaming: true,
      ));
    });

    test('P2P 实际通道不冒充可用的局域网 watcher', () {
      final target = resolveWatcherConnectionTarget(
        manager: const DeviceManagerState(
          devices: [active],
          activeDeviceId: 'dev-active',
          loaded: true,
        ),
        session: PiState.initial().copyWith(
          activeTransport: PiActiveTransport.p2p,
          selectedSourceId: 'desktop:active',
        ),
      );

      expect(target, isNull);
    });

    test('watcher clientId 按安装和设备隔离', () {
      expect(
        nativeWatcherClientId(appClientId: 'app-123', deviceId: active.id),
        'app-123:native-watcher:${active.id}',
      );
      expect(
        nativeWatcherClientId(appClientId: '', deviceId: active.id),
        '${active.id}:native-watcher:${active.id}',
      );
    });
  });

  test('连接中断通知使用保留的固定 id', () {
    expect(connectionLostNotificationId, 2);
  });

  test('通知操作串行执行,快速重连不会让延迟显示覆盖取消', () async {
    final sequencer = NotificationOperationSequencer();
    final showStarted = Completer<void>();
    final releaseShow = Completer<void>();
    final operations = <String>[];

    final show = sequencer.enqueue(() async {
      operations.add('show:start');
      showStarted.complete();
      await releaseShow.future;
      operations.add('show:end');
    });
    await showStarted.future;

    final cancel = sequencer.enqueue(() async {
      operations.add('cancel');
    });
    await Future<void>.delayed(Duration.zero);
    expect(operations, ['show:start']);

    releaseShow.complete();
    await Future.wait([show, cancel]);
    expect(operations, ['show:start', 'show:end', 'cancel']);
  });

  test('通知操作失败后仍继续执行后续操作', () async {
    final sequencer = NotificationOperationSequencer();
    final operations = <String>[];

    await expectLater(
      sequencer.enqueue(() async {
        operations.add('failed');
        throw StateError('notification failed');
      }),
      throwsStateError,
    );
    await sequencer.enqueue(() async {
      operations.add('next');
    });

    expect(operations, ['failed', 'next']);
  });

  group('keepAliveSessionCounts', () {
    test('sessions 还没就绪(空列表)时返回 null,不推状态', () {
      expect(keepAliveSessionCounts(const []), isNull);
    });

    test('已连接与工作中分开计数', () {
      final counts = keepAliveSessionCounts([
        _session(sessionId: 'a', connected: true, streaming: true),
        _session(sessionId: 'b', connected: true),
      ]);
      expect(counts, (connected: 2, working: 1));
    });

    test('dormant(只在磁盘上)不算已连接', () {
      final counts = keepAliveSessionCounts([
        _session(sessionId: 'a', connected: true),
        _session(
          sessionId: 'b',
          connected: false,
          liveness: SessionLiveness.dormant,
        ),
      ]);
      expect(counts, (connected: 1, working: 0));
    });

    test('断开源上残留的 streaming 标记不算工作中', () {
      // 桌面进程被杀时 streamingBySource 可能留着 true,
      // connected=false 的会话不该计入「工作中」。
      final counts = keepAliveSessionCounts([
        _session(sessionId: 'a', connected: true),
        _session(sessionId: 'b', connected: false, streaming: true),
      ]);
      expect(counts, (connected: 1, working: 0));
    });

    test('全部空闲时 working 为 0', () {
      final counts = keepAliveSessionCounts([
        _session(sessionId: 'a', connected: true),
        _session(sessionId: 'b', connected: true),
      ]);
      expect(counts, (connected: 2, working: 0));
    });
  });
  group('taskCompletionTitle', () {
    test('带会话名:<会话名> 已完成', () {
      expect(taskCompletionTitle('PiPilot'), 'PiPilot 已完成');
    });

    test('没有会话名时退成通用标题', () {
      expect(taskCompletionTitle(null), 'PiPilot 任务完成');
      expect(taskCompletionTitle(''), 'PiPilot 任务完成');
      expect(taskCompletionTitle('  '), 'PiPilot 任务完成');
    });
  });
}
