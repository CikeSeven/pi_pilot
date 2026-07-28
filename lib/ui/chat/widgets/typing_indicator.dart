import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 流式等待中的三点动画。
///
/// 原来是拼字符串 `'.'*n`,行宽会随点数跳动。改成三个固定位置的圆点做相位缩放,
/// 布局稳定,也更像 M3 的进度反馈。
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              _Dot(color: color, scale: _scaleFor(i)),
            ],
          ],
        );
      },
    );
  }

  /// 每个点错开 1/3 周期,正弦取正半轴 → 0.55~1.0 之间脉动。
  double _scaleFor(int index) {
    final phase = (_controller.value + index / 3) % 1.0;
    return 0.55 + 0.45 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.scale});

  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 8,
      height: 8,
      child: Center(
        child: Container(
          width: 8 * scale,
          height: 8 * scale,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.35 + 0.65 * scale),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
