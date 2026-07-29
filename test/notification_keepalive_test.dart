import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/hub_models.dart';
import 'package:pi_pilot/state/notification_controller.dart';

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
