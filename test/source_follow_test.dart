import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  group('选中源从推送目录消失的宽限复核', () {
    /// registry 是内存态:bridge 重启后各桌面 pi 要懒重注册,推送缺席可能只是
    /// 重注册还没轮到 —— 不能一缺席就清选择+跟随(那会把用户从活着的会话上拽走)。
    _GraceSession graceSetUp(
      ProviderContainer container,
      List<SourceInfo> both,
    ) {
      // 必须在读 provider 之前塞好:读 .notifier 的那一刻 build() 就跑。
      _GraceSession.nextInitial = PiState.initial().copyWith(
        selectedSourceId: 'host:100',
        sources: both,
      );
      return container.read(_graceProvider.notifier);
    }

    test('暂时缺席又回来:选择不动、不跟随', () {
      FakeAsync().run((async) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final a = source('host:100', sessionId: 's-1');
        final b = source('host:200', sessionId: 's-9');
        final notifier = graceSetUp(container, [a, b]);

        notifier.handleSourcesChanged([b]); // a 缺席
        expect(notifier.state.selectedSourceId, 'host:100'); // 选择留住
        notifier.handleSourcesChanged([a, b]); // a 回来了
        async.elapse(const Duration(seconds: 5));
        expect(notifier.state.selectedSourceId, 'host:100');
        expect(notifier.follows, isEmpty);
        expect(notifier.selections, isEmpty);
      });
    });

    test('复核时源已回到权威列表:虚惊一场,不清选择不跟随', () {
      FakeAsync().run((async) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final a = source('host:100', sessionId: 's-1');
        final b = source('host:200', sessionId: 's-9');
        final notifier = graceSetUp(container, [a, b]);

        notifier.handleSourcesChanged([b]);
        notifier.refreshResult = [a, b]; // 权威重拉:a 还在
        async.elapse(const Duration(seconds: 3));
        expect(notifier.state.selectedSourceId, 'host:100');
        expect(notifier.follows, isEmpty);
      });
    });

    test('复核确认源没了:清选择并走跟随', () {
      FakeAsync().run((async) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final a = source('host:100', sessionId: 's-1');
        final b = source('host:200', sessionId: 's-9');
        final notifier = graceSetUp(container, [a, b]);

        notifier.handleSourcesChanged([b]);
        notifier.refreshResult = [b]; // 权威重拉:a 真没了
        async.elapse(const Duration(seconds: 3));
        expect(notifier.state.selectedSourceId, isNull); // 清了
        expect(notifier.follows, hasLength(1)); // 走了跟随
        expect(notifier.follows.single.map((s) => s.id), ['host:200']);
      });
    });

    test('自动换源写偏好的纪律:同会话才写,跨会话只是代打', () {
      expect(
        PiSessionNotifier.shouldPersistAutoSwitch(
          source('host:200', sessionId: 's-9'),
          's-1',
        ),
        isFalse,
      );
      expect(
        PiSessionNotifier.shouldPersistAutoSwitch(
          source('host:300', sessionId: 's-1'),
          's-1',
        ),
        isTrue,
      );
      expect(
        PiSessionNotifier.shouldPersistAutoSwitch(
          source('host:300', sessionId: 's-1'),
          null,
        ),
        isFalse,
      );
    });
  });
}

/// 失联宽限复核的测试假会话:不连网,跟随/选源/刷新全部记账,
/// 真逻辑(宽限定时器、清选择)走 PiSessionNotifier 本体。
///
/// Notifier.state 的读写必须挂在容器上,所以测试一律经 [_graceProvider] 取实例。
class _GraceSession extends PiSessionNotifier {
  _GraceSession() : super('dev');

  /// 容器构建实例前由测试塞入的初始状态(每个测试新建容器,静态字段够用)。
  static PiState nextInitial = PiState.initial();

  final List<(String, bool)> selections = [];
  final List<List<SourceInfo>> follows = [];
  List<SourceInfo> refreshResult = const [];

  @override
  PiState build() => nextInitial;

  @override
  Future<bool> selectSource(String sourceId, {bool persist = true}) async {
    selections.add((sourceId, persist));
    return true;
  }

  @override
  Future<void> followLiveDesktop(
    List<SourceInfo> sources,
    SourceInfo? previous,
  ) async {
    follows.add(sources);
  }

  @override
  Future<List<SourceInfo>> refreshSources() async => refreshResult;
}

final _graceProvider = NotifierProvider<_GraceSession, PiState>(
  _GraceSession.new,
);
