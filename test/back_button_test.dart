import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/shell/app_shell.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Material 的 `Drawer` 不注册任何返回键拦截(drawer.dart 里没有 PopScope),
/// 所以抽屉开着时返回键会直接落到根路由上 —— 表现是一下退到桌面,抽屉白开。
///
/// `NavigatorState.maybePop` 的返回值正好区分这两种结局:
/// - `true`  → 被 PopScope 拦下并自行处理(这里是关抽屉)
/// - `false` → 冒泡给系统,根路由上就是退出到桌面
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => ProviderScope(
    child: MaterialApp(theme: buildLightTheme(), home: const AppShell()),
  );

  Future<bool> pressBack(WidgetTester tester) async {
    final popped = await tester
        .state<NavigatorState>(find.byType(Navigator))
        .maybePop();
    await tester.pumpAndSettle();
    return popped;
  }

  testWidgets('抽屉开着时返回键只关抽屉,不退出到桌面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);

    // 返回被拦下(true = 没有冒泡给系统),抽屉关掉
    expect(await pressBack(tester), isTrue);
    expect(find.byType(Drawer), findsNothing);
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold)).isDrawerOpen,
      isFalse,
    );
  });

  testWidgets('抽屉关掉之后再按返回才冒泡给系统(退出到桌面)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    expect(await pressBack(tester), isTrue);
    // 第二次:抽屉已经关了,这一下必须放给系统,否则返回键就彻底失灵了
    expect(await pressBack(tester), isFalse);
  });

  testWidgets('抽屉没开时返回键直接冒泡,不被无故吞掉', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(await pressBack(tester), isFalse);
  });
}
