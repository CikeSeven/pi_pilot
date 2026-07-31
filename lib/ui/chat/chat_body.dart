import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../settings/settings_screen.dart';
import '../theme/paper.dart';
import '../theme/shapes.dart';
import '../theme/typography.dart';
import 'widgets/chat_item_view.dart';
import 'widgets/composer.dart';
import 'widgets/message_timestamp.dart';
import 'widgets/quick_panel.dart';
import 'widgets/scroll_to_bottom_button.dart';
import 'widgets/ui_request_card.dart';

/// 对话主体。**不再自带 `Scaffold`** —— 那一层上移到了 `AppShell`,
/// 这样才有地方挂抽屉。
class ChatBody extends ConsumerStatefulWidget {
  const ChatBody({super.key, this.topPadding = 0});

  /// 顶部留空(灵动岛高度 + 状态栏)。
  /// 列表静止时第一项在岛下面;滚动时内容滚入顶部渐变区渐隐。
  final double topPadding;

  @override
  ConsumerState<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<ChatBody> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  String _inputText = '';

  /// 快捷指令没有输入框可清,用它挡住连点(否则会开两个会话、发两条消息)。
  bool _sending = false;

  /// 悬浮输入卡的实测高度,用来给列表留底部空间。
  ///
  /// **不能写死**:输入卡高 = 84 + 系统手势条 inset,再加上展开的快捷面板/
  /// 投递芯片。手势条 48dp 的机器上写死 96 会把最后一条消息压掉 28dp。
  /// 默认值 140:足够覆盖手势条 48dp + 内容 92dp 的常见情况,
  /// 首帧测量成功后会被实测值覆盖。
  final _composerKey = GlobalKey();
  double _composerHeight = 140;

  /// 派生数据缓存:key -> 下标、以及时间标注标志。
  ///
  /// 两者都只依赖 items 列表本身,但以前都在 build 里现算:
  /// - findChildIndexCallback 里用 indexWhere 线性扫描,而它**对每个可见子项调一次**,
  ///   一次重建就是 O(可见项 x 总条数);流式期间每个 token 都涨 revision 触发重建。
  /// - _timestampFlags 全量重扫一遍 items。
  /// 靠 revision 判定失效,同一份列表只算一次。
  int _derivedRevision = -1;
  Map<String, int> _indexByKey = const {};
  List<bool> _timestampFlagCache = const [];

  /// 会话切换后待执行的「跳到底部」。
  ///
  /// 加载完的落点必须是最新消息 —— 长会话停在第一条,用户要滑很久。
  String? _pendingBottomToken;
  String? _lastSessionToken;

  /// 正在跑的跳底链(防止 build 每帧都新开一条)。
  String? _bottomChainToken;

  /// 列表窗口:只渲染最后这么多条。
  ///
  /// **这是消除切换卡顿的关键**。`RenderSliverList` 要求子项在布局上连续,
  /// 没法跳过中间项直接量最后一项的位置 —— 所以 `jumpTo(maxScrollExtent)`
  /// 会在一帧里把从头到底的所有项全建出来。2000 条的会话切过去,
  /// 那一帧就是几百毫秒的掉帧。窗口化之后无论会话多长,首帧只建这么多条。
  static const _windowStep = 60;
  int _windowSize = _windowStep;

  /// 离顶部多远就开始预加载。
  ///
  /// 留一段提前量而不是等 pixels 归零:联网那一段有往返延迟,
  /// 真到顶了才发请求的话用户会看到一次硬停。
  static const _autoLoadThreshold = 600.0;

