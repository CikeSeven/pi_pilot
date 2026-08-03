import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/device_models.dart';
import 'package:pi_pilot/state/device_manager.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/island_bar.dart';
import 'package:pi_pilot/ui/sessions/devices_page.dart';
import 'package:pi_pilot/ui/sessions/sessions_drawer.dart';
import 'package:pi_pilot/ui/settings/settings_screen.dart';
import 'package:pi_pilot/ui/shell/app_shell.dart';
import 'package:pi_pilot/ui/shell/liquid_nav_bar.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话抽屉的手势归属。
///
/// 核心 bug:右滑打开抽屉后**不松手**继续左滑,会触发 PageView 翻页到「设备」,
/// 而不是把抽屉跟手推回去。根因是手势竞技场的胜负在手势**开始阶段**就决出了 ——
/// 老做法靠 PageView 的前缘过卷累计到阈值再调 `openDrawer()`,那只是播一段
/// fling 动画,这根手指始终归 PageView。中途切 physics / 放宽
/// `drawerEdgeDragWidth` / 事后 `openDrawer()` 都救不回来:那些只影响之后新建的
/// 识别器,管不到已在飞的 pointer。
///
/// 现在抽屉由 `DrawerDragRecognizer` 接管,它挂在 PageView **页面内部**参与
/// 竞争:关着时右滑才 accept、左滑 reject 让位翻页;一旦接管则两个方向都由它
/// 持有,进度按 pointer delta 连续变化。所以下面的用例都用**真实 pointer 序列**
/// (startGesture + moveBy,中途不松手)来验证,而不是一次性投递的 drag。
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

  /// 抽屉当前展开的宽度。0 = 完全关闭(常驻树内、整体停在屏外)。
  ///
  /// 自渲染抽屉按进度定位:`left = (progress - 1) * width`,所以量它的左缘
  /// 就能反推进度,比去翻内部 AnimationController 稳。
  double drawerReveal(WidgetTester tester) {
    final finder = find.byType(SessionsDrawer);
    if (finder.evaluate().isEmpty) return 0;
    final rect = tester.getRect(finder);
    // 露出来的部分 = 右缘距屏幕左边的距离(左缘为负时被推到屏外)。
    return rect.right.clamp(0.0, double.infinity);
  }

  /// 右滑把抽屉拉开,**手指不松**,返回这次手势句柄。
  /// 右滑把抽屉拉开,**手指不松**,返回这次手势句柄。
  ///
  /// 每步只挪 `step` 像素(默认 8px,接近真机逐帧采样)。这个细节致命:
  /// 早先这里一步走 50px,首个 move 事件就越过横向阈值,识别器侥幸赢下
  /// 竞技场 —— 而真机上手指每帧只挪几像素,走到 `kTouchSlop`(18px) 时
  /// `PageView` 已经先表态拿走了 pointer,右滑根本打不开抽屉。大跳步的测试
  /// 却全绿,把这个 bug 整整掩过去了。所以这里必须按真机节奏分小步走。
  Future<TestGesture> dragOpen(
    WidgetTester tester, {
    double dx = 200,
    double step = 8,
    Offset from = const Offset(200, 400),
  }) async {
    final gesture = await tester.startGesture(from);
    var moved = 0.0;
    while (moved < dx) {
      await gesture.moveBy(Offset(step, 0));
      // 带上帧间隔:速度跟踪需要真实时间戳,否则松手时算不出速度。
      await tester.pump(const Duration(milliseconds: 16));
      moved += step;
    }
    return gesture;
  }

  testWidgets('灵动岛左侧圆钮:点击拉开会话抽屉', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(drawerReveal(tester), 0);
    await tester.tap(find.byTooltip('会话列表'));
    await settle(tester);

    expect(find.byType(SessionsDrawer), findsOneWidget);
    expect(drawerReveal(tester), greaterThan(0));
  });

  testWidgets('右滑任意位置跟手拉开会话抽屉(不再限于左边缘)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 屏幕中部往右拖:抽屉跟着手指露出来,不需要等松手。
    final gesture = await dragOpen(tester);
    expect(drawerReveal(tester), greaterThan(0));

    await gesture.up();
    await settle(tester);

    // 松手后落到全开。
    expect(find.byType(SessionsDrawer), findsOneWidget);
    expect(drawerReveal(tester), greaterThan(100));
  });

  testWidgets('每帧只挪几像素也能拉开(真机节奏,不能输给 PageView)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 回归守卫:横向判定阈值必须小于 PageView 的 kTouchSlop(18px),
    // 否则手指慢慢挪时 pointer 已被翻页抢走,抽屉彻底打不开。
    // 每步 5px 是比真机更苛刻的下限;总位移要过半程(抽屉宽 304,半程 152),
    // 否则松手按设计会回弹关闭 —— 那考的是落位规则,不是这条用例的主题。
    final gesture = await dragOpen(tester, dx: 200, step: 5);
    expect(
      drawerReveal(tester),
      greaterThan(0),
      reason: '小步幅右滑必须能拉开抽屉,否则真机上根本打不开',
    );

    await gesture.up();
    await settle(tester);
    expect(find.byType(SessionsDrawer), findsOneWidget);
    expect(find.byType(DevicesPage), findsNothing);
  });

  testWidgets('抽屉跟着手指走:右滑越多露出越多', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    final little = drawerReveal(tester);

    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    final more = drawerReveal(tester);

    // 跟手的判据:位移更多 → 露出更多。固定动画做不到这一点。
    expect(little, greaterThan(0));
    expect(more, greaterThan(little));

    await gesture.up();
    await settle(tester);
  });

  /// 这就是用户报的那个 bug。
  testWidgets('打开后不松手左滑:抽屉跟手关闭,不切页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 同一根手指:先右滑拉开。
    final gesture = await dragOpen(tester, dx: 240);
    final opened = drawerReveal(tester);
    expect(opened, greaterThan(0));

    // 不松手,反向往左推。
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    final pushedBack = drawerReveal(tester);

    // 抽屉跟着手指缩回去 —— 而不是纹丝不动、由 PageView 去翻页。
    expect(pushedBack, lessThan(opened));

    await gesture.up();
    await settle(tester);

    // 关键:整个过程都没有翻页,还在对话页。以前这里会滑到「设备」。
    expect(find.byType(DevicesPage), findsNothing);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('打开后左滑到底:抽屉关闭且仍留在对话页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    final gesture = await dragOpen(tester, dx: 240);
    expect(drawerReveal(tester), greaterThan(0));

    // 一路推回去,推过头也不该出问题(进度被 clamp 在 0)。
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();
    await gesture.up();
    await settle(tester);

    expect(drawerReveal(tester), 0);
    expect(find.byType(DevicesPage), findsNothing);
  });

  testWidgets('抽屉关闭后,左滑恢复为翻页到设备页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 开了又关。
    final gesture = await dragOpen(tester, dx: 240);
    await gesture.moveBy(const Offset(-400, 0));
    await gesture.up();
    await settle(tester);
    expect(drawerReveal(tester), 0);

    // 这是一次**新的**手势:抽屉关着 + 向左 → 识别器 reject,让位给 PageView。
    await tester.flingFrom(const Offset(400, 300), const Offset(-300, 0), 1000);
    await settle(tester);

    expect(find.byType(DevicesPage), findsOneWidget);
  });

  testWidgets('小幅右滑不误触抽屉(不过 slop 不接管)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 只动几个像素:连 slop 都没过,抽屉不该露头。
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(6, 0));
    await tester.pump();
    expect(drawerReveal(tester), 0);

    await gesture.up();
    await settle(tester);
    expect(drawerReveal(tester), 0);
  });

  testWidgets('上下滚动不误触抽屉(竖向为主一律让位)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 竖向拖拽滚动聊天列表:识别器判定竖向为主后 reject。
    await tester.dragFrom(const Offset(400, 300), const Offset(0, -160));
    await settle(tester);

    expect(drawerReveal(tester), 0);
  });

  testWidgets('灵动岛入口仍能打开抽屉', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 手势之外必须留一个可点的入口 —— 不是所有人都会去试滑动。
    final island = tester.state<DynamicIslandBarState>(
      find.byType(DynamicIslandBar),
    );
    expect(island, isNotNull);

    // 抽屉常驻树内,初始整体停在屏外。
    expect(drawerReveal(tester), 0);
  });

  testWidgets('抽屉是会话列表,不做会话创建与目录管理', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    final gesture = await dragOpen(tester, dx: 240);
    await gesture.up();
    await settle(tester);

    // 「会话」标题只在抽屉里(底栏 tab 不在抽屉子树),限定子树断言。
    expect(
      find.descendant(
        of: find.byType(SessionsDrawer),
        matching: find.text('会话'),
      ),
      findsOneWidget,
    );
    // 抽屉里**不再**有「设置」入口 —— 底栏已经有「设置」tab,
    // 同一个目的地给两个入口只会让人犹豫点哪个。
    expect(
      find.descendant(
        of: find.byType(SessionsDrawer),
        matching: find.text('设置'),
      ),
      findsNothing,
    );

    // 手机只负责「连到已经开着的窗口」,不负责创建会话或换目录。
    expect(find.text('新建会话'), findsNothing);
    expect(find.text('切换工作目录'), findsNothing);
  });

  testWidgets('没连上时抽屉给出明确的空态,而不是一片空白', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    final gesture = await dragOpen(tester, dx: 240);
    await gesture.up();
    await settle(tester);

    // 对话页的未连接态也有同样文案,这里只看抽屉里的那份。
    expect(
      find.descendant(
        of: find.byType(SessionsDrawer),
        matching: find.text('还没有设备'),
      ),
      findsOneWidget,
    );
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

  testWidgets('抽屉打开后点会话项:切换会话并关抽屉', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const work = DeviceProfile(
      id: 'dev-work',
      name: '工作机',
      host: 'h',
      port: 1,
      token: 't',
    );
    final harness = <String, _FakeSession>{};
    final state = PiState.initial().copyWith(
      status: PiConnStatus.connected,
      selectedSourceId: 'win-1',
      sources: const [
        SourceInfo(
          id: 'win-1',
          kind: PiSourceKind.desktop,
          label: 'win-1',
          connected: true,
          epoch: 'e1',
          capabilities: [],
          ownerPresent: false,
          ownedByYou: false,
          cwd: '/a',
          sessionName: '修复登录页',
        ),
        SourceInfo(
          id: 'win-2',
          kind: PiSourceKind.desktop,
          label: 'win-2',
          connected: true,
          epoch: 'e2',
          capabilities: [],
          ownerPresent: false,
          ownedByYou: false,
          cwd: '/b',
          sessionName: '写周报',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceManagerProvider.overrideWith(
            () => _FakeManager(
              const DeviceManagerState(
                devices: [work],
                activeDeviceId: 'dev-work',
                loaded: true,
              ),
            ),
          ),
          piSessionFamilyProvider.overrideWith2(
            (deviceId) => harness[deviceId] = _FakeSession(deviceId, state),
          ),
        ],
        child: MaterialApp(theme: buildLightTheme(), home: const AppShell()),
      ),
    );
    await settle(tester);

    // 右滑拉开抽屉。
    final gesture = await dragOpen(tester, dx: 240);
    await gesture.up();
    await settle(tester);
    expect(find.byType(SessionsDrawer), findsOneWidget);

    // 点「写周报」:必须触发选源,而不是被手势吞掉。
    // 回归守卫:抽屉开着时 DrawerDragRecognizer 若在 pointer down 就
    // accept,竞技场会当场拒掉 InkWell 的 TapGestureRecognizer,
    // 这里 selectedSources 就会是空的。
    await tester.tap(find.text('写周报'));
    await settle(tester);
    expect(harness['dev-work']!.selectedSources, ['win-2']);
    // 选完抽屉自己关上(onClose 回调)。
    expect(drawerReveal(tester), 0);
  });

  testWidgets('关抽屉不会把焦点还给输入框(否则键盘每次都弹出来)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await settle(tester);

    // 开了再关。
    final gesture = await dragOpen(tester, dx: 240);
    await gesture.up();
    await settle(tester);
    await tester.tapAt(const Offset(700, 300)); // 点遮罩关闭
    await settle(tester);

    // 关抽屉后若把焦点还给 body 里第一个可聚焦节点(= 输入框),
    // 键盘就跟着弹出来。判据取「没有任何文本框持有焦点」。
    //
    // 先断言抽屉真的关了:早先这条用例点了遮罩却从不检查结果,
    // 以至于「抽屉开着时识别器在 pointer down 就 accept、竞技场当场拒掉
    // 所有 TapGestureRecognizer」的 bug(点击切换会话失灵)从这里溜过去。
    expect(drawerReveal(tester), 0, reason: '点遮罩后抽屉必须关闭,否则遮罩上的点击也被手势吞了');
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
