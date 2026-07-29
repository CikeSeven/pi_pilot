import 'package:flutter/material.dart';

import '../../theme/motion.dart';

/// 流式输出末尾的闪烁竖线光标。
///
/// 替代旧实现里 `'${item.text} ▍'` 的字符拼接:那个写法把光标粘在
/// 文本末尾,每个 token 刷新时整段重建,光标跟着末尾位置一起跳动,
/// 既不连贯也不闪。这里用独立的脉冲竖线:
///
/// - **固定宽度** —— 不会因字体度量抖动;
/// - **呼吸闪烁** —— 透明度 0.25↔1.0,周期 1s,比硬闪更柔和;
/// - **高度对齐正文** —— 用 [StrutStyle] 与正文行高一致,多行回复时
///   光标跟着最后一个字符、稳稳坐在 baseline 上,不会因换行错位。
///
/// 作为 [WidgetSpan] 嵌入 `Text.rich` 的末尾 span,既能跟随文本换行,
/// 又不破坏宿主 `SelectableText` 的可选中性。
class StreamingCursor extends StatefulWidget {
  const StreamingCursor({
    super.key,
    this.color,
    this.width = 2.5,
    this.height = 18,
  });

  /// 光标颜色。默认在 [AssistantBubble] 里传入 `colorScheme.primary`。
  final Color? color;

  /// 光标宽度。2.5dp 在 16sp 正文里既能看清又不抢戏。
  final double width;

  /// 光标高度。略低于一行正文(行高 1.5 × 16 = 24),上下各留一点,
  /// 视觉上落在行内,不顶满行高。
  final double height;

  @override
  State<StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // 比典型输入光标的 ~530ms 稍慢一点:流式场景下文本本身就在变,
    // 光标闪太快会和 token 节奏打架,1s 一次的呼吸刚好。
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.25).animate(
        CurvedAnimation(parent: _controller, curve: PiMotion.std),
      ),
      child: Container(
        width: widget.width,
        height: widget.height,
        // 一点点圆角让竖线收口柔和,不至于像一根硬棍
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.all(Radius.circular(1.5)),
        ),
      ),
    );
  }
}
