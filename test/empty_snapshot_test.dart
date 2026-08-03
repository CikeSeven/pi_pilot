import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// 脚本化向前分页响应。
  final List<Map<String, dynamic>?> historyResponses = [];
  final List<Map<String, dynamic>> historyRequests = [];

  @override
  Future<Map<String, dynamic>?> syncRequest(
    String type, [
    Map<String, dynamic> extra = const {},
  ]) async {
    if (type != 'get_entries' || !extra.containsKey('before')) {
      return super.syncRequest(type, extra);
    }
    historyRequests.add(Map<String, dynamic>.from(extra));
    return historyResponses.isEmpty ? null : historyResponses.removeAt(0);
  }

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

class _HubSyncSession extends PiSessionNotifier {
  _HubSyncSession() : super('dev');

  static PiState nextInitial = PiState.initial();

  @override
  PiState build() => nextInitial;

  final List<Map<String, dynamic>> requests = [];
  final List<Future<Map<String, dynamic>?> Function(Map<String, dynamic>)>
  handlers = [];
  ({String? anchor, List<Map<String, dynamic>> entries}) rebaseSeed = (
    anchor: null,
    entries: const <Map<String, dynamic>>[],
  );
  final List<Map<String, dynamic>> entryRequests = [];
  final List<Future<Map<String, dynamic>?> Function(Map<String, dynamic>)>
  entryHandlers = [];

  @override
  Future<({String? anchor, List<Map<String, dynamic>> entries})>
  loadRebaseSeedForSync() async => rebaseSeed;

  @override
  Future<Map<String, dynamic>?> syncRequest(
    String type, [
    Map<String, dynamic> extra = const {},
  ]) {
    if (type != 'get_entries') return super.syncRequest(type, extra);
    entryRequests.add(Map<String, dynamic>.from(extra));
    if (entryHandlers.isEmpty) return Future.value(null);
    return entryHandlers.removeAt(0)(extra);
  }

  @override
  Future<Map<String, dynamic>?> hubSyncRequest(Map<String, dynamic> extra) {
    requests.add(Map<String, dynamic>.from(extra));
    if (handlers.isEmpty) return Future.value(null);
    return handlers.removeAt(0)(extra);
  }

  @override
  bool get isSyncTransportOpen => true;
}

