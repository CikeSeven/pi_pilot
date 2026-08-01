import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/shapes.dart';

/// 液态玻璃小胶囊:**折叠态摘要的通用外壳**。
///
/// 和输入框/灵动岛同一套液态语言:三段对角渐变(微高光 → 主体 → 微阴影)
/// + 0.5px 细描边 + 999 全圆角。思考块、工具组的折叠态都套这层壳,
/// 整个对话流里的「可展开摘要」形态统一。
///
/// 传了 [expandedChild] 时,展开内容长在**胶囊内部**:摘要行保持 34dp,
/// 内容接在它下面,整颗胶囊自己长高。这才是「结果在卡片里」——
/// 把内容摆成胶囊的兄弟节点,视觉上就是「上面一颗胶囊、下面另一块东西」。
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.expandedChild,
    this.fillWidth = true,
  });

  /// 摘要行。始终占一行(34dp),是胶囊的「标题」。
  final Widget child;
  final VoidCallback? onTap;

  /// 外壳是否占满可用宽度。
  ///
  /// 工具组胶囊要撑满(内部有 Spacer 撑开左右两端);
  /// 思考胶囊只需裹住短文案,传 false 收缩到内容宽度。
  final bool fillWidth;

  /// 展开内容。非空即视为展开态:胶囊长高把它裹进去,圆角收成中等圆角。
  ///
  /// 全圆角(999)只适合一行高的胶囊 —— 内容长起来以后,那个巨大的圆角会把
  /// 首尾两行的左右两端切掉。
  final Widget? expandedChild;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final expanded = expandedChild != null;
    // 展开后收成中等圆角:长条内容配 999 全圆角会切掉首尾行的两端。
    final radius = BorderRadius.circular(expanded ? PiShape.md : PiShape.lg);

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(
                colors.surfaceContainerLow,
                Colors.white,
                isDark ? 0.06 : 0.15,
              )!,
              colors.surfaceContainerLow,
              Color.lerp(
                colors.surfaceContainerLow,
                Colors.black,
                isDark ? 0.08 : 0.04,
              )!,
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
        // 渐变/描边由外层 Container 画,内容用 ClipRRect 裁进同一个圆角里,
        // 否则展开内容(代码块、diff)的方角会戳出胶囊的圆角。
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: fillWidth
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 只有摘要行可点:展开内容里有代码块、可滚动输出井、问卷按钮,
              // 整块包进 InkWell 会把它们的手势全吃掉。
              InkWell(
                onTap: onTap,
                // 展开时上圆角贴合外壳,下边缘是直角(内容接着往下长)。
                borderRadius: expanded
                    ? BorderRadius.vertical(top: radius.topLeft)
                    : radius,
                child: Container(
                  // minHeight 而不是固定 height:展开时摘要行可能换成
                  // 完整命令的多行全文(工具组胶囊就这么干),行高跟着
                  // 内容长;单行时仍是 34,视觉与以前一致。
                  constraints: const BoxConstraints(minHeight: 34),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  // fillWidth=false 时不设 alignment:有 alignment 的
                  // Container 会无视 start 强制扩到最大宽度,
                  // 思考胶囊的 shrink-wrap 会被它撑回去。
                  alignment: fillWidth ? Alignment.centerLeft : null,
                  child: child,
                ),
              ),
              if (expandedChild case final content?) ...[
                // 摘要行与内容之间一条细线:胶囊内部的分区,替代「另起一张卡」。
                Divider(
                  height: 1,
                  thickness: 1,
                  color: colors.outlineVariant.withValues(alpha: 0.5),
                ),
                AnimatedSize(
                  duration: PiMotion.collapse,
                  curve: PiMotion.collapseCurve,
                  alignment: Alignment.topCenter,
                  child: content,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
