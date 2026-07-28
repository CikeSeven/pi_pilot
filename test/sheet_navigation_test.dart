import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/common/app_sheet.dart';
import 'package:pi_pilot/ui/common/sheet_navigator.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// 弹窗导航。
///
/// 改造前:点「模型」是 `Navigator.pop(context)` 紧接 `showModelSwitchSheet(context)`
/// —— 用一个正在被卸载的 context 开新弹窗;选完又无条件把整摞关掉,回不到上一层。
/// 长按消息弹出的面板更是除了下滑和点遮罩没有任何退出方式。
///
/// 这一层原先**零测试覆盖**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 打开一个带页面栈的弹窗,root 页有一个能 push 二级页的按钮。
  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showAppSheet<void>(
                  context,
                  builder: (_) => SheetNavigator(
                    root: (_) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SheetHeader('会话'),
                        Builder(
                          builder: (inner) => ListTile(
                            title: const Text('模型'),
                            onTap: () => SheetNavigator.of(inner).push(
                              (_) => const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SheetHeader('切换模型'),
                                  ListTile(title: Text('Kimi K3')),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('根页的出口是关闭键,不是返回键', (tester) async {
    await openSheet(tester);

    expect(find.text('会话'), findsOneWidget);
    // 长按消息那个面板以前**连关闭键都没有**,只能下滑或点遮罩
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.byTooltip('返回'), findsNothing);
  });

  testWidgets('进二级页后弹窗不关,并且出现返回键', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();

    // 关键:仍然在**同一个**弹窗里 —— 之前是 pop 掉再开一个新的
    expect(find.text('切换模型'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
  });

  testWidgets('点返回回到上一层,而不是关掉整个弹窗', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('切换模型'), findsNothing);
    // 弹窗本身没被关掉
    expect(find.byType(SheetNavigator), findsOneWidget);
  });

  testWidgets('根页点关闭才真的关掉弹窗', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.byType(SheetNavigator), findsNothing);
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('二级页选完后 pop 回根页,弹窗保持打开', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();

    // 模拟「选中一个模型」——业务代码走的就是 SheetNavigator.of(ctx).pop()
    final state = tester.state<SheetNavigatorState>(
      find.byType(SheetNavigator),
    );
    expect(state.canPop, isTrue);
    state.pop();
    await tester.pumpAndSettle();

    expect(state.canPop, isFalse);
    expect(find.text('会话'), findsOneWidget);
    expect(find.byType(SheetNavigator), findsOneWidget);
  });

  testWidgets('根页上再 pop 是安全的空操作', (tester) async {
    await openSheet(tester);
    final state = tester.state<SheetNavigatorState>(
      find.byType(SheetNavigator),
    );
    state.pop();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('会话'), findsOneWidget);
  });
}
