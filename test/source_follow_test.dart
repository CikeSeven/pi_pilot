import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';

/// 电脑上 Ctrl+Z 挂起 pi 再开一个时,新进程的 sourceId 里嵌着新的 PID,必然与旧的
/// 不同。以前只有首次连接才会回退选源,运行期换窗口时 App 就一直钉在那个已经死掉
/// 的源上,必须杀掉 App 重开才恢复。
///
/// 这条判定挑错窗口就等于替用户换掉了他正在看的会话,所以单独钉住。
SourceInfo source(
  String id, {
  bool connected = true,
  bool desktop = true,
  String? sessionId,
  String? label,
}) => SourceInfo(
  id: id,
  kind: desktop ? PiSourceKind.desktop : PiSourceKind.headless,
  label: label ?? id,
  connected: connected,
  epoch: 'epoch-$id',
  capabilities: const ['prompt'],
  ownerPresent: false,
  ownedByYou: false,
  sessionId: sessionId,
);

void main() {
  group('旧桌面窗口失联后的自动跟随', () {
    test('同一会话优先:fg 回原会话或另开一个跑同一会话都跟过去', () {
      final dead = source('host:100', connected: false, sessionId: 's-1');
      final target = PiSessionNotifier.pickFollowTarget([
        dead,
        source('host:200', sessionId: 's-9'),
        source('host:300', sessionId: 's-1'),
      ], dead);
      expect(target?.id, 'host:300');
    });

    test('只剩一个候选时直接跟随', () {
      final dead = source('host:100', connected: false, sessionId: 's-1');
      final target = PiSessionNotifier.pickFollowTarget([
        dead,
        source('host:200', sessionId: 's-9'),
      ], dead);
      expect(target?.id, 'host:200');
    });

    test('多个候选且都不是同一会话时不猜:擅自挑一个等于替用户换会话', () {
      final dead = source('host:100', connected: false, sessionId: 's-1');
      final target = PiSessionNotifier.pickFollowTarget([
        dead,
        source('host:200', sessionId: 's-8'),
        source('host:300', sessionId: 's-9'),
      ], dead);
      expect(target, isNull);
    });

    test('没有活着的桌面窗口时不跟随', () {
      final dead = source('host:100', connected: false, sessionId: 's-1');
      final target = PiSessionNotifier.pickFollowTarget([
        dead,
        source('host:200', connected: false, sessionId: 's-2'),
      ], dead);
      expect(target, isNull);
    });

    test('headless 源不算候选:它是休眠会话,发消息就能唤醒,不该顶替桌面窗口', () {
      final dead = source('host:100', connected: false, sessionId: 's-1');
      final target = PiSessionNotifier.pickFollowTarget([
        dead,
        source('s:abc', desktop: false, sessionId: 's-1'),
      ], dead);
      expect(target, isNull);
    });

    test('原窗口的会话 id 未知时,仍能在唯一候选下跟随', () {
      final target = PiSessionNotifier.pickFollowTarget([
        source('host:200', sessionId: 's-9'),
      ], null);
      expect(target?.id, 'host:200');
    });
  });
}
