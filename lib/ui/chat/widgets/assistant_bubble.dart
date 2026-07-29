import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../theme/motion.dart';
import '../../theme/paper.dart';
import '../../theme/squircle.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'markdown_body.dart';
import 'message_actions_sheet.dart';
import 'streaming_cursor.dart';
import 'thinking_block.dart';
import 'typing_indicator.dart';

/// 助手消息:**编辑式署名行 + 描边奶油纸卡**。
///
/// Editorial Retro 改版。旧版是「完全裸排」——正文直接铺在页面上,靠留白
/// 与用户消息分段。那在纯色底上成立,但新的纸底 + 陶土橙用户卡之下,
/// 裸排的 AI 正文显得没有承载、和工具卡也失去了并列关系。
///
/// 现在的结构(对齐参考图):
/// ```
/// ✦ PI · 回应            ← 编辑式署名行(衬线小标 + 细线延伸)
/// ┌──────────────────┐
/// │ 正文 / Markdown   │   ← 描边奶油卡,零阴影
/// └──────────────────┘
/// ```
/// 卡片承载正文而不是裸排,理由:一屏里 AI 回应、工具卡、用户纸条
/// 三者需要同一套「纸片放在桌面上」的语言,裸排会让 AI 回应掉出这套系统。
class AssistantBubble extends ConsumerWidget {
  const AssistantBubble({super.key, required this.item});

  final AssistantItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final streaming = !item.complete;

    // 空回复不渲染:AI 直接调用工具时会产生一个 text 和 thinking 都空的
    // AssistantItem,署名行 + 空白卡片是个「空壳」,没有信息价值。
    // streaming 时除外——那是初始态,要显示打字指示器。
    if (!streaming && item.text.isEmpty && item.thinking.isEmpty) {
      return const SizedBox.shrink();
    }

    final bodyStyle = theme.textTheme.bodyLarge?.copyWith(
      color: colors.onSurface,
    );

    final Widget body;
    if (item.text.isEmpty && streaming) {
      body = const TypingIndicator();
    } else if (streaming) {
      // 流式期:纯文本(零解析开销) + 末尾闪烁竖线光标。
      //
      // 光标作为独立 WidgetSpan 而不是拼接 '▍' 字符:字符拼接会跟着文本
      // 末尾位置一起跳、也不会闪。StrutStyle 锁行高,光标不撑高当前行。
      body = SelectableText.rich(
        TextSpan(
          text: item.text,
          style: bodyStyle,
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: StreamingCursor(color: colors.primary),
            ),
          ],
        ),
        // 行高锁定在正文字阶上 —— 光标不撑高当前行。
        // 字号/行高都从 bodyLarge 取,不手写数字。
        strutStyle: StrutStyle.fromTextStyle(
          bodyStyle ?? const TextStyle(),
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
            // 署名行只在有正文时显示:纯思考(无正文卡)不需要署名。
            if (item.text.isNotEmpty || streaming) ...[
              _Byline(streaming: streaming),
              const SizedBox(height: 8),
            ],
            // 思考块在卡外:它是「过程」,正文卡是「结论」,不该混在一张纸上。
            if (item.thinking.isNotEmpty) ...[
              ThinkingBlock(thinking: item.thinking, streaming: streaming),
              const SizedBox(height: 8),
            ],
            // 正文纸卡:只在有内容或正在生成时渲染。
            // text 为空且非 streaming = AI 纯思考/纯工具调用,不画空壳。
            if (item.text.isNotEmpty || streaming)
              Material(
                color: colors.surfaceContainerLow,
                shape: SquircleBorder(
                  borderRadius: BorderRadius.circular(PiShape.md),
                  side: BorderSide(color: colors.outlineVariant),
                  smoothing: PiShape.smoothing,
                ),
                elevation: 1,
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  child: AnimatedSwitcher(
                    duration: PiMotion.quick,
                    switchInCurve: PiMotion.enter,
                    child: KeyedSubtree(key: ValueKey(streaming), child: body),
                  ),
                ),
              ),
            if (item.isErrored) const _AssistantErrorBadge(),
          ],
        ),
      ),
    );
  }
}

/// AI 回应的编辑式署名行:`✦ PI ———————`。
///
/// 参考图里每段 AI 回答上方都有这样一行小标 + 细线,是「杂志栏目」语言。
/// 生成中时星芒换成脉冲点,让状态在署名行就能读到。
class _Byline extends StatefulWidget {
  const _Byline({required this.streaming});

  final bool streaming;

  @override
  State<_Byline> createState() => _BylineState();
}

class _BylineState extends State<_Byline> with SingleTickerProviderStateMixin {
  // 生成中时图标缓慢呼吸,「正在想」的律动。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.streaming) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Byline old) {
    super.didUpdateWidget(old);
    // 生成结束:停住呼吸(停在自然位);重新生成:再启动。
    if (widget.streaming && !old.streaming) {
      _pulse.repeat(reverse: true);
    } else if (!widget.streaming && old.streaming) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fg = colors.primary;
    return Row(
      children: [
        // 图标:生成中时是 blur_on 并缓慢呼吸;完成时是 auto_awesome。
        // 不用 AnimatedSwitcher —— 它与无限循环的 AnimatedBuilder 嵌套会让
        // element 树混乱。这里用单一 AnimatedBuilder,在 builder 内部按状态
        // 换 iconData 和缩放,结构最简、不会报错。
        AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            // 生成中:缩放随呼吸走(0.75↔1.1);完成:固定 1.0。
            final s = widget.streaming ? 0.75 + 0.35 * _pulse.value : 1.0;
            return Transform.scale(
              scale: s,
              child: Icon(
                widget.streaming ? Icons.blur_on : Icons.auto_awesome,
                size: 13,
                color: fg,
              ),
            );
          },
        ),
        const SizedBox(width: 7),
        Text(
          widget.streaming ? 'PI · 正在回应' : 'PI · 回应',
          style: AppType.eyebrow(color: fg),
        ),
        const SizedBox(width: 12),
        Expanded(child: EditorialRule(color: colors.outlineVariant)),
      ],
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
