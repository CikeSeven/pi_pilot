import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_body.dart';
import '../chat/widgets/chat_app_bar.dart';
import '../sessions/devices_page.dart';
import '../settings/settings_screen.dart';
import '../theme/motion.dart';
import '../theme/paper.dart';
import 'liquid_nav_bar.dart';
import 'swipe_to_open_drawer.dart';

/// 应用外壳:**三页常驻 + 同步横向滑动 + 水滴底栏**。
///
/// ## 为什么从右往左会卡(旧版的 bug)
///
/// 旧版非动画态只保留当前页,其他页从树中移除。于是切走再切回时,目标页
/// 要**重新构建**。"从右往左"通常切回最重的会话页(长列表+输入框+滚动状态),
/// 重建就卡;"从左往右"切向较轻页面,感觉丝滑 —— 其实是页面重量差异,
/// 不是方向差异。
///
/// ## 正解:三页常驻,只移动位置
///
/// 三页在 `initState` 一次性构建、常驻一个 `Stack`,切换时**只改位置**,
/// 不构建也不销毁。所有页面状态(滚动、输入、窗口)始终保留,切回去零开销。
///
/// 位置由一个浮点 `display` 决定:动画时从 `oldIndex` 连续插值到 `index`,
/// 每页的偏移 = `(i - display)` 屏宽。三页用**同一个 display**,
/// 物理上不可能不同步 —— 这是丝滑的根本保证。双向对称,不再有方向差异。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with TickerProviderStateMixin {
  int _index = 0;
  int _oldIndex = 0;
  AnimationController? _controller;

  /// 三页常驻引用:只构建一次,之后切换只移动它们,绝不重建。
  /// 这是双向丝滑的关键 —— 切回去时滚动位置/输入内容/窗口大小都不丢。
  static const _keys = [
    GlobalObjectKey('tab-chat'),
    GlobalObjectKey('tab-devices'),
    GlobalObjectKey('tab-settings'),
  ];

  late final List<Widget> _pages;

  static const _tabs = [
    NavTabSpec(
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
      label: '会话',
    ),
    NavTabSpec(
      icon: Icons.devices_outlined,
      selectedIcon: Icons.devices,
      label: '设备',
    ),
    NavTabSpec(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: '设置',
    ),
  ];

  @override
  void initState() {
    super.initState();
    // 一次性构建三页,常驻整个 app 生命周期。
    _pages = [
      _ChatTab(key: _keys[0]),
      DevicesPage(key: _keys[1]),
      SettingsScreen(key: _keys[2]),
    ];
  }

  void _switchTo(int i) {
    if (i == _index) return;
    // 切换中途又点新的:跳到上一个动画的终点,再开新动画。
    _controller?.stop();
    setState(() {
      _oldIndex = _index;
      _index = i;
    });
    _controller = AnimationController(
      vsync: this,
      duration: PiMotion.standard,
    )..addListener(() => setState(() {}));
    _controller!.forward().then((_) {
      _controller?.dispose();
      _controller = null;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    final isAnimating = ctrl != null && ctrl.isAnimating;
    // display:当前「连续」位置。静止时 = _index;动画时从 _oldIndex 插值到 _index。
    final display = isAnimating
        ? _oldIndex + (_index - _oldIndex) * _easeOutCubic(ctrl.value)
        : _index.toDouble();

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: BackdropPaper(
        // 背景常驻,切换时这层完全不动。
        child: Stack(
          fit: StackFit.expand,
          // 裁掉移出屏幕的页面,不让它们画到背景层上。
          clipBehavior: Clip.hardEdge,
          children: [
            // 三页全部常驻,每页只随 display 移动。
            // offset = (i - display):当前页 ≈ 0(居中),左侧页 <0(屏外左),
            // 右侧页 >0(屏外右)。三页偏移之差始终是整数屏宽,
            // 永不重叠 → 不会出现「两页同时叠在一起」。
            for (var i = 0; i < _pages.length; i++)
              Positioned.fill(
                child: FractionalTranslation(
                  translation: Offset(i - display, 0),
                  child: _pages[i],
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: LiquidNavBar(
        selectedIndex: _index,
        tabs: _tabs,
        onTap: _switchTo,
      ),
    );
  }
}

/// 会话 tab:顶栏 + 消息流。
///
/// 不带自己的背景 —— 背景由外层 [AppShell] 的 BackdropPaper 统一提供。
class _ChatTab extends StatefulWidget {
  const _ChatTab({super.key});

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _drawerOpen = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _scaffoldKey.currentState?.closeDrawer();
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.transparent,
        drawer: const DevicesDrawer(),
        onDrawerChanged: (isOpen) {
          if (!isOpen) FocusManager.instance.primaryFocus?.unfocus();
          if (isOpen != _drawerOpen) setState(() => _drawerOpen = isOpen);
        },
        appBar: const ChatAppBar(),
        // 右滑开抽屉。挂在 body 外面而不是放大 drawerEdgeDragWidth ——
        // 那个检测器叠在 body 之上,加宽会抢掉聊天页里代码块/diff/芯片行的
        // 横向滚动。详见 SwipeToOpenDrawer 的注释。
        body: SwipeToOpenDrawer(
          enabled: !_drawerOpen,
          onOpen: () => _scaffoldKey.currentState?.openDrawer(),
          child: const ChatBody(),
        ),
      ),
    );
  }
}

/// ease-out 三次曲线:快进慢出。手动插值用(controller 的 Curve 通道喂不进来)。
double _easeOutCubic(double t) {
  final v = 1 - math.pow(1 - t, 3);
  return v.toDouble();
}
