import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/message_timestamp.dart';

void main() {
  group('shouldShowTimestamp', () {
    test('首条带时间的消息显示', () {
      expect(shouldShowTimestamp(null, DateTime(2026, 1, 1)), isTrue);
    });

    test('5 分钟内不显示', () {
      final base = DateTime(2026, 1, 1, 10);
      expect(
        shouldShowTimestamp(base, base.add(const Duration(minutes: 4))),
        isFalse,
      );
    });

    test('超过 5 分钟显示', () {
      final base = DateTime(2026, 1, 1, 10);
      expect(
        shouldShowTimestamp(base, base.add(const Duration(minutes: 6))),
        isTrue,
      );
    });

    test('无时间的项不显示', () {
      expect(shouldShowTimestamp(DateTime(2026), null), isFalse);
    });
  });

  test('timeOf 只对用户/助手项返回时间', () {
    final time = DateTime(2026, 1, 1);
    expect(timeOf(UserItem('u', text: 'x', time: time)), time);
    expect(timeOf(AssistantItem('a')..time = time), time);
    expect(timeOf(ToolItem('t', toolCallId: '1', name: 'read')), isNull);
    expect(timeOf(SystemItem('s', text: 'x')), isNull);
  });

  test('格式化', () {
    final time = DateTime(2026, 3, 5, 9, 7, 3);
    expect(formatTimeShort(time), '09:07');
    expect(formatTimeFull(time), '2026-03-05 09:07:03');
  });
}
