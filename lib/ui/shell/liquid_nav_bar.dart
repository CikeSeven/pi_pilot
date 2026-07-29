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

/// 底部导航:**水滴形变指示器**。
///
/// 指示器固定 64×48 -- 必须比图标(22)+间距(3)+文字(16)=41px 高,
/// 否则「包不住」内容。旧版 36px 太矮,文字露在指示器外面。
///
/// **不自带 SafeArea / 背景色** -- 外层给。
class LiquidNavBar extends StatefulWidget {
  const LiquidNavBar({
    super.key,
    required this.selectedIndex,
    required this.tabs,
    required this.onTap,
    this.position,
  });

  final int selectedIndex;

  /// 浮点位置(拖拽时传 display 值,指示器跟着手指走)。
  /// null = 用 selectedIndex + 内部动画。
  final double? position;

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
    value: 1,
  );

  int _from = 0;
  int _to = 0;

  @override
  void initState() {
    super.initState();
    _to = widget.selectedIndex;
  }

  @override
  void didUpdateWidget(LiquidNavBar old) {
    super.didUpdateWidget(old);
    if (widget.selectedIndex != old.selectedIndex) {
      _from = _to;
      _to = widget.selectedIndex;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // 指示器固定尺寸:宽 64 > 图标 22,高 48 > 图标+文字 41,完全包住。
  static const _indW = 64.0;
  static const _indH = 48.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = widget.tabs.length;

    return SizedBox(
      height: 64,
      child: LayoutBuilder(
        builder: (context, c) {
          final tabW = c.maxWidth / n;

          return Stack(
            children: [
              // ── 指示器层 ──
              AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) {
                  final t = _ctrl.value;
                  final pos = widget.position;
                  double x;
                  double bell;
                  if (pos != null) {
                    // 拖拽模式:直接用浮点位置,水滴形变跟着滚动进度。
                    // frac 从 0 到 1(一页内),sin(frac*pi) 从 0 到 1 再到 0 --
                    // 指示器在滚动中间最扁,两端恢复正常,就是「缩小再放大」。
                    x = tabW * (pos + 0.5);
                    final frac = pos - pos.floorToDouble();
                    bell = math.sin(frac * math.pi);
                  } else {
                    // 正常模式:_from -> _to 动画 + 水滴形变。
                    final eased = 1 - math.pow(1 - t, 3).toDouble();
                    final fromX = tabW * (_from + 0.5);
                    final toX = tabW * (_to + 0.5);
                    x = fromX + (toX - fromX) * eased;
                    bell = math.sin(t * math.pi);
                  }
                  final w = _indW * (1 - 0.20 * bell);
                  final h = _indH * (1 + 0.08 * bell);
                  final maxR = w / 2;
                  final pillR = _indH / 2;
                  final radius = pillR + (maxR - pillR) * bell;

                  return Positioned(
                    left: x - w / 2,
                    top: (64 - h) / 2,
                    child: Container(
                      width: w,
                      height: h,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color.lerp(
                              scheme.primaryContainer,
                              Colors.white,
                              0.25,
                            )!,
                            scheme.primaryContainer,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(radius),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.12),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              // ── 图标文字层 ──
              Row(
                children: [
                  for (var i = 0; i < n; i++)
                    Expanded(
                      child: _NavTabButton(
                        spec: widget.tabs[i],
                        selected: i == widget.selectedIndex,
                        color: scheme.primary,
                        unselectedColor: scheme.onSurfaceVariant,
                        onTap: () => widget.onTap(i),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NavTabButton extends StatelessWidget {
  const _NavTabButton({
    required this.spec,
    required this.selected,
    required this.color,
    required this.unselectedColor,
    required this.onTap,
  });

  final NavTabSpec spec;
  final bool selected;
  final Color color;
  final Color unselectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? spec.selectedIcon : spec.icon,
              size: 22,
              color: selected ? color : unselectedColor,
            ),
            const SizedBox(height: 3),
            Text(
              spec.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: selected
                    ? color
                    : unselectedColor.withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
