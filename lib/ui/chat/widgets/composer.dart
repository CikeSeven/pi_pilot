import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/motion.dart';

/// 输入条:**胶囊纸卡 + 圆形陶土橙发送键**。
///
/// Editorial Retro 改版。参考图的输入区是一颗完整的胶囊,右端一个实心圆形
/// 发送键——「更像纸上的输入区域」而不是聊天软件的方框。
///
/// 与旧版差异:
/// - 输入卡从 28 圆角方卡改成 **stadium 胶囊**;
/// - 发送键从 `IconButton.filled`(方角)改成 **正圆**,陶土橙实心;
/// - 投递方式 chip 行保留,但改编辑式描边标签。
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.streaming,
    this.compacting = false,
    required this.onSend,
    this.onSteer,
    this.onFollowUp,
    this.onInterruptAndSend,
    this.onAbort,
    this.onChanged,
    this.quickPanel,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool streaming;

  /// 桌面端正在压缩上下文:它也是「忙」,但不是流式 ——
  /// 没有打字指示器、没有中断按钮,输入框必须自己说清楚消息会排队。
  final bool compacting;
  final VoidCallback onSend;

  /// 生成中的三种投递方式(输入框有内容时才展示)。
  /// 注意 steer 叫「插队」而不是「打断」—— 它不会中断当前这一轮。
  final VoidCallback? onSteer;
  final VoidCallback? onFollowUp;
  final VoidCallback? onInterruptAndSend;

  /// 流式且输入框为空时,发送键变为停止键。
  final VoidCallback? onAbort;
  final ValueChanged<String>? onChanged;

  /// 斜杠命令/快捷指令面板插槽(渲染在输入行上方)。
  final Widget? quickPanel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 输入框有内容时仍是发送(会进入 follow-up/steer 队列),空了才是停止
    final showStop =
        streaming && onAbort != null && controller.text.trim().isEmpty;
    final sendEnabled = enabled || showStop;
    // 压缩期间桌面 ctx.isIdle() 也是 false,消息同样要选投递方式。
    // 但停止键只跟流式绑定 —— 中断压缩不是这个按钮该干的事。
    final busy = streaming || compacting;
    // 输入条本身是透明的,「悬浮卡片」是下面那个 Material。
    // 不投影 —— 靠底色(surfaceContainerHigh)和四周留白与消息流分开。
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: PiMotion.quick,
              curve: PiMotion.enter,
              alignment: Alignment.bottomCenter,
              child: quickPanel ?? const SizedBox(width: double.infinity),
            ),
            // 生成中且已经写了内容:让用户明确选投递方式,而不是猜发送键的语义
            AnimatedSize(
              duration: PiMotion.quick,
              curve: PiMotion.enter,
              alignment: Alignment.bottomCenter,
              child: busy && controller.text.trim().isNotEmpty
                  ? SizedBox(
                      width: double.infinity,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                        child: Row(
                          children: [
                            ActionChip(
                              avatar: const Icon(Icons.bolt_outlined, size: 18),
                              label: const Text('插队'),
                              tooltip: compacting ? '压缩结束后立刻处理' : '本轮结束后立刻处理',
                              onPressed: onSteer,
                            ),
                            const SizedBox(width: 8),
                            ActionChip(
                              avatar: const Icon(
                                Icons.playlist_add_outlined,
                                size: 18,
                              ),
                              label: const Text('排队'),
                              tooltip: '全部处理完之后再处理',
                              onPressed: onFollowUp,
                            ),
                            // 压缩中不给「中断并发送」:那个按钮打断的是生成,
                            // 拿它去中断压缩只会让上下文停在半路。
                            if (streaming) ...[
                              const SizedBox(width: 8),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.stop_circle_outlined,
                                  size: 18,
                                ),
                                label: const Text('中断并发送'),
                                tooltip: '停止当前这一轮,然后发送',
                                onPressed: onInterruptAndSend,
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            // 悬浮的大圆角输入卡:四周留白让它和消息流明确分开
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Material(
                color: colors.surfaceContainerLow,
                // 胶囊 + 1px 描边:纸上的书写区,不是方框控件。
                shape: StadiumBorder(
                  side: BorderSide(color: colors.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 6, 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          onChanged: onChanged,
                          decoration: InputDecoration(
                            hintText: compacting
                                ? '压缩上下文中 · 发送会排队'
                                : streaming
                                ? '生成中 · 发送会插队'
                                : '指挥 pi 做点什么…',
                            // 视觉容器由外面那张卡承担,输入框自己不画边框和底色。
                            // 设置页的输入框不受影响,仍走 inputDecorationTheme。
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 14,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 正圆实心发送键。参考图里它是输入胶囊右端的一颗圆点,
                      // 陶土橙实心 —— 全屏最明确的「动作」信号。
                      IconButton.filled(
                        iconSize: 22,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(46, 46),
                          maximumSize: const Size(46, 46),
                          padding: EdgeInsets.zero,
                          shape: const CircleBorder(),
                          backgroundColor: showStop
                              ? colors.error
                              : colors.primary,
                          foregroundColor: showStop
                              ? colors.onError
                              : colors.onPrimary,
                        ),
                        onPressed: !sendEnabled
                            ? null
                            : () {
                                if (showStop) {
                                  HapticFeedback.mediumImpact();
                                  onAbort!();
                                } else {
                                  HapticFeedback.lightImpact();
                                  onSend();
                                }
                              },
                        icon: AnimatedSwitcher(
                          duration: PiMotion.quick,
                          child: Icon(
                            showStop
                                ? Icons.stop_rounded
                                : Icons.arrow_upward_rounded,
                            key: ValueKey(showStop),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
