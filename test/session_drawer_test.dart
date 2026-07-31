import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/island_bar.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/shell/app_shell.dart';
import 'package:pi_pilot/ui/shell/liquid_nav_bar.dart';
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

  testWidgets('右滑任意位置打开会话抽屉(不再限于左边缘)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 屏幕中部向右拖:对话页是 PageView 第一页,右滑只会产生前缘过卷,
    // 累计超过阈值即开抽屉(见 AppShell._onScrollNotification)。
    await tester.dragFrom(const Offset(400, 300), const Offset(160, 0));
    await settle(tester);

    expect(find.byType(Drawer), findsOneWidget);
  });

  testWidgets('小幅右滑不误触抽屉(累计位移要过阈值)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    await tester.dragFrom(const Offset(400, 300), const Offset(40, 0));
    await settle(tester);

    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('上下滚动不误触抽屉(过卷监听按轴过滤)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 竖向拖拽滚动聊天列表:竖向过卷通知会被 axis == horizontal 过滤掉。
    await tester.dragFrom(const Offset(400, 300), const Offset(0, -160));
    await settle(tester);

    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('设置向左连翻两页可达(不再走抽屉页脚)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 三页 PageView(对话 | 设备 | 设置)。对话页的液态导航平时收起,
    // 设置靠「把内容往左拖,连翻两页」到达。用带显式速度的 fling,
    // 隐式速度的 drag 在临界速度下会弹回,行为不确定。
    await tester.flingFrom(const Offset(400, 300), const Offset(-300, 0), 1000);
    await settle(tester);
    await tester.flingFrom(const Offset(400, 300), const Offset(-300, 0), 1000);
    await settle(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('底栏只在对话页收起,设备/设置页常驻', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    AnimatedOpacity navOpacity() => tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(LiquidNavBar),
        matching: find.byType(AnimatedOpacity),
      ),
    );

    // 对话页:不滑动时底栏收起(内容全屏优先)。
    expect(navOpacity().opacity, 0.0);

    // 翻到设备页:滑动停止后底栏仍常驻。
    await tester.flingFrom(const Offset(400, 300), const Offset(-300, 0), 1000);
    await settle(tester);
    expect(navOpacity().opacity, 1.0);

    // 再翻到设置页:同样常驻。
    await tester.flingFrom(const Offset(400, 300), const Offset(-300, 0), 1000);
    await settle(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(navOpacity().opacity, 1.0);

    // 回到对话页:再次收起。
    await tester.flingFrom(const Offset(400, 300), const Offset(300, 0), 1000);
    await settle(tester);
    await tester.flingFrom(const Offset(400, 300), const Offset(300, 0), 1000);
    await settle(tester);
    // PageView 弹簧在目标附近还要爬行一段才彻底收敛(page≈0.01 时
    // isScrolling 仍为 true,底栏按设计保持显示)。多等一拍让滚动活动
    // 真正结束,isScrolling 落 false 后底栏才淡出。
    await tester.pump(const Duration(seconds: 2));
    expect(navOpacity().opacity, 0.0);
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
