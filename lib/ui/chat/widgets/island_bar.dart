import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../sessions/session_tree_screen.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import '../../theme/semantic_colors.dart';
import 'session_sheet.dart';

/// 灵动岛顶栏:**平时小胶囊只显示标题,点击丝滑展开成完整信息卡**。
///
/// 收起态(42px 胶囊):`标题`(生成中多一个迷你停止键)。
/// 展开态(信息卡):字标 + 会话名 + 状态副行 + 中断 + 菜单。
///
/// ## 为什么用单个 AnimationController 而不是 AnimatedContainer + AnimatedSwitcher
///
/// 两套隐式动画各跑各的:尺寸在动、内容也在切,中间态两个半透明内容
/// 叠在一起,看起来「糊」「跳」。
/// 改成**一个 controller 驱动一切**:尺寸 lerp 与内容淡入淡出严格同步 ——
/// 收起内容在前 35% 淡出,展开内容在后 45% 淡入,中间 20% 纯尺寸变化。
/// 这是 iOS 灵动岛同款编排。
class DynamicIslandBar extends ConsumerStatefulWidget {
  const DynamicIslandBar({super.key, required this.onOpenDrawer});

  final VoidCallback onOpenDrawer;

  @override
  ConsumerState<DynamicIslandBar> createState() => DynamicIslandBarState();
}

/// 压缩是独立于 streaming 的忙碌态,必须先判;否则旧的 Working 文案
/// 或 `isStreaming == false` 会把「压缩中」整个遮掉。
String? islandWorkStatus(PiState state) {
  if (state.isCompacting) return '压缩中';
  if (state.activityStatus != null) return state.activityStatus;
  if (!state.isStreaming) return null;
  if (state.items.isEmpty) return '生成中';
  final last = state.items.last;
  if (last is AssistantItem) {
    return last.thinking.isNotEmpty ? '思考中' : '回复中';
  }
  if (last is ToolItem) return '调用 ${last.name}';
  if (last is BashItem) return '执行命令';
  return '生成中';
}

