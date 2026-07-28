import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../theme/motion.dart';
import 'markdown_body.dart';
import 'message_actions_sheet.dart';
import 'thinking_block.dart';
import 'typing_indicator.dart';

/// 助手消息气泡。流式期间走纯文本(零解析开销),完成后切换为 Markdown。
class AssistantBubble extends ConsumerWidget {
  const AssistantBubble({super.key, required this.item});

  final AssistantItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final streaming = !item.complete;

    final Widget body;
    if (item.text.isEmpty && streaming) {
      body = const TypingIndicator();
    } else if (streaming) {
      body = SelectableText(
        '${item.text} ▍',
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(color: colors.onSurface),
      );
    } else {
      body = PiMarkdown(text: item.text);
    }

    // **不包容器**。AI 的回答是这一屏的主体内容,给它套卡片只会把
    // 长回答挤进一个框里,还要和工具卡抢视觉层级。直接铺在页面上,
    // 靠留白与用户消息分段。
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      child: GestureDetector(
        onLongPress: item.text.isEmpty
            ? null
            : () => showMessageActions(context, ref, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.thinking.isNotEmpty)
              ThinkingBlock(thinking: item.thinking, streaming: streaming),
            AnimatedSwitcher(
              duration: PiMotion.quick,
              switchInCurve: PiMotion.enter,
              child: KeyedSubtree(key: ValueKey(streaming), child: body),
            ),
            if (item.isErrored) const _AssistantErrorBadge(),
          ],
        ),
      ),
    );
  }
}

/// 助手响应因 error/aborted 终止时的尾部徽标。不干扰正文,只标记终止状态。
class _AssistantErrorBadge extends StatelessWidget {
  const _AssistantErrorBadge();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 14, color: colors.error),
          const SizedBox(width: 6),
          Text(
            '响应已中断',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.error,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
