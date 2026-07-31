import 'package:flutter/material.dart';

import '../../theme/motion.dart';

/// 消息导航轨道的锚点:一条用户消息在完整行表中的位置与预览。
class NavAnchor {
  const NavAnchor({required this.rowIndex, required this.preview, this.time});

  /// 该用户消息在完整渲染行表(_rows)中的下标。
  final int rowIndex;

  /// 消息全文(预览卡自己截断)。
  final String preview;
  final DateTime? time;
}

/// 消息导航轨道:屏幕左缘、**垂直居中**的一段刻度条,
/// 每个刻度对应一条用户消息。
///
/// 形态(参考章节刻度轨):轨道不铺满全屏 —— 高度约为可用区的 55%
/// (220~520dp 之间),居中停靠;刻度在轨道内**均匀密布**,
/// 第 i 个刻度就是第 i 条用户消息,过密时抽样绘制。
///
/// 交互:
/// - **点击刻度** —— 直接跳转到对应消息;
/// - **按住拖动 / 长按** —— 浮出预览卡,实时跟随手指切换刻度,
///   松手跳到最后预览的那条;
/// - **当前位置** —— 视口估算位置对应的刻度加长加亮;
/// - **显隐** —— 由外部 [visible] 驱动(滚动时弹出,静置自动缩回),
///   轨道被触摸期间外部应挂起自动隐藏。
///
/// 触控热区随轨道一起缩在中间:左缘上下不再拦截消息区的滚动手势。
class MessageNavRail extends StatefulWidget {
  const MessageNavRail({
    super.key,
    required this.visible,
    required this.anchors,
    required this.currentRow,
    required this.onJump,
    required this.onInteractionChanged,
  });

  /// 外部驱动的显隐。动画在内部做,外部只切 bool。
  final bool visible;

  /// 全部用户消息锚点(按 rowIndex 升序)。
  final List<NavAnchor> anchors;

  /// 视口估算位置对应的行下标(-1 未知),用来高亮最近刻度。
  final int currentRow;

  /// 跳转请求:参数是目标行下标。窗口扩展/粗跳/精修由调用方负责。
  final ValueChanged<int> onJump;

  /// 轨道被触摸(true)时外部挂起自动隐藏;松手(false)后恢复计时。
  final ValueChanged<bool> onInteractionChanged;

  @override
  State<MessageNavRail> createState() => _MessageNavRailState();
}

