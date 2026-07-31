import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/island_bar.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/shell/app_shell.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => ProviderScope(
    child: MaterialApp(theme: buildLightTheme(), home: const AppShell()),
  );

  /// 新外壳(灵动岛/液态导航)有常驻动画,pumpAndSettle 会超时。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openDrawer(WidgetTester tester) async {
    tester.state<ScaffoldState>(findDrawerScaffold()).openDrawer();
    await settle(tester);
  }

  testWidgets('会话页仍挂着抽屉(底栏之外的第二入口)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // 底部导航改版后「设备」有了底栏入口,但抽屉作为已形成的手势习惯保留。
    // Scaffold 惰性构建抽屉,所以查它的属性而不是 widget 树。
    final scaffold = tester.widget<Scaffold>(findDrawerScaffold());
    expect(scaffold.drawer, isNotNull);

    // 打开后抽屉才真的进树
    await openDrawer(tester);
    expect(find.byType(Drawer), findsOneWidget);
  });

  testWidgets('抽屉是会话列表,不做会话创建与目录管理', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    await openDrawer(tester);

    // 「会话」标题只在抽屉里(底栏 tab 不在 Drawer 子树),限定子树断言。
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('会话')),
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

    await openDrawer(tester);

    // 对话页的未连接态也有同样文案,这里只看抽屉里的那份
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('还没有设备')),
      findsOneWidget,
    );
  });

  testWidgets('设置向右翻页可达(不再走抽屉页脚)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // 新外壳:三页 PageView(设置 | 会话 | 设备)。液态导航栏只在滚动时
    // 现身,平时收起 —— 所以设置靠「把内容往右拖,翻到上一页」到达。
    await tester.dragFrom(const Offset(400, 300), const Offset(300, 0));
    await settle(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('会话页没有常驻顶栏,灵动岛浮在内容上', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // Editorial Retro 把「报头 AppBar」删了:无常驻顶栏,内容区全屏,
    // 品牌/状态/入口收进灵动岛(收起是小胶囊,点开是完整信息卡)。
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(DynamicIslandBar), findsOneWidget);
  });

  testWidgets('关抽屉不会把焦点还给输入框(否则键盘每次都弹出来)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    final scaffold = tester.state<ScaffoldState>(findDrawerScaffold());
    scaffold.openDrawer();
    await settle(tester);
    scaffold.closeDrawer();
    await settle(tester);

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
