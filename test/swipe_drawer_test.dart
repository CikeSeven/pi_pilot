import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/shell/swipe_to_open_drawer.dart';

/// 聊天页右滑开抽屉。
///
/// 这里最要紧的一条是**不能抢掉内层横向滚动**:聊天页有四处横向可滚动区域
/// (代码块、diff、投递芯片、快捷面板)。所以手势挂在 body 的祖先位置,
/// 靠手势竞技场"最深者先入场、sweep 时先入场者胜"把优先权让给内层。
void main() {
  Widget wrap({
    required VoidCallback onOpen,
    bool enabled = true,
    Widget? child,
  }) => MaterialApp(
    home: Scaffold(
      body: SwipeToOpenDrawer(
        enabled: enabled,
        onOpen: onOpen,
        child:
            child ??
            const SizedBox.expand(child: ColoredBox(color: Colors.grey)),
      ),
    ),
  );

  testWidgets('右滑超过阈值就开抽屉', (tester) async {
    var opened = 0;
    await tester.pumpWidget(wrap(onOpen: () => opened++));

    await tester.drag(find.byType(SwipeToOpenDrawer), const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('一次拖拽只开一次', (tester) async {
    var opened = 0;
    await tester.pumpWidget(wrap(onOpen: () => opened++));

    // 分多次 move 模拟真实拖拽:update 会持续来,不能每帧都开一次。
    final gesture = await tester.startGesture(const Offset(20, 300));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('左滑不开', (tester) async {
    var opened = 0;
    await tester.pumpWidget(wrap(onOpen: () => opened++));

    await tester.drag(find.byType(SwipeToOpenDrawer), const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(opened, 0);
  });

  testWidgets('竖滑不开:否则滚消息列表会误开抽屉', (tester) async {
    var opened = 0;
    await tester.pumpWidget(wrap(onOpen: () => opened++));

    await tester.drag(find.byType(SwipeToOpenDrawer), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(opened, 0);
  });

  testWidgets('来回蹭不开:只认单向累计位移', (tester) async {
    var opened = 0;
    await tester.pumpWidget(wrap(onOpen: () => opened++));

    final gesture = await tester.startGesture(const Offset(100, 300));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(opened, 0);
  });

  testWidgets('抽屉已开时不再触发', (tester) async {
    var opened = 0;
    await tester.pumpWidget(wrap(onOpen: () => opened++, enabled: false));

    await tester.drag(find.byType(SwipeToOpenDrawer), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(opened, 0);
  });

  testWidgets('内层横向滚动优先:在代码块上右滑不能开抽屉', (tester) async {
    // 这是选择"挂祖先"而不是"放大 drawerEdgeDragWidth"的全部理由。
    // Scaffold 的边缘拖拽检测器叠在 body 之上,命中测试先到它,加宽之后
    // 代码块就横向滚不动了。
    var opened = 0;
    final controller = ScrollController();
    await tester.pumpWidget(
      wrap(
        onOpen: () => opened++,
        child: Center(
          child: SizedBox(
            height: 100,
            child: ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              itemCount: 40,
              itemBuilder: (_, i) =>
                  Container(width: 120, color: Colors.blue, child: Text('$i')),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0), reason: '内层必须还能横向滚');

    // 反向(会开抽屉的方向)在内层上滑:应当滚回去,而不是开抽屉。
    await tester.drag(find.byType(ListView), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(opened, 0, reason: '内层横向滚动必须赢下竞技场');
  });

  testWidgets('内层横向区域之外仍能右滑开抽屉', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      wrap(
        onOpen: () => opened++,
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: List.generate(
                  20,
                  (i) => Container(width: 100, color: Colors.blue),
                ),
              ),
            ),
            const Expanded(child: ColoredBox(color: Colors.grey)),
          ],
        ),
      ),
    );

    // 在下方空白区域(不属于横向 ListView)右滑
    await tester.dragFrom(const Offset(50, 500), const Offset(150, 0));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });
}