class _MessageNavRailState extends State<MessageNavRail>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: PiMotion.entrance,
  );
  late final Animation<double> _slide = CurvedAnimation(
    parent: _ctrl,
    curve: PiMotion.enter,
    reverseCurve: PiMotion.exit,
  );

  /// 正在拖拽/长按预览的刻度下标(null = 未交互)。
  int? _activeIndex;

  /// 预览卡中心 y(相对轨道顶)。
  double _previewY = 0;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _ctrl.value = 1;
  }

  @override
  void didUpdateWidget(MessageNavRail old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) {
      if (widget.visible) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 当前视口位置最近的刻度下标。
  int get _currentIndex {
    if (widget.anchors.isEmpty || widget.currentRow < 0) return -1;
    var best = 0;
    var bestDist = 1 << 30;
    for (var i = 0; i < widget.anchors.length; i++) {
      final d = (widget.anchors[i].rowIndex - widget.currentRow).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// 手势 y → 刻度下标:轨道内均匀分布,与绘制同一套映射。
  int _indexAt(double y, double height) {
    final n = widget.anchors.length;
    if (n == 0) return 0;
    const pad = _RailPainter.vPad;
    final usable = (height - pad * 2).clamp(1.0, double.infinity);
    final t = ((y - pad) / usable).clamp(0.0, 1.0);
    return (t * (n - 1)).round();
  }

  void _startPreview(double y, double height) {
    widget.onInteractionChanged(true);
    setState(() {
      _activeIndex = _indexAt(y, height);
      _previewY = y.clamp(0.0, height);
    });
  }

  void _updatePreview(double y, double height) {
    setState(() {
      _activeIndex = _indexAt(y, height);
      _previewY = y.clamp(0.0, height);
    });
  }

  void _endPreview() {
    final index = _activeIndex;
    widget.onInteractionChanged(false);
    setState(() => _activeIndex = null);
    if (index != null && index < widget.anchors.length) {
      widget.onJump(widget.anchors[index].rowIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.anchors.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;

    return FadeTransition(
      opacity: _slide,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).animate(_slide),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 轨道缩在中间:高度 = 可用区 55%,夹在 220~520 之间。
            // 刻度在里面均匀密布 —— 不铺满全屏。
            final railHeight = (constraints.maxHeight * 0.55).clamp(
              220.0,
              520.0,
            );
            return Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  final i = _indexAt(d.localPosition.dy, railHeight);
                  if (i < widget.anchors.length) {
                    widget.onJump(widget.anchors[i].rowIndex);
                  }
                },
                onVerticalDragStart: (d) =>
                    _startPreview(d.localPosition.dy, railHeight),
                onVerticalDragUpdate: (d) =>
                    _updatePreview(d.localPosition.dy, railHeight),
                onVerticalDragEnd: (_) => _endPreview(),
                onVerticalDragCancel: _endPreview,
                onLongPressStart: (d) =>
                    _startPreview(d.localPosition.dy, railHeight),
                onLongPressMoveUpdate: (d) =>
                    _updatePreview(d.localPosition.dy, railHeight),
                onLongPressEnd: (_) => _endPreview(),
                onLongPressCancel: _endPreview,
                child: SizedBox(
                  width: 28,
                  height: railHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CustomPaint(
                        size: Size(28, railHeight),
                        painter: _RailPainter(
                          count: widget.anchors.length,
                          currentIndex: _currentIndex,
                          activeIndex: _activeIndex,
                          tickColor: colors.outlineVariant,
                          currentColor: colors.primary,
                          trackColor: colors.outlineVariant.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ),
                      if (_activeIndex != null)
                        Positioned(
                          left: 32,
                          top: (_previewY - 44).clamp(0.0, railHeight - 88),
                          child: _PreviewCard(
                            anchor: widget.anchors[_activeIndex!],
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
    );
  }
}

/// 刻度绘制:轨道内均匀分布的小横线。
///
/// 过密(相邻 < 3px)时抽样绘制,当前/拖拽刻度永远绘制;
/// 抽样只影响视觉,手势映射仍按全量序号。
/// 一条淡竖线作轨道基线,稀疏时读起来是「轨道」而不是散点。
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.count,
    required this.currentIndex,
    required this.activeIndex,
    required this.tickColor,
    required this.currentColor,
    required this.trackColor,
  });

  static const vPad = 6.0;

  final int count;
  final int currentIndex;
  final int? activeIndex;
  final Color tickColor;
  final Color currentColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (count <= 0) return;
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final usable = size.height - vPad * 2;

    // 轨道基线。
    canvas.drawLine(
      const Offset(2, vPad),
      Offset(2, size.height - vPad),
      Paint()
        ..color = trackColor
        ..strokeWidth = 1,
    );

    // 均匀密布:3px 一个刻度,超出容量就抽样(视觉),交互不受影响。
    final maxTicks = (usable / 3).floor().clamp(1, count);
    final step = (count / maxTicks).ceil();

    for (var i = 0; i < count; i += step) {
      final y = count == 1
          ? vPad + usable / 2
          : vPad + usable * i / (count - 1);
      final isCurrent =
          i == currentIndex ||
          (currentIndex >= 0 && (currentIndex - i).abs() < step);
      final isActive = i == activeIndex;
      final width = isCurrent
          ? 16.0
          : isActive
          ? 12.0
          : 8.0;
      paint.color = isCurrent
          ? currentColor
          : isActive
          ? currentColor.withValues(alpha: 0.6)
          : tickColor;
      canvas.drawLine(Offset(3, y), Offset(3 + width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.count != count ||
      old.currentIndex != currentIndex ||
      old.activeIndex != activeIndex ||
      old.tickColor != tickColor ||
      old.currentColor != currentColor ||
      old.trackColor != trackColor;
}

/// 长按/拖动时浮出的消息预览卡。
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.anchor});

  final NavAnchor anchor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final time = anchor.time;
    return Container(
      width: 240,
      constraints: const BoxConstraints(maxHeight: 88),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (time != null)
            Text(
              '${time.hour.toString().padLeft(2, '0')}:'
              '${time.minute.toString().padLeft(2, '0')}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 2),
          Flexible(
            child: Text(
              anchor.preview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
