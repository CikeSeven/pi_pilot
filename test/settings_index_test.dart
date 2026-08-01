import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pi_pilot/ui/settings/diagnostics_page.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/settings/settings_sections.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => ProviderScope(
    child: MaterialApp(theme: buildLightTheme(), home: const SettingsScreen()),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('设置页不再提供旧的单设备连接入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.text('连接'), findsNothing);
    for (final title in ['外观', '通知与快捷指令', '模型与行为', '当前会话', '关于', '诊断']) {
      expect(find.text(title), findsOneWidget, reason: '缺少入口:$title');
    }
  });

  testWidgets('设置页入口仍能推进对应子页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cases = <String, Type>{
      '外观': AppearancePage,
      '通知与快捷指令': NotificationsPage,
      '模型与行为': BehaviorPage,
      '当前会话': SessionInfoPage,
      '关于': AboutPage,
      '诊断': DiagnosticsPage,
    };

    await tester.pumpWidget(wrap());
    await settle(tester);

    for (final entry in cases.entries) {
      await tester.scrollUntilVisible(find.text(entry.key), 120);
      await settle(tester);
      await tester.tap(find.text(entry.key));
      await settle(tester);
      expect(find.byType(entry.value), findsOneWidget);
      await tester.pageBack();
      await settle(tester);
    }
  });

  testWidgets('设置页保留全局通知设置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);
    await tester.tap(find.text('通知与快捷指令'));
    await settle(tester);

    expect(find.text('后台通知'), findsOneWidget);
    expect(find.text('震动'), findsOneWidget);
    expect(find.text('系统通知设置'), findsOneWidget);
  });
}
