import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/state/stream_derivation.dart';

void main() {
  group('deriveStreaming', () {
    test('全部证据为假 → 不在生成', () {
      expect(
        deriveStreaming(
          snapshotStreaming: false,
          eventStreaming: false,
          hasOpenAssistantBubble: false,
          hasInFlightMessage: false,
        ),
        isFalse,
      );
    });

    test('快照说 false 但带 inFlightMessage → 仍算在生成', () {
      // 这正是"中途加入正在生成的会话"的场景:
      // 桌面快照是上一轮 agent_settled 时拍的,isStreaming 必然为 false。
      expect(
        deriveStreaming(
          snapshotStreaming: false,
          eventStreaming: false,
          hasOpenAssistantBubble: false,
          hasInFlightMessage: true,
        ),
        isTrue,
      );
    });

    test('有未完成的助手气泡 → 在生成', () {
      expect(
        deriveStreaming(
          snapshotStreaming: false,
          eventStreaming: false,
          hasOpenAssistantBubble: true,
          hasInFlightMessage: false,
        ),
        isTrue,
      );
    });

    test('agent_start 事件 → 在生成', () {
      expect(
        deriveStreaming(
          snapshotStreaming: false,
          eventStreaming: true,
          hasOpenAssistantBubble: false,
          hasInFlightMessage: false,
        ),
        isTrue,
      );
    });
  });

  group('undoTarget', () {
    test('取最后一条带 entryId 的用户消息', () {
      final items = <ChatItem>[
        UserItem('u1', text: '第一条', time: DateTime(2026))..entryId = 'e1',
        AssistantItem('a1')..complete = true,
        UserItem('u2', text: '第二条', time: DateTime(2026))..entryId = 'e2',
        AssistantItem('a2')..complete = true,
      ];
      expect(undoTarget(items), 'e2');
    });

    test('跳过没有 entryId 的用户消息', () {
      final items = <ChatItem>[
        UserItem('u1', text: '有 id', time: DateTime(2026))..entryId = 'e1',
        UserItem('u2', text: '无 id', time: DateTime(2026)),
      ];
      expect(undoTarget(items), 'e1');
    });

    test('没有用户消息 → null', () {
      final items = <ChatItem>[
        AssistantItem('a1')..complete = true,
        SystemItem('s1', text: 'x'),
      ];
      expect(undoTarget(items), isNull);
    });

    test('空列表 → null', () {
      expect(undoTarget(const []), isNull);
    });
  });
}
