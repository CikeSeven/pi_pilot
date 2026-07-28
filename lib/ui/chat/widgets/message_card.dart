import 'package:flutter/material.dart';

/// 所有消息共用的卡片外壳。
///
/// 重构前 `chat/` 目录里**一个 `Card` 都没有** —— 七种消息各自手搓
/// `Container(margin) → Material(color, shape)`,elevation 全是隐含的 0,
/// 所以 `surfaceTint` 永远不生效、深浅两个主题都是纯平的。左右边距还不对称
/// (用户气泡 `left: 56`,其余 `right: 20`),平板上更是没有任何宽度约束。
///
/// 这里统一成:真 `Card` + 对称边距 + 最大宽度 + 卡内身份行。
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
          // 对称边距 —— 不再是 left56 / right20 那种一边倒的观感
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          color: color,
          elevation: elevation,
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: child,
          ),
        ),
      ),
    );
  }
}
