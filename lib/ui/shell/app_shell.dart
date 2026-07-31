import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_body.dart';
import '../chat/widgets/island_bar.dart';
import '../sessions/devices_page.dart';
import '../sessions/sessions_drawer.dart';
import '../settings/settings_screen.dart';
import '../theme/motion.dart';
import '../theme/paper.dart';
import 'liquid_nav_bar.dart';

/// 应用外壳:**PageView 左右滑动切页 + 液态导航栏**。
///
/// 用 Flutter 原生 `PageView` 替代手写手势 —— 它自带跟手、回弹、
/// 手势竞争处理,是最可靠的方案。三页用 `AutomaticKeepAliveClientMixin`
/// 保活,切页不丢状态。
///
/// 页面顺序:对话 | 设备 | 设置。导航栏可见性按页区分:
/// 对话页内容全屏优先,导航栏平时收起、滑动时现身;
/// 设备/设置页导航栏常驻,随时能切走。
///
/// 对话页是第一页,右滑本来只会回弹 —— 把这个废手势利用起来开
/// 「会话抽屉」:横向前缘过卷累计超过阈值即打开(见
/// [_onScrollNotification])。按轴过滤后上下滚动不会误触。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  // 对话是主页面,放第一页(initialPage 默认 0):往左依次是设备、设置。
  final _pageController = PageController();
  int _index = 0;

  /// 对话页抽屉的 Scaffold key 提到这层:右滑过卷开抽屉要由 AppShell
  /// 触发 —— 手势落在 PageView 上,不在内层 Scaffold 手里。
  final _chatScaffoldKey = GlobalKey<ScaffoldState>();

  /// 右滑过卷开抽屉的累计位移阈值:太小容易误触,太大显得迟钝。
  static const _drawerOverscrollThreshold = 64.0;
  double _overscrollAccum = 0;
  bool _drawerOpenedThisScroll = false;

  static const _keys = [
    GlobalObjectKey('tab-chat'),
    GlobalObjectKey('tab-devices'),
    GlobalObjectKey('tab-settings'),
  ];

  static const _tabs = [
    NavTabSpec(
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
      label: '对话',
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

  /// 滚动通知:对话页(第 0 页)的**横向前缘过卷**视为「打开会话抽屉」。
  ///
  /// 为什么不再用抽屉自带的边缘手势(drawerEdgeDragWidth):那要求手指
  /// 落在左边缘 60px 内,是当年对话页夹在中间、横向手势要让位给翻页时
  /// 的折中。现在对话页是第一页,右滑只会回弹,把这个手势拿来开抽屉
  /// 最顺手。关键点:
  /// - `axis == horizontal` 过滤掉聊天列表上下滚动的过卷通知 ——
  ///   竖向滚动永远不可能误开抽屉;
  /// - 累计位移要超过阈值,轻轻一划不会误触;
  /// - 一次滚动只开一次,抽屉打开后不再重复触发。
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      if (n.metrics.axis == Axis.horizontal) {
        _overscrollAccum = 0;
        _drawerOpenedThisScroll = false;
      }
    } else if (n is OverscrollNotification &&
        n.metrics.axis == Axis.horizontal &&
        n.overscroll < 0 &&
        _index == 0 &&
        !_drawerOpenedThisScroll) {
      // 前缘过卷(overscroll < 0)只可能发生在第 0 页(对话):
      // 用户正在往右拖,而右边没有页面 —— 这就是「开抽屉」的意图。
      _overscrollAccum -= n.overscroll;
      if (_overscrollAccum >= _drawerOverscrollThreshold) {
        _drawerOpenedThisScroll = true;
        _chatScaffoldKey.currentState?.openDrawer();
      }
    }
    return false;
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
            // NotificationListener 包一层:对话页右滑出的前缘过卷 = 开抽屉。
            NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  _KeepAlivePage(
                    key: _keys[0],
                    child: _ChatTab(scaffoldKey: _chatScaffoldKey),
                  ),
                  _KeepAlivePage(key: _keys[1], child: const DevicesPage()),
                  _KeepAlivePage(key: _keys[2], child: const SettingsScreen()),
                ],
              ),
            ),
            // ── 导航栏(指示器跟着滚动位置;可见性按页区分) ──
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
                    // 只「读」isScrollingNotifier 不够 —— 外层 AnimatedBuilder 的
                    // 重建由 pixels 变化驱动,而滚动**停止**那一刻不再产生 pixels
                    // 通知,builder 会拿到陈旧的 isScrolling=true,底栏卡住不淡出。
                    // 内层直接监听 isScrollingNotifier,滚停瞬间立刻重建。
                    return AnimatedBuilder(
                      animation: _pageController.hasClients
                          ? _pageController.position.isScrollingNotifier
                          : const AlwaysStoppedAnimation<bool>(false),
                      builder: (context, _) {
                        final isScrolling =
                            _pageController.hasClients &&
                            _pageController.position.isScrollingNotifier.value;
                        // 对话页(第 0 页)平时收起、滑动时现身;
                        // 设备/设置页常驻显示。
                        final onChat = _index == 0;
                        final opacity = !onChat || isScrolling ? 1.0 : 0.0;
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
  const _ChatTab({required this.scaffoldKey});

  /// Scaffold key 由 AppShell 注入:任意位置右滑开抽屉的过卷手势落在
  /// PageView 层(见 AppShell._onScrollNotification),要能从外层打开
  /// 这个抽屉。
  final GlobalKey<ScaffoldState> scaffoldKey;

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  final _islandKey = GlobalKey<DynamicIslandBarState>();
  bool _drawerOpen = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        widget.scaffoldKey.currentState?.closeDrawer();
      },
      child: Scaffold(
        key: widget.scaffoldKey,
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        drawer: const SessionsDrawer(),
        // 左边缘 60px 的交互拉出仍保留(跟手);任意位置右滑由 AppShell 的
        // 过卷监听接管。往左的横向手势让 PageView 翻页去设备/设置。
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
                onOpenDrawer: () =>
                    widget.scaffoldKey.currentState?.openDrawer(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
