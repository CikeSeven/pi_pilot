import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/device_models.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/device_manager.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/settings/settings_sections.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 多设备改造后「保存并连接」走 roster:upsertDevice 即触发连接编排
/// (详见 device_manager.dart)。假 manager 只记录 upsert,不真打网络。
class _FakeDeviceManager extends DeviceManagerNotifier {
  final List<DeviceProfile> upserts = [];

  @override
  DeviceManagerState build() => const DeviceManagerState(loaded: true);

  @override
  Future<void> upsertDevice(
    DeviceProfile device, {
    bool connect = true,
  }) async {
    upserts.add(device);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => ProviderScope(
    child: MaterialApp(theme: buildLightTheme(), home: const SettingsScreen()),
  );

  /// 设置页里有常驻动画(纸面动效),pumpAndSettle 会超时。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('索引页首屏就能看到全部 6 个入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

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
    await settle(tester);

    for (final entry in cases.entries) {
      // 靠后的入口在折叠线以下,先滚到可见
      await tester.scrollUntilVisible(find.text(entry.key), 120);
      await settle(tester);
      await tester.tap(find.text(entry.key));
      await settle(tester);
      expect(
        find.byType(entry.value),
        findsOneWidget,
        reason: '${entry.key} 没能推进 ${entry.value}',
      );
      // 退回索引页再试下一个 —— 同一棵树,路由栈是延续的
      await tester.pageBack();
      await settle(tester);
    }
  });

  testWidgets('保存并连接会同时保存 P2P 卡内容', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fakeManager = _FakeDeviceManager();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceManagerProvider.overrideWith(() => fakeManager)],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const ConnectionPage(),
        ),
      ),
    );
    await settle(tester);

    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

    await tester.enterText(field('主机'), '192.168.1.10');
    await tester.enterText(field('端口'), '9377');
    await tester.enterText(field('Token'), 'hub-token');

    await tester.scrollUntilVisible(
      find.text('远程打洞(P2P)'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
    final p2pSwitch = tester.widget<Switch>(find.byType(Switch));
    p2pSwitch.onChanged?.call(true);
    await tester.pump();
    await tester.enterText(field('信令服地址'), 'relay.example');
    await tester.enterText(field('设备名'), 'home-pc');
    await tester.enterText(field('配对密钥'), 'pairing-secret');

    await tester.ensureVisible(find.text('保存并连接'));
    await tester.pump();
    await tester.tap(find.text('保存并连接'));
    await settle(tester);

    final saved = await SettingsRepository().load();
    expect(saved.p2pEnabled, isTrue);
    expect(saved.p2pRendezvous, 'wss://relay.example');
    expect(saved.p2pDeviceId, 'home-pc');
    expect(saved.p2pSecret, 'pairing-secret');

    // 「保存并连接」= 写入 roster(upsert 内部触发连接编排)。
    expect(fakeManager.upserts, hasLength(1));
    final upserted = fakeManager.upserts.single;
    expect(upserted.host, '192.168.1.10');
    expect(upserted.p2pDeviceId, 'home-pc');
    expect(upserted.transport, DeviceTransport.auto);
  });

  testWidgets('公网明文信令会阻止保存与连接', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fakeManager = _FakeDeviceManager();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceManagerProvider.overrideWith(() => fakeManager)],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const ConnectionPage(),
        ),
      ),
    );
    await settle(tester);

    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

    await tester.enterText(field('主机'), '192.168.1.10');
    await tester.enterText(field('Token'), 'hub-token');
    await tester.scrollUntilVisible(
      find.text('远程打洞(P2P)'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
    tester.widget<Switch>(find.byType(Switch)).onChanged?.call(true);
    await tester.pump();
    await tester.enterText(field('信令服地址'), 'ws://relay.example:9378');
    await tester.enterText(field('设备名'), 'home-pc');
    await tester.enterText(field('配对密钥'), 'pairing-secret');

    await tester.ensureVisible(find.text('保存并连接'));
    await tester.pump();
    await tester.tap(find.text('保存并连接'));
    await settle(tester);

    expect(find.text('公网信令必须使用 wss://,ws:// 仅限本机测试'), findsOneWidget);
    final saved = await SettingsRepository().load();
    expect(saved.p2pEnabled, isFalse);
    // 校验失败 → 不落 roster、不发起连接。
    expect(fakeManager.upserts, isEmpty);
  });

  testWidgets('入口带当前值摘要,不用点进去才知道配了什么', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 默认赤陶 + 浅色
    expect(find.textContaining('赤陶'), findsOneWidget);
  });
}
