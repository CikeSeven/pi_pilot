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
  });

  final VoidCallback onOpen;
  final Widget child;

  /// 抽屉已经开着时关掉,免得在关闭动画那几帧里又触发一次。
  final bool enabled;

  /// 累计右移多少就认定是「要开抽屉」。
  final double threshold;

  @override
  State<SwipeToOpenDrawer> createState() => _SwipeToOpenDrawerState();
}

class _SwipeToOpenDrawerState extends State<SwipeToOpenDrawer> {
  double _dx = 0;

  /// 一次拖拽只开一次 —— 手指还没抬起时 update 会持续来。
  bool _fired = false;

  void _start(DragStartDetails _) {
    _dx = 0;
    _fired = false;
  }

  void _update(DragUpdateDetails details) {
    if (_fired || !widget.enabled) return;
    _dx += details.delta.dx;
    // 只认单向右滑:来回蹭的话累计值到不了阈值,不会误开。
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
