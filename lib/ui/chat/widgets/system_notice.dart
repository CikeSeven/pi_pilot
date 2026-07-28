import 'package:flutter/material.dart';

import '../../../state/pi_session.dart';
import '../../theme/semantic_colors.dart';
import 'message_card.dart';

/// 居中的系统提示。M3 色调容器,不用 alpha 混色。
class SystemNotice extends StatelessWidget {
  const SystemNotice({super.key, required this.item});

  final SystemItem item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final (icon, background, foreground) = switch (item.kind) {
      SystemKind.info => (
        Icons.info_outline,
        colors.surfaceContainerHigh,
        colors.onSurfaceVariant,
      ),
      SystemKind.warning => (
        Icons.warning_amber_rounded,
        piColors.warningContainer,
        piColors.onWarningContainer,
      ),
      SystemKind.error => (
        Icons.error_outline,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
    };
    return MessageNotice(
      color: background,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              item.text,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
