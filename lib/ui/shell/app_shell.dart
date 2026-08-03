import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/back_dispatch.dart';
import '../chat/chat_body.dart';
import '../chat/widgets/island_bar.dart';
import '../sessions/devices_page.dart';
import '../sessions/sessions_drawer.dart';
import '../settings/settings_screen.dart';
import '../theme/motion.dart';
import '../theme/paper.dart';
import 'drawer_drag.dart';
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
/// 对话页是第一页,向右本来无页可翻 —— 那个方向的横向手势留给
/// 「会话抽屉」。具体由 `_ChatTab` 内部的 [DrawerDragRecognizer] 接管:
/// 它必须挂在 PageView **页面内部**才能同台竞争。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  // 对话是主页面,放第一页(initialPage 默认 0):往左依次是设备、设置。
  final _pageController = PageController();
  int _index = 0;

  /// 返回键要关抽屉时,从这里够到 _ChatTab。
  final _chatTabKey = GlobalKey<_ChatTabState>();

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLow;

    // 返回键统一在这里分发:先收看得见的展开态,全收完了才放行退出。
    // canPop 必须盯住全部拦截条件 —— 漏一个,那个状态下返回键就直接退应用。
    final backTarget = resolveBackTarget(
      drawerOpen: ref.watch(drawerOpenProvider),
      pageIndex: _index,
      islandExpanded: ref.watch(islandExpandedProvider),
      modelPickerExpanded: ref.watch(modelPickerExpandedProvider),
    );

    return PopScope(
      canPop: backTarget == BackTarget.exit,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        switch (backTarget) {
          case BackTarget.exit:
            break;
          case BackTarget.drawer:
            _chatTabKey.currentState?.closeDrawer();
          case BackTarget.chatPage:
            _onTabTap(0);
          case BackTarget.island:
            ref.read(islandExpandedProvider.notifier).state = false;
          case BackTarget.modelPicker:
            ref.read(modelPickerExpandedProvider.notifier).state = false;
        }
      },
      child: Scaffold(
        extendBody: true,
        body: BackdropPaper(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── 三页(PageView 自带左右滑动,跟手、回弹) ──
              // 向右开抽屉的手势在对话页**内部**处理(见 _ChatTab 里的
              // DrawerDragRecognizer) —— 只有作为 PageView 的后代才能同台竞争,
              // 抢得下整根 pointer,右滑拉开、不松手左滑推回都跟手。
              PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  _KeepAlivePage(
                    key: _keys[0],
                    child: _ChatTab(key: _chatTabKey),
                  ),
                  _KeepAlivePage(key: _keys[1], child: const DevicesPage()),
                  _KeepAlivePage(key: _keys[2], child: const SettingsScreen()),
                ],
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
                              _pageController
                                  .position
                                  .isScrollingNotifier
                                  .value;
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

/// 会话 tab:灵动岛 + 消息流 + 自渲染的会话抽屉。
class _ChatTab extends ConsumerStatefulWidget {
  const _ChatTab({super.key});

  @override
  ConsumerState<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends ConsumerState<_ChatTab>
    with SingleTickerProviderStateMixin {
  final _islandKey = GlobalKey<DynamicIslandBarState>();

  /// 抽屉展开进度:0 = 全关,1 = 全开。
  ///
  /// 自己拿住这个 controller 而不用 `Scaffold.drawer`,是为了让**同一根手指**
  /// 的右滑、左滑连续驱动同一个进度值。原生 drawer 只能用 `open()`/`close()`
  /// 整段 fling,拿不到跟手的中间态(`_move` 是私有的)。
  late final AnimationController _drawer = AnimationController(
    vsync: this,
    duration: PiMotion.standard,
    value: 0,
  );

  /// 抽屉宽度:和 Material 默认一致(304),窄屏上留出 56 的余光区
  /// —— 完全盖死屏幕就看不出「这是一层盖上去的面板」。
  double _drawerWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width - 56 < 304.0 ? width - 56 : 304.0;
  }

  bool get _isOpen => _drawer.value > 0;

  /// 上一次的开关镜像:只在 0/非 0 边沿写 provider,不逐帧写。
  bool _drawerOpenMirror = false;

  @override
  void initState() {
    super.initState();
    // PopScope 上移到了 AppShell,这里把抽屉开合镜像过去,
    // 否则它不知道返回键该不该先关抽屉。
    _drawer.addListener(_syncDrawerOpen);
  }

  void _syncDrawerOpen() {
    final open = _isOpen;
    if (open == _drawerOpenMirror) return;
    _drawerOpenMirror = open;
    ref.read(drawerOpenProvider.notifier).state = open;
  }

  @override
  void dispose() {
    _drawer.dispose();
    super.dispose();
  }

  void openDrawer() {
    _drawer.animateTo(1, curve: Curves.easeOutCubic);
  }

  void closeDrawer() {
    FocusManager.instance.primaryFocus?.unfocus();
    _drawer.animateBack(0, curve: Curves.easeOutCubic);
  }

  void _onDragStart() {
    // 拖动接管:停掉正在跑的落位动画,否则手指与动画抢同一个值。
    _drawer.stop();
    _islandKey.currentState?.collapse();
  }

  void _onDragDelta(double dx) {
    final width = _drawerWidth(context);
    if (width <= 0) return;
    _drawer.value = (_drawer.value + dx / width).clamp(0.0, 1.0);
  }

  void _onDragEnd(double velocity) {
    final width = _drawerWidth(context);
    // 快速甲一下:按方向落位,不管当前在哪。阈值取 Flutter 自己的
    // kMinFlingVelocity,和系统其它翻页/抽屉手感一致。
    if (velocity.abs() >= kMinFlingVelocity && width > 0) {
      _drawer.fling(velocity: velocity / width);
      if (velocity < 0) FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    // 慢慢拖:过半开,不过半关。
    if (_drawer.value >= 0.5) {
      openDrawer();
    } else {
      closeDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = _drawerWidth(context);
    return AnimatedBuilder(
      animation: _drawer,
      builder: (context, _) {
        final progress = _drawer.value;
        // 返回键不在这里拦:PopScope 上移到 AppShell 统一分发
        // (抽屉/灵动岛/模型选择/切页共用一条优先级链),
        // 抽屉开态经 drawerOpenProvider 镜像过去。
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          // 无常驻 AppBar —— 灵动岛浮在内容上,内容区全屏,
          // 顶部渐变遮罩让滚上去的内容渐隐,岛只占自己那一小块。
          body: RawGestureDetector(
            // 识别器必须在 PageView **页面内部**才能与翻页同台竞争 ——
            // 挂在外层或事后才挂都接不住当前这根 pointer。
            //
            // behavior 必须显强制指定:缺省时只有命中子树里实际 RenderBox 的
            // 点才会派发事件。未连接态的 ChatBody 是 `Center` 包一小块内容,
            // 屏幕大片区域是空的,手指落在那里识别器根本收不到事件。
            // 用 translucent 而不是 opaque:后者会把点击也吐掉,聊天内容就
            // 点不动了。translucent 只把自己加进命中链,不抢子节点的事件。
            behavior: HitTestBehavior.translucent,
            gestures: {
              DrawerDragRecognizer:
                  GestureRecognizerFactoryWithHandlers<DrawerDragRecognizer>(
                    () => DrawerDragRecognizer(
                      isOpen: () => _isOpen,
                      onStart: _onDragStart,
                      onDelta: _onDragDelta,
                      onEnd: _onDragEnd,
                      debugOwner: this,
                    ),
                    (recognizer) {},
                  ),
            },
            child: NotificationListener<ScrollNotification>(
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
                  DynamicIslandBar(key: _islandKey, onOpenDrawer: openDrawer),
                  // 遮罩:跟着进度变深。progress == 0 时完全不拦点击。
                  if (progress > 0)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: progress == 0,
                        child: GestureDetector(
                          onTap: closeDrawer,
                          child: ColoredBox(
                            color: Colors.black54.withValues(
                              alpha: 0.54 * progress,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 抽屉本体:按进度从左侧推出。跟手的关键就在这里 ——
                  // progress 由 pointer delta 连续驱动,而不是一段固定动画。
                  if (progress > 0)
                    Positioned(
                      left: (progress - 1) * width,
                      top: 0,
                      bottom: 0,
                      width: width,
                      child: SessionsDrawer(onClose: closeDrawer),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
