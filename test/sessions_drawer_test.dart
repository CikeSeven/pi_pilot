import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/device_models.dart';
import 'package:pi_pilot/state/device_manager.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/sessions/sessions_drawer.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只给抽屉喂固定状态的假会话:notifier 不连网,selectSource 只记账。
class _FakeSession extends PiSessionNotifier {
  _FakeSession(super.deviceId, this._initial);

  final PiState _initial;
  final List<String> selectedSources = [];

  @override
  PiState build() => _initial;

  @override
  Future<bool> selectSource(String sourceId, {bool persist = true}) async {
    selectedSources.add(sourceId);
    state = state.copyWith(selectedSourceId: sourceId);
    return true;
  }
}

/// roster 固定的假设备管理:不读盘、不发现、不连网。
class _FakeManager extends DeviceManagerNotifier {
  _FakeManager(this._initial);

  final DeviceManagerState _initial;

  @override
  DeviceManagerState build() => _initial;

  @override
  Future<void> setActive(String deviceId) async {
    state = state.copyWith(activeDeviceId: deviceId);
  }
}

SourceInfo _window(
  String id, {
  String? cwd,
  String? sessionName,
  bool connected = true,
  bool desktop = true,
}) => SourceInfo(
  id: id,
  kind: desktop ? PiSourceKind.desktop : PiSourceKind.headless,
  label: id,
  connected: connected,
  epoch: 'epoch-$id',
  capabilities: const [],
  ownerPresent: false,
  ownedByYou: false,
  cwd: cwd,
  sessionName: sessionName,
);

