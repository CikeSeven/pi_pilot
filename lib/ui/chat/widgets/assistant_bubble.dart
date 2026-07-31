import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../../state/settings_provider.dart';
import '../../theme/motion.dart';
import 'markdown_body.dart';
import 'message_actions_sheet.dart';
import 'streaming_cursor.dart';
import 'thinking_block.dart';
import 'typing_indicator.dart';

/// 助手消息:**无框裸排正文**(Claude/ChatGPT 风格)。
///
/// 正文不套卡片、没有署名行——文字直接排在屏幕背景上。卡片框和
/// 「PI · 回应」标头会让每段回复都像「便签纸」,读长文时视线被反复
/// 打断;裸排才是「在和人对话」。代码块/引用等内部元素仍保留自己的
/// 井底,那是内容层级的一部分。思考块收在胶囊里,点开才展开。
///
/// 结构:
/// ```
/// (思考胶囊)
/// 正文 / Markdown         ← 无框裸排,直接铺在背景上
/// ```
class AssistantBubble extends ConsumerWidget {
  const AssistantBubble({super.key, required this.item});

  final AssistantItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final settings = ref.watch(settingsProvider);
    final streaming = !item.complete;

    // 空回复不渲染:AI 直接调用工具时会产生一个 text 和 thinking 都空的
    // AssistantItem,署名行 + 空白卡片是个「空壳」,没有信息价值。
    // streaming 时除外——那是初始态,要显示打字指示器。
    if (!streaming && item.text.isEmpty && item.thinking.isEmpty) {
      return const SizedBox.shrink();
    }

    final bodyStyle = chatBodyStyle(context, settings, color: colors.onSurface);

    final Widget body;
    if (item.text.isEmpty && streaming) {
      body = const TypingIndicator();
    } else if (streaming) {
      // 流式期:纯文本(零解析开销) + 末尾闪烁竖线光标。
      //
      // 光标对齐用 middle(行框内垂直居中)而不是 baseline:
      // baseline 对齐是「光标底部贴正文 baseline」,18px 高的光标从
      // baseline 向上冒,比大写字母还高出一截,多行时像顶进上一行。
      // middle 对齐让光标在行框内居中,前后再加一个 hair space,
      // 既不贴最后一个字,也不撑高当前行(strut 已锁行高)。
      // 光标高度跟正文行高走(~72%),字号/行距设置变了它也变。
      final linePx =
          (bodyStyle.fontSize ?? 16) * (bodyStyle.height ?? 1.45);
      body = SelectableText.rich(
        TextSpan(
          text: item.text,
          style: bodyStyle,
          children: [
            const TextSpan(text: '\u200A'),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: StreamingCursor(
                color: colors.primary,
                height: linePx * 0.72,
              ),
            ),
          ],
        ),
        // 行高锁定在正文字阶上 —— 光标不撑高当前行。
        strutStyle: StrutStyle.fromTextStyle(
          bodyStyle,
          forceStrutHeight: true,
        ),
      );
    } else {
      body = PiMarkdown(text: item.text);
    }

    return Padding(
      // top/bottom 各 4:和工具卡/用户消息的间距 = 4+4 = 8,
      // 同一轮内部间距统一。轮切换由 user_bubble 的 top 20 承担。
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: GestureDetector(
        onLongPress: item.text.isEmpty
            ? null
            : () => showMessageActions(context, ref, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 思考块:生成中是深卡+波形,完成后收成「思考了 Xs」单行。
            if (item.thinking.isNotEmpty) ...[
              ThinkingBlock(
                thinking: item.thinking,
                streaming: streaming,
                duration: item.thinkingDuration,
              ),
              // 胶囊与正文的间距:2+2+2 = 6px,紧凑不空廈。
              const SizedBox(height: 2),
            ],
            // 正文:无框纯文字(Claude/ChatGPT 风格)——文字直接排在
            // 屏幕背景上,不套卡片。卡片框会让每段回复都像「便签纸」，
            // 读长文时视线被边框反复打断;裸排才有「在和人对话」的感觉。
            // 代码块/引用等内部元素仍保留自己的井底,那是内容的一部分。
            if (item.text.isNotEmpty || streaming)
              Padding(
                // 左右 6px 呼吸:正文比署名行稍稍内缩,形成版式层次。
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                child: AnimatedSwitcher(
                  duration: PiMotion.quick,
                  switchInCurve: PiMotion.enter,
                  child: KeyedSubtree(key: ValueKey(streaming), child: body),
                ),
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
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 14, color: colors.error),
          const SizedBox(width: 6),
          Text(
            '响应已中断',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
