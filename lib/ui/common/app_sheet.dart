import 'package:flutter/material.dart';

import 'sheet_navigator.dart';
import 'tokens.dart';

/// 统一 iOS 风底部弹窗入口:顶部大圆角与拖把手来自 bottomSheetTheme,
/// 这里补充弹出动效与可选固定高度。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double? heightFactor,
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: isScrollControlled || heightFactor != null,
    showDragHandle: true,
    // showModalBottomSheet 只采纳时长,curve 字段会被忽略
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 380),
      reverseDuration: Duration(milliseconds: 260),
    ),
    builder: heightFactor == null
        ? builder
        : (context) => SizedBox(
            height: MediaQuery.sizeOf(context).height * heightFactor,
            width: double.infinity,
            child: builder(context),
          ),
  );
}

/// 弹窗大标题行。
///
/// 左上角**永远有一个明确的出口**:在二级页是返回箭头,在根页是关闭键。
/// 之前这里只有 trailing 的 `actions`,长按消息弹出的那个面板除了下滑和点
/// 遮罩没有任何退出方式。
class SheetHeader extends StatelessWidget {
  const SheetHeader(this.title, {super.key, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final sheet = SheetNavigator.maybeOf(context);
    final canGoBack = sheet?.canPop ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: canGoBack ? '返回' : '关闭',
            icon: Icon(canGoBack ? Icons.arrow_back : Icons.close),
            onPressed: () {
              if (canGoBack) {
                sheet!.pop();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 弹窗内的分组卡。
///
/// M3 靠**留白与色阶**分组,而不是发丝分隔线 —— 所以这里没有 `Divider`,
/// 组内项之间只有 4px 间隙,组本身是一张 `surfaceContainerHigh` 的大圆角卡。
class SheetGroup extends StatelessWidget {
  const SheetGroup({
    super.key,
    required this.children,
    this.title,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  });

  final List<Widget> children;

  /// 可选组标题(渲染在卡片上方,`labelLarge` + `onSurfaceVariant`)。
  final String? title;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title case final label?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PiShape.xl),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (index, child) in children.indexed) ...[
                    if (index > 0) const SizedBox(height: 4),
                    child,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