final _hubProvider = NotifierProvider<_HubSyncSession, PiState>(
  _HubSyncSession.new,
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

Map<String, dynamic> _assistantToolEntry(
  String id,
  String ts,
  String callId,
  String name,
) => {
  'type': 'message',
  'id': id,
  'message': {
    'role': 'assistant',
    'content': [
      {
        'type': 'toolCall',
        'id': callId,
        'name': name,
        'arguments': {'claim': 'review'},
      },
    ],
    'timestamp': ts,
  },
};

Map<String, dynamic> _toolResultEntry(
  String id,
  String ts,
  String callId,
  String text,
) => {
  'type': 'message',
  'id': id,
  'message': {
    'role': 'toolResult',
    'toolCallId': callId,
    'content': [
      {'type': 'text', 'text': text},
    ],
    'timestamp': ts,
  },
};

Map<String, dynamic> _snapshotResponse({
  required List<Map<String, dynamic>> entries,
  required String leafId,
  int baseSeq = 1,
  bool entriesHasMore = false,
  String? entriesOldestId,
}) => {
  'success': true,
  'data': {
    'mode': 'snapshot',
    'continuous': true,
    'events': <dynamic>[],
    'snapshot': {
      'epoch': 'epoch-1',
      'baseSeq': baseSeq,
      'state': {'sessionId': 's1'},
      'leafId': leafId,
      'entries': entries,
    },
    if (entriesHasMore) 'entriesHasMore': true,
    'entriesOldestId': ?entriesOldestId,
  },
};

Map<String, dynamic> _replayResponse() => {
  'success': true,
  'data': {'mode': 'replay', 'continuous': true, 'events': <dynamic>[]},
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

      expect(notifier.state.items, hasLength(2), reason: '空快照不能把已有消息清掉');
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
      expect(notifier.resyncReasons, isEmpty, reason: '换会话是正常清空,不该触发补货重试');
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
      expect(notifier.resyncReasons, isEmpty, reason: '本来就没内容,没什么可保护的,不该排重试');
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
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'leafId': 'e2',
        'entries': [_userEntry('e3', '2026-08-02T12:02:00.000Z', '增量来的第三条')],
      }, reconcile: true);

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
  group('替换事务的原子性:绝不发布半成品列表', () {
    // 这一组钉的是**发布序列**,不是最终状态。
    //
    // 事故现场:同源重连清掉 365 条内部条目之后、快照灌回之前,只要有一个
    // 流式 token 到达就会 _emit() 出一个只含当前 assistant 的列表。真机
    // 症状是「所有消息全没了,只剩正在生成的那一条,还一直在生成中」,而且
    // **不会再多打一条清空日志** —— 取证时极容易误判成「清空后没填回来」。
    //
    // 只断言最终 items 长度抓不到这个 bug:最终态往往是对的,错的是中间那
    // 一帧。所以这里断言整个发布序列里不出现 0 / 1 这种残缺长度。

    test('空快照守卫路径:发布序列里不出现残缺长度', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);
      final before = notifier.debugEmittedLengths.length;

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'entries': <dynamic>[],
      });

      final emitted = notifier.debugEmittedLengths.skip(before).toList();
      expect(emitted, isNotEmpty, reason: '守卫路径应当发布一次(状态可能有更新)');
      expect(
        emitted.where((n) => n < 2),
        isEmpty,
        reason: '本地有 2 条,任何一次发布都不该少于 2 —— 少了就是半成品泄漏出去了',
      );
    });

    test('清空窗口撞上流式 token:不能发布出「只剩正在生成的那一条」', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);

      // 同一会话的对账式快照:sameBranch 成立 → 不清空,就地补齐。
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'leafId': 'e2',
        'entries': [_userEntry('e3', '2026-08-02T12:02:00.000Z', '第三条')],
      }, reconcile: true);
      final before = notifier.debugEmittedLengths.length;

      // 流式 token 到达。
      notifier.debugMessageUpdate(
        timestamp: '2026-08-02T12:03:00.000Z',
        text: '正在生成',
      );

      final emitted = notifier.debugEmittedLengths.skip(before).toList();
      expect(
        emitted.where((n) => n <= 1),
        isEmpty,
        reason: '历史还在,流式发布不该出现长度 0/1',
      );
      expect(notifier.state.items.length, greaterThanOrEqualTo(3));
    });

    test('对账快照保留既有游标 —— 补齐尾部不该抹掉往前翻的能力', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);
      notifier.debugSetEarlierCursor('e1', hasMore: true);

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'leafId': 'e2',
        'entries': [_userEntry('e3', '2026-08-02T12:02:00.000Z', '第三条')],
      }, reconcile: true);

      expect(notifier.debugOldestEntryId, 'e1', reason: '对账只是补尾部,既有游标必须留住');
      expect(notifier.state.hasMoreHistory, isTrue);
    });

    test('重建时桥给了权威元数据:游标与标志成对落地', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);

      // 换会话重建,桥说「只发了尾巴,更早的还在会话文件里」。
      notifier.debugApplyHubSnapshot(
        {
          'state': {'sessionId': 's2'},
          'entries': [_userEntry('e90', '2026-08-02T13:00:00.000Z', '新会话尾巴')],
        },
        entriesHasMore: true,
        entriesOldestId: 'e90',
      );

      expect(notifier.state.hasMoreHistory, isTrue);
      expect(notifier.debugOldestEntryId, 'e90');
    });

    test('重建时桥没给元数据:标志为假,不留下转圈状态', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _seeded(container);
      notifier.debugSetEarlierCursor('e1', hasMore: true);

      // 换会话重建,且桥这次整份都塞得进预算(不下发 entriesHasMore)。
      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's2'},
        'entries': [_userEntry('e90', '2026-08-02T13:00:00.000Z', '新会话尾巴')],
      });

      // 标志必须为假:游标已随清空作废,留着 true 就是永久转圈。
      expect(notifier.state.hasMoreHistory, isFalse);
      expect(notifier.state.loadingEarlier, isFalse);
    });
  });

  group('历史基线与重同步竞争', () {
    test('强制快照在途时 announce 只排队,不能用空 replay 作废快照', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _HubSyncSession.nextInitial = PiState.initial().copyWith(
        hubId: 'hub-1',
        selectedSourceId: 'desktop:1',
        sourceEpoch: 'epoch-1',
        sessionId: 's1',
      );
      final notifier = container.read(_hubProvider.notifier)
        ..debugEnableHubV2();
      final snapshot = Completer<Map<String, dynamic>?>();
      notifier.handlers
        ..add((_) => snapshot.future)
        ..add((_) async => _replayResponse());

      final initialSync = notifier.debugSyncSelectedSource(forceFull: true);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.requests, hasLength(1));
      expect(notifier.requests.single, isNot(contains('cursor')));

      notifier.debugScheduleSourceResync(reason: 'announce');
      await Future<void>.delayed(Duration.zero);
      expect(
        notifier.requests,
        hasLength(1),
        reason: 'announce 不得另起 generation 抢占正在建立历史的快照',
      );

      snapshot.complete(
        _snapshotResponse(
          entries: [
            _userEntry('e1', '2026-08-03T15:28:00.000Z', 'advisor 之前的历史'),
            _userEntry('e2', '2026-08-03T15:29:00.000Z', '当前消息'),
          ],
          leafId: 'e2',
          baseSeq: 10,
        ),
      );
      await initialSync;
      expect(notifier.debugConversationHydrated, isTrue);
      expect(notifier.state.items, hasLength(2));

      // 排队的 announce 会在快照落地后做一次普通 replay 对账。
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(notifier.requests, hasLength(2));
      expect(notifier.requests.last, contains('cursor'));
      expect(
        notifier.state.items.whereType<UserItem>().map((item) => item.text),
        containsAll(['advisor 之前的历史', '当前消息']),
      );
    });

    test('慢速 rebase 完成前 announce 不能启动竞争同步', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _HubSyncSession.nextInitial = PiState.initial().copyWith(
        hubId: 'hub-1',
        selectedSourceId: 'desktop:1',
        sourceEpoch: 'epoch-1',
        sessionId: 's1',
      );
      final notifier = container.read(_hubProvider.notifier)
        ..debugEnableHubV2();
      notifier.rebaseSeed = (
        anchor: 'e4',
        entries: [
          _assistantToolEntry(
            'e1',
            '2026-08-03T15:20:00.000Z',
            'advisor-rebase',
            'advisor',
          ),
          _toolResultEntry(
            'e2',
            '2026-08-03T15:20:01.000Z',
            'advisor-rebase',
            '慢链路审查结论',
          ),
          _userEntry('e3', '2026-08-03T15:21:00.000Z', '缓存历史'),
          _userEntry('e4', '2026-08-03T15:22:00.000Z', 'rebase 锚点'),
        ],
      );
      final rebasePage = Completer<Map<String, dynamic>?>();
      notifier.handlers
        ..add(
          (_) async => _snapshotResponse(
            entries: [
              _userEntry('e5', '2026-08-03T15:23:00.000Z', '裁剪窗口'),
              _userEntry('e6', '2026-08-03T15:24:00.000Z', '当前 leaf'),
            ],
            leafId: 'e6',
            baseSeq: 20,
            entriesHasMore: true,
            entriesOldestId: 'e5',
          ),
        )
        ..add((_) async => _replayResponse());
      notifier.entryHandlers.add((_) => rebasePage.future);

      final sync = notifier.debugSyncSelectedSource();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.requests, hasLength(1));
      expect(notifier.entryRequests, hasLength(1));
      expect(notifier.entryRequests.single['since'], 'e4');

      notifier.debugScheduleSourceResync(reason: 'announce');
      await Future<void>.delayed(Duration.zero);
      expect(
        notifier.requests,
        hasLength(1),
        reason: 'rebase 仍在补历史时不得启动第二个 hub_sync',
      );

      rebasePage.complete({
        'success': true,
        'data': {
          'entries': [
            _userEntry('e5', '2026-08-03T15:23:00.000Z', '裁剪窗口'),
            _userEntry('e6', '2026-08-03T15:24:00.000Z', '当前 leaf'),
          ],
          'tipId': 'e6',
          'nextSinceId': 'e6',
          'hasMore': false,
        },
      });
      await sync;

      expect(notifier.debugConversationHydrated, isTrue);
      expect(notifier.debugLeafId, 'e6');
      final advisor = notifier.state.items.whereType<ToolItem>().singleWhere(
        (item) => item.name == 'advisor',
      );
      expect(advisor.output, '慢链路审查结论');
      expect(
        notifier.state.items.whereType<UserItem>().map((item) => item.text),
        containsAll(['缓存历史', 'rebase 锚点', '裁剪窗口', '当前 leaf']),
      );

      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(notifier.requests, hasLength(2));
      expect(notifier.requests.last, contains('cursor'));
    });

    test('未建立历史基线时即使有持久化 cursor 也必须请求快照', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hub.cursor:hub-1:desktop:1': jsonEncode({
          'hubId': 'hub-1',
          'sourceId': 'desktop:1',
          'sourceEpoch': 'epoch-1',
          'seq': 99,
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _HubSyncSession.nextInitial = PiState.initial().copyWith(
        hubId: 'hub-1',
        selectedSourceId: 'desktop:1',
        sourceEpoch: 'epoch-1',
        sessionId: 's1',
      );
      final notifier = container.read(_hubProvider.notifier)
        ..debugEnableHubV2();
      notifier.handlers.add(
        (_) async => _snapshotResponse(
          entries: [_userEntry('e1', '2026-08-03T15:28:00.000Z', '权威历史')],
          leafId: 'e1',
          baseSeq: 100,
        ),
      );

      await notifier.debugSyncSelectedSource();

      expect(notifier.requests.single, isNot(contains('cursor')));
      expect(notifier.debugConversationHydrated, isTrue);
      expect((notifier.state.items.single as UserItem).text, '权威历史');
    });
  });

  group('分页历史不能被后续快照裁掉', () {
    test('同分支裁剪快照保留已加载的 advisor 工具消息并追加新尾部', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        sessionId: 's1',
      );
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'leafId': 'e4',
        'entries': [
          _assistantToolEntry(
            'e1',
            '2026-08-03T15:20:00.000Z',
            'advisor-1',
            'advisor',
          ),
          _toolResultEntry(
            'e2',
            '2026-08-03T15:20:01.000Z',
            'advisor-1',
            '关键审查结论',
          ),
          _userEntry('e3', '2026-08-03T15:21:00.000Z', '旧消息'),
          _userEntry('e4', '2026-08-03T15:22:00.000Z', '原 leaf'),
        ],
      });
      notifier.debugSetEarlierCursor('e1', hasMore: false);

      notifier.debugApplyHubSnapshot(
        {
          'state': {'sessionId': 's1'},
          'leafId': 'e5',
          'entries': [
            _userEntry('e4', '2026-08-03T15:22:00.000Z', '原 leaf'),
            _userEntry('e5', '2026-08-03T15:23:00.000Z', '新尾部'),
          ],
        },
        reconcile: true,
        entriesHasMore: true,
        entriesOldestId: 'e4',
      );

      final advisor = notifier.state.items.whereType<ToolItem>().singleWhere(
        (item) => item.name == 'advisor',
      );
      expect(advisor.output, '关键审查结论');
      expect(
        notifier.state.items.whereType<UserItem>().map((item) => item.text),
        containsAll(['旧消息', '原 leaf', '新尾部']),
      );
      expect(
        notifier.state.hasMoreHistory,
        isFalse,
        reason: '客户端已翻到历史尽头，裁剪快照不能把加载槽重新打开',
      );
      expect(notifier.debugOldestEntryId, 'e1');
      expect(notifier.debugLeafId, 'e5');
    });

    test('回退快照不含原 leaf 时仍会重建并删除旧分支后缀', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        sessionId: 's1',
      );
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'leafId': 'e3',
        'entries': [
          _userEntry('e1', '2026-08-03T15:20:00.000Z', '保留一'),
          _userEntry('e2', '2026-08-03T15:21:00.000Z', '保留二'),
          _userEntry('e3', '2026-08-03T15:22:00.000Z', '应删除的旧后缀'),
        ],
      });

      notifier.debugApplyHubSnapshot({
        'state': {'sessionId': 's1'},
        'leafId': 'e2',
        'entries': [
          _userEntry('e1', '2026-08-03T15:20:00.000Z', '保留一'),
          _userEntry('e2', '2026-08-03T15:21:00.000Z', '保留二'),
        ],
      }, reconcile: true);

      expect(
        notifier.state.items.whereType<UserItem>().map((item) => item.text),
        ['保留一', '保留二'],
      );
      expect(notifier.debugLeafId, 'e2');
    });

    test('向前分页只移动 oldest cursor,不会把当前 leaf 倒退到旧消息', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        sessionId: 's1',
      );
      final notifier = container.read(_provider.notifier);
      notifier.debugApplyHubSnapshot(
        {
          'state': {'sessionId': 's1'},
          'leafId': 'e4',
          'entries': [
            _userEntry('e3', '2026-08-03T15:22:00.000Z', '较新三'),
            _userEntry('e4', '2026-08-03T15:23:00.000Z', '当前 leaf'),
          ],
        },
        entriesHasMore: true,
        entriesOldestId: 'e3',
      );
      notifier.historyResponses.add({
        'success': true,
        'data': {
          'entries': [
            _userEntry('e1', '2026-08-03T15:20:00.000Z', '更早一'),
            _userEntry('e2', '2026-08-03T15:21:00.000Z', '更早二'),
          ],
          'oldestId': 'e1',
          'hasMore': false,
        },
      });

      expect(await notifier.loadEarlierHistory(), isTrue);
      expect(notifier.debugLeafId, 'e4');
      expect(notifier.debugOldestEntryId, 'e1');
      expect(notifier.state.hasMoreHistory, isFalse);
      expect(
        notifier.state.items.whereType<UserItem>().map((item) => item.text),
        ['更早一', '更早二', '较新三', '当前 leaf'],
      );
    });

    test('分页失败保留游标和加载入口并安排恢复', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        sessionId: 's1',
      );
      final notifier = container.read(_provider.notifier);
      notifier.debugApplyHubSnapshot(
        {
          'state': {'sessionId': 's1'},
          'leafId': 'e4',
          'entries': [
            _userEntry('e3', '2026-08-03T15:22:00.000Z', '较新三'),
            _userEntry('e4', '2026-08-03T15:23:00.000Z', '当前 leaf'),
          ],
        },
        entriesHasMore: true,
        entriesOldestId: 'e3',
      );
      notifier.historyResponses.add(null);

      expect(await notifier.loadEarlierHistory(), isFalse);
      expect(notifier.state.loadingEarlier, isFalse);
      expect(notifier.state.hasMoreHistory, isTrue);
      expect(notifier.debugOldestEntryId, 'e3');
      expect(notifier.resyncReasons, ['history-page-failed']);
    });
  });

  group('压缩状态必须可恢复且防倒灌', () {
    test('旧快照提示不能把已经结束的压缩重新盖回 true', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        selectedSourceId: 'desktop:1',
        sourceEpoch: 'epoch-1',
        lastSourceSeq: 10,
      );
      final notifier = container.read(_provider.notifier);

      notifier.debugApplySourceSnapshotAnnouncement({
        'type': 'hub_source_snapshot',
        'sourceId': 'desktop:1',
        'epoch': 'epoch-1',
        'baseSeq': 9,
        'isCompacting': true,
      });

      expect(notifier.state.isCompacting, isFalse);
      expect(notifier.resyncReasons, isEmpty);
    });

    test('同序号快照提示可以恢复漏掉的压缩开始状态', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        selectedSourceId: 'desktop:1',
        sourceEpoch: 'epoch-1',
        lastSourceSeq: 10,
      );
      final notifier = container.read(_provider.notifier);

      notifier.debugApplySourceSnapshotAnnouncement({
        'type': 'hub_source_snapshot',
        'sourceId': 'desktop:1',
        'epoch': 'epoch-1',
        'baseSeq': 10,
        'isCompacting': true,
      });

      expect(notifier.state.isCompacting, isTrue);
    });

    test('agent_start → end → settled 只记一次明确完成', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({'type': 'agent_start'});
      notifier.debugApplyPiEvent({'type': 'agent_end'});
      notifier.debugApplyPiEvent({'type': 'agent_settled'});

      expect(notifier.state.taskCompletionTick, 1);
      expect(notifier.state.isStreaming, isFalse);
    });

    test('没有配对 agent_start 的状态收口不冒充任务完成', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        isStreaming: true,
      );
      final notifier = container.read(_provider.notifier);

      // 这模拟切源/回退或断线重建后残留的 UI 布尔状态。settled 和 pi_exit
      // 可以收口显示，但都不能制造 completion tick。
      notifier.debugApplyPiEvent({'type': 'agent_settled'});
      notifier.debugApplyPiEvent({'type': 'bridge_pi_exit', 'code': 0});

      expect(notifier.state.taskCompletionTick, 0);
      expect(notifier.state.isStreaming, isFalse);
    });

    test('回退重建不推进完成 tick', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        taskCompletionTick: 3,
      );
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({'type': 'session_tree', 'leafId': 'older'});

      expect(notifier.state.taskCompletionTick, 3);
    });

    test('agent_settled 清掉漏收 compaction_end 后残留的压缩态', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        isCompacting: true,
      );
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({'type': 'agent_settled'});

      expect(notifier.state.isCompacting, isFalse);
    });

    test('压缩中断与失败分别给出准确收口提示', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({'type': 'compaction_start'});
      notifier.debugApplyPiEvent({'type': 'compaction_end', 'aborted': true});
      expect(notifier.state.isCompacting, isFalse);
      expect((notifier.state.items.last as SystemItem).text, '上下文压缩已中断');

      notifier.debugApplyPiEvent({'type': 'compaction_start'});
      notifier.debugApplyPiEvent({
        'type': 'compaction_end',
        'errorMessage': 'summary failed',
      });
      expect(notifier.state.isCompacting, isFalse);
      expect(
        (notifier.state.items.last as SystemItem).text,
        '上下文压缩失败:summary failed',
      );
      expect((notifier.state.items.last as SystemItem).kind, SystemKind.error);
    });
  });

  group('完成通知边界:中断与自动重试不冒充完成', () {
    test('用户中断的 agent_end 收口但不推进完成 tick', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({'type': 'agent_start'});
      notifier.debugApplyPiEvent({'type': 'agent_end', 'aborted': true});
      // settled 紧随:中断的轮次已收口,settled 也不能再补 tick。
      notifier.debugApplyPiEvent({'type': 'agent_settled'});

      expect(notifier.state.taskCompletionTick, 0);
      expect(notifier.state.isStreaming, isFalse);
    });

    test('willRetry 的 agent_end 不收口,重试后的最终结束才记完成', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({'type': 'agent_start'});
      notifier.debugApplyPiEvent({'type': 'agent_end', 'willRetry': true});
      // API 报错后电脑端会自动重试:流式状态必须保持,tick 不动。
      expect(notifier.state.taskCompletionTick, 0);
      expect(notifier.state.isStreaming, isTrue);

      // 重试:新的 agent_start 是幂等的,最终 agent_end 才收口。
      notifier.debugApplyPiEvent({'type': 'agent_start'});
      notifier.debugApplyPiEvent({'type': 'agent_end'});
      notifier.debugApplyPiEvent({'type': 'agent_settled'});

      expect(notifier.state.taskCompletionTick, 1);
      expect(notifier.state.isStreaming, isFalse);
    });

    test('后台会话中断翻空不记 backgroundFinishTick', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial().copyWith(
        selectedSourceId: 'desktop:1',
        sessions: const [
          HubSession(
            sessionId: 'sess-2',
            sourceId: 'headless:2',
            liveness: SessionLiveness.headless,
            connected: true,
            streaming: true,
          ),
        ],
      );
      final notifier = container.read(_provider.notifier);

      // 中断翻空:bridge 在会话帧上带了 lastEndAborted,不是「跑完了」。
      notifier.debugApplySessionsChanged([
        {
          'sessionId': 'sess-2',
          'sourceId': 'headless:2',
          'liveness': 'headless',
          'connected': true,
          'streaming': false,
          'lastEndAborted': true,
        },
      ]);
      expect(notifier.state.backgroundFinishTick, 0);

      // 对照:正常结束(无 aborted 标记)要记一笔。
      notifier.debugApplySessionsChanged([
        {
          'sessionId': 'sess-2',
          'sourceId': 'headless:2',
          'liveness': 'headless',
          'connected': true,
          'streaming': true,
        },
      ]);
      notifier.debugApplySessionsChanged([
        {
          'sessionId': 'sess-2',
          'sourceId': 'headless:2',
          'liveness': 'headless',
          'connected': true,
          'streaming': false,
        },
      ]);
      expect(notifier.state.backgroundFinishTick, 1);
    });
  });

  group('错误提示带具体内容', () {
    test('message_end 的 errorMessage 显示在错误提示里', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({
        'type': 'message_start',
        'message': {'role': 'assistant', 'timestamp': 1000, 'content': []},
      });
      notifier.debugApplyPiEvent({
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'timestamp': 1000,
          'content': [],
          'stopReason': 'error',
          'errorMessage': '429 rate limit exceeded',
        },
      });

      final errors = notifier.state.items.whereType<SystemItem>().where(
            (i) => i.kind == SystemKind.error,
          );
      expect(errors.length, 1);
      expect(errors.single.text, contains('429 rate limit exceeded'));
      expect(errors.single.text, contains('出错'));
    });

    test('流式 error delta 的 errorMessage 也能显示', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({
        'type': 'message_start',
        'message': {'role': 'assistant', 'timestamp': 1000, 'content': []},
      });
      notifier.debugApplyPiEvent({
        'type': 'message_update',
        'message': {'role': 'assistant', 'timestamp': 1000, 'content': []},
        'assistantMessageEvent': {
          'type': 'error',
          'reason': 'error',
          'error': {'errorMessage': 'connection reset by peer'},
        },
      });

      final errors = notifier.state.items.whereType<SystemItem>().where(
            (i) => i.kind == SystemKind.error,
          );
      expect(errors.length, 1);
      expect(errors.single.text, contains('connection reset by peer'));
    });

    test('delta 先到没详情时,message_end 原位升级而不是追加第二条', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({
        'type': 'message_start',
        'message': {'role': 'assistant', 'timestamp': 1000, 'content': []},
      });
      // 旧版 pi 的 error delta 不带 error 消息体:先出无详情提示。
      notifier.debugApplyPiEvent({
        'type': 'message_update',
        'message': {'role': 'assistant', 'timestamp': 1000, 'content': []},
        'assistantMessageEvent': {'type': 'error', 'reason': 'error'},
      });
      notifier.debugApplyPiEvent({
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'timestamp': 1000,
          'content': [],
          'stopReason': 'error',
          'errorMessage': 'model overloaded',
        },
      });

      final errors = notifier.state.items.whereType<SystemItem>().where(
            (i) => i.kind == SystemKind.error,
          );
      expect(errors.length, 1, reason: '升级不是追加,仍只有一条提示');
      expect(errors.single.text, contains('model overloaded'));
    });

    test('中断是用户主动行为,不附错误详情', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _SnapshotSession.nextInitial = PiState.initial();
      final notifier = container.read(_provider.notifier);

      notifier.debugApplyPiEvent({
        'type': 'message_start',
        'message': {'role': 'assistant', 'timestamp': 1000, 'content': []},
      });
      notifier.debugApplyPiEvent({
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'timestamp': 1000,
          'content': [],
          'stopReason': 'aborted',
          'errorMessage': 'Request was aborted',
        },
      });

      final errors = notifier.state.items.whereType<SystemItem>().where(
            (i) => i.kind == SystemKind.error,
          );
      expect(errors.length, 1);
      expect(errors.single.text, '助手响应已中断(无输出)');
    });
  });
}
