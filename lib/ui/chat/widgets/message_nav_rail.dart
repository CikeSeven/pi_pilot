import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import '../../theme/shapes.dart';
import '../chat_scroll_anchor.dart';
import '../nav_anchor.dart';

export '../nav_anchor.dart' show NavAnchor;

/// 消息导航轨道:屏幕左缘、**垂直居中**的一段刻度条,
/// 每个刻度对应一条用户消息。
///
/// 形态(参考章节刻度轨):轨道不铺满全屏 —— 高度约为可用区的 55%
/// (220~520dp 之间),居中停靠;刻度在轨道内**均匀密布**,
/// 第 i 个刻度就是第 i 条用户消息,过密时抽样绘制。
///
/// 当前位置指示是**连续游标**:一条随滚动进度实时滑动的长胶囊
/// (像滚动条 thumb,滚动到哪它滑到哪,天然丝滑,不需要补间动画),
/// 游标附近的锚点刻度联动高亮。滚动进度由外部 [progress] 驱动 ——
/// 必须是可以滚动时逐帧更新的 listenable,否则游标会停在
/// 滚动前的位置(滚动本身不触发外层 rebuild,这是个真踩过的坑)。
///
/// 交互:
/// - **点击刻度** —— 直接跳转到对应消息;
/// - **按住拖动 / 长按** —— 浮出预览卡,实时跟随手指切换刻度,
///   松手跳到最后预览的那条;
/// - **显隐** —— 由外部 [visible] 驱动(滚动时弹出,静置自动缩回),
///   轨道被触摸期间外部应挂起自动隐藏。
///
/// 触控热区随轨道一起缩在中间:左缘上下不再拦截消息区的滚动手势。
class MessageNavRail extends StatefulWidget {
  const MessageNavRail({
    super.key,
    required this.visible,
    required this.anchors,
    required this.progress,
    required this.onJump,
    required this.onInteractionChanged,
  });

  /// 外部驱动的显隐。动画在内部做,外部只切 bool。
  final bool visible;

  /// 全部用户消息锚点(按 rowIndex 升序)。
  final List<NavAnchor> anchors;

  /// 滚动进度(0~1,pixels/maxScrollExtent),滚动时逐帧更新。
  /// 游标位置 = progress,连续滑动;联动高亮 = 最近的锚点刻度。
  final ValueListenable<double> progress;

  /// 跳转请求:参数是目标行下标。窗口扩展/粗跳/精修由调用方负责。
  final ValueChanged<int> onJump;

  /// 轨道被触摸(true)时外部挂起自动隐藏;松手(false)后恢复计时。
  final ValueChanged<bool> onInteractionChanged;

  @override
  State<MessageNavRail> createState() => _MessageNavRailState();
}

