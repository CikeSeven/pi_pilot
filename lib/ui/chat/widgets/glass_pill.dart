import 'package:flutter/material.dart';

/// 液态玻璃小胶囊:**折叠态摘要的通用外壳**。
///
/// 和输入框/灵动岛同一套液态语言:三段对角渐变(微高光 → 主体 → 微阴影)
/// + 0.5px 细描边 + 999 全圆角。思考块、工具组的折叠态都套这层壳,
/// 整个对话流里的「可展开摘要」形态统一。
class GlassPill extends StatelessWidget {
  const GlassPill({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
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
          child: child,
        ),
      ),
    );
  }
}
