import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';

/// 「消息列表突然清空」的回归测试。
///
/// 旧实现是「先清后拉」:增量失败就 _resetConversation(),全量再失败时
/// 空白列表直接被 emit,且这条路径不安排补货 —— 列表一直空到下次碰巧的
/// 重同步(严重时只能重启 App)。现在是 staged replacement:先拉到完整
/// entries 再替换;任何一步失败都保留现有列表并调度退避重试。
class _SyncSession extends PiSessionNotifier {
  _SyncSession() : super('dev');

  static PiState nextInitial = PiState.initial();

  @override
  PiState build() => nextInitial;

  /// 已发出的 get_entries:'full' 或 'since:<leaf>'。
  final List<String> requests = [];

  /// 兜底重试调度记录。
  final List<String> recoveryReasons = [];

  /// 脚本化响应:key 同 requests;缺 key 或队列空 = 请求失败(返回 null)。
  final Map<String, List<Map<String, dynamic>?>> scripted = {};

  @override
  Future<Map<String, dynamic>?> syncRequest(
    String type, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final key = extra['since'] is String ? 'since:${extra['since']}' : 'full';
    requests.add(key);
    final queue = scripted[key];
    if (queue == null || queue.isEmpty) return null;
    return queue.removeAt(0);
  }

  @override
  void scheduleSyncRecovery({required String reason}) {
    recoveryReasons.add(reason);
  }
}

final _syncProvider = NotifierProvider<_SyncSession, PiState>(_SyncSession.new);

UserItem _oldMessage() =>
    UserItem('user:1', text: '旧消息', time: DateTime.utc(2026, 8, 2, 12));

Map<String, dynamic> _entriesResponse(List<Map<String, dynamic>> entries) => {
  'success': true,
  'data': {'entries': entries, 'hasMore': false},
};

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

_SyncSession _setUp(ProviderContainer container) {
  // 必须在读 provider 之前塞好:读 .notifier 的那一刻 build() 就跑。
  _SyncSession.nextInitial = PiState.initial().copyWith(
    items: [_oldMessage()],
  );
  return container.read(_syncProvider.notifier);
}

void main() {
  group('同步拉取失败不再清空消息列表', () {
    test('全量拉取失败:保留旧消息并调度兜底重试', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _setUp(container);

      await notifier.debugSync(forceFull: true);

      expect(notifier.requests, ['full']);
      expect(notifier.state.items, hasLength(1));
      expect((notifier.state.items.single as UserItem).text, '旧消息');
      expect(notifier.recoveryReasons, ['entries-fetch-failed']);
    });

    test('增量失败+全量失败:保留旧消息', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _setUp(container);
      notifier.debugLeafId = 'e1';

      await notifier.debugSync();

      expect(notifier.requests, ['since:e1', 'full']);
      expect(notifier.state.items, hasLength(1));
      expect((notifier.state.items.single as UserItem).text, '旧消息');
      expect(notifier.recoveryReasons, ['entries-fetch-failed']);
    });

    test('拉取成功:替换为新内容', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _setUp(container);
      notifier.scripted['full'] = [
        _entriesResponse([
          _userEntry('e100', '2026-08-02T12:01:00.000Z', '新消息'),
        ]),
      ];

      await notifier.debugSync(forceFull: true);

      expect(notifier.recoveryReasons, isEmpty);
      expect(notifier.state.items, hasLength(1));
      expect((notifier.state.items.single as UserItem).text, '新消息');
    });

    test('重试恢复:失败后下一次同步成功替换', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = _setUp(container);

      await notifier.debugSync(forceFull: true); // 失败,保留旧消息
      expect((notifier.state.items.single as UserItem).text, '旧消息');
      expect(notifier.recoveryReasons, ['entries-fetch-failed']);

      // 兜底重试触发时链路已恢复 → 成功替换。
      notifier.scripted['full'] = [
        _entriesResponse([
          _userEntry('e100', '2026-08-02T12:02:00.000Z', '恢复后的消息'),
        ]),
      ];
      await notifier.debugSync(forceFull: true);

      expect(notifier.state.items, hasLength(1));
      expect((notifier.state.items.single as UserItem).text, '恢复后的消息');
    });
  });
}
