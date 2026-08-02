import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../theme/motion.dart';

/// 距底部较远时出现的「回到底部」按钮;期间有新消息则带 Badge 角标。
///
/// 显隐判据是**终点哨兵(列表最后一个槽,1px)有没有在可见集里**。
///
/// 两种更直觉的判据都试过且都错:
/// - 「距底部还有多少像素」要读 `maxScrollExtent`,而那在惰性列表里只是按已建行
///   平均高度外推的估算值 —— 聊天行高差几十倍时它一直在抖,按钮会自己闪;
/// - 「最大可见下标离最后一个槽还差几格」对高个流式行不成立:一条比视口高
///   好几屏的长回答,人在它内部往上翻很远,它仍是最大可见下标。
///
/// 哨兵只有 1px,它进可见集就是「内容末端真的在视野里」,不掺任何高度信息。
class ScrollToBottomButton extends StatefulWidget {
  const ScrollToBottomButton({
    super.key,
    required this.positions,
    required this.terminalSlot,
    required this.onJump,
    required this.revision,
  });

  /// 列表的可见项监听器。
  final ItemPositionsListener positions;

  /// 终点哨兵的槽位下标(列表最后一个槽)。
  final int terminalSlot;

  /// 点击后回到底部(定位逻辑归调用方,它才知道槽位怎么换算)。
  final VoidCallback onJump;

  /// 消息列表修订号;隐藏在上方期间该值变化 → 显示新消息角标。
  final int revision;

  @override
  State<ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<ScrollToBottomButton> {
  bool _visible = false;
  bool _hasNew = false;

  @override
  void initState() {
    super.initState();
    widget.positions.itemPositions.addListener(_onPositions);
  }

  @override
  void didUpdateWidget(ScrollToBottomButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positions != widget.positions) {
      oldWidget.positions.itemPositions.removeListener(_onPositions);
      widget.positions.itemPositions.addListener(_onPositions);
    }
    // terminalSlot 变了要立刻重算:追加新消息时列表末尾往后移了一格,
    // 可见性判据的参照点跟着变。不重算的话显隐会一直停在旧判断上,
    // 得等用户下一次滚动才纠正 —— 表现就是「刚发完消息按钮该出现却没出现」。
    if (oldWidget.terminalSlot != widget.terminalSlot) _onPositions();
    if (oldWidget.revision != widget.revision && _visible) {
      setState(() => _hasNew = true);
    }
  }

  @override
  void dispose() {
    widget.positions.itemPositions.removeListener(_onPositions);
    super.dispose();
  }

  void _onPositions() {
    final positions = widget.positions.itemPositions.value;
    if (positions.isEmpty) return;
    // 哨兵进了可见集就是贴着底 → 按钮该收起来。
    final atBottom = positions.any(
      (p) => p.index == widget.terminalSlot && p.itemTrailingEdge <= 1.001,
    );
    final visible = !atBottom;
    if (visible == _visible) return;
    setState(() {
      _visible = visible;
      if (!visible) _hasNew = false;
    });
  }

  void _jump() {
    widget.onJump();
    setState(() => _hasNew = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: _visible ? 1 : 0,
      duration: PiMotion.quick,
      curve: PiMotion.enter,
      child: Badge(
        isLabelVisible: _hasNew,
        backgroundColor: colors.error,
        child: FloatingActionButton.small(
          // 与输入条的发送 FAB 同屏,必须去掉 hero tag
          heroTag: null,
          onPressed: _jump,
          backgroundColor: colors.surfaceContainerHigh,
          foregroundColor: colors.onSurface,
          child: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
        ),
      ),
    );
  }
}
