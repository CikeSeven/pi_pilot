import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../theme/motion.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';

/// 输入条:**Claude Code 风格两行布局**。
///
/// ```
/// ┌────────────────────────────┐
/// │ 输入文字…                  │
/// │ [✦ Kimi K3 ▾]         [↑]  │
/// └────────────────────────────┘
/// ```
///
/// 第一行是输入区;第二行左侧是**模型选择胶囊**(液态玻璃),
/// 点一下它就像灵动岛一样变长变宽、展开成模型列表;右侧是发送键
/// (固定 48,垂直居中于第二行,不会随输入框变高而移位)。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.streaming,
    this.compacting = false,
    required this.onSend,
    this.onSteer,
    this.onFollowUp,
    this.onInterruptAndSend,
    this.onAbort,
    this.onChanged,
    this.quickPanel,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool streaming;

  /// 桌面端正在压缩上下文:它也是「忙」,但不是流式 ——
  /// 没有打字指示器、没有中断按钮,输入框必须自己说清楚消息会排队。
  final bool compacting;
  final VoidCallback onSend;

  /// 生成中的三种投递方式(输入框有内容时才展示)。
  /// 注意 steer 叫「插队」而不是「打断」—— 它不会中断当前这一轮。
  final VoidCallback? onSteer;
  final VoidCallback? onFollowUp;
  final VoidCallback? onInterruptAndSend;

  /// 流式且输入框为空时,发送键变为停止键。
  final VoidCallback? onAbort;
  final ValueChanged<String>? onChanged;

  /// 斜杠命令/快捷指令面板插槽(渲染在输入行上方)。
  final Widget? quickPanel;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _focusNode = FocusNode();
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() => _isFocused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final showStop =
        widget.streaming &&
        widget.onAbort != null &&
        widget.controller.text.trim().isEmpty;
    final sendEnabled = widget.enabled || showStop;
    final busy = widget.streaming || widget.compacting;

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: PiMotion.quick,
              curve: PiMotion.enter,
              alignment: Alignment.bottomCenter,
              child:
                  widget.quickPanel ?? const SizedBox(width: double.infinity),
            ),
            // 生成中且已经写了内容:让用户明确选投递方式,而不是猜发送键的语义
            AnimatedSize(
              duration: PiMotion.quick,
              curve: PiMotion.enter,
              alignment: Alignment.bottomCenter,
              child: busy && widget.controller.text.trim().isNotEmpty
                  ? SizedBox(
                      width: double.infinity,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                        child: Row(
                          children: [
                            ActionChip(
                              avatar: const Icon(Icons.bolt_outlined, size: 18),
                              label: const Text('插队'),
                              tooltip: widget.compacting
                                  ? '压缩结束后立刻处理'
                                  : '本轮结束后立刻处理',
                              onPressed: widget.onSteer,
                            ),
                            const SizedBox(width: 8),
                            ActionChip(
                              avatar: const Icon(
                                Icons.playlist_add_outlined,
                                size: 18,
                              ),
                              label: const Text('排队'),
                              tooltip: '全部处理完之后再处理',
                              onPressed: widget.onFollowUp,
                            ),
                            if (widget.streaming) ...[
                              const SizedBox(width: 8),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.stop_circle_outlined,
                                  size: 18,
                                ),
                                label: const Text('中断并发送'),
                                tooltip: '停止当前这一轮,然后发送',
                                onPressed: widget.onInterruptAndSend,
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            // 悬浮输入卡:液态玻璃,两行布局。
            // top 必须是 0:外层(chat_body)给整个编辑区包的是不透明底色,
            // 这里若留上 padding,会被填成一条不透明背景悬在卡片上边框外,
            // 把从底下滚过的文字齐边截断 —— 渐隐带白做了。
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(PiShape.lg),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(
                        colors.surfaceContainerLow,
                        Colors.white,
                        Theme.of(context).brightness == Brightness.dark
                            ? 0.06
                            : 0.15,
                      )!,
                      colors.surfaceContainerLow,
                      Color.lerp(
                        colors.surfaceContainerLow,
                        Colors.black,
                        Theme.of(context).brightness == Brightness.dark
                            ? 0.08
                            : 0.04,
                      )!,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                  // 聚焦时边框高亮:液态玻璃「活了」。
                  border: Border.all(
                    color: _isFocused
                        ? colors.primary.withValues(alpha: 0.35)
                        : colors.outlineVariant.withValues(alpha: 0.3),
                    width: _isFocused ? 1.0 : 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: 0.04),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  // 四边统一 10:模型按钮距左=距底,发送按钮距右=距底。
                  // top 只要 2:TextField 自带 contentPadding vertical 10,
                  // 视觉上方间距 = 2+10 = 12,和下方 10 接近。
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 第一行:输入区
                      TextField(
                        controller: widget.controller,
                        focusNode: _focusNode,
                        enabled: widget.enabled,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        onChanged: widget.onChanged,
                        decoration: InputDecoration(
                          hintText: widget.compacting
                              ? '压缩中 · 发送会排队'
                              : widget.streaming
                              ? '生成中 · 发送会插队'
                              : null,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 10,
                          ),
                        ),
                      ),
                      // 第二行:模型选择胶囊 + 上下文环 + 发送键
                      LayoutBuilder(
                        builder: (context, constraints) {
                          // 模型面板展开宽 = Row 宽 − 上下文环(30) − 间距(8)
                          // − 发送键(48) − 余量(4)。不定宽 240:小屏溢出。
                          final pickerMax = constraints.maxWidth - 90;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              ModelPicker(maxExpandedWidth: pickerMax),
                              const SizedBox(width: 8),
                              const _ContextRing(),
                              const Spacer(),
                              _SendButton(
                                showStop: showStop,
                                enabled: sendEnabled,
                                onTap: () {
                                  if (showStop) {
                                    HapticFeedback.mediumImpact();
                                    widget.onAbort!();
                                  } else {
                                    HapticFeedback.lightImpact();
                                    widget.onSend();
                                  }
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 展开卡内的两个视图。
enum _PickerView { models, thinking }

/// 模型选择胶囊:**液态玻璃,点一下像灵动岛一样变长变宽**。
///
/// 收起态:小胶囊显示当前模型名(132×32)。
/// 展开态:列表卡(≤240×内容),从胶囊位置向上生长,
/// 列出 `getAvailableModels()` 返回的全部模型,选一个即切换并收起。
class ModelPicker extends ConsumerStatefulWidget {
  const ModelPicker({super.key, this.maxExpandedWidth = 240});

  /// 展开时的最大宽度。调用方按 Row 剩余空间传入(卡内宽 − 上下文环
  /// − 发送键),防止 240 定宽在小屏上溢出 RIGHT OVERFLOWED。
  final double maxExpandedWidth;

  @override
  ConsumerState<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends ConsumerState<ModelPicker> {
  bool _expanded = false;

  /// 展开卡内的视图:一级选模型,二级选思考深度。
  /// 选完模型自动进二级 —— 模型和深度是配套决策,不该让用户再点一次。
  _PickerView _view = _PickerView.models;

  List<ModelInfo>? _models;
  List<String>? _levels;
  bool _loading = false;

  Future<void> _toggle() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() {
      _expanded = true;
      _view = _PickerView.models;
    });
    if (_models == null && !_loading) {
      _loading = true;
      final notifier = ref.read(piSessionNotifierProvider);
      if (notifier == null) {
        _loading = false;
        return;
      }
      // 模型和深度并行加载:同一次展开都要用。
      final results = await Future.wait([
        notifier.getAvailableModels(),
        notifier.getThinkingLevels(),
      ]);
      if (mounted) {
        setState(() {
          _models = results[0] as List<ModelInfo>;
          _levels = results[1] as List<String>;
          _loading = false;
        });
      }
    }
  }

  /// 选中模型:不切走就收起来不及选深度 —— 自动进二级。
  Future<void> _selectModel(ModelInfo m) async {
    final ok = await ref
        .read(piSessionNotifierProvider)
        ?.setModel(m.provider, m.id);
    if (!mounted) return;
    if (ok != true) {
      setState(() => _expanded = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('切换模型失败')));
      return;
    }
    setState(() => _view = _PickerView.thinking);
  }

  Future<void> _selectLevel(String level) async {
    setState(() => _expanded = false);
    final ok = await ref
        .read(piSessionNotifierProvider)
        ?.setThinkingLevel(level);
    if (mounted && ok != true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('切换思考深度失败')));
    }
  }

  /// 深度的中文标签:off/minimal/low/medium/high 是协议词,UI 说人话。
  static String _levelLabel(String level) => switch (level) {
    'off' => '关闭',
    'minimal' => '极简',
    'low' => '低',
    'medium' => '中',
    'high' => '高',
    _ => level,
  };

  double get _expandedHeight {
    if (_view == _PickerView.thinking) {
      final n = _levels?.length ?? 5;
      return (n * 42.0 + 44.0).clamp(72.0, 268.0);
    }
    if (_models == null) return 72;
    return (_models!.length * 42.0 + 44.0).clamp(72.0, 268.0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentName =
        ref.watch(piSessionProvider.select((s) => s.modelName)) ?? '选择模型';
    final currentId = ref.watch(piSessionProvider.select((s) => s.modelId));
    final thinking = ref.watch(
      piSessionProvider.select((s) => s.thinkingLevel),
    );
    // 胶囊上把深度也亮出来:模型和深度是配套信息。
    // off 是默认值,不占地方。
    final pillText = thinking != null && thinking != 'off'
        ? '$currentName · ${_levelLabel(thinking)}'
        : currentName;

    // 展开宽:理想 240,但不超过调用方给的可用宽(小屏防溢出)。
    final expandedWidth = widget.maxExpandedWidth.clamp(160.0, 240.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
      width: _expanded ? expandedWidth : 132,
      height: _expanded ? _expandedHeight : 32,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_expanded ? 18 : 16),
        // 液态玻璃:比输入卡再亮一档,像嵌在卡里的玻璃珠。
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(
              colors.surfaceContainerHigh,
              Colors.white,
              isDark ? 0.08 : 0.2,
            )!,
            colors.surfaceContainerHigh,
          ],
        ),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.4),
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: !_expanded
              ? _buildPill(colors, pillText)
              : (_view == _PickerView.models
                    ? _buildList(colors, currentId)
                    : _buildThinking(colors, thinking)),
        ),
      ),
    );
  }

  /// 收起态:胶囊。
  Widget _buildPill(ColorScheme colors, String name) {
    return InkWell(
      key: const ValueKey('pill'),
      onTap: _toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, size: 13, color: colors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Icon(
              Icons.keyboard_arrow_up,
              size: 15,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 二级菜单:思考深度列表。
  ///
  /// 选完模型自动进到这里;返回箭头回模型列表,选一个深度即收起。
  Widget _buildThinking(ColorScheme colors, String? currentLevel) {
    final theme = Theme.of(context);
    final levels = _levels ?? const ['off', 'minimal', 'low', 'medium', 'high'];
    return Column(
      key: const ValueKey('thinking'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题行:返回 + 标题 + 收起
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(PiShape.sm),
                onTap: () => setState(() => _view = _PickerView.models),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.arrow_back,
                    size: 15,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '思考深度',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(PiShape.sm),
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant.withValues(alpha: 0.5)),
        Flexible(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: levels.length,
            itemExtent: 42,
            itemBuilder: (context, i) {
              final level = levels[i];
              final selected = level == currentLevel;
              return InkWell(
                onTap: () => _selectLevel(level),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        size: 15,
                        color: selected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _levelLabel(level),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(Icons.check, size: 16, color: colors.primary),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 展开态:模型列表卡。
  Widget _buildList(ColorScheme colors, String? currentId) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('list'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题行(点击收起)
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '选择模型',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant.withValues(alpha: 0.5)),
        Flexible(
          child: _models == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: _models!.length,
                  itemExtent: 42,
                  itemBuilder: (context, i) {
                    final m = _models![i];
                    final selected = m.id == currentId;
                    return InkWell(
                      onTap: () => _selectModel(m),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                  if (m.provider.isNotEmpty)
                                    Text(
                                      m.provider,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                            if (selected)
                              Icon(
                                Icons.check,
                                size: 16,
                                color: colors.primary,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 上下文占用圆环:30px 小环,和模型胶囊并排。
///
/// 颜色语义:<60% 主题色(安全),60-85% 琥珀(注意),>85% 砖红(快满)。
/// 中间放百分比数字(mono 等宽,8.5px 塞得下三位数)。
class _ContextRing extends ConsumerWidget {
  const _ContextRing();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final usage = ref.watch(piSessionProvider.select((s) => s.contextUsage));
    final percent = usage?.percent;
    if (percent == null) return const SizedBox.shrink();

    final color = percent < 60
        ? colors.primary
        : percent < 85
        ? const Color(0xFFB8860B) // 琥珀:复古色系里的「注意」
        : colors.error;

    final label = percent >= 100 ? '满' : '$percent';

    return Tooltip(
      message: '上下文占用 $percent%',
      child: SizedBox(
        width: 30,
        height: 30,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: (percent / 100).clamp(0.0, 1.0),
              strokeWidth: 2.5,
              strokeCap: StrokeCap.round,
              backgroundColor: colors.outlineVariant.withValues(alpha: 0.3),
              color: color,
            ),
            Text(
              label,
              style: AppType.mono(
                size: 8.5,
                weight: FontWeight.w600,
                color: color,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 液态玻璃发送键:渐变高光 + 柔和投影 + 按压缩放回弹。
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.showStop,
    required this.enabled,
    required this.onTap,
  });

  final bool showStop;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final showStop = widget.showStop;
    return GestureDetector(
      onTap: !widget.enabled ? null : widget.onTap,
      onTapDown: !widget.enabled
          ? null
          : (_) => setState(() => _pressed = true),
      onTapUp: !widget.enabled ? null : (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.86 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: showStop
                  ? [Color.lerp(colors.error, Colors.white, 0.3)!, colors.error]
                  : [
                      Color.lerp(colors.primary, Colors.white, 0.3)!,
                      colors.primary,
                    ],
            ),
            boxShadow: [
              BoxShadow(
                color: (showStop ? colors.error : colors.primary).withValues(
                  alpha: 0.4,
                ),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: AnimatedSwitcher(
            duration: PiMotion.quick,
            child: Icon(
              showStop ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              key: ValueKey(showStop),
              size: 22,
              color: showStop ? colors.onError : colors.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
