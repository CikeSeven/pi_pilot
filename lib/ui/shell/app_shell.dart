import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_body.dart';
import '../chat/widgets/island_bar.dart';
import '../sessions/devices_page.dart';
import '../settings/settings_screen.dart';
import '../theme/motion.dart';
import '../theme/paper.dart';
import 'liquid_nav_bar.dart';

/// 应用外壳:**PageView 左右滑动切页 + 导航栏跟随弹出**。
///
/// 用 Flutter 原生 `PageView` 替代手写手势 —— 它自带跟手、回弹、
/// 手势竞争处理,是最可靠的方案。三页用 `AutomaticKeepAliveClientMixin`
/// 保活,切页不丢状态。
///
/// 导航栏在 PageView 滚动时显示(指示器跟着滚动位置),停止时淡出收起。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  // 会话是主页面,放中间:往左滑到设备(窗口),往右滑到设置。
  final _pageController = PageController(initialPage: 1);
  int _index = 1;

  static const _keys = [
    GlobalObjectKey('tab-settings'),
    GlobalObjectKey('tab-chat'),
    GlobalObjectKey('tab-devices'),
  ];

  static const _tabs = [
    NavTabSpec(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: '设置',
    ),
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
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTap(int i) {
    if (i == _index) return;
    _pageController.animateToPage(
      i,
      duration: PiMotion.standard,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLow;

    return Scaffold(
      extendBody: true,
      body: BackdropPaper(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── 三页(PageView 自带左右滑动,跟手、回弹) ──
            PageView(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _index = i),
              children: [
                _KeepAlivePage(key: _keys[0], child: const SettingsScreen()),
                _KeepAlivePage(key: _keys[1], child: const _ChatTab()),
                _KeepAlivePage(key: _keys[2], child: const DevicesPage()),
              ],
            ),
            // ── 导航栏(PageView 滚动时显示,指示器跟着滚动位置) ──
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: AnimatedBuilder(
                  animation: _pageController,
                  builder: (context, _) {
                    final page = _pageController.hasClients
                        ? (_pageController.page ?? 0.0)
                        : 0.0;
                    // 滚动中显示,停止时隐藏
                    final isScrolling =
                        _pageController.hasClients &&
                        _pageController.position.isScrollingNotifier.value;
                    final opacity = isScrolling ? 1.0 : 0.0;
                    return AnimatedOpacity(
                      opacity: opacity,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: opacity < 0.5,
                        child: Container(
                          color: bg,
                          child: LiquidNavBar(
                            selectedIndex: _index,
                            tabs: _tabs,
                            onTap: _onTabTap,
                            // 滚动时传浮点位置,指示器跟着滚动;
                            // 停止时传 null,走内部水滴动画。
                            position: isScrolling ? page : null,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 保活包装:让 PageView 的每一页在切走时不被销毁。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({super.key, required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 会话 tab:灵动岛 + 消息流。
class _ChatTab extends StatefulWidget {
  const _ChatTab();

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _islandKey = GlobalKey<DynamicIslandBarState>();
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
        extendBodyBehindAppBar: true,
        drawer: const DevicesDrawer(),
        // 左边缘 60px 内滑动开抽屉。其他区域让 PageView 处理横向手势。
        drawerEdgeDragWidth: 60,
        onDrawerChanged: (isOpen) {
          if (!isOpen) FocusManager.instance.primaryFocus?.unfocus();
          if (isOpen != _drawerOpen) setState(() => _drawerOpen = isOpen);
        },
        // 无常驻 AppBar —— 灵动岛浮在内容上,内容区全屏,
        // 顶部渐变遮罩让滚上去的内容渐隐,岛只占自己那一小块。
        body: NotificationListener<ScrollNotification>(
          // 滚动列表时自动收起灵动岛(iOS 标准行为)。
          onNotification: (n) {
            if (n is ScrollStartNotification) {
              _islandKey.currentState?.collapse();
            }
            return false;
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              ChatBody(topPadding: MediaQuery.paddingOf(context).top + 52),
              // 灵动岛:平时小胶囊,点击展开成完整信息卡。
              DynamicIslandBar(
                key: _islandKey,
                onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
