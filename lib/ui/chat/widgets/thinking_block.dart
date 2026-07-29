import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/shapes.dart';
import '../../theme/squircle.dart';
import '../../theme/typography.dart';
import 'ansi_text.dart';

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
  });

  final String thinking;
  final bool streaming;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  late bool _expanded = widget.streaming;

  @override
  Widget build(BuildContext context) {
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

    // 用 Material + SquircleBorder,和 assistant_bubble/message_card 同一种圆角语言。
    // 之前用 BoxDecoration(普通圆角),和其他卡的 squircle 视觉不一致。
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
                  Text(
                    widget.streaming ? '思考过程 · 进行中' : '思考过程',
                    style: AppType.eyebrow(color: accent),
                  ),
                  const SizedBox(width: 12),
                  // 生成中:波形动效。这是参考图明确要的「不要只有一个 loading」。
                  if (widget.streaming)
                    Expanded(child: _ThinkingWaveform(color: accent))
                  else
                    const Spacer(),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: PiMotion.quick,
                    curve: PiMotion.enter,
                    child: Icon(Icons.expand_more, size: 18, color: fgMuted),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: PiMotion.quick,
            curve: PiMotion.enter,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
