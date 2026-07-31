import 'package:flutter/widgets.dart';

/// 嵌套纵向滚动的「到头让路」。
///
/// 工具输出井、代码块、diff 内部各有自己的纵向滚动区。内层滚动件会抢先
/// 赢下手势竞技场,于是手指按在内层上拖,外层消息列表永远接不到这次拖动
/// —— 哪怕内层已经滚到了头,剩下的增量也被内层的边界吞掉(只余一抹微光)。
///
/// 包上这一层:内层滚到边后继续拖,未被消费的增量(OverscrollNotification)
/// 直接转交给最近的外层 Scrollable(聊天列表),滑动自然衔接。
class OverscrollForwarder extends StatelessWidget {
  const OverscrollForwarder({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 注意:这个 context 在内层 Scrollable **之上**,所以
    // Scrollable.maybeOf 找到的是外层列表,而不是内层自己。
    final outer = Scrollable.maybeOf(context);
    if (outer == null) return child;
    return NotificationListener<OverscrollNotification>(
      onNotification: (notification) {
        // 只接管纵向:代码块还有横向滚动,横向到边的增量不能拿去
        // 竖着晃消息列表。
        if (notification.metrics.axis != Axis.vertical) return false;
        final position = outer.position;
        final target = (position.pixels + notification.overscroll).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (target != position.pixels) {
          position.jumpTo(target.toDouble());
        }
        return true;
      },
      child: child,
    );
  }
}
