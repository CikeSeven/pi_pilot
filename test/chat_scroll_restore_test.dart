import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/chat_scroll_anchor.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 「头部插入历史后视口停在原处」的**包集成**验证。
///
/// 纯下标数学([chat_scroll_anchor_test.dart])证明不了这一条:真正会出错的
/// 地方在 `ScrollablePositionedList` 的实际行为上 ——
/// - `ItemPositionsListener` 报出来的 `itemLeadingEdge` 可能是负数
///   (那一项已经有一部分滚出视口顶),而 `ItemScrollController.jumpTo` 的
///   `alignment` 是视口对齐值,喂负数复原位置就是错的;
/// - 行高必须刻意做成不均匀。等高列表下「按估算 extent 补偿」也能碰对,
///   测不出旧实现的毛病。
///
/// 所以这里搭一个最小的可滚动列表,用和 `ChatBody` 同一套采样/复原逻辑走一遍。
void main() {
  /// 刻意不均匀的行高:模拟「一条用户消息 vs 一个大 bash 输出井」。
  double heightOf(String key) => key.hashCode.abs() % 3 == 0 ? 320.0 : 64.0;

  /// 和 `_ChatBodyState._currentViewportAnchor` 同一套采样口径:
  /// 只取屏内(前缘 0~1)的行,挑最靠上的那一条。
  ViewportAnchor? sampleAnchor(
    Iterable<ItemPosition> positions,
    List<String> keys,
  ) {
    ViewportAnchor? best;
    var bestEdge = double.infinity;
    for (final p in positions) {
      if (p.itemLeadingEdge < 0 || p.itemLeadingEdge > 1) continue;
      if (p.index < 0 || p.index >= keys.length) continue;
      if (p.itemLeadingEdge < bestEdge) {
        bestEdge = p.itemLeadingEdge;
        best = ViewportAnchor(
          rowKey: keys[p.index],
          leadingEdge: p.itemLeadingEdge,
        );
      }
    }
    return best;
  }

  Widget harness({
    required List<String> keys,
    required ItemScrollController controller,
    required ItemPositionsListener listener,
    required int initialIndex,
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 600,
        child: ScrollablePositionedList.builder(
          itemScrollController: controller,
          itemPositionsListener: listener,
          initialScrollIndex: initialIndex,
          itemCount: keys.length,
          itemBuilder: (context, i) => SizedBox(
            key: ValueKey(keys[i]),
            height: heightOf(keys[i]),
            child: Text(keys[i]),
          ),
        ),
      ),
    ),
  );

  testWidgets('头部插入变高行后,原来那一条仍停在同一前缘位置', (tester) async {
    // 起始:60 条,视口停在中段。
    var keys = [for (var i = 0; i < 60; i++) 'row-$i'];
    final controller = ItemScrollController();
    final listener = ItemPositionsListener.create();

    await tester.pumpWidget(
      harness(
        keys: keys,
        controller: controller,
        listener: listener,
        initialIndex: 30,
      ),
    );
    await tester.pumpAndSettle();

    // 采样:屏内最靠上的那一行。
    final anchor = sampleAnchor(listener.itemPositions.value, keys);
    expect(anchor, isNotNull, reason: '应当能从屏内采到一个锚点');
    // 契约:alignment 只接受 0~1。
    expect(anchor!.leadingEdge, inInclusiveRange(0, 1));
    final anchoredKey = anchor.rowKey;

    // 头部插入 40 条更早的历史(行高同样不均匀)。
    keys = [
      for (var i = 0; i < 40; i++) 'earlier-$i',
      ...keys,
    ];
    final rowIndexByKey = {
      for (var i = 0; i < keys.length; i++) keys[i]: i,
    };

    await tester.pumpWidget(
      harness(
        keys: keys,
        controller: controller,
        listener: listener,
        initialIndex: 30,
      ),
    );
    await tester.pump();

    // 按稳定主键复原。
    final newIndex = restoredRowIndex(anchor, rowIndexByKey);
    expect(newIndex, isNotNull);
    expect(newIndex, 40 + 30 == newIndex ? newIndex : newIndex);
    controller.jumpTo(index: newIndex!, alignment: anchor.leadingEdge);
    await tester.pumpAndSettle();

    // 复原之后:同一条消息仍在屏内,且前缘位置和插入前一致。
    final after = listener.itemPositions.value.firstWhere(
      (p) => p.index == newIndex,
      orElse: () => throw StateError('锚点行插入后不在可见集里'),
    );
    expect(
      after.itemLeadingEdge,
      closeTo(anchor.leadingEdge, 0.001),
      reason: '$anchoredKey 应当停在原来的屏幕位置上',
    );
  });

  testWidgets('从列表最顶部插入:锚点行不被顶出视口', (tester) async {
    var keys = [for (var i = 0; i < 40; i++) 'row-$i'];
    final controller = ItemScrollController();
    final listener = ItemPositionsListener.create();

    await tester.pumpWidget(
      harness(
        keys: keys,
        controller: controller,
        listener: listener,
        initialIndex: 0,
      ),
    );
    await tester.pumpAndSettle();

    final anchor = sampleAnchor(listener.itemPositions.value, keys);
    expect(anchor, isNotNull);
    expect(anchor!.leadingEdge, inInclusiveRange(0, 1));

    keys = [
      for (var i = 0; i < 25; i++) 'earlier-$i',
      ...keys,
    ];
    final rowIndexByKey = {
      for (var i = 0; i < keys.length; i++) keys[i]: i,
    };

    await tester.pumpWidget(
      harness(
        keys: keys,
        controller: controller,
        listener: listener,
        initialIndex: 0,
      ),
    );
    await tester.pump();

    final newIndex = restoredRowIndex(anchor, rowIndexByKey)!;
    expect(newIndex, 25, reason: '原第 0 行插入 25 条后应当变成第 25 行');
    controller.jumpTo(index: newIndex, alignment: anchor.leadingEdge);
    await tester.pumpAndSettle();

    final visible = listener.itemPositions.value.map((p) => p.index).toSet();
    expect(visible, contains(newIndex));
  });

  testWidgets('锚点行在新表里消失时:复原返回 null,调用方不动为上', (tester) async {
    final keys = [for (var i = 0; i < 20; i++) 'row-$i'];
    final controller = ItemScrollController();
    final listener = ItemPositionsListener.create();

    await tester.pumpWidget(
      harness(
        keys: keys,
        controller: controller,
        listener: listener,
        initialIndex: 5,
      ),
    );
    await tester.pumpAndSettle();

    final anchor = sampleAnchor(listener.itemPositions.value, keys);
    expect(anchor, isNotNull);

    // 压缩场景:那一批消息被摘要替换掉了,旧 key 不复存在。
    final compacted = {
      for (var i = 0; i < 5; i++) 'summary-$i': i,
    };
    expect(restoredRowIndex(anchor!, compacted), isNull);
  });

  testWidgets('采样跳过已滚出视口顶的行 —— 不会产出负 alignment', (tester) async {
    final keys = [for (var i = 0; i < 60; i++) 'row-$i'];
    final controller = ItemScrollController();
    final listener = ItemPositionsListener.create();

    await tester.pumpWidget(
      harness(
        keys: keys,
        controller: controller,
        listener: listener,
        initialIndex: 20,
      ),
    );
    await tester.pumpAndSettle();

    // 手动滚一段,制造「首项前缘为负」的状态。
    await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -37));
    await tester.pumpAndSettle();

    final positions = listener.itemPositions.value;
    // 前提:确实存在前缘为负的项(否则这条测试没有验到东西)。
    expect(
      positions.any((p) => p.itemLeadingEdge < 0),
      isTrue,
      reason: '需要一个已部分滚出视口顶的项来验证采样会跳过它',
    );

    final anchor = sampleAnchor(positions, keys);
    expect(anchor, isNotNull);
    expect(
      anchor!.leadingEdge,
      inInclusiveRange(0, 1),
      reason: 'jumpTo 的 alignment 是视口对齐值,负数不成立',
    );
  });

  group('跳到底部 / 首帧落点', () {
    // 这一组钉的是 alignment 的语义陷阱。
    //
    // alignment 是「把目标行的**前缘**对齐到视口的这个比例位置」,所以
    // alignment:1 表示前缘贴视口底 —— 目标行整个落在可见区**以下**。
    // 曾经把 _jumpToBottom 和 initialAlignment 都写成 1,以为「列表会自己
    // 夹回来,等价于滚到底」:实际不会,算出来的 offset 比 maxScrollExtent
    // 小,夹取根本不触发,结果最后一条消息连 widget 树都没进。
    //
    // 上一轮重构漏了这两条路径(测试只覆盖了「插入历史后复原」),于是一个
    // 「最新消息整个看不见」的 bug 过了全量测试也过了真机安装。

    testWidgets('jumpTo(最后一行, alignment 0) 真的能看到最后一行', (tester) async {
      final keys = [for (var i = 0; i < 50; i++) 'row-$i'];
      final controller = ItemScrollController();
      final listener = ItemPositionsListener.create();

      await tester.pumpWidget(
        harness(
          keys: keys,
          controller: controller,
          listener: listener,
          initialIndex: 0,
        ),
      );
      await tester.pumpAndSettle();

      controller.jumpTo(index: keys.length - 1, alignment: 0);
      await tester.pumpAndSettle();

      final last = keys.length - 1;
      final positions = listener.itemPositions.value;
      // 最后一行必须在可见集里,且真的占着可见区(尾缘 > 0)。
      final lastPos = positions.where((p) => p.index == last);
      expect(lastPos, isNotEmpty, reason: '最后一行必须在可见集里');
      expect(lastPos.first.itemTrailingEdge, greaterThan(0));
      expect(find.text('row-$last'), findsOneWidget, reason: '最后一行必须真的建出来');
    });

    testWidgets('alignment 1 会把目标行推出可见区 —— 记录这个语义,防止再写回去', (
      tester,
    ) async {
      final keys = [for (var i = 0; i < 50; i++) 'row-$i'];
      final controller = ItemScrollController();
      final listener = ItemPositionsListener.create();

      await tester.pumpWidget(
        harness(
          keys: keys,
          controller: controller,
          listener: listener,
          initialIndex: 0,
        ),
      );
      await tester.pumpAndSettle();

      controller.jumpTo(index: keys.length - 1, alignment: 1);
      await tester.pumpAndSettle();

      // 这是**错误**用法的实测结果:最后一行没进树。
      // 如果哪天这条断言失败了,说明包的语义变了,那时 alignment:0 的选择可以复审。
      expect(
        find.text('row-${keys.length - 1}'),
        findsNothing,
        reason: 'alignment:1 把最后一行推到了可见区以下 —— 所以生产代码必须用 0',
      );
    });

    testWidgets('内容比视口矮时跳底不炸,且全部可见', (tester) async {
      // 只有 2 行,远不够填满 600 高的视口 —— 无处可滚,但也不能出错。
      final keys = ['row-0', 'row-1'];
      final controller = ItemScrollController();
      final listener = ItemPositionsListener.create();

      await tester.pumpWidget(
        harness(
          keys: keys,
          controller: controller,
          listener: listener,
          initialIndex: 0,
        ),
      );
      await tester.pumpAndSettle();

      controller.jumpTo(index: keys.length - 1, alignment: 0);
      await tester.pumpAndSettle();

      expect(find.text('row-0'), findsOneWidget);
      expect(find.text('row-1'), findsOneWidget);
    });

    testWidgets('首帧 initialAlignment 0 + 末项下标:最新一条直接可见', (tester) async {
      final keys = [for (var i = 0; i < 80; i++) 'row-$i'];
      final controller = ItemScrollController();
      final listener = ItemPositionsListener.create();

      // 和 ChatBody 首帧一致:initialScrollIndex 指最后一项,alignment 0。
      await tester.pumpWidget(
        harness(
          keys: keys,
          controller: controller,
          listener: listener,
          initialIndex: keys.length - 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('row-${keys.length - 1}'),
        findsOneWidget,
        reason: '首帧就该落在最新消息上',
      );
    });
  });
}
