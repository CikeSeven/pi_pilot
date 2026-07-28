import 'package:flutter/material.dart';

import '../../theme/motion.dart';

/// 距底部较远时出现的「回到底部」按钮;期间有新消息则带 Badge 角标。
class ScrollToBottomButton extends StatefulWidget {
  const ScrollToBottomButton({
    super.key,
    required this.controller,
    required this.revision,
  });

  final ScrollController controller;

  /// 消息列表修订号;隐藏在上方期间该值变化 → 显示新消息角标。
  final int revision;

  @override
  State<ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<ScrollToBottomButton> {
  static const _threshold = 400.0;

  bool _visible = false;
  bool _hasNew = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ScrollToBottomButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
    if (oldWidget.revision != widget.revision && _visible) {
      setState(() => _hasNew = true);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    final visible = position.maxScrollExtent - position.pixels > _threshold;
    if (visible != _visible) {
      setState(() {
        _visible = visible;
        if (!visible) _hasNew = false;
      });
    }
  }

  void _jump() {
    if (!widget.controller.hasClients) return;
    widget.controller.animateTo(
      widget.controller.position.maxScrollExtent,
      duration: PiMotion.standard,
      curve: PiMotion.enter,
    );
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