  /// 自动加载的重入阁:一次滚动里 position 会反复通知。
  bool _autoLoading = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  /// 接近顶部就自动往前补。
  void _onScroll() {
    if (_autoLoading || !_scroll.hasClients) return;
    final position = _scroll.position;
    final state = ref.read(piSessionProvider);
    final window = ChatWindow.of(
      total: state.items.length,
      windowSize: _windowSize,
      hasPendingUiRequest: state.pendingUiRequest != null,
      hasRemoteEarlier: state.hasMoreHistory,
    );
    final trigger = shouldAutoLoadEarlier(
      pixels: position.pixels,
      maxScrollExtent: position.hasContentDimensions
          ? position.maxScrollExtent
          : 0,
      threshold: _autoLoadThreshold,
      hasEarlier: window.hasEarlier,
      loadingEarlier: state.loadingEarlier,
      jumpingToBottom: _pendingBottomToken != null,
    );
    if (!trigger) return;

    _autoLoading = true;
    unawaited(
      _loadEarlier(window).whenComplete(() {
        // 下一帧再放门:本帧里 position 还会因为补偿 jumpTo 再通知几次。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _autoLoading = false;
        });
      }),
    );
  }

  void _growWindow() {
    if (!_scroll.hasClients) {
      setState(() => _windowSize += _windowStep);
      return;
    }
    // 头部插入内容会把当前位置整体推下去,记下展开前的高度,
    // 下一帧按增量补偿,视觉上停在原处。
    final before = _scroll.position.maxScrollExtent;
    final pixels = _scroll.position.pixels;
    setState(() => _windowSize += _windowStep);
    _compensateAfterGrow(pixels: pixels, extentBefore: before);
  }

  /// 头部长高之后把滚动位置拉回原处。
  void _compensateAfterGrow({
    required double pixels,
    required double extentBefore,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final delta = _scroll.position.maxScrollExtent - extentBefore;
      if (delta <= 0) return;
      _scroll.jumpTo(
        (pixels + delta).clamp(
          _scroll.position.minScrollExtent,
          _scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  /// 「加载更早」—— 本地还有就只放大窗口,本地空了就联网补。
  ///
  /// 桥为了不撞爆手机的 2MB 套接字缓冲只发 entries 的尾巴(全量快照实测到过
  /// 10.27MB),更早的留在桥上。所以滚到本地头部不等于历史到头了。
  Future<void> _loadEarlier(ChatWindow window) async {
    if (!window.needsRemoteFetch) {
      _growWindow();
      return;
    }
    final extentBefore = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : null;
    final pixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final countBefore = ref.read(piSessionProvider).items.length;
    final ok = await ref.read(piSessionProvider.notifier).loadEarlierHistory();
    if (!mounted || !ok) return;
    final added = ref.read(piSessionProvider).items.length - countBefore;
    if (added <= 0) return;
    // 必须同时把窗口放大 —— 窗口是锚在**尾部**的,光把历史插进列表的话
    // offset 会跟着变大,刚取回来的那批仍然在窗口之上,点了等于没反应。
    setState(() => _windowSize += added);
    if (extentBefore != null) {
      _compensateAfterGrow(pixels: pixels, extentBefore: extentBefore);
    }
  }

  void _syncDerived(PiState state) {
    if (_derivedRevision == state.revision) return;
    _derivedRevision = state.revision;
    final items = state.items;

    final index = <String, int>{};
    final flags = List<bool>.filled(items.length, false);
    DateTime? prev;
    for (var i = 0; i < items.length; i++) {
      index[items[i].key] = i;
      final time = timeOf(items[i]);
      if (time == null) continue;
      flags[i] = shouldShowTimestamp(prev, time);
      prev = time;
    }
    _indexByKey = index;
    _timestampFlagCache = flags;
  }

  void _syncComposerHeight() {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    final height = box?.size.height;
    if (height == null || !mounted) return;
    if ((height - _composerHeight).abs() < 0.5) return;
    setState(() => _composerHeight = height);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottomIfNear() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 240) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  /// 无条件跳到底部。
  ///
  /// 与 [_scrollToBottomIfNear] 的区别是不看当前位置 —— 会话刚加载完时
  /// pixels 是 0 而 maxScrollExtent 很大,「接近底部」永远不成立。
  ///
  /// 惰性列表的 maxScrollExtent 是估算值,一次 jumpTo 到不了真正的底,
  /// 所以连着推几帧,每帧都朝当前的 maxScrollExtent 再跳一次。
  void _jumpToBottomSoon(String token) {
    // build 每帧都会调到这里(流式时尤其频),同一个 token 只允许一条链在跑。
    if (_bottomChainToken == token) return;
    _bottomChainToken = token;
    var remaining = 6;
    void step() {
      if (!mounted || _pendingBottomToken != token) {
        if (_bottomChainToken == token) _bottomChainToken = null;
        return;
      }
      if (!_scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) => step());
        return;
      }
      final position = _scroll.position;
      if (position.pixels < position.maxScrollExtent) {
        _scroll.jumpTo(position.maxScrollExtent);
      }
      if (--remaining > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => step());
      } else {
        _pendingBottomToken = null;
        _bottomChainToken = null;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => step());
  }

  void _send({PiDelivery? delivery}) {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    unawaited(
      ref.read(piSessionProvider.notifier).sendPrompt(text, delivery: delivery),
    );
    _input.clear();
    setState(() => _inputText = '');
  }

  /// 中断当前生成再发送。桌面端的中断会把未发送的排队消息回填到电脑输入框,
  /// 这个副作用必须如实告知,不能藏。
  Future<void> _interruptAndSend() async {
    final desktop =
        ref.read(piSessionProvider).selectedSource?.isDesktop == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('中断当前生成?'),
        content: Text(
          desktop
              ? '会停止电脑端正在进行的这一轮,然后发送你的消息。\n'
                    '电脑端尚未发送的排队消息会被放回它的输入框。'
              : '会停止正在进行的这一轮,然后发送你的消息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('中断并发送'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _send(delivery: PiDelivery.interrupt);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      piSessionProvider.select((s) => s.revision),
      (_, _) => _scrollToBottomIfNear(),
    );

    final state = ref.watch(piSessionProvider);
    _syncDerived(state);
    final timestampFlags = _timestampFlagCache;

    // 会话/源一换就残一个「跳底」标记。不能在此时就跳 ——
    // 切换瞬间 items 还是空的,得等历史刷进来。
    final sessionToken = '${state.selectedSourceId}/${state.sessionId}';
    if (sessionToken != _lastSessionToken) {
      _lastSessionToken = sessionToken;
      _pendingBottomToken = sessionToken;
      // 换会话必须收回窗口,否则从长会话切过去会继承一个很大的窗口,
      // 首帧又要建几百条。
      _windowSize = _windowStep;
    }
    if (_pendingBottomToken == sessionToken && state.items.isNotEmpty) {
      _jumpToBottomSoon(sessionToken);
    }

    // 只渲染尾部窗口。offset 是窗口首项在完整列表里的下标。
    final window = ChatWindow.of(
      total: state.items.length,
      windowSize: _windowSize,
      hasPendingUiRequest: state.pendingUiRequest != null,
      hasRemoteEarlier: state.hasMoreHistory,
    );

    // 首帧之后量一次;之后由 SizeChangedLayoutNotifier 驱动
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncComposerHeight());
    // _composerHeight 已含手势条(Composer 内有 SafeArea),不要再加 bottomInset,
    // 否则列表底部悬空,和输入框之间露出空隙。
    final listBottomInset = _composerHeight + 4;

    return Column(
      children: [
        _LivenessBanner(state: state, topPadding: widget.topPadding),
        if (state.isCompacting) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          // 输入条**浮在**消息流之上,内容从它下面滚过去 —— 这才是「悬浮」。
          // 它原来是 Column 的兄弟节点,身后必然是 scaffold 的实色背景,
          // 所以无论怎么调都会看到一条白底。
          child: Stack(
            children: [
              if (!state.hasSession)
                const _NotConnectedView()
              else if (state.items.isEmpty)
                const _EmptyHint()
              else
                ListView.builder(
                  controller: _scroll,
                  // 底部留出输入卡的实测高度,免得最后一条消息被压在下面;
                  // 顶部留出灵动岛高度,静止时第一项在岛下面。
                  // 左右 4:卡片自己带 10 margin,总边距 14(收紧,放更多内容)。
                  padding: EdgeInsets.fromLTRB(
                    4,
                    widget.topPadding + 12,
                    4,
                    listBottomInset,
                  ),
                  // 长会话里 keep-alive 会把滚过的每一项都钉在内存里不释放,
                  // 越滚越重。消息项本身无状态可留(展开态在 ChatItem 上),关掉。
                  addAutomaticKeepAlives: false,
                  itemCount: window.itemCount,
                  findChildIndexCallback: (key) {
                    // 预建的 key -> 下标表。以前这里 indexWhere 线性扫描,
                    // 而本回调对每个可见子项都会调一次 —— 一次重建就是
                    // O(可见项 x 总条数),流式期间每个 token 都要付这笔钱。
                    if (key is! ValueKey<String>) return null;
                    final full = _indexByKey[key.value];
                    if (full == null) return null;
                    return window.slotOf(full);
                  },
                  itemBuilder: (context, index) {
                    if (window.isLoadEarlierSlot(index)) {
                      return _EarlierLoader(
                        remaining: window.offset,
                        loading: state.loadingEarlier,
                        onRetry: () => unawaited(_loadEarlier(window)),
                      );
                    }
                    if (window.isPendingRequestSlot(index)) {
                      final request = state.pendingUiRequest!;
                      return UiRequestCard(
                        key: ValueKey('ui-request-${request.id}'),
                        request: request,
                      );
                    }
                    final full = window.itemIndexOf(index);
                    final item = state.items[full];
                    final view = ChatItemView(
                      key: ValueKey(item.key),
                      item: item,
                    );
                    if (!timestampFlags[full]) return view;
                    return Column(
                      children: [
                        MessageTimestamp(time: timeOf(item)!),
                        view,
                      ],
                    );
                  },
                ),
              if (state.hasSession)
                Positioned(
                  right: 16,
                  // 抬到输入卡上方,不然会被它压住
                  bottom: listBottomInset,
                  child: ScrollToBottomButton(
                    controller: _scroll,
                    revision: state.revision,
                  ),
                ),
              // 顶部渐变遮罩:灵动岛不遮一整栏,内容滚到顶部时渐隐。
              // 上段纯不透明(盖住岛后面的碎片),下段渐隐到透明。
              if (widget.topPadding > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: widget.topPadding + 24,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Theme.of(context).colorScheme.surface,
                            Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0),
                          ],
                          stops: const [0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              // 渐变遮罩:紧贴输入卡顶部(_composerHeight 已含手势条,
              // 不要再加 bottomInset,否则渐变悬空、和输入卡之间露出空隙)。
              Positioned(
                left: 0,
                right: 0,
                bottom: _composerHeight,
                height: 28,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 0),
                          Theme.of(context).colorScheme.surface,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 输入永远开放:任意一端、任意时刻都能发消息和打断。
              // 唯一的门是"还没连上 bridge",那时整个界面都不在这条分支。
              // 外层包一层不透明背景:确保输入框下方(含手势条区域)没有文字透出。
              // 参考 Claude Code:输入框下方是一块不透明底色,列表内容不会透出。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Theme.of(context).colorScheme.surface,
                  child: NotificationListener<SizeChangedLayoutNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _syncComposerHeight(),
                      );
                      return true;
                    },
                    child: SizeChangedLayoutNotifier(
                      key: _composerKey,
                      child: Composer(
                        controller: _input,
                        enabled: true,
                        streaming: state.isStreaming,
                        compacting: state.isCompacting,
                        onSend: _send,
                        onSteer: () => _send(delivery: PiDelivery.steer),
                        onFollowUp: () => _send(delivery: PiDelivery.followUp),
                        onInterruptAndSend: _interruptAndSend,
                        onAbort: () => unawaited(
                          ref.read(piSessionProvider.notifier).abort(),
                        ),
                        onChanged: (text) => setState(() => _inputText = text),
                        quickPanel: QuickPanel(
                          inputText: _inputText,
                          onInsert: (text) {
                            _input.text = text;
                            _input.selection = TextSelection.collapsed(
                              offset: text.length,
                            );
                            setState(() => _inputText = text);
                          },
                          onSendPrompt: (text) {
                            // 快捷指令没有输入框可清,自己挡住连点
                            if (_sending) return;
                            setState(() => _sending = true);
                            unawaited(
                              ref
                                  .read(piSessionProvider.notifier)
                                  .sendPrompt(text)
                                  .whenComplete(() {
                                    if (mounted) {
                                      setState(() => _sending = false);
                                    }
                                  }),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotConnectedView extends ConsumerWidget {
  const _NotConnectedView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(piSessionProvider.select((s) => s.status));
    final error = ref.watch(piSessionProvider.select((s) => s.error));
    final hasConn = ref.watch(settingsProvider.select((s) => s.hasConnection));
    final colors = Theme.of(context).colorScheme;

    // 空状态用场景插画而不是图标 —— 设计规范要的「安静等待」气质:
    // 「中央留白插画 + 标题 + 副文案 + 稳重主按钮」。
    final (message, hint) = switch (status) {
      PiConnStatus.connecting => ('正在连接…', '正在唤醒你的电脑。'),
      PiConnStatus.failed => ('连接失败', '检查一下 bridge 地址和 token。'),
      _ => ('尚未连接', '连接电脑,远程协作。'),
    };

    // Center 包 SCSV:内容矮时居中,内容比视口高时(横屏/大字体/长错误
    // 文本)可以滚 —— 否则 Column 在 Stack 的定高里没有出路,直接纵向溢出。
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 矢量装饰:素材 PNG 自带象牙纸底,在奶油页面上会露出一圈更亮的
              // 白边(看着像廉价贴图)。CustomPaint 天然透明,干净。
              const EditorialOrnament(size: 156),
              const SizedBox(height: 26),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppType.displayTitle(size: 27, color: colors.onSurface),
              ),
              const SizedBox(height: 10),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: AppType.serifItalic(color: colors.onSurfaceVariant),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.error),
                ),
              ],
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (status != PiConnStatus.connecting && hasConn)
                    FilledButton.icon(
                      onPressed: () =>
                          ref.read(piSessionProvider.notifier).connect(),
                      icon: const Icon(Icons.link),
                      label: const Text('连接'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('前往设置'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话活跃度横幅。
///
/// **空闲且一切正常时完全不渲染** —— 这是"大方"最直接的动作:平时聊天区域
/// 上方没有任何 chrome。只有四种真正需要说话的情况才出现。
class _LivenessBanner extends ConsumerWidget {
  const _LivenessBanner({required this.state, this.topPadding = 0});

  final PiState state;

  /// 灵动岛占位:横幅显示时要在岛下面,不被遮住。
  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final source = state.selectedSource;

    final queueParts = <String>[
      if (state.steeringQueue.isNotEmpty) '插队 ${state.steeringQueue.length}',
      if (state.followUpQueue.isNotEmpty) '排队 ${state.followUpQueue.length}',
    ];

    final (
      IconData icon,
      String text,
      Color bg,
      Color fg,
      Widget? action,
    ) = switch (state) {
      _ when source == null => (
        Icons.dashboard_customize_outlined,
        '还没有选择会话',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        TextButton(
          // maybeOf:ChatBody 被单独 pump 时(测试)没有外层 Scaffold,
          // 用 of() 会直接抛异常。
          onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
          child: const Text('选择会话'),
        ),
      ),
      _ when state.sessionWaking => (
        Icons.play_circle_outline,
        '正在唤醒 ${source.label}',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      // 「正在生成」**不占横幅**。这个状态本来就有三处更省地方的表达:
      // 顶栏的中断按钮、助手气泡里的打字指示器、输入框的「生成中 · 发送会插队」。
      // 再压一条 50dp 的横幅纯属浪费空间。
      //
      // 压缩不一样:它没有打字指示器、没有中断按钮,输入框也不知道自己在忙,
      // 以前只有一条 2px 进度条 —— 等于没提示。所以压缩要占横幅。
      _ when state.isCompacting => (
        Icons.compress,
        '${source.label} 正在压缩上下文 · 消息会排队等它完成',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      _ when !source.connected => (
        Icons.bedtime_outlined,
        '${source.label} 已休眠 · 发消息会自动唤醒',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      // 一切正常:下面 text.isEmpty 会返回 SizedBox.shrink(),这里的颜色画不出来
      _ => (
        Icons.circle,
        '',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
    };

    // 一切正常:不渲染任何东西
    if (text.isEmpty && queueParts.isEmpty) return const SizedBox.shrink();

    return Card(
      // 14 = ListView 左右 padding(4) + 卡片 margin(10),和内容卡对齐。
      margin: EdgeInsets.fromLTRB(14, topPadding + 10, 14, 2),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text.isNotEmpty)
              Row(
                children: [
                  if (state.isStreaming || state.isCompacting)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                      ),
                    )
                  else
                    Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: fg),
                    ),
                  ),
                  ?action,
                ],
              ),
            if (queueParts.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: text.isEmpty ? 0 : 4),
                child: Row(
                  children: [
                    Icon(Icons.schedule, size: 14, color: fg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${queueParts.join(' · ')} — '
                        '${[...state.steeringQueue, ...state.followUpQueue].first}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 滚到顶部附近时该不该自动补更早的历史。
///
/// 抽成顶层函数而不是留在 `_onScroll` 里,是因为几道卡全是真踩过的坑,
/// 而内联在私有 State 里没法单独测。
bool shouldAutoLoadEarlier({
  required double pixels,
  required double maxScrollExtent,
  required double threshold,
  required bool hasEarlier,
  required bool loadingEarlier,
  required bool jumpingToBottom,
}) {
  if (!hasEarlier) return false;
  if (loadingEarlier) return false;
  // 切会话后还在跳底的过程中:pixels 从 0 往下跑,中途必然落在阈值内,
  // 不挡的话每次切会话都会白白发一轮往前分页。
  if (jumpingToBottom) return false;
  // 内容还没撑满一屏时 maxScrollExtent 是 0,pixels 永远在「顶部」。
  // 那种情况下本来也滚不动,交给指示行自己可点。
  if (maxScrollExtent <= 0) return false;
  return pixels <= threshold;
}

/// 消息列表的尾部窗口下标运算。
///
/// 提成独立类而不是留在 `build` 里,是因为这里的下标换算(完整列表下标 ↔
/// 列表槽位)一旦算错就会**渲染错消息**,而内联在 build 里没法单独测。
///
/// 槽位布局:`[加载更早?] + 窗口内消息 + [待应答对话框?]`
class ChatWindow {
  const ChatWindow({
    required this.total,
    required this.offset,
    required this.hasPendingUiRequest,
    this.hasRemoteEarlier = false,
  });

  factory ChatWindow.of({
    required int total,
    required int windowSize,
    required bool hasPendingUiRequest,
    bool hasRemoteEarlier = false,
  }) => ChatWindow(
    total: total,
    offset: total > windowSize ? total - windowSize : 0,
    hasPendingUiRequest: hasPendingUiRequest,
    hasRemoteEarlier: hasRemoteEarlier,
  );

  /// 完整列表的总条数。
  final int total;

  /// 窗口首项在完整列表里的下标。
  final int offset;
  final bool hasPendingUiRequest;

  /// 桥上还留着更早的历史(本地已经没有了,但能联网取)。
  ///
  /// 桥为了不撞爆手机的 2MB 套接字缓冲只发 entries 的尾巴,所以「没有本地更早」
  /// 不等于「没有更早」—— 滚到本地头部时按钮还要在,只是改成联网补。
  final bool hasRemoteEarlier;

  /// 窗口之上还有没渲染的历史 → 需要「加载更早」按钮占一个槽位。
  bool get hasEarlier => offset > 0 || hasRemoteEarlier;

  /// 本地窗口之上已经空了,再往前得联网取。
  bool get needsRemoteFetch => offset == 0 && hasRemoteEarlier;

  int get _leading => hasEarlier ? 1 : 0;
  int get _trailing => hasPendingUiRequest ? 1 : 0;

  /// 窗口内渲染的消息条数。
  int get visibleCount => total - offset;

  int get itemCount => _leading + visibleCount + _trailing;

  bool isLoadEarlierSlot(int slot) => hasEarlier && slot == 0;

  bool isPendingRequestSlot(int slot) =>
      hasPendingUiRequest && slot - _leading == visibleCount;

  /// 槽位 → 完整列表下标。调用前必须先排除两个特殊槽位。
  int itemIndexOf(int slot) => offset + slot - _leading;

  /// 完整列表下标 → 槽位;落在窗口之外返回 null(ListView 会当作新子项)。
  int? slotOf(int index) {
    if (index < offset || index >= total) return null;
    return index - offset + _leading;
  }
}

/// 列表顶部的历史加载指示。
///
/// 不是按钮:滚到顶部附近由 `_onScroll` 自动触发补齐。仍然可点只是兼一手
/// —— 内容没撑满一屏时根本没有滚动事件,此时自动触发依赖不上。
class _EarlierLoader extends StatelessWidget {
  const _EarlierLoader({
    required this.remaining,
    required this.onRetry,
    this.loading = false,
  });

  /// 窗口之上还没渲染的条数。0 表示本地已空,接下来要联网取 ——
  /// 那时数不出来还剩多少,因为条数在桥上。
  final int remaining;
  final VoidCallback onRetry;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: InkWell(
          onTap: loading ? null : onRetry,
          borderRadius: BorderRadius.circular(PiShape.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  remaining > 0 ? '正在加载更早的消息 · 还有 $remaining 条' : '正在加载更早的消息…',
                  style: text,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EditorialOrnament(size: 150),
              const SizedBox(height: 26),
              Text(
                '开始一段对话',
                textAlign: TextAlign.center,
                style: AppType.displayTitle(size: 27, color: colors.onSurface),
              ),
              const SizedBox(height: 10),
              Text(
                '开始你的第一个指令',
                textAlign: TextAlign.center,
                style: AppType.serifItalic(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              // 页脚一条编辑式短线,替代原来那枚带白底的印章 PNG
              SizedBox(
                width: 56,
                child: EditorialRule(color: colors.outlineVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
