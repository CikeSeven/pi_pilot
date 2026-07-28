import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// 底部弹窗内部的页面栈。
///
/// 之前「点模型」是 `Navigator.pop(context)` 紧接着 `showModelSwitchSheet(context)`
/// —— 用一个正在被卸载的 context 开新弹窗,选完还把整摞都关掉,回不到上一层。
/// 这里让弹窗自己持有页面栈:进二级页是 push,选完是 pop,弹窗本身不动。
///
/// 全代码库原先没有任何 sheet 内导航模式(无嵌套 `Navigator`、无 `IndexedStack`、
/// 无 `PageView`),所以是新建而不是复用。
class SheetNavigator extends StatefulWidget {
  const SheetNavigator({super.key, required this.root});

  final WidgetBuilder root;

  static SheetNavigatorState of(BuildContext context) {
    final state = context.findAncestorStateOfType<SheetNavigatorState>();
    assert(state != null, '这个 widget 不在 SheetNavigator 里');
    return state!;
  }

  /// 不在 `SheetNavigator` 里时返回 null —— 供 `SheetHeader` 判断该画返回还是关闭。
  static SheetNavigatorState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<SheetNavigatorState>();

  @override
  State<SheetNavigator> createState() => SheetNavigatorState();
}

class SheetNavigatorState extends State<SheetNavigator> {
  final List<WidgetBuilder> _stack = [];

  bool get canPop => _stack.isNotEmpty;

  void push(WidgetBuilder page) => setState(() => _stack.add(page));

  void pop() {
    if (_stack.isEmpty) return;
    setState(() => _stack.removeLast());
  }

  @override
  Widget build(BuildContext context) {
    final builder = _stack.isEmpty ? widget.root : _stack.last;
    return AnimatedSize(
      duration: PiMotion.quick,
      curve: PiMotion.enter,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: PiMotion.quick,
        switchInCurve: PiMotion.enter,
        // 二级页从右侧滑入,退回时反向 —— 和整页路由的方向感一致
        transitionBuilder: (child, animation) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.12, 0),
            end: Offset.zero,
          ).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        child: KeyedSubtree(
          key: ValueKey(_stack.length),
          child: Builder(builder: builder),
        ),
      ),
    );
  }
}
