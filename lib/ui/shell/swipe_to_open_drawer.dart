import 'package:flutter/material.dart';

/// 在聊天页任意位置右滑打开抽屉。
///
/// **必须挂在 body 的祖先位置,不能改用 `Scaffold.drawerEdgeDragWidth`。**
/// Scaffold 的边缘拖拽检测器是叠在 body 之上的兄弟节点,命中测试先到它,
/// 一旦把宽度放大就会抢掉聊天页里那些横向可滚动区域(代码块、diff、
/// 投递芯片、快捷面板)的横向滚动。
///
/// 挂在祖先位置则正好相反:手势竞技场在 sweep 时取最先入场的成员,而入场顺序
/// 就是命中测试顺序 —— 最深的那个先入场。所以内层横向 `ListView` 会赢,
/// 只有在它们身上滑不动时这个手势才生效。
class SwipeToOpenDrawer extends StatefulWidget {
  const SwipeToOpenDrawer({
    super.key,
    required this.onOpen,
    required this.child,
    this.enabled = true,
    this.threshold = 48,
    this.edgeWidth = 60,
  });

  final VoidCallback onOpen;
  final Widget child;

  /// 抽屉已经开着时关掉,免得在关闭动画那几帧里又触发一次。
  final bool enabled;

  /// 累计右移多少就认定是「要开抽屉」。
  final double threshold;

  /// 只在屏幕左边缘这么宽内生效。
  ///
  /// 旧版全屏检测往右滑,和页面左右切换冲突 —— 用户想切页时总是先开抽屉。
  /// 限制在左边缘后:左边缘往右滑开抽屉,中间往右滑切页。
  final double edgeWidth;

  @override
  State<SwipeToOpenDrawer> createState() => _SwipeToOpenDrawerState();
}

class _SwipeToOpenDrawerState extends State<SwipeToOpenDrawer> {
  double _dx = 0;

  /// 一次拖拽只开一次 —— 手指还没抬起时 update 会持续来。
  bool _fired = false;

  /// 起点是否在左边缘。不在边缘的拖拽不累计,避免和页面切换冲突。
  bool _inEdge = false;

  void _start(DragStartDetails details) {
    _dx = 0;
    _fired = false;
    _inEdge = details.globalPosition.dx < widget.edgeWidth;
  }

  void _update(DragUpdateDetails details) {
    if (_fired || !widget.enabled || !_inEdge) return;
    _dx += details.delta.dx;
    if (_dx < widget.threshold) return;
    _fired = true;
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 不遮挡子节点自己的命中测试:空白处也要能滑,所以不用 deferToChild。
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      child: widget.child,
    );
  }
}
