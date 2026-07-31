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

/// 消息导航轨道:左侧边缘的刻度条,每个刻度对应一条用户消息。
///
/// 交互:
/// - **点击刻度** —— 直接跳转到对应消息;
/// - **按住拖动 / 长按** —— 浮出预览卡,实时跟随手指切换刻度,
///   松手跳到最后预览的那条;
/// - **当前位置** —— 视口估算位置对应的刻度加长加亮;
/// - **显隐** —— 由外部 [visible] 驱动(滚动时弹出,静置自动缩回),
///   轨道被触摸期间外部应挂起自动隐藏。
///
/// 视觉上是一条 28dp 宽的透明热区,刻度画在右内侧;预览卡浮在轨道右边。
class MessageNavRail extends StatefulWidget {
  const MessageNavRail({
    super.key,
    required this.visible,
    required this.anchors,
    required this.currentRow,
    required this.totalRows,
    required this.onJump,
    required this.onInteractionChanged,
  });

  /// 外部驱动的显隐。动画在内部做,外部只切 bool。
  final bool visible;

  /// 全部用户消息锚点(按 rowIndex 升序)。
  final List<NavAnchor> anchors;

  /// 视口估算位置对应的行下标(-1 未知),用来高亮最近刻度。
  final int currentRow;

  /// 完整渲染行表长度。刻度按 rowIndex/(totalRows-1) 比例分布 ——
  /// 刻度位置就是消息在列表里的真实相对位置,和滚动位置成线性关系。
  ///(之前按「锚点序号」均布,消息分布不均时刻度和真实位置对不上,
  /// 点/拖到的消息和视觉位置预期不一致;均布还把刻度摊开,间隙虚大。)
  final int totalRows;

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

  /// 手势 y → 最近的刻度下标。
  ///
  /// 与绘制同一套映射:y 比例 → 列表行号 → 最近锚点。
  /// 锚点按 rowIndex 升序,线性扫描对几百条足够(手势更新才 60Hz)。
  int _indexAt(double y, double height) {
    final n = widget.anchors.length;
    if (n == 0) return 0;
    const pad = _RailPainter.vPad;
    final usable = (height - pad * 2).clamp(1.0, double.infinity);
    final t = ((y - pad) / usable).clamp(0.0, 1.0);
    final denom = (widget.totalRows - 1).clamp(1, 1 << 30);
    final targetRow = t * denom;
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < n; i++) {
      final d = (widget.anchors[i].rowIndex - targetRow).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
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
            final height = constraints.maxHeight;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final i = _indexAt(d.localPosition.dy, height);
                if (i < widget.anchors.length) {
                  widget.onJump(widget.anchors[i].rowIndex);
                }
              },
              onVerticalDragStart: (d) =>
                  _startPreview(d.localPosition.dy, height),
              onVerticalDragUpdate: (d) =>
                  _updatePreview(d.localPosition.dy, height),
              onVerticalDragEnd: (_) => _endPreview(),
              onVerticalDragCancel: _endPreview,
              onLongPressStart: (d) =>
                  _startPreview(d.localPosition.dy, height),
              onLongPressMoveUpdate: (d) =>
                  _updatePreview(d.localPosition.dy, height),
              onLongPressEnd: (_) => _endPreview(),
              onLongPressCancel: _endPreview,
              child: SizedBox(
                width: 28,
                height: height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomPaint(
                      size: Size(28, height),
                      painter: _RailPainter(
                        rowIndexes: [
                          for (final a in widget.anchors) a.rowIndex,
                        ],
                        totalRows: widget.totalRows,
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
                        top: (_previewY - 44).clamp(0.0, height - 88),
                        child: _PreviewCard(
                          anchor: widget.anchors[_activeIndex!],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 刻度绘制:按消息在列表中的真实位置(rowIndex/totalRows)比例分布。
///
/// 过密时跳过重叠刻度(相邻 < 2.5px),但当前/拖拽刻度永远绘制。
/// 轨道画一条淡竖线打底 —— 比例分布下消息稀疏区刻度必然稀,
/// 没有基线会显得「断档」,有基线读起来才是「这条轨道上这里没消息」。
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.rowIndexes,
    required this.totalRows,
    required this.currentIndex,
    required this.activeIndex,
    required this.tickColor,
    required this.currentColor,
    required this.trackColor,
  });

  static const vPad = 6.0;

  /// 每个锚点的行下标(升序)。
  final List<int> rowIndexes;
  final int totalRows;
  final int currentIndex;
  final int? activeIndex;
  final Color tickColor;
  final Color currentColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final count = rowIndexes.length;
    if (count <= 0) return;
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final usable = size.height - vPad * 2;
    final denom = (totalRows - 1).clamp(1, 1 << 30);

    // 轨道基线:淡竖线,刻度从它出发向右画。
    canvas.drawLine(
      const Offset(2, vPad),
      Offset(2, size.height - vPad),
      Paint()
        ..color = trackColor
        ..strokeWidth = 1,
    );

    var lastY = -10.0;
    for (var i = 0; i < count; i++) {
      final y = vPad + usable * rowIndexes[i] / denom;
      final isCurrent = i == currentIndex;
      final isActive = i == activeIndex;
      // 重叠刻度跳过绘制(交互映射不受影响),高亮刻度除外。
      if (!isCurrent && !isActive && y - lastY < 2.5) continue;
      lastY = y;
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
      old.rowIndexes != rowIndexes ||
      old.totalRows != totalRows ||
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