/// public 状态类:_ChatTab 通过 GlobalKey 调 collapse()(滚动列表时自动收起)。
class DynamicIslandBarState extends ConsumerState<DynamicIslandBar>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  static const _collapsedH = 42.0;
  static const _expandedH = 108.0;

  /// 收起态宽度随文案自适应:短文案窄、长文案宽,
  /// working-activity 的长状态行不再被 ellipsis 截断。
  double _measureCollapsedW(
    BuildContext context,
    String text, {
    bool hasTimer = false,
    double clusterW = 0,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: Theme.of(context).textTheme.labelLarge),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final screenW = MediaQuery.sizeOf(context).width;
    // Timer 和左侧连接状态簇都占位置:不算它们的话文案会被挤成 ellipsis。
    // Timer 按「00:00」等宽实测预留——之前拍脑袋 68,是收起态
    // 「内容很小、岛却很宽」的主要来源。
    final timerW = hasTimer ? _measureTimerW(context) : 0.0;
    // 36 = 水平 padding 18*2;最窄 120,最宽屏宽 78%(留位置给右侧内容)。
    return (tp.width + 36 + timerW + clusterW).clamp(120.0, screenW * 0.78);
  }

  /// 计时器宽度:等宽数字按「00:00」实测(覆盖到 59:59),+8 是与左侧文案的间距。
  double _measureTimerW(BuildContext context) {
    final tp = TextPainter(
      text: TextSpan(
        text: '00:00',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFamily: 'monospace',
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width + 8;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  /// 收起(供外部调用:滚动列表时自动收起)。
  void collapse() {
    if (!_expanded) return;
    setState(() => _expanded = false);
    _ctrl.reverse();
  }

  void _collapse() => collapse();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _subtitle(PiState state) {
    if (state.status != PiConnStatus.connected) {
      return switch (state.status) {
        PiConnStatus.connecting => '连接中…',
        PiConnStatus.failed => '连接失败',
        _ => '未连接',
      };
    }
    final dir = state.cwd?.split('/').where((p) => p.isNotEmpty).lastOrNull;
    final percent = state.contextUsage?.percent;
    return [
      ?dir,
      ?state.modelName,
      if (percent != null) 'ctx $percent%',
    ].join(' · ');
  }

  String _title(PiState state) {
    final name = state.sessionName;
    if (name != null && name.isNotEmpty) return name;
    return state.selectedSource?.label ?? 'PiPilot';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(piSessionProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final notifier = ref.read(piSessionNotifierProvider);
    final isDark = theme.brightness == Brightness.dark;

    final screenW = MediaQuery.sizeOf(context).width;
    final topPad = MediaQuery.paddingOf(context).top;
    // 收起态宽度随文案自适应(working-activity 长文案不被截断)。
    final collapsedW = _measureCollapsedW(
      context,
      islandWorkStatus(state) ?? _title(state),
      hasTimer: state.isStreaming && state.activityStatus == null,
      clusterW: _connClusterW(context, state),
    );

    return Stack(
      children: [
        // 展开时的全屏点击层:点岛外任意处收起。
        // translucent:滑动(切页/滚列表)穿透不受影响,只有 tap 触发收起。
        if (_expanded)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _collapse,
            ),
          ),
        // 岛本体:一个 controller 驱动尺寸 + 双层内容交叉淡化。
        Positioned(
          left: 12,
          top: topPad + 4,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              final t = Curves.easeInOutCubic.transform(_ctrl.value);
              // 收起内容:前 35% 淡出;展开内容:后 45% 淡入。
              final collapsedOpacity = 1 - (t / 0.35).clamp(0.0, 1.0);
              final expandedOpacity = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: collapsedW),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                builder: (context, animW, _) => Container(
                  width: animW + (screenW - 24 - animW) * t,
                  height: _collapsedH + (_expandedH - _collapsedH) * t,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    // 圆角和输入卡、PiShape.lg 统一。
                    borderRadius: BorderRadius.circular(PiShape.lg),
                    // 液态玻璃:和输入框同一套语言。
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(
                          colors.surfaceContainerLow,
                          Colors.white,
                          isDark ? 0.06 : 0.15,
                        )!,
                        colors.surfaceContainerLow,
                        Color.lerp(
                          colors.surfaceContainerLow,
                          Colors.black,
                          isDark ? 0.08 : 0.04,
                        )!,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: 0.3),
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: colors.shadow.withValues(alpha: 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  // Material 提供 InkWell 水波宿主(transparent 不盖渐变)。
                  child: Material(
                    color: Colors.transparent,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (collapsedOpacity > 0)
                          Opacity(
                            opacity: collapsedOpacity,
                            child: IgnorePointer(
                              ignoring: t > 0.1,
                              child: _buildCollapsed(
                                context,
                                state,
                                colors,
                                notifier,
                              ),
                            ),
                          ),
                        if (expandedOpacity > 0)
                          Opacity(
                            opacity: expandedOpacity,
                            child: IgnorePointer(
                              ignoring: t < 0.9,
                              child: _buildExpanded(
                                context,
                                state,
                                colors,
                                notifier,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 收起态左侧连接状态簇的文案:已连接是延迟;其余是状态词。
  String? _connLabel(PiState state) {
    switch (state.status) {
      case PiConnStatus.connected:
        final rtt = state.rttMs;
        // 显示封顶 999ms:再大的值没有信息量,只会把岛撑宽;
        // 颜色分档仍看真实 rtt(_latencyColor),不一起封顶。
        return rtt == null ? null : '${rtt > 999 ? 999 : rtt}ms';
      case PiConnStatus.connecting:
        // 有过会话的连接中 = 断线重连;首次连接才叫连接中。
        return state.hasSession ? '重连中' : '连接中';
      case PiConnStatus.failed:
        return '连接失败';
      case PiConnStatus.disconnected:
        return '已断开';
    }
  }

  /// 状态簇的宽度估算:不在收起态宽度里给它留位,中间文案会被挤成省略号。
  double _connClusterW(BuildContext context, PiState state) {
    final label = _connLabel(state);
    // 图标 13 + 与中间文案的间距 8。
    if (label == null) return 13 + 8;
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: Theme.of(context).textTheme.labelSmall,
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return 13 + 4 + tp.width + 8;
  }

  /// 延迟分档配色:<100ms 绿,<300ms 黄,再高红;没测到延迟按绿(刚连上)。
  Color _latencyColor(int? rttMs, PiColors piColors, ColorScheme colors) {
    final rtt = rttMs;
    if (rtt == null || rtt < 100) return piColors.success;
    if (rtt < 300) return piColors.warning;
    return colors.error;
  }

  /// 左侧连接状态簇:通道图标(局域网/P2P)+ 延迟;连接/断开/失败各有其态。
  Widget _connCluster(BuildContext context, PiState state) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final (IconData? icon, Color color) = switch (state.status) {
      PiConnStatus.connected => (
        state.activeTransport == PiActiveTransport.p2p
            ? Icons.public
            : Icons.wifi,
        _latencyColor(state.rttMs, piColors, colors),
      ),
      // 连接中用 spinner 而不是静态图标:转圈本身就是「正在连」。
      PiConnStatus.connecting => (null, colors.primary),
      PiConnStatus.failed => (Icons.error_outline, colors.error),
      PiConnStatus.disconnected => (Icons.wifi_off, colors.outline),
    };
    final label = _connLabel(state);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon == null)
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
          )
        else
          Icon(icon, size: 13, color: color),
        if (label != null) ...[
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
        const SizedBox(width: 8),
      ],
    );
  }

  /// 收起态:只显示标题(生成中多一个迷你停止键)。
  Widget _buildCollapsed(
    BuildContext context,
    PiState state,
    ColorScheme colors,
    dynamic notifier,
  ) {
    return InkWell(
      onTap: _toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _connCluster(context, state),
            Flexible(
              child: Text(
                // 生成中显示工作状态(思考中/回复中/调用 read),
                // 非生成中显示会话名。
                islandWorkStatus(state) ?? _title(state),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            // 生成中:运行时长(替代迷你停止键——
            // 中断入口已经有两处:展开态的中断按钮、输入框的停止键,
            // 收起态再放一个就是第三处重复。改成运行时长更有信息价值。
            // 插件状态自带节奏(「· 总30s」),不再重复显示本地计时。
            if (state.isStreaming && state.activityStatus == null) ...[
              const SizedBox(width: 8),
              const _StreamTimer(),
            ],
          ],
        ),
      ),
    );
  }

  /// 展开态:完整信息卡(原 AppBar 的全部功能)。
  Widget _buildExpanded(
    BuildContext context,
    PiState state,
    ColorScheme colors,
    dynamic notifier,
  ) {
    final theme = Theme.of(context);
    // 生成中不再藏撤销:回退链路(relay 的 runNavigate)自己会先中断当前
    // 回合再移动 leaf。「生成完才能撤」会把最想撤的人(看着输出不对想立刻
    // 回退的)挡在门外 —— 那就是用户感知的「回退功能没了」。
    final canUndo = notifier.undoTargetEntryId != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一行:字标 + 会话名(点击切会话) + 撤销 + 会话树
          Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(PiShape.md),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    showSessionSheet(context, ref);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 14,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          'PiPilot',
                          style: AppType.wordmark(
                            size: 18,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _title(state),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.expand_more,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 原菜单三项:撤销、会话树直接摆成图标按钮;断开连接整项删除
              // (设置页仍有断开入口)。生成中的中断按钮也删了 —— 它和输入框
              // 的停止键是重复入口,留一个就够。
              IconButton(
                tooltip: '撤销上一轮',
                // 20px,和第二行收起箭头同尺寸 —— 默认 24 会让可见
                // 右边缘比收起箭头靠外 2px,两行对不齐。
                icon: const Icon(Icons.undo_rounded, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: canUndo
                    ? () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final ok = await notifier.undoLastTurn();
                        messenger.showSnackBar(
                          SnackBar(content: Text(ok ? '已撤销上一轮' : '撤销失败')),
                        );
                      }
                    : null,
              ),
              IconButton(
                tooltip: '会话树',
                icon: const Icon(Icons.account_tree_outlined, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: state.hasSelectedSource
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SessionTreeScreen(),
                        ),
                      )
                    : null,
              ),
            ],
          ),
          // 第二行:状态副行 + 收起箭头
          Row(
            children: [
              const SizedBox(width: 12),
              StatusDot(status: state.status),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  // 生成中时副行前面加工作状态,一眼看出模型在干什么。
                  [?islandWorkStatus(state), _subtitle(state)].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              IconButton(
                tooltip: '收起',
                icon: const Icon(Icons.expand_less, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: _collapse,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 生成中的运行时长:从挂载(streaming 开始)起表,每秒 tick。
///
/// 因为只在 `isStreaming == true` 时才会被插进树里,
/// initState 就是计时起点,dispose 自然停止 —— 不需要外部同步状态。
class _StreamTimer extends StatefulWidget {
  const _StreamTimer();

  @override
  State<_StreamTimer> createState() => _StreamTimerState();
}

class _StreamTimerState extends State<_StreamTimer> {
  late final DateTime _start = DateTime.now();
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed = DateTime.now().difference(_start));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _elapsed.inSeconds;
    final text = s < 60
        ? '${s}s'
        : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontFamily: 'monospace',
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 连接状态圆点;连接中带呼吸脉冲。
///
/// 原在 chat_app_bar.dart,旧顶栏被灵动岛取代后挪到这里
/// (灵动岛是唯一使用点)。
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.status});

  final PiConnStatus status;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    if (widget.status == PiConnStatus.connecting) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final color = switch (widget.status) {
      PiConnStatus.connected => piColors.success,
      PiConnStatus.connecting => piColors.warning,
      PiConnStatus.failed => colors.error,
      PiConnStatus.disconnected => colors.outline,
    };
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.35).animate(_pulse),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
