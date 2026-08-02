import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';

/// 「消息列表莫名其妙没了」的回归测试 —— hub v2 快照路径。
///
/// `_applyHubSnapshot` 原来是「先清空,再灌 entries」。快照没带 entries
/// (字段缺失被 `?? const []` 兜成空,或桥在会话切换间隙返回了空批)时,
/// 列表就被清成空白 —— 而且这条路径**自己不安排补货**,只能等下次碰巧
/// 触发同步,严重时一直空到重启 App。
///
/// `full-sync` 路径此前已按 staged replacement 加固过(见
/// sync_recovery_test.dart),但 hub v2 快照这条漏了,于是同一个症状换条
/// 路径又回来了。
///
/// 反向约束同样重要:**换会话时空快照必须照常清空**。那时候快照本就该是
/// 空的(真的没消息),保留旧列表会把上一个会话的消息留在界面上冒充新会话
/// 的内容 —— 那是更糟的 bug。
class _SnapshotSession extends PiSessionNotifier {
  _SnapshotSession() : super('dev');

  static PiState nextInitial = PiState.initial();

  @override
  PiState build() => nextInitial;

  /// 兜底重同步的调度记录。
  final List<String> resyncReasons = [];

  @override
  void scheduleSyncRecovery({required String reason}) {
    resyncReasons.add(reason);
  }
}

final _provider = NotifierProvider<_SnapshotSession, PiState>(
  _SnapshotSession.new,
);

Map<String, dynamic> _userEntry(String id, String ts, String text) => {
  'type': 'message',
  'id': id,
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'timestamp': ts,
  },
};

/// 建一个「已经在看某会话、本地有 2 条消息」的 notifier。
_SnapshotSession _seeded(ProviderContainer container, {String session = 's1'}) {
  _SnapshotSession.nextInitial = PiState.initial().copyWith(sessionId: session);
  final notifier = container.read(_provider.notifier);
  notifier.debugIngestEntry(
    _userEntry('e1', '2026-08-02T12:00:00.000Z', '第一条'),
  );
  notifier.debugIngestEntry(
    _userEntry('e2', '2026-08-02T12:01:00.000Z', '第二条'),
  );
  return notifier;
}

