import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/chat_scroll_anchor.dart';
import 'package:pi_pilot/ui/chat/nav_anchor.dart';

/// 消息列表的滚动锚点数学。
///
/// 这三处换算全都是**用户可见的 bug 现场**,所以逐个边界钉住:
/// - 加载完更早的消息后列表乱窜 → [restoredRowIndex];
/// - 左侧轨道拖到某处却没定位过去 → [anchorIndexAt];
/// - 轨道游标位置和实际在看第几条消息对不上 → [anchorFocusOf]。
///
/// 旧实现把这些全都建立在 `pixels / maxScrollExtent` 比例 +「行高均等」的
/// 假设上。聊天行高差几十倍(一条用户消息 vs 一个大 bash 输出井),而惰性
/// 列表的 `maxScrollExtent` 本身又只是按已建行平均高度外推的估算值 ——
/// 所以这里全部改成纯下标/主键运算,和行高彻底解耦。这些测试的意义就是:
/// **一旦谁又把高度信息掺回来,立刻红**。
void main() {
  group('restoredRowIndex:头部插入后按稳定主键复原视口', () {
    test('同一条消息在新行表里的下标 —— 不靠「旧下标 + 插入行数」推算', () {
      const anchor = ViewportAnchor(rowKey: 'user-42', leadingEdge: 0.25);
      // 插入 40 行历史之后,user-42 落到了 52。
      final newIndex = restoredRowIndex(anchor, {'user-42': 52, 'user-1': 11});
      expect(newIndex, 52);
    });

    test('行增量 ≠ 条目增量时依然精确 —— 主键不受派生行数影响', () {
      // 同一批历史里工具行/统计行的数量会变,所以位移量不是常数。
      // 主键查表天然免疫:插入了多少行根本不参与运算。
      const anchor = ViewportAnchor(rowKey: 'assistant-7', leadingEdge: 0);
      expect(restoredRowIndex(anchor, {'assistant-7': 133}), 133);
      expect(restoredRowIndex(anchor, {'assistant-7': 91}), 91);
    });

    test('查不到主键返回 null —— 调用方应当不动为上,硬跳只会更乱', () {
      const anchor = ViewportAnchor(rowKey: 'tool-old', leadingEdge: 0.5);
      expect(restoredRowIndex(anchor, const {}), isNull);
      expect(restoredRowIndex(anchor, {'tool-new': 3}), isNull);
    });

    test('第 0 行也能被正确复原(不要和「查不到」混为一谈)', () {
      const anchor = ViewportAnchor(rowKey: 'user-first', leadingEdge: 0);
      expect(restoredRowIndex(anchor, {'user-first': 0}), 0);
    });

    test('前缘位置只接受 0~1 —— jumpTo 的 alignment 是视口对齐值,喂负数不成立', () {
      // 这条契约由采样端保证(只挑屏内的行),这里把约束写成可执行的说明。
      const anchor = ViewportAnchor(rowKey: 'k', leadingEdge: 0.3);
      expect(anchor.leadingEdge, inInclusiveRange(0, 1));
    });
  });

  group('anchorIndexAt:轨道手势 → 锚点序号', () {
    test('两端与中点严格对齐', () {
      expect(anchorIndexAt(0, 5), 0);
      expect(anchorIndexAt(1, 5), 4);
      expect(anchorIndexAt(0.5, 5), 2);
    });

    test('越界的 t 被夹住,不会越过锚点表', () {
      expect(anchorIndexAt(-1, 5), 0);
      expect(anchorIndexAt(2, 5), 4);
    });

    test('空表与单条不炸', () {
      expect(anchorIndexAt(0.7, 0), 0);
      expect(anchorIndexAt(0.7, 1), 0);
    });

    test('长会话:每个刻度都能被选中,不会有够不到的消息', () {
      const n = 137;
      final reachable = <int>{};
      // 手势分辨率取够细(轨道最高 520dp,远小于 2000 步)。
      for (var step = 0; step <= 2000; step++) {
        reachable.add(anchorIndexAt(step / 2000, n));
      }
      expect(reachable.length, n);
    });
  });

  group('anchorFocusOf:可见行 → 轨道焦点', () {
    // 行高刻意做成极不均匀:锚点之间隔 1 行和隔 100 行混在一起。
    // 焦点只看**序号**,所以疏密不该影响「第 i 条消息落在第 i 个大节点」。
    final anchors = [
      const NavAnchor(rowIndex: 0, preview: 'a'),
      const NavAnchor(rowIndex: 1, preview: 'b'),
      const NavAnchor(rowIndex: 101, preview: 'c'),
      const NavAnchor(rowIndex: 102, preview: 'd'),
      const NavAnchor(rowIndex: 300, preview: 'e'),
    ];

    test('正在看第 i 条用户消息 → 焦点严格落在第 i 个大节点上', () {
      // 5 个锚点,节点位置就是 0, 0.25, 0.5, 0.75, 1。
      expect(anchorFocusOf(anchors, 0), 0);
      expect(anchorFocusOf(anchors, 1), closeTo(0.25, 1e-9));
      expect(anchorFocusOf(anchors, 101), closeTo(0.5, 1e-9));
      expect(anchorFocusOf(anchors, 102), closeTo(0.75, 1e-9));
      expect(anchorFocusOf(anchors, 300), 1);
    });

    test('锚点之间连续插值,不阶跃', () {
      // 101 与 102 之间没有中间行,取 1↔101 这段的中点:第 51 行。
      final mid = anchorFocusOf(anchors, 51);
      expect(mid, greaterThan(0.25));
      expect(mid, lessThan(0.5));
    });

    test('稀疏段与密集段的映射互不干扰 —— 焦点不吃行高', () {
      // 1→101 跨 100 行、101→102 只跨 1 行,但两段各自都占 0.25 的轨道长度。
      final justAfterSparseStart = anchorFocusOf(anchors, 2);
      expect(justAfterSparseStart, greaterThan(0.25));
      expect(justAfterSparseStart, lessThan(0.26));
    });

    test('超出两端被夹住', () {
      expect(anchorFocusOf(anchors, -5), 0);
      expect(anchorFocusOf(anchors, 9999), 1);
    });

    test('空表与单条不炸', () {
      expect(anchorFocusOf(const [], 3), 0);
      expect(
        anchorFocusOf(const [NavAnchor(rowIndex: 4, preview: 'x')], 4),
        0,
      );
    });

    test('二分与线性扫描结果一致(长表)', () {
      final many = [
        for (var i = 0; i < 500; i++)
          NavAnchor(rowIndex: i * 7, preview: 'm$i'),
      ];
      double linear(int visibleRow) {
        final n = many.length;
        if (visibleRow <= many.first.rowIndex) return 0;
        if (visibleRow >= many.last.rowIndex) return 1;
        for (var j = 0; j + 1 < n; j++) {
          final a = many[j].rowIndex;
          final b = many[j + 1].rowIndex;
          if (visibleRow <= b) {
            final local = ((visibleRow - a) / (b - a)).clamp(0.0, 1.0);
            return (j + local) / (n - 1);
          }
        }
        return 1;
      }

      for (var row = 0; row <= 500 * 7; row += 13) {
        expect(
          anchorFocusOf(many, row),
          closeTo(linear(row), 1e-9),
          reason: 'row=$row',
        );
      }
    });
  });
}
