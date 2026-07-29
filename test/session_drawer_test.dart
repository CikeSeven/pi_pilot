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

  testWidgets('会话页仍挂着抽屉(底栏之外的第二入口)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // 底部导航改版后「设备」有了底栏入口,但抽屉作为已形成的手势习惯保留。
    // Scaffold 惰性构建抽屉,所以查它的属性而不是 widget 树。
    final scaffold = tester.widget<Scaffold>(findDrawerScaffold());
    expect(scaffold.drawer, isNotNull);

    // 打开后抽屉才真的进树
    tester.state<ScaffoldState>(findDrawerScaffold()).openDrawer();
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
  });

  testWidgets('抽屉只列 pi 窗口,不做会话创建与目录管理', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    tester.state<ScaffoldState>(findDrawerScaffold()).openDrawer();
    await tester.pumpAndSettle();

    // 「pi 窗口」标题在抽屉和「设备」tab 里各有一份(同一份 UI 两个外壳),
    // 所以限定在 Drawer 子树里断言。
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('pi 窗口')),
      findsOneWidget,
    );
    // 抽屉里**不再**有「设置」入口 —— 底栏已经有「设置」tab,
    // 同一个目的地给两个入口只会让人犹豫点哪个。
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('设置')),
      findsNothing,
    );

    // 手机只负责「连到已经开着的窗口」,不负责创建会话或换目录 ——
    // 那些操作要么在电脑上做,要么会把人正在用的会话抽走。
    expect(find.text('新建会话'), findsNothing);
    expect(find.text('切换工作目录'), findsNothing);
  });

  testWidgets('没连上时抽屉给出明确的空态,而不是一片空白', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    tester.state<ScaffoldState>(findDrawerScaffold()).openDrawer();
    await tester.pumpAndSettle();

    // 对话页的未连接态也有同样文案,这里只看抽屉里的那份
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('尚未连接')),
      findsOneWidget,
    );
  });

  testWidgets('设置从底栏可达(不再走抽屉页脚)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // 底栏第三格就是设置 —— 这取代了原来「抽屉页脚一条设置」的路径。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('顶栏是报头:衬线字标 + 状态副行 + 一条细线', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    // Editorial Retro:顶栏底部是一条 1px 编辑式细线(替代滚动阴影),
    // 不再是旧版那个 48dp 的等宽字体芯片行。
    expect(appBar.bottom, isNotNull);
    expect(appBar.bottom!.preferredSize.height, 1);
    expect(appBar.toolbarHeight, 76);
    // 品牌字标在顶栏里,而且是**衬线**的 —— 这是「衬线负责气质」的落点。
    // 顶栏里 'PiPilot' 会出现两次:衬线字标,以及未选会话时标题回退的同名文本。
    // 只断言「存在一个衬线的 PiPilot」,避免与回退文本混淆。
    final wordmarks = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('PiPilot'),
          ),
        )
        .where((t) => t.style?.fontFamily == 'serif');
    expect(wordmarks, hasLength(1), reason: '顶栏必须有一个衬线品牌字标');
  });

  testWidgets('关抽屉不会把焦点还给输入框(否则键盘每次都弹出来)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    final scaffold = tester.state<ScaffoldState>(findDrawerScaffold());
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

/// 定位**带抽屉的那个** `Scaffold`。
///
/// 底部导航改版后树里有多个 Scaffold:AppShell 外层一个(挂底栏),
/// `IndexedStack` 里每个 tab 各一个。`find.byType(Scaffold)` 会命中多个
/// 并抛 "Too many elements",所以按「有没有 drawer」把会话页那个挑出来。
Finder findDrawerScaffold() => find.byWidgetPredicate(
  (widget) => widget is Scaffold && widget.drawer != null,
);