void main() {
  group('空快照不许清空消息列表', () {
    test('同一会话 + 快照 entries 为空:保留现有列表并调度重同步', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);
      expect(notifier.state.items, hasLength(2));

      // 桥返回了同一会话、但 entries 是空的快照。
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'entries': <dynamic>[],
      });

      expect(
        notifier.state.items,
        hasLength(2),
        reason: '空快照不能把已有消息清掉',
      );
      expect(notifier.resyncReasons, ['empty-snapshot']);
    });

    test('快照完全没有 entries 字段:同样保留', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);

      // 字段缺失 —— 原实现会被 `?? const []` 兜成空,然后清空列表。
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
      });

      expect(notifier.state.items, hasLength(2));
      expect(notifier.resyncReasons, ['empty-snapshot']);
    });

    test('换会话 + 空快照:必须照常清空,不能留着上一个会话的消息', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);
      expect(notifier.state.items, hasLength(2));

      // 切到另一个会话,那边确实没消息。
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's2'},
        'entries': <dynamic>[],
      });

      expect(
        notifier.state.items,
        isEmpty,
        reason: '换会话时保留旧列表 = 用上一个会话的消息冒充新会话内容',
      );
      expect(
        notifier.resyncReasons,
        isEmpty,
        reason: '换会话是正常清空,不该触发补货重试',
      );
    });

    test('本地本来就空 + 空快照:照常走清空路径,不刷无用重试', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        sessionId: 's1',
      );
      final notifier = container.read(_provider.notifier);
      expect(notifier.state.items, isEmpty);

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'entries': <dynamic>[],
      });

      expect(notifier.state.items, isEmpty);
      expect(
        notifier.resyncReasons,
        isEmpty,
        reason: '本来就没内容,没什么可保护的,不该排重试',
      );
    });

    test('非空快照:正常替换成新内容', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'entries': [_userEntry('e9', '2026-08-02T12:05:00.000Z', '快照里的消息')],
      });

      expect(notifier.state.items, hasLength(1));
      expect((notifier.state.items.single as UserItem).text, '快照里的消息');
      expect(notifier.resyncReasons, isEmpty);
    });

    test('对账式重同步(同会话、leaf 已在本地)不清空,也不受空快照守卫干扰', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);

      // reconcile + leafId 已在本地 → sameBranch 成立,就地对账补一条。
      notifier.debugApplyHubSnapshot(
        {
          'state': {'sessionId': 's1'},
          'leafId': 'e2',
          'entries': [
            _userEntry('e3', '2026-08-02T12:02:00.000Z', '增量来的第三条'),
          ],
        },
        reconcile: true,
      );

      expect(
        notifier.state.items,
        hasLength(3),
        reason: '对账应当在原有 2 条基础上补第 3 条,而不是重建',
      );
      expect(notifier.resyncReasons, isEmpty);
    });
  });

  group('清空历史后游标与 hasMoreHistory 必须同生同死', () {
    // 「突然加载不出来之前的消息了」的回归测试。
    //
    // _resetConversation 会把 _oldestEntryId(往前分页游标)清成 null,但它
    // 原来**完全不碰 state** —— 于是 state.hasMoreHistory 还停在 true。
    // 这两个值裂开就得到一个永久卡住的状态:
    //   - UI 看 hasMoreHistory 为真 → 一直显示「加载更早」那一行,还自动补货;
    //   - loadEarlierHistory() 第一行 `cursor == null` → 每次立刻 return false。
    // 结果「正在加载更早的消息…」一直转,上面的消息永远出不来。
    //
    // 现实触发路径:select-source / epoch-changed / branch-fallback 等清空后,
    // 若这次快照整份塞得进桥的字节预算(clipped.omitted == 0),桥就不下发
    // entriesHasMore/entriesOldestId,没有任何人把游标设回来。

    test('清空之后 hasMoreHistory 必须归零,不能留着 true 卡住 UI', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);

      // 前置:桥说过「还有更早的」。
      notifier.debugSetHasMoreHistory(true);
      expect(notifier.state.hasMoreHistory, isTrue);

      // 换会话 → 清空。
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's2'},
        'entries': <dynamic>[],
      });

      expect(notifier.state.items, isEmpty);
      expect(
        notifier.state.hasMoreHistory,
        isFalse,
        reason: '游标已作废,hasMoreHistory 留 true 会让「加载更早」永远转圈',
      );
    });

    test('卡住状态不再出现:清空后 loadEarlierHistory 不该被 UI 反复空转', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);
      notifier.debugSetHasMoreHistory(true);

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's2'},
        'entries': <dynamic>[],
      });

      // hasMoreHistory 已归零 → UI 不会显示「加载更早」,也不会自动补货。
      expect(notifier.state.hasMoreHistory, isFalse);
      // 真去调也只是干净地返回 false,不会把 loadingEarlier 卡在 true。
      final ok = await notifier.loadEarlierHistory();
      expect(ok, isFalse);
      expect(
        notifier.state.loadingEarlier,
        isFalse,
        reason: 'loadingEarlier 卡在 true 就是那个一直转的圈',
      );
    });

    test('清空也要顺手清 loadingEarlier —— 加载中途被清空不能留下转圈状态', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);
      notifier.debugSetLoadingEarlier(true);

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's2'},
        'entries': <dynamic>[],
      });

      expect(notifier.state.loadingEarlier, isFalse);
    });

    test('清空后快照带 entriesHasMore:游标与标志一起回来,历史可以继续往前翻', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);

      // 换会话清空,随后桥告知「这次只发了尾巴,更早的还在桥上」。
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's2'},
        'entries': [_userEntry('e50', '2026-08-02T13:00:00.000Z', '新会话最后一条')],
      });
      expect(notifier.state.hasMoreHistory, isFalse);

      // 这一步模拟 _syncSelectedSource 里 entriesHasMore 分支做的事。
      notifier.debugSetEarlierCursor('e50', hasMore: true);

      expect(notifier.state.hasMoreHistory, isTrue);
      expect(
        notifier.debugOldestEntryId,
        'e50',
        reason: '标志为真时游标必须同时存在,否则又是卡住状态',
      );
    });
  });
}
