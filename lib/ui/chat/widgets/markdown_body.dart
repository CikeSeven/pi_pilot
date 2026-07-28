import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'code_block.dart';

/// 助手消息的 Markdown 渲染(围栏代码块交给 CodeBlock)。
class PiMarkdown extends StatelessWidget {
  const PiMarkdown({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final piColors = PiColors.of(context);
    return SelectionArea(
      child: GptMarkdown(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
        codeBuilder: (context, name, code, closed) =>
            // 围栏信息串可能带属性(```json title="…"),只取第一个 token
            CodeBlock(
              code: code,
              language: name.isEmpty ? null : name.split(RegExp(r'\s+')).first,
            ),
        highlightBuilder: (context, text, style) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: piColors.codeWellBg,
            borderRadius: BorderRadius.circular(PiShape.xs),
            border: Border.all(color: piColors.codeWellBorder),
          ),
          child: Text(
            text,
            style: AppType.mono(
              size: (style.fontSize ?? 14) - 1,
              color: theme.colorScheme.onSurface,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
