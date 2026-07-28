import 'package:flutter/material.dart';

/// 字体规范:正文用系统字体(Android 上 CJK 走 Noto Sans CJK),
/// 代码/路径/输出统一用 JetBrains Mono(无 CJK 字形,fallback 到系统等宽)。
abstract final class AppType {
  static const monoFamily = 'JetBrainsMono';
  static const monoFallback = ['monospace'];

  /// 等宽样式统一出口——业务代码禁止再写 fontFamily 字面量。
  static TextStyle mono({
    double size = 13,
    FontWeight? weight,
    Color? color,
    double height = 1.5,
  }) {
    return TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );
  }

  /// 工具/bash 输出正文。
  static TextStyle monoSmall({Color? color}) => mono(size: 12, color: color);

  /// 参数摘要、命令行、chip 标签。
  static TextStyle monoLabel({Color? color, FontWeight? weight}) =>
      mono(size: 12, color: color, weight: weight, height: 1.4);

  /// Material 3 字阶。负字距是 SF-Pro 的光学补偿,
  /// 在 Roboto / Noto Sans CJK 下会显得发挤,因此全部去掉。
  static const textTheme = TextTheme(
    headlineLarge: TextStyle(fontSize: 32, height: 1.25),
    headlineMedium: TextStyle(fontSize: 28, height: 1.29),
    headlineSmall: TextStyle(fontSize: 24, height: 1.33),
    titleLarge: TextStyle(fontSize: 22, height: 1.27),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.5,
      letterSpacing: 0.15,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.43,
      letterSpacing: 0.1,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.5, letterSpacing: 0.15),
    bodyMedium: TextStyle(fontSize: 14, height: 1.43, letterSpacing: 0.25),
    bodySmall: TextStyle(fontSize: 12, height: 1.33, letterSpacing: 0.4),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.43,
      letterSpacing: 0.1,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.33,
      letterSpacing: 0.5,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 1.45,
      letterSpacing: 0.5,
    ),
  );
}