class _MessageNavRailState extends State<MessageNavRail>
    with TickerProviderStateMixin {
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

  /// 拖拽中手指的归一化位置(0~1):波形跟着手指走,
  /// 松手后回到滚动进度。比「离散步进」顺滑得多。
  double? _dragT;

  /// 预览卡中心 y(相对轨道顶)。
  double _previewY = 0;

  /// 拖拽中上次触发跳转的锚点序号:同一锚点内微调不重复滚动。
  int? _lastJumpIndex;

  // -- 焦点平滑层 ----------------------------------------------------------
  //
  // painter 不吃原始进度:所有 focus 变化(滚动/跳转/拖拽/窗口扩展)
  // 都经过一道指数平滑,跳变被拉成 ~150ms 的弹簧收尾。
  // 拖拽时系数放大 —— 跟手优先,平滑退居其次。
  late final Ticker _focusTicker = createTicker(_tickFocus);
  final _smoothFocus = ValueNotifier<double>(0);
  double _targetFocus = 0;
  static const _kFollowScroll = 0.28;
  static const _kFollowDrag = 0.48;

  void _setFocusTarget(double t) {
    _targetFocus = t.clamp(0.0, 1.0);
    if (!_focusTicker.isTicking) _focusTicker.start();
  }

  void _tickFocus(Duration _) {
    final k = _dragT != null ? _kFollowDrag : _kFollowScroll;
    final cur = _smoothFocus.value;
    final next = cur + (_targetFocus - cur) * k;
    if ((next - _targetFocus).abs() < 0.0005) {
      _smoothFocus.value = _targetFocus;
      _focusTicker.stop();
    } else {
      _smoothFocus.value = next;
    }
  }

  void _onExternalProgress() => _setFocusTarget(widget.progress.value);

  @override
  void initState() {
    super.initState();
    if (widget.visible) _ctrl.value = 1;
    _smoothFocus.value = widget.progress.value;
    _targetFocus = widget.progress.value;
    widget.progress.addListener(_onExternalProgress);
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
    if (old.progress != widget.progress) {
      old.progress.removeListener(_onExternalProgress);
      widget.progress.addListener(_onExternalProgress);
      _onExternalProgress();
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onExternalProgress);
    _focusTicker.dispose();
    _smoothFocus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// 手势 y → 刻度下标:轨道内均匀分布,与绘制同一套映射。
  ///
  /// 映射本身抽到 [anchorIndexAt] —— 它要能独立于行高被测试,
  /// 「拖到哪就该是第几条消息」是这条轨道唯一的正确性契约。
  int _indexAt(double y, double height) =>
      anchorIndexAt(_tAt(y, height), widget.anchors.length);

  void _startPreview(double y, double height) {
    widget.onInteractionChanged(true);
    _lastJumpIndex = null;
    setState(() {
      _activeIndex = _indexAt(y, height);
      _dragT = _tAt(y, height);
      _previewY = y.clamp(0.0, height);
    });
    _setFocusTarget(_dragT!);
  }

  void _updatePreview(double y, double height) {
    final newIndex = _indexAt(y, height);
    setState(() {
      _activeIndex = newIndex;
      _dragT = _tAt(y, height);
      _previewY = y.clamp(0.0, height);
    });
    _setFocusTarget(_dragT!);
    // 实时跟随:拖到新锚点时列表立刻滚过去,
    // 不再等松手才跳 —— 用户的手指就是滚动条。
    if (newIndex != _lastJumpIndex && newIndex < widget.anchors.length) {
      _lastJumpIndex = newIndex;
      widget.onJump(widget.anchors[newIndex].rowIndex);
    }
  }

  void _endPreview() {
    final index = _activeIndex;
    widget.onInteractionChanged(false);
    setState(() {
      _activeIndex = null;
      _dragT = null;
    });
    if (index != null && index < widget.anchors.length) {
      widget.onJump(widget.anchors[index].rowIndex);
    }
  }

  /// 手势 y → 归一化位置(0~1)。
  double _tAt(double y, double height) {
    const pad = _RailPainter.vPad;
    final usable = (height - pad * 2).clamp(1.0, double.infinity);
    return ((y - pad) / usable).clamp(0.0, 1.0);
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
                      // 波形跟进度/手指走:ValueListenableBuilder 只重画
                      // painter,滚动/拖拽时不触发任何外层 rebuild。
                      ValueListenableBuilder<double>(
                        valueListenable: _smoothFocus,
                        builder: (context, focus, _) => CustomPaint(
                          size: Size(28, railHeight),
                          painter: _RailPainter(
                            count: widget.anchors.length,
                            // 平滑层出口:滚动/拖拽/跳转统一走这里。
                            focus: focus,
                            tickColor: colors.onSurfaceVariant.withValues(
                              alpha: 0.5,
                            ),
                            minorColor: colors.onSurfaceVariant.withValues(
                              alpha: 0.2,
                            ),
                            focusColor: colors.primary,
                            trackColor: colors.onSurfaceVariant.withValues(
                              alpha: 0.16,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 32,
                        top: (_previewY - 44).clamp(0.0, railHeight - 88),
                        child: AnimatedScale(
                          scale: _activeIndex != null ? 1 : 0.92,
                          duration: PiMotion.quick,
                          curve: PiMotion.enter,
                          child: AnimatedOpacity(
                            opacity: _activeIndex != null ? 1 : 0,
                            duration: PiMotion.quick,
                            child: _activeIndex != null
                                ? _PreviewCard(
                                    anchor: widget.anchors[_activeIndex!],
                                  )
                                : const SizedBox(width: 240, height: 60),
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
    );
  }
}

/// 声波波形绘制:大节点(用户消息锚点) + 小节点(过渡装饰)
/// 双排从基线向右伸出的横条,随「焦点位置」连续起伏。
///
/// - 小节点均匀插在大节点之间,只负责让波形连续好看,不映射消息;
/// - **增益分离**:焦点处大节点 5→12px 冒尖、小节点只 3→7px,
///   峰值差距拉开,「当前在哪条消息」一眼能看出来;
/// - 包络 σ 收窄到一个大节点间隔内 —— 焦点在大节点上时,
///   两侧小节点只微微隆起,不会和峰值一样高;
/// - 焦点(滚动进度/手指位置)是连续值,条高变化天然丝滑。
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.count,
    required this.focus,
    required this.tickColor,
    required this.minorColor,
    required this.focusColor,
    required this.trackColor,
  });

  static const vPad = 6.0;

  final int count;

  /// 焦点位置 0~1(连续):滚动进度,拖拽时是手指位置。
  final double focus;

  /// 大节点(消息锚点)的常态色。
  final Color tickColor;

  /// 小节点(过渡装饰)的常态色,比大节点淡。
  final Color minorColor;
  final Color focusColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (count <= 0) return;
    final paint = Paint()..strokeCap = StrokeCap.round;
    final usable = size.height - vPad * 2;

    // 轨道基线:极淡,克制。
    canvas.drawLine(
      const Offset(2, vPad),
      Offset(2, size.height - vPad),
      Paint()
        ..color = trackColor
        ..strokeWidth = 1,
    );

    // 大节点太密时抽样(视觉),手势映射不受影响。
    final maxTicks = (usable / 3).floor().clamp(1, 200);
    final majorStep = (count / maxTicks).ceil();
    final majors = <int>[
      for (var i = 0; i < count; i += majorStep) i,
      if ((count - 1) % majorStep != 0) count - 1,
    ];

    // 每个大节点间隔插多少小节点:总条数逼近 3px 一根的容量,上限 3。
    final gaps = majors.length - 1;
    final fill = gaps > 0
        ? ((maxTicks - majors.length) / gaps).floor().clamp(0, 3)
        : 0;

    // σ = 1/6 个大节点间隔:焦点在大节点上时,最近的小节点
    // influence ≈ 0.35,下个大节点 ≈ 0 —— 峰值尖锐,两侧只微微隆起。
    final sigma = gaps > 0 ? (1.0 / gaps) / 6 : 0.05;

    double tOf(double index) => count == 1 ? 0.5 : index / (count - 1);

    void bar(double t, bool major) {
      final y = vPad + usable * t;
      final dist = t - focus;
      final influence = math.exp(-(dist * dist) / (2 * sigma * sigma));
      if (major) {
        paint
          ..strokeWidth = 2.2 + 0.9 * influence
          ..color = Color.lerp(tickColor, focusColor, influence)!;
        canvas.drawLine(Offset(3, y), Offset(3 + 5 + 7 * influence, y), paint);
      } else {
        paint
          ..strokeWidth = 1.8 + 0.4 * influence
          ..color = Color.lerp(
            minorColor,
            focusColor.withValues(alpha: 0.6),
            influence,
          )!;
        canvas.drawLine(Offset(3, y), Offset(3 + 3 + 4 * influence, y), paint);
      }
    }

    for (var m = 0; m < majors.length; m++) {
      bar(tOf(majors[m].toDouble()), true);
      if (m + 1 < majors.length) {
        final span = majors[m + 1] - majors[m];
        for (var k = 1; k <= fill; k++) {
          bar(tOf(majors[m] + span * k / (fill + 1)), false);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.count != count ||
      old.focus != focus ||
      old.tickColor != tickColor ||
      old.minorColor != minorColor ||
      old.focusColor != focusColor ||
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
        borderRadius: BorderRadius.circular(PiShape.md),
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
