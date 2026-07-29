import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// 一个 tab 的定义。
class NavTabSpec {
  const NavTabSpec({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 底部导航:**水滴形变选中指示器 + 同色通栏**。
///
/// ## 核心难点:位置 + 形变必须同步
///
/// 旧版用 `AnimatedAlign` 驱动位置 + 另一个 controller 驱动形变,
/// 两个动画各自为政 —— 位置滑到一半形变已经结束(或反之),看着就「没对上」。
///
/// 这里用**单个 `AnimationController` 同时驱动三件事**:
/// 1. 指示器的水平偏移量(从旧 tab 中心 → 新 tab 中心);
/// 2. 指示器的宽度(中段收窄,模拟液滴被拉伸 → 两侧「变圆」);
/// 3. 圆角半径(中段趋向正圆,两端回到药丸)。
///
/// 三者用同一个 `t`,物理上不可能不同步。这才是「丝滑、对齐、有形变」
/// 的正确实现。
///
/// ## 对齐
///
/// 指示器宽度不写死,而是**屏宽 / tab 数 × 0.62**(占一个 tab 宽的 62%),
/// 左右边距天然相等。水平位置用「tab 中心点的像素坐标」精确驱动,
/// 不依赖 `Alignment` 的百分比插值 —— 那个会因 child 宽度不同而漂移。
class LiquidNavBar extends StatefulWidget {
  const LiquidNavBar({
    super.key,
    required this.selectedIndex,
    required this.tabs,
    required this.onTap,
  });

  final int selectedIndex;
  final List<NavTabSpec> tabs;
  final ValueChanged<int> onTap;

  @override
  State<LiquidNavBar> createState() => _LiquidNavBarState();
}

class _LiquidNavBarState extends State<LiquidNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: PiMotion.standard,
    value: 1, // 初始静止态 = 已到位
  );

  /// 动画起点(旧 tab 中心)与终点(新 tab 中心)的索引。
  int _from = 0;
  int _to = 0;

  @override
  void didUpdateWidget(LiquidNavBar old) {
    super.didUpdateWidget(old);
    if (widget.selectedIndex != old.selectedIndex) {
      // 从「当前实际位置」出发,滑到新的 tab 中心。
      _from = _to; // 上次的终点 = 这次起点
      _to = widget.selectedIndex;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: LayoutBuilder(
            builder: (context, c) {
              final n = widget.tabs.length;
              final tabW = c.maxWidth / n;
              // 指示器基准宽度:占一个 tab 的 58%。
              final baseW = tabW * 0.58;
              final indicatorH = baseW * 0.72; // 高 ≈ 宽的 0.72,接近圆角矩形
              final pillR = indicatorH / 2;

              // tab i 中心的 x 坐标(像素,相对左边)。
              double centerX(int i) => tabW * (i + 0.5);

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // ── 指示器层 ──
                  // 用 AnimatedBuilder 监听 _ctrl,同一 t 驱动位置 + 形变。
                  AnimatedBuilder(
                    animation: _ctrl,
                    builder: (context, _) {
                      final t = _ctrl.value;
                      // 位置:线性插值就能丝滑(曲线由 controller 的 curve 给)。
                      // 但 _ctrl 默认线性,这里手动加缓动:
                      final eased = _easeOutCubic(t);
                      final x =
                          centerX(_from) +
                          (centerX(_to) - centerX(_from)) * eased;

                      // 形变:钟形权重,中段=1、两端=0。
                      // sin(πt) 在 0 和 1 处为 0,在 0.5 处为 1 —— 完美的钟形。
                      final bell = math.sin(t * math.pi);
                      // 形变幅度调到明显可感:中段宽度收窄 30%、高度胀大 18%。
                      // 旧值 0.12/0.08 太弱,几乎看不出「水滴」。
                      final w = baseW * (1 - 0.30 * bell);
                      final h = indicatorH * (1 + 0.18 * bell);
                      // 圆角:药丸 → 正圆 → 药丸。中段直接拉到正圆半径。
                      final maxR = w / 2;
                      final radius = pillR + (maxR - pillR) * bell;

                      return Positioned(
                        // 以 (x, 垂直居中) 为中心放置指示器。
                        left: x - w / 2,
                        top: (64 - h) / 2,
                        child: Container(
                          width: w,
                          height: h,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(radius),
                          ),
                        ),
                      );
                    },
                  ),
                  // ── 文字图标层(在指示器之上) ──
                  // 用和指示器**同一个垂直中心**:两者都按 barHeight=64 居中,
                  // 不会再出现「图标靠上、指示器靠下」的错位。
                  Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        Expanded(
                          child: _NavTabButton(
                            spec: widget.tabs[i],
                            selected: i == widget.selectedIndex,
                            color: scheme.primary,
                            unselectedColor: scheme.onSurfaceVariant,
                            barHeight: 64,
                            onTap: () => widget.onTap(i),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 标准的 ease-out 三次曲线:快进慢出。
/// AnimatedController 的 Curve 通道没法直接喂给手动插值,所以内联。
double _easeOutCubic(double t) {
  final v = 1 - math.pow(1 - t, 3);
  return v.toDouble();
}

class _NavTabButton extends StatelessWidget {
  const _NavTabButton({
    required this.spec,
    required this.selected,
    required this.color,
    required this.unselectedColor,
    required this.barHeight,
    required this.onTap,
  });

  final NavTabSpec spec;
  final bool selected;
  final Color color;
  final Color unselectedColor;
  /// 与指示器同一个 bar 总高,保证两者垂直中心对齐。
  final double barHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // 用 SizedBox 锁住和指示器一致的高度,Column 在里面居中 →
      // 垂直中心和指示器完全对齐,图标不再靠上。
      child: SizedBox(
        height: barHeight,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            // 图标:选中时放大、用选中色。
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.8, end: selected ? 1.0 : 0.9),
              duration: PiMotion.standard,
              curve: PiMotion.enter,
              builder: (context, scale, child) => Transform.scale(
                scale: scale,
                child: child,
              ),
              child: Icon(
                selected ? spec.selectedIcon : spec.icon,
                size: 22,
                color: selected ? color : unselectedColor,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: PiMotion.quick,
              curve: PiMotion.enter,
              style: theme.textTheme.labelSmall!.copyWith(
                color: selected
                    ? color
                    : unselectedColor.withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
              child: Text(spec.label),
            ),
          ],
        ),
      ),
    );
  }
}
