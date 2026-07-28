import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../../state/settings_provider.dart';
import '../../common/tool_avatar.dart';
import '../../theme/typography.dart';

/// 输入条上方的快捷面板:
/// - 输入以 `/` 开头 → 过滤后的斜杠命令列表(点按补全)
/// - 输入为空 → 自定义快捷指令 chips
class QuickPanel extends ConsumerStatefulWidget {
  const QuickPanel({
    super.key,
    required this.inputText,
    required this.onInsert,
    required this.onSendPrompt,
  });

  final String inputText;

  /// 把命令文本填入输入框(不发送)。
  final void Function(String text) onInsert;

  /// 直接发送一条快捷指令。
  final void Function(String text) onSendPrompt;

  @override
  ConsumerState<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends ConsumerState<QuickPanel> {
  List<SlashCommand> _commands = const [];
  bool _loaded = false;

  @override
  void didUpdateWidget(QuickPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.inputText.startsWith('/') && !_loaded) {
      _loaded = true;
      ref.read(piSessionProvider.notifier).getCommands().then((commands) {
        if (mounted) setState(() => _commands = commands);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = widget.inputText;

    if (text.startsWith('/')) {
      final query = text.substring(1).toLowerCase();
      final matches = _commands
          .where((command) => command.name.toLowerCase().contains(query))
          .take(6)
          .toList();
      if (matches.isEmpty) return const SizedBox(width: double.infinity);
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            for (final command in matches)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: PiToolAvatar(
                  icon: switch (command.source) {
                    'skill' => Icons.bolt_outlined,
                    'prompt' => Icons.notes_outlined,
                    _ => Icons.extension_outlined,
                  },
                  category: switch (command.source) {
                    'skill' => PiToolCategory.search,
                    'prompt' => PiToolCategory.read,
                    _ => PiToolCategory.extension,
                  },
                  size: 28,
                ),
                title: Text(
                  '/${command.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoLabel(color: colors.onSurface),
                ),
                subtitle: command.description == null
                    ? null
                    : Text(
                        command.description!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                onTap: () => widget.onInsert('/${command.name} '),
              ),
          ],
        ),
      );
    }

    final quickPrompts = ref.watch(
      settingsProvider.select((s) => s.quickPrompts),
    );
    if (text.isNotEmpty || quickPrompts.isEmpty) {
      return const SizedBox(width: double.infinity);
    }
    // 不定死高度:横向 SCSV 的高度由 chip 固有高度决定,系统字体放大后
    // chip 变高也不会被 44dp 硬约束压出纵向溢出。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          for (final prompt in quickPrompts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: Icon(
                  Icons.bolt,
                  size: 14,
                  color: Theme.of(context).colorScheme.primary,
                ),
                label: Text(
                  prompt.length > 18 ? '${prompt.substring(0, 18)}…' : prompt,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  widget.onSendPrompt(prompt);
                },
              ),
            ),
        ],
      ),
    );
  }
}
