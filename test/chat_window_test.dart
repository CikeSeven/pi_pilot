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

  /// 滑到顶部自动补齐 —— 顶部那行只是指示,不需要用户去点。
  ///
  /// 这几道卡全是真踩过的坑,算错的后果是「每次切会话都白发一轮请求」
  /// 或者「滑到顶了不动弹」。
  group('滑到顶部自动加载的触发条件', () {
    test('接近顶部且还有更早 → 触发', () {
      expect(
        shouldAutoLoadEarlier(
          pixels: 300,
          maxScrollExtent: 5000,
          threshold: 600,
          hasEarlier: true,
          loadingEarlier: false,
          jumpingToBottom: false,
        ),
        isTrue,
      );
    });

    test('留提前量:还差一点到顶就该开始取,别等硬停', () {
      expect(
        shouldAutoLoadEarlier(
          pixels: 600,
          maxScrollExtent: 5000,
          threshold: 600,
          hasEarlier: true,
          loadingEarlier: false,
          jumpingToBottom: false,
        ),
        isTrue,
      );
      expect(
        shouldAutoLoadEarlier(
          pixels: 601,
          maxScrollExtent: 5000,
          threshold: 600,
          hasEarlier: true,
          loadingEarlier: false,
          jumpingToBottom: false,
        ),
        isFalse,
      );
    });

    test('历史到头了就不再触发', () {
      expect(
        shouldAutoLoadEarlier(
          pixels: 0,
          maxScrollExtent: 5000,
          threshold: 600,
          hasEarlier: false,
          loadingEarlier: false,
          jumpingToBottom: false,
        ),
        isFalse,
      );
    });

    test('已经在取了就不叠第二轮', () {
      expect(
        shouldAutoLoadEarlier(
          pixels: 0,
          maxScrollExtent: 5000,
          threshold: 600,
          hasEarlier: true,
          loadingEarlier: true,
          jumpingToBottom: false,
        ),
        isFalse,
      );
    });

    test('切会话正在跳底时不能触发', () {
      // 跳底途中 pixels 从 0 往下跑,中途必然落在阈值内 ——
      // 不挡的话每次切会话都会白白往前分页一次。
      expect(
        shouldAutoLoadEarlier(
          pixels: 0,
          maxScrollExtent: 5000,
          threshold: 600,
          hasEarlier: true,
          loadingEarlier: false,
          jumpingToBottom: true,
        ),
        isFalse,
      );
    });

    test('内容没撑满一屏时不触发', () {
      // maxScrollExtent 为 0 时 pixels 恒为 0,恒等于「在顶部」,
      // 列表刚建好那几帧会白白发一轮请求。
      expect(
        shouldAutoLoadEarlier(
          pixels: 0,
          maxScrollExtent: 0,
          threshold: 600,
          hasEarlier: true,
          loadingEarlier: false,
          jumpingToBottom: false,
        ),
        isFalse,
      );
    });
  });

  /// 桥为了不撞爆手机的 2MB 套接字缓冲,只发 entries 的尾巴(全量快照实测到过
  /// 10.27MB)。所以「本地没有更早」不等于「没有更早」—— 滚到本地头部时按钮还得在,
  /// 只是改成联网补。
  group('本地到头但桥上还有历史', () {
    test('本地窗口装得下全部,仍要显示按钮并走联网', () {
      final w = ChatWindow.of(
        total: 40,
        windowSize: 60,
        hasPendingUiRequest: false,
        hasRemoteEarlier: true,
      );
      expect(w.offset, 0);
      expect(w.hasEarlier, isTrue, reason: '桥上还有,按钮不能消失');
      expect(w.needsRemoteFetch, isTrue);
      // 按钮占掉槽位 0,消息整体后移一格
      expect(w.itemCount, 41);
      expect(w.isLoadEarlierSlot(0), isTrue);
      expect(w.itemIndexOf(1), 0);
      expect(w.slotOf(0), 1);
    });

    test('本地还有更早时先扩窗,不联网', () {
      final w = ChatWindow.of(
        total: 200,
        windowSize: 60,
        hasPendingUiRequest: false,
        hasRemoteEarlier: true,
      );
      expect(w.offset, 140);
      expect(w.hasEarlier, isTrue);
      expect(w.needsRemoteFetch, isFalse, reason: '本地还有 140 条没渲染');
    });

    test('桥上没有了、本地也到头 → 按钮消失', () {
      final w = ChatWindow.of(
        total: 40,
        windowSize: 60,
        hasPendingUiRequest: false,
        hasRemoteEarlier: false,
      );
      expect(w.hasEarlier, isFalse);
      expect(w.needsRemoteFetch, isFalse);
      expect(w.itemCount, 40);
    });

    test('联网补齐 + 同步扩窗后,新取回的那批必须落进窗口', () {
      // 补齐前:本地 40 条全在窗口里
      final before = ChatWindow.of(
        total: 40,
        windowSize: 60,
        hasPendingUiRequest: false,
        hasRemoteEarlier: true,
      );
      expect(before.offset, 0);

      // 回归:光把历史插进列表而不放大窗口,offset 会跟着变大,
      // 刚取回来的那批仍在窗口之上,点了等于没反应。
      final grownOnly = ChatWindow.of(
        total: 140,
        windowSize: 60,
        hasPendingUiRequest: false,
        hasRemoteEarlier: true,
      );
      expect(grownOnly.offset, 80, reason: '没扩窗时新历史反而看不见');

      // 正确做法:窗口同时加上新增条数
      final after = ChatWindow.of(
        total: 140,
        windowSize: 60 + 100,
        hasPendingUiRequest: false,
        hasRemoteEarlier: true,
      );
      expect(after.offset, 0);
      expect(after.visibleCount, 140);
    });
  });
}
