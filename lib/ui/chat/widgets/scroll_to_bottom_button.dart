import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../theme/motion.dart';

/// 距底部较远时出现的「回到底部」按钮;期间有新消息则带 Badge 角标。
///
/// 显隐判据是**最后一个槽位有没有在可见集里**,不是「距底部还有多少像素」。
/// 像素判据要读 `maxScrollExtent`,而那在惰性列表里只是按已建行平均高度外推的
/// 估算值 —— 聊天行高差几十倍时它一直在抖,按钮会无规律地自己闪出来。
class ScrollToBottomButton extends StatefulWidget {
  const ScrollToBottomButton({
    super.key,
    required this.positions,
    required this.lastSlot,
    required this.onJump,
    required this.revision,
  });

  /// 列表的可见项监听器。
  final ItemPositionsListener positions;

  /// 最后一个槽位的下标。
  final int lastSlot;

  /// 点击后回到底部(定位逻辑归调用方,它才知道槽位怎么换算)。
  final VoidCallback onJump;

  /// 消息列表修订号;隐藏在上方期间该值变化 → 显示新消息角标。
  final int revision;

  @override
  State<ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<ScrollToBottomButton> {
  /// 离底部还有这么多槽位就算「不在底部」。
  ///
  /// 留 2 个槽的余量:流式期间末尾那一两行高度一直在长,贴着最后一行看时
  /// 可见集边界会来回抖,阈值太紧按钮会闪。
  static const _slack = 2;

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
    // lastSlot 变了要立刻重算:追加新消息时列表末尾往后移了一格,
    // 可见性判据的参照点跟着变。不重算的话显隐会一直停在旧判断上,
    // 得等用户下一次滚动才纠正 —— 表现就是「刚发完消息按钮该出现却没出现」。
    if (oldWidget.lastSlot != widget.lastSlot) _onPositions();
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
    var maxIndex = positions.first.index;
    for (final p in positions) {
      if (p.index > maxIndex) maxIndex = p.index;
    }
    final visible = maxIndex < widget.lastSlot - _slack;
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
