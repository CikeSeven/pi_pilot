import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/back_dispatch.dart';
import 'package:pi_pilot/ui/sessions/sessions_drawer.dart';
import 'package:pi_pilot/ui/shell/app_shell.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 抽屉开着时返回键必须只关抽屉,不能一下退到桌面。
///
/// `NavigatorState.maybePop` 的返回值正好区分这两种结局:
/// - `true`  → 被 PopScope 拦下并自行处理(这里是关抽屉)
/// - `false` → 冒泡给系统,根路由上就是退出到桌面
///
/// 抽屉现在不由 `Scaffold.drawer` 托管,而是 `_ChatTab` 按进度自渲染的一层
/// 面板(这样同一根手指的右滑/左滑才能连续驱动同一个进度值,见
/// `DrawerDragRecognizer`)。所以这里用真实手势拉开它,拦截判据仍是 maybePop。
///
/// 注意:新外壳(灵动岛/液态导航)有常驻动画,`pumpAndSettle` 会超时,
/// 所以这里一律用固定时长 pump。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => ProviderScope(
    child: MaterialApp(theme: buildLightTheme(), home: const AppShell()),
  );

  Future<bool> pressBack(WidgetTester tester) async {
    final popped = await tester
        .state<NavigatorState>(find.byType(Navigator))
        .maybePop();
    await tester.pump();
    // 抽屉收起动画 ~300ms,给 500ms 足够跑完;不能用 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 500));
    return popped;
  }

  /// 右滑把抽屉拉开并等落位动画跑完(同样不能 pumpAndSettle)。
  Future<void> openDrawer(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(200, 400));
    // 分步移动更接近真机采样;总位移要足够大,松手后才落到全开。
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('抽屉开着时返回键只关抽屉,不退出到桌面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await openDrawer(tester);
    expect(find.byType(SessionsDrawer), findsOneWidget);

    // 返回被拦下(true = 没有冒泡给系统),抽屉关掉
    expect(await pressBack(tester), isTrue);
    // 抽屉常驻树内(进度归零时整体停在屏外),判定看位置不看在不在树里。
    expect(tester.getRect(find.byType(SessionsDrawer)).right, 0);
  });

  testWidgets('抽屉关掉之后再按返回才冒泡给系统(退出到桌面)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await openDrawer(tester);

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

  testWidgets('灵动岛展开时返回键只收岛,不退出到桌面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppShell)),
    );
    container.read(islandExpandedProvider.notifier).state = true;
    await tester.pump();

    // 被拦下(true)并收岛;再按一下才放行给系统。
    expect(await pressBack(tester), isTrue);
    expect(container.read(islandExpandedProvider), isFalse);
    expect(await pressBack(tester), isFalse);
  });

  testWidgets('模型选择展开时返回键只收选择器,不退出到桌面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppShell)),
    );
    container.read(modelPickerExpandedProvider.notifier).state = true;
    await tester.pump();

    expect(await pressBack(tester), isTrue);
    expect(container.read(modelPickerExpandedProvider), isFalse);
    expect(await pressBack(tester), isFalse);
  });

  testWidgets('设备页按返回切回对话页,再按才退出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 左滑翻页到「设备」(抽屉识别器对左滑会让位给 PageView)。
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 被拦下(true)并切回对话页;再按一下才放行给系统。
    expect(await pressBack(tester), isTrue);
    expect(await pressBack(tester), isFalse);
  });
}
