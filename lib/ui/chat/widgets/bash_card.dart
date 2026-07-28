import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../common/tool_avatar.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'ansi_text.dart';
import 'message_actions_sheet.dart';
import 'message_card.dart';

/// 用户 bash 执行卡片:命令行 + exit 徽标 + ANSI 着色输出井。
class BashCard extends ConsumerWidget {
  const BashCard({super.key, required this.item});

  final BashItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final (headerBg, headerFg) = PiToolAvatar.colorsFor(
      PiToolCategory.terminal,
      piColors,
    );

    return MessageCard(
      headerColor: headerBg,
      titleColor: headerFg,
      avatar: const PiToolAvatar(
        icon: Icons.terminal,
        category: PiToolCategory.terminal,
        size: 32,
      ),
      // 冻结:测试查 Text('ls -la')
      title: Text(
        item.command.isEmpty ? 'bash' : item.command,
        style: AppType.monoLabel(color: headerFg),
      ),
      onLongPress: () => showMessageActions(context, ref, item),
      trailing: item.exitCode == null
          ? null
          : Badge(
              label: Text(
                'exit ${item.exitCode}',
                style: AppType.monoLabel(
                  color: item.isError
                      ? colors.onErrorContainer
                      : colors.onSurfaceVariant,
                ),
              ),
              backgroundColor: item.isError
                  ? colors.errorContainer
                  : colors.surfaceContainerHighest,
              textColor: item.isError
                  ? colors.onErrorContainer
                  : colors.onSurfaceVariant,
              largeSize: 22,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: item.output.isEmpty
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: piColors.codeWellBg,
                borderRadius: BorderRadius.circular(PiShape.md),
                border: Border.all(color: piColors.codeWellBorder),
              ),
              child: SingleChildScrollView(
                child: AnsiText(
                  text: item.output,
                  style: AppType.monoSmall(color: piColors.codeWellFg),
                ),
              ),
            ),
    );
  }
}
