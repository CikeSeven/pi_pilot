import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../../state/settings_provider.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'message_actions_sheet.dart';
import '../../theme/squircle.dart';

/// 用户消息:**陶土橙实心卡,右对齐**。
///
/// Editorial Retro 改版的关键对比元素。旧版用 `surfaceContainerHigh` 淡底、
/// 铺满整行宽度——在新的奶油纸底上那层淡底几乎看不见,「谁在说话」就丢了。
///
/// 现在的设计语言(对齐参考图):
/// - 主强调色实心 + 反白字 —— 全屏唯一的实色块,是视觉锚点;
/// - **右对齐 + 最大宽度 82%** —— 靠位置区分说话人,比靠底色更快;
/// - 左上角留一个 `你` 的编辑式小标 —— 像信笺上的落款;
/// - 圆角走纸卡档(14),不是胶囊 —— 它是一张纸条,不是聊天气泡。
class UserBubble extends ConsumerWidget {
  const UserBubble({super.key, required this.item});

  final UserItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      // top 20:和前一个元素(AI 回复/工具卡)间距 = 4+20 = 24,轮切换大间距。
      // bottom 4:和后面的工具卡/AI 回复间距 = 4+4 = 8,同一轮内部。
      padding: const EdgeInsets.fromLTRB(10, 20, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 落款小标:在卡片右上,像纸条上的署名
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 6),
            child: Text(
              '你',
              style: AppType.eyebrow(
                color: colors.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
          // 右对齐 + 宽度上限:长消息不会顶满全宽,短消息自然收缩
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.82,
            ),
            child: Material(
              color: colors.primary,
              shape: SquircleBorder(
                borderRadius: BorderRadius.circular(PiShape.md),
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
                    style: chatBodyStyle(
                      context,
                      ref.watch(settingsProvider),
                      color: colors.onPrimary,
                    ),
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
