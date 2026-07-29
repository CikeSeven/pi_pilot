import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/settings/settings_sections.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => ProviderScope(
    child: MaterialApp(theme: buildLightTheme(), home: const SettingsScreen()),
  );

  testWidgets('索引页首屏就能看到全部 6 个入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 原来是 ~2,100dp(约 3 屏)的单页,其中 448dp 是纯分组标题留白
    for (final title in ['连接', '外观', '通知与快捷指令', '模型与行为', '当前会话', '关于']) {
      expect(find.text(title), findsOneWidget, reason: '缺少入口:$title');
    }
  });

  testWidgets('每个入口都能推进对应子页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cases = <String, Type>{
      '连接': ConnectionPage,
      '外观': AppearancePage,
      '通知与快捷指令': NotificationsPage,
      '模型与行为': BehaviorPage,
      '当前会话': SessionInfoPage,
      '关于': AboutPage,
    };

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    for (final entry in cases.entries) {
      // 靠后的入口在折叠线以下,先滚到可见
      await tester.scrollUntilVisible(find.text(entry.key), 120);
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(
        find.byType(entry.value),
        findsOneWidget,
        reason: '${entry.key} 没能推进 ${entry.value}',
      );
      // 退回索引页再试下一个 —— 同一棵树,路由栈是延续的
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('入口带当前值摘要,不用点进去才知道配了什么', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 默认赤陶 + 浅色
    expect(find.textContaining('赤陶'), findsOneWidget);
  });
}
