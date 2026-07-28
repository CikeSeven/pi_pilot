import 'package:flutter/material.dart';

import '../theme/semantic_colors.dart';
import '../theme/shapes.dart';

enum PiToolCategory { terminal, read, edit, search, files, extension, generic }

/// Material 3 色调头像:每个工具类别一对固定的 container / on-container。
/// 取代旧的 iOS 设置风纯色方块(那个把白字硬编码在里面)。
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
      ),
      child: Icon(icon, size: size * 0.5, color: foreground),
    );
  }
}
