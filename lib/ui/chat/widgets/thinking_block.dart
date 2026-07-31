import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/shapes.dart';
import '../../theme/squircle.dart';
import '../../theme/typography.dart';
import 'ansi_text.dart';
import 'glass_pill.dart';

/// 思考过程:**深炭纸卡 + 波形指示**。
///
/// Editorial Retro 改版。旧版是「左侧一条竖线导轨 + 斜体灰字」,很克制,
/// 但参考图对这一块有明确的更高要求:思考是「Agent 正在认真处理任务」的
/// 核心表达,应该是一张**深色卡**,与奶油正文卡形成明暗对照,
/// 并且生成中要有波形动效,而不只是一个转圈。
///
/// 设计要点:
/// - 深炭底 + 奶油字:全屏唯一的深色内容块,视觉上就是「幕后」;
/// - 折叠头是可点的整行,带 `思考过程` 栏目名 + 生成中波形;
/// - 展开后正文用等宽小字 —— 思考是原始材料,不是成稿。
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.thinking,
    required this.streaming,
    this.duration = Duration.zero,
  });

  final String thinking;
  final bool streaming;

  /// 思考累计时长(完成后显示「思考了 Xs」)。
  final Duration duration;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  late bool _expanded = widget.streaming;

  @override
  void didUpdateWidget(ThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 生成结束:自动收起。AnimatedSize 会丝滑折叠,
    // 用户之后仍可手动点开回顾。
    if (oldWidget.streaming && !widget.streaming && _expanded) {
      setState(() => _expanded = false);
    }
  }

  /// 摘要行的时长文案:「思考了 12s」;历史回放时长未知时退化为「已思考」。
  String get _durationLabel {
    final s = widget.duration.inSeconds;
    if (s < 1) return '已思考';
    final m = s ~/ 60;
    if (m > 0) return '思考了 $m分${s % 60}秒';
    return '思考了 ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    // 生成中:完整深卡 + 波形,思考在流动要看得见。
    if (widget.streaming) return _buildStreamingCard(context);
    // 完成后:一行摘要,点开才展开深卡内容 —— 不占地方。
    return _buildFinishedRow(context);
  }

  /// 完成态:液态玻璃胶囊 + 可展开的深卡内容。
  Widget _buildFinishedRow(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 液态玻璃胶囊:和工具组折叠态共用 GlassPill,形态统一。
        // vertical 2:相邻胶囊间距 = 2+4+4+2 = 12,不再空廈。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: GlassPill(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.psychology_outlined, size: 15, color: muted),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    _durationLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: muted,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: PiMotion.collapse,
                  curve: PiMotion.collapseCurve,
                  child: Icon(Icons.expand_more, size: 15, color: muted),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: PiMotion.collapse,
          curve: PiMotion.collapseCurve,
          alignment: Alignment.topCenter,
          child: !_expanded
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _buildWell(context),
                ),
        ),
      ],
    );
  }

  /// 生成中:完整深卡(标题行带波形 + 可折叠内容)。
  Widget _buildStreamingCard(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // 思考卡是全屏唯一的**反差块**——「幕后」的视觉表达。
    // 浅色页面上它是暖炭黑;深色页面上不能再用暖炭黑(会糊进背景),
    // 改用抬升一档的暖石墨灰,仍与奶油正文卡形成明暗对照。
    final bg = isDark ? colors.surfaceContainerHigh : colors.inverseSurface;
    final fg = isDark ? colors.onSurface : colors.onInverseSurface;
    final fgMuted = fg.withValues(alpha: 0.72);
    // 栏目名与波形的点缀色:两套都用提亮过的主色系
    final accent = isDark ? colors.primary : colors.inversePrimary;

    return Material(
      color: bg,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        smoothing: PiShape.smoothing,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined, size: 15, color: accent),
                  const SizedBox(width: 9),
                  Text('思考过程 · 进行中', style: AppType.eyebrow(color: accent)),
                  const SizedBox(width: 12),
                  // 生成中:波形动效。「不要只有一个 loading」。
                  Expanded(child: _ThinkingWaveform(color: accent)),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: PiMotion.collapse,
                    curve: PiMotion.collapseCurve,
                    child: Icon(Icons.expand_more, size: 18, color: fgMuted),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: PiMotion.collapse,
            curve: PiMotion.collapseCurve,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : _buildWellContent(context),
          ),
        ],
      ),
    );
  }

  /// 完成态展开后的深卡内容(带外壳)。
  Widget _buildWell(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? colors.surfaceContainerHigh : colors.inverseSurface;
    return Material(
      color: bg,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        smoothing: PiShape.smoothing,
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildWellContent(context),
    );
  }

  /// 深卡里的正文:mono 小字 + 顶部分隔线。
  Widget _buildWellContent(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final fg = isDark ? colors.onSurface : colors.onInverseSurface;
    final fgMuted = fg.withValues(alpha: 0.72);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 1,
            margin: const EdgeInsets.only(bottom: 12),
            color: fgMuted.withValues(alpha: 0.22),
          ),
          SelectableText(
            // 全 app 唯一一个不走 ANSI 处理的文本出口,现在补上
            sanitizeThinking(widget.thinking),
            style: AppType.mono(
              size: 12,
              color: fg.withValues(alpha: 0.88),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 思考中的波形动效。
///
/// 一排竖条按正弦相位起伏,像声波/心跳监视器。
/// 比转圈更能表达「正在持续处理」,也贴合素材包里的 waveform 纹样语言。
class _ThinkingWaveform extends StatefulWidget {
  const _ThinkingWaveform({required this.color});

  final Color color;

  @override
  State<_ThinkingWaveform> createState() => _ThinkingWaveformState();
}

class _ThinkingWaveformState extends State<_ThinkingWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  /// 竖条数量。参考图里的波形大约这个密度。
  static const _bars = 14;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < _bars; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              _Bar(scale: _scaleFor(i), color: widget.color),
            ],
          ],
        ),
      ),
    );
  }

  /// 每条错开相位,取正弦正半轴 → 0.25~1.0 之间起伏。
  double _scaleFor(int index) {
    final phase = (_controller.value + index / _bars * 1.6) % 1.0;
    return 0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.scale, required this.color});

  final double scale;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 2,
      height: 16,
      child: Center(
        child: Container(
          width: 2,
          height: 16 * scale,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.4 + 0.6 * scale),
            borderRadius: const BorderRadius.all(Radius.circular(1)),
          ),
        ),
      ),
    );
  }
}
