import 'package:flutter/material.dart';

import '../theme/semantic_colors.dart';
import '../theme/shapes.dart';

enum PiToolCategory { terminal, read, edit, search, files, extension, generic }

/// 工具类别印章:每个工具类别一对固定的 container / on-container 复古色。
///
/// Editorial Retro:方正圆角 + 细描边 —— 像盖在纸上的分类戳,
/// 不是圆头像(圆头像是「人」的语言,工具是「操作」)。
class PiToolAvatar extends StatelessWidget {
  const PiToolAvatar({
    super.key,
    required this.icon,
    required this.category,
    this.size = 36,
  });

  final IconData icon;
  final PiToolCategory category;
  final double size;

  static PiToolCategory categoryForTool(String name) => switch (name) {
    'bash' => PiToolCategory.terminal,
    'read' => PiToolCategory.read,
    'write' || 'edit' => PiToolCategory.edit,
    'grep' || 'find' => PiToolCategory.search,
    'ls' => PiToolCategory.files,
    // 扩展注入的工具:与内置工具区分开,一眼看出这不是 pi 自己在读写文件。
    'ask_user_question' => PiToolCategory.extension,
    _ => PiToolCategory.generic,
  };

  /// 该类别的 (容器色, on-容器色)。卡片头行铺色时复用同一套,
  /// 保证头像和它所在的整条身份行是同一个色相。
  static (Color, Color) colorsFor(PiToolCategory category, PiColors piColors) =>
      switch (category) {
        PiToolCategory.terminal => (
          piColors.toolTerminalContainer,
          piColors.onToolTerminalContainer,
        ),
        PiToolCategory.read => (
          piColors.toolReadContainer,
          piColors.onToolReadContainer,
        ),
        PiToolCategory.edit => (
          piColors.toolEditContainer,
          piColors.onToolEditContainer,
        ),
        PiToolCategory.search => (
          piColors.toolSearchContainer,
          piColors.onToolSearchContainer,
        ),
        PiToolCategory.files => (
          piColors.toolFilesContainer,
          piColors.onToolFilesContainer,
        ),
        PiToolCategory.extension => (
          piColors.toolExtensionContainer,
          piColors.onToolExtensionContainer,
        ),
        PiToolCategory.generic => (
          piColors.toolGenericContainer,
          piColors.onToolGenericContainer,
        ),
      };

  (Color, Color) _colors(PiColors piColors) => switch (category) {
    PiToolCategory.terminal => (
      piColors.toolTerminalContainer,
      piColors.onToolTerminalContainer,
    ),
    PiToolCategory.read => (
      piColors.toolReadContainer,
      piColors.onToolReadContainer,
    ),
    PiToolCategory.edit => (
      piColors.toolEditContainer,
      piColors.onToolEditContainer,
    ),
    PiToolCategory.search => (
      piColors.toolSearchContainer,
      piColors.onToolSearchContainer,
    ),
    PiToolCategory.files => (
      piColors.toolFilesContainer,
      piColors.onToolFilesContainer,
    ),
    PiToolCategory.extension => (
      piColors.toolExtensionContainer,
      piColors.onToolExtensionContainer,
    ),
    PiToolCategory.generic => (
      piColors.toolGenericContainer,
      piColors.onToolGenericContainer,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = _colors(PiColors.of(context));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(PiShape.sm),
        // 印章描边:与纸卡同一套骨架线语言
        border: Border.all(color: foreground.withValues(alpha: 0.22)),
      ),
      child: Icon(icon, size: size * 0.5, color: foreground),
    );
  }
}
