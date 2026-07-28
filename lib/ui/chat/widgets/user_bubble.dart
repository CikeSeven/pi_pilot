import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../theme/shapes.dart';
import 'message_actions_sheet.dart';

/// 用户消息。
///
/// 全屏只有它和工具卡带底色 —— AI 的回答是裸排的,所以这一层淡底就是
/// 「这句是我说的」的唯一标记。
///
/// 用 `surfaceContainerHigh` 而不是 `primaryContainer`:顶栏已经是一整块
/// `primaryContainer`,再用主题色会和它抢注意力,而且每条用户消息都上主题色
/// 会让长对话变得很吵。
class UserBubble extends ConsumerWidget {
  const UserBubble({super.key, required this.item});

  final UserItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          // 左侧留白让它和 AI 的裸排文字错开,一眼能看出说话的人变了
          const SizedBox(width: 24),
          Expanded(
            child: Material(
              color: colors.surfaceContainerHigh,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(PiShape.xl)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onLongPress: () => showMessageActions(context, ref, item),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: SelectableText(
                    item.text,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: colors.onSurface),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
