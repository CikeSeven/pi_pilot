import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/shell/app_shell.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => ProviderScope(
    child: MaterialApp(theme: buildLightTheme(), home: const AppShell()),
  );

  testWidgets('主导航是抽屉,不再是标题旁一个 16px 的小箭头', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // 从「没有抽屉」反转为「有抽屉」——这是这次重构的核心。
    // Scaffold 惰性构建抽屉,所以查它的属性而不是 widget 树。
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.drawer, isNotNull);

    // 打开后抽屉才真的进树
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
  });

  testWidgets('抽屉只列 pi 窗口,不做会话创建与目录管理', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('pi 窗口'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // 手机只负责「连到已经开着的窗口」,不负责创建会话或换目录 ——
    // 那些操作要么在电脑上做,要么会把人正在用的会话抽走。
    expect(find.text('新建会话'), findsNothing);
    expect(find.text('切换工作目录'), findsNothing);
  });

  testWidgets('没连上时抽屉给出明确的空态,而不是一片空白', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    // 对话页的未连接态也有同样文案,这里只看抽屉里的那份
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('尚未连接')),
      findsOneWidget,
    );
  });

  testWidgets('设置从抽屉页脚可达', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('顶栏没有等宽字体芯片行了', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // 104dp（56 + 48 芯片行）→ 72dp
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.bottom, isNull);
    expect(appBar.toolbarHeight, 72);
  });

  testWidgets('关抽屉不会把焦点还给输入框(否则键盘每次都弹出来)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    scaffold.closeDrawer();
    await tester.pumpAndSettle();

    // Flutter 关抽屉后会把焦点还给 body 里第一个可聚焦节点 = 输入框,
    // 键盘就跟着弹出来。AppShell 的 onDrawerChanged 必须把它收掉。
    // 判据取「没有任何文本框持有焦点」—— 有焦点就等于键盘会弹。
    for (final editable in tester.widgetList<EditableText>(
      find.byType(EditableText),
    )) {
      expect(
        editable.focusNode.hasFocus,
        isFalse,
        reason: '关抽屉后输入框不该拿到焦点,否则键盘每次都弹出来',
      );
    }
  });
}