PiState _connected({
  List<SourceInfo> sources = const [],
  List<HubSession> sessions = const [],
  String? selectedSourceId,
}) => PiState.initial().copyWith(
  status: PiConnStatus.connected,
  sources: sources,
  sessions: sessions,
  selectedSourceId: selectedSourceId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const work = DeviceProfile(
    id: 'dev-work',
    name: '工作机',
    host: '192.168.1.10',
    port: 9377,
    token: 't-work',
  );
  const home = DeviceProfile(
    id: 'dev-home',
    name: '家里的 Mac',
    host: '192.168.1.20',
    port: 9377,
    token: 't-home',
  );

  final harness = <String, _FakeSession>{};

  Widget wrap({
    required DeviceManagerState manager,
    required Map<String, PiState> sessions,
  }) => ProviderScope(
    overrides: [
      deviceManagerProvider.overrideWith(() => _FakeManager(manager)),
      piSessionFamilyProvider.overrideWith2(
        (deviceId) => harness[deviceId] = _FakeSession(
          deviceId,
          sessions[deviceId] ?? PiState.initial(),
        ),
      ),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: const Scaffold(drawer: SessionsDrawer(), body: SizedBox()),
    ),
  );

  /// EditorialOrnament 有常驻动画,pumpAndSettle 会超时。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openDrawer(WidgetTester tester) async {
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await settle(tester);
  }

  DeviceManagerState roster() => const DeviceManagerState(
    devices: [work, home],
    activeDeviceId: 'dev-work',
    loaded: true,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    harness.clear();
  });

  testWidgets('按设备分组列出开着的窗口,设备名做分割线', (tester) async {
    await tester.pumpWidget(
      wrap(
        manager: roster(),
        sessions: {
          'dev-work': _connected(
            selectedSourceId: 'win-1',
            sources: [
              _window('win-1', sessionName: '修复登录页', cwd: '/home/u/app'),
              _window('win-2', sessionName: '写周报', cwd: '/home/u/notes'),
            ],
            sessions: [
              HubSession(
                sessionId: 's-2',
                sourceId: 'win-2',
                liveness: SessionLiveness.desktop,
                connected: true,
                streaming: true,
              ),
            ],
          ),
          'dev-home': _connected(
            sources: [_window('win-3', sessionName: '重构支付', cwd: '/u/pay')],
          ),
        },
      ),
    );
    await openDrawer(tester);

    // 设备名各自作为分割线标题出现。
    expect(find.text('工作机'), findsOneWidget);
    expect(find.text('家里的 Mac'), findsOneWidget);
    // 窗口按设备分组列出;当前选中的那个有「当前」标记。
    expect(find.text('修复登录页'), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    expect(find.text('重构支付'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    // win-2 正在流式生成,副标让位给状态行(尾部 spinner 与「当前」徽标
    // 互斥:流式优先,所以把流式放在非当前窗口上断言)。
    expect(find.text('正在生成…'), findsOneWidget);
  });

  testWidgets('没开窗口的设备整组隐藏,不留空分割线', (tester) async {
    await tester.pumpWidget(
      wrap(
        manager: roster(),
        sessions: {
          'dev-work': _connected(
            sources: [_window('win-1', sessionName: '修复登录页')],
          ),
          'dev-home': _connected(),
        },
      ),
    );
    await openDrawer(tester);

    expect(find.text('工作机'), findsOneWidget);
    expect(find.text('修复登录页'), findsOneWidget);
    expect(find.text('家里的 Mac'), findsNothing);
    expect(find.text('没有打开的窗口'), findsNothing);
  });

  testWidgets('headless 与已断开的源不算「开着的窗口」', (tester) async {
    await tester.pumpWidget(
      wrap(
        manager: const DeviceManagerState(
          devices: [work],
          activeDeviceId: 'dev-work',
          loaded: true,
        ),
        sessions: {
          'dev-work': _connected(
            sources: [
              _window('win-live', sessionName: '活着的窗口'),
              _window('win-dead', sessionName: '断开的窗口', connected: false),
              _window('win-pool', sessionName: '进程池会话', desktop: false),
            ],
          ),
        },
      ),
    );
    await openDrawer(tester);

    expect(find.text('活着的窗口'), findsOneWidget);
    expect(find.text('断开的窗口'), findsNothing);
    expect(find.text('进程池会话'), findsNothing);
  });

  testWidgets('点另一台设备的窗口:切设备 + 选源 + 关抽屉', (tester) async {
    await tester.pumpWidget(
      wrap(
        manager: roster(),
        sessions: {
          'dev-work': _connected(
            selectedSourceId: 'win-1',
            sources: [_window('win-1', sessionName: '修复登录页')],
          ),
          'dev-home': _connected(
            sources: [_window('win-3', sessionName: '重构支付')],
          ),
        },
      ),
    );
    await openDrawer(tester);

    await tester.tap(find.text('重构支付'));
    await settle(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );
    expect(container.read(deviceManagerProvider).activeDeviceId, 'dev-home');
    expect(harness['dev-home']!.selectedSources, ['win-3']);
    // 抽屉已关闭。
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('点当前窗口只关抽屉,不重复选源', (tester) async {
    await tester.pumpWidget(
      wrap(
        manager: roster(),
        sessions: {
          'dev-work': _connected(
            selectedSourceId: 'win-1',
            sources: [_window('win-1', sessionName: '修复登录页')],
          ),
          'dev-home': _connected(
            sources: [_window('win-3', sessionName: '重构支付')],
          ),
        },
      ),
    );
    await openDrawer(tester);

    await tester.tap(find.text('修复登录页'));
    await settle(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );
    expect(container.read(deviceManagerProvider).activeDeviceId, 'dev-work');
    expect(harness['dev-work']!.selectedSources, isEmpty);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('有设备但没开窗口:空态引导去电脑上开窗', (tester) async {
    await tester.pumpWidget(wrap(manager: roster(), sessions: const {}));
    await openDrawer(tester);

    expect(find.text('没有打开的窗口'), findsOneWidget);
    expect(find.text('还没有设备'), findsNothing);
  });

  testWidgets('roster 为空:空态引导去设备页添加', (tester) async {
    await tester.pumpWidget(
      wrap(manager: const DeviceManagerState(loaded: true), sessions: const {}),
    );
    await openDrawer(tester);

    expect(find.text('还没有设备'), findsOneWidget);
    expect(find.text('没有打开的窗口'), findsNothing);
  });
}
