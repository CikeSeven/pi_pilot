import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/chat_body.dart';

/// 消息列表只渲染尾部窗口 —— 这是消除会话切换卡顿的关键。
///
/// `RenderSliverList` 要求子项在布局上连续,没法跳过中间项直接量最后一项的位置,
/// 所以 `jumpTo(maxScrollExtent)` 会在一帧里把从头到底的所有项全建出来。
/// 窗口化之后无论会话多长,首帧只建窗口内那些条。
///
/// 这里的下标换算(完整列表下标 ↔ 列表槽位)一旦算错就会**渲染错消息**,
/// 所以逐个边界都要钉住。
void main() {
  group('短会话:装得下,不出现「加载更早」', () {
    test('总数小于窗口', () {
      final w = ChatWindow.of(
        total: 10,
        windowSize: 60,
        hasPendingUiRequest: false,
      );
      expect(w.offset, 0);
      expect(w.hasEarlier, isFalse);
      expect(w.visibleCount, 10);
      expect(w.itemCount, 10);
    });

    test('总数正好等于窗口:仍然不该出现按钮', () {
      final w = ChatWindow.of(
        total: 60,
        windowSize: 60,
        hasPendingUiRequest: false,
      );
      expect(w.offset, 0);
      expect(w.hasEarlier, isFalse);
      expect(w.itemCount, 60);
    });

    test('空列表', () {
      final w = ChatWindow.of(
        total: 0,
        windowSize: 60,
        hasPendingUiRequest: false,
      );
      expect(w.offset, 0);
      expect(w.hasEarlier, isFalse);
      expect(w.itemCount, 0);
    });
  });

  group('长会话:只渲染尾部', () {
    final w = ChatWindow.of(
      total: 2000,
      windowSize: 60,
      hasPendingUiRequest: false,
    );

    test('窗口锚在末尾,而不是开头', () {
      expect(w.offset, 1940);
      expect(w.visibleCount, 60);
      // 60 条消息 + 1 个「加载更早」按钮
      expect(w.itemCount, 61);
      expect(w.hasEarlier, isTrue);
    });

    test('槽位 0 是「加载更早」,不是消息', () {
      expect(w.isLoadEarlierSlot(0), isTrue);
      expect(w.isLoadEarlierSlot(1), isFalse);
    });

    test('按钮之后的槽位依次对应窗口内的消息', () {
      // 槽位 1 是窗口第一条,即完整列表的 1940
      expect(w.itemIndexOf(1), 1940);
      // 最后一个槽位是完整列表的最后一条
      expect(w.itemIndexOf(w.itemCount - 1), 1999);
    });

    test('完整列表下标换回槽位:与 itemIndexOf 互为逆运算', () {
      for (final index in [1940, 1941, 1970, 1999]) {
        expect(w.itemIndexOf(w.slotOf(index)!), index);
      }
    });

    test('窗口之外的下标没有槽位', () {
      expect(w.slotOf(1939), isNull);
      expect(w.slotOf(0), isNull);
      // 越界也不能返回槽位,否则 ListView 会拿到不存在的位置
      expect(w.slotOf(2000), isNull);
    });
  });

  group('待应答的扩展对话框占列表最后一个槽位', () {
    test('长会话:按钮 + 消息 + 对话框', () {
      final w = ChatWindow.of(
        total: 2000,
        windowSize: 60,
        hasPendingUiRequest: true,
      );
      expect(w.itemCount, 62);
      // 最后一个槽位是对话框,不是消息
      expect(w.isPendingRequestSlot(61), isTrue);
      expect(w.isPendingRequestSlot(60), isFalse);
      // 倒数第二个槽位仍是最后一条消息
      expect(w.itemIndexOf(60), 1999);
    });

    test('短会话:没有按钮,对话框直接跟在消息后面', () {
      final w = ChatWindow.of(
        total: 3,
        windowSize: 60,
        hasPendingUiRequest: true,
      );
      expect(w.itemCount, 4);
      expect(w.isLoadEarlierSlot(0), isFalse);
      expect(w.itemIndexOf(0), 0);
      expect(w.itemIndexOf(2), 2);
      expect(w.isPendingRequestSlot(3), isTrue);
    });

    test('没有对话框时,最后一个槽位不该被误判', () {
      final w = ChatWindow.of(
        total: 3,
        windowSize: 60,
        hasPendingUiRequest: false,
      );
      expect(w.isPendingRequestSlot(3), isFalse);
      expect(w.isPendingRequestSlot(2), isFalse);
    });
  });

  group('「加载更早」逐段扩窗', () {
    test('窗口变大后 offset 前移,剩余条数相应减少', () {
      final first = ChatWindow.of(
        total: 200,
        windowSize: 60,
        hasPendingUiRequest: false,
      );
      expect(first.offset, 140);

      final second = ChatWindow.of(
        total: 200,
        windowSize: 120,
        hasPendingUiRequest: false,
      );
      expect(second.offset, 80);
      expect(second.visibleCount, 120);

      // 扩到超过总数就到头了,按钮消失
      final full = ChatWindow.of(
        total: 200,
        windowSize: 240,
        hasPendingUiRequest: false,
      );
      expect(full.offset, 0);
      expect(full.hasEarlier, isFalse);
      expect(full.itemCount, 200);
    });
  });
}
