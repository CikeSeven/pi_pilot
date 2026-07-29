import 'package:flutter/material.dart';

import '../../theme/shapes.dart';
import '../../theme/squircle.dart';

/// 所有消息共用的卡片外壳。
///
/// Editorial Retro:纸卡语言 —— **描边 + 零阴影 + 方正圆角**,
/// 身份行与正文之间用一条细线分隔(编辑式版式,不靠色块分区)。
///
/// 统一提供:描边纸卡 + 对称边距 + 最大宽度 + 卡内身份行。
class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.child,
    this.color,
    this.avatar,
    this.title,
    this.titleColor,
    this.subtitle,
    this.headerColor,
    this.trailing,
    this.elevation = 0,
    this.onTap,
    this.onLongPress,
    this.contentPadding = const EdgeInsets.fromLTRB(16, 8, 16, 16),
  });

  /// 卡片内容(身份行下方)。
  final Widget child;

  /// 卡片底色。默认走 `cardTheme` 的 `surfaceContainerLow`。
  final Color? color;

  /// 身份行左侧头像。为空则不渲染身份行。
  final Widget? avatar;

  /// 身份行标题。工具卡必须传**裸 `Text(item.name)`**,测试点它。
  final Widget? title;
  final Color? titleColor;

  /// 标题下方的第二行(工具参数、命令摘要)。
  ///
  /// 这类内容**不能**塞进 `trailing` —— 那是状态位,宽度必须是固定的。
  final Widget? subtitle;

  /// 身份行底色。工具/bash 卡用类别色铺满整行,让工具类型一眼可辨。
  final Color? headerColor;

  /// 身份行右侧(状态指示、徽标、展开箭头)。
  final Widget? trailing;

  final double elevation;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsets contentPadding;

  /// 平板/横屏下的最大内容宽度。原来完全没有约束,会拉满整屏。
  static const maxContentWidth = 720.0;

  /// trailing 最多能吃掉身份行的这个比例。状态位(图标 + 箭头)实际只要
  /// ~50dp,给到 40% 是留给 `exit 137` 这类徽标的余量,同时保证标题列
  /// 至少还有 60% —— 不会再出现「一半宽度给了两个图标」。
  static const _trailingWidthFraction = 0.4;

  @override
  Widget build(BuildContext context) {
    final hasHeader = avatar != null || title != null;
    final titleStyle = Theme.of(
      context,
    ).textTheme.labelLarge!.copyWith(color: titleColor);

    final header = hasHeader
        ? Container(
            color: headerColor,
            padding: EdgeInsets.fromLTRB(16, 12, trailing == null ? 16 : 8, 12),
            // trailing 必须**非 flex**才会贴到行尾:它和标题列一样是
            // `Flexible`/`Expanded` 的话,两个 flex 因子都是 1,`RenderFlex`
            // 把可用宽度对半分 —— 标题只拿到一半(提前截断),状态位就停在
            // 行的中间,而不是最右侧。
            //
            // 但非 flex 子节点是用 `maxWidth: infinity` 布局的,trailing 里
            // 若有文本就会按固有宽度铺开、把整行撑爆(实测 400dp 屏溢出
            // 588px)。所以这里量出行宽,给它一个有限上限,ellipsis 才有效。
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trailingMaxWidth = constraints.hasBoundedWidth
                    ? constraints.maxWidth * _trailingWidthFraction
                    : double.infinity;
                return Row(
                  children: [
                    if (avatar case final widget?) ...[
                      widget,
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (title case final widget?)
                            DefaultTextStyle.merge(
                              style: titleStyle,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              child: widget,
                            ),
                          if (subtitle case final widget?)
                            DefaultTextStyle.merge(
                              style: titleStyle.copyWith(
                                color: titleStyle.color?.withValues(
                                  alpha: 0.75,
                                ),
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              child: widget,
                            ),
                        ],
                      ),
                    ),
                    if (trailing case final widget?) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: trailingMaxWidth),
                        child: widget,
                      ),
                    ],
                  ],
                );
              },
            ),
          )
        : null;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ?header,
        // 身份行与正文之间的细线:编辑式分隔,替代靠底色分区。
        if (hasHeader)
          Container(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        Padding(
          padding: hasHeader
              ? contentPadding
              : contentPadding.copyWith(top: contentPadding.bottom),
          child: child,
        ),
      ],
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxContentWidth),
        child: Card(
          // 上下各 4:工具卡↔工具卡 = 4+4 = 8,和思考↔正文的间距一致。
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
          color: color,
          // 微阴影(elevation 1):不是零也不是 M3 默认的 6。
          // 用户反馈「简陋、没层次感」-- 纯零阴影让卡片融进背景,
          // 加一点点浮起感,层次立刻出来了,又不失克制。
          elevation: elevation > 0 ? elevation : 1,
          // 显式描边:color 被调用方覆盖时(工具卡类别色)仍要有骨架线
          shape: SquircleBorder(
            borderRadius: BorderRadius.circular(PiShape.md),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            smoothing: PiShape.smoothing,
          ),
          child: onTap == null && onLongPress == null
              ? body
              : InkWell(onTap: onTap, onLongPress: onLongPress, child: body),
        ),
      ),
    );
  }
}

/// 系统提示这类居中窄卡:不需要身份行,也不该占满整行宽度。
class MessageNotice extends StatelessWidget {
  const MessageNotice({super.key, required this.child, required this.color});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Card(
          margin: EdgeInsets.zero,
          color: color,
          shape: SquircleBorder(
            borderRadius: BorderRadius.circular(PiShape.md),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            smoothing: PiShape.smoothing,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: child,
          ),
        ),
      ),
    );
  }
}
