import 'package:flutter/material.dart';

/// 字体规范:**衬线负责气质,无衬线负责效率,等宽负责代码**。
///
/// Editorial Retro 的核心排版原则(来自设计规范):
/// - 大标题 / 品牌字标 / 空状态标题 → 衬线体,拉文艺气质;
/// - 正文 / 列表 / 设置项 / 状态标签 → 无衬线,保证信息密度下的可读性;
/// - 代码 / 路径 / 输出 / 参数 → JetBrains Mono。
///
/// 为什么衬线用系统 `serif` 族而不打包字体文件:
/// 中文衬线(思源宋体/Noto Serif CJK)单字重就 10-20MB,打包进 APK 不现实;
/// 而 Android 系统 `serif` 族本身就映射到 Noto Serif + Noto Serif CJK,
/// 中英文都有衬线效果、零体积、零网络请求。iOS 上映射到 Times/宋体系,
/// 同样是衬线。代价是不同 OS 字形略有差异——对「气质」而言可以接受。
abstract final class AppType {
  static const monoFamily = 'JetBrainsMono';
  static const monoFallback = ['monospace'];

  /// 衬线族:系统衬线。`serif` 在 Android 走 Noto Serif / Noto Serif CJK,
  /// 在 iOS 走 Times New Roman / 宋体,都是衬线。
  static const serifFamily = 'serif';
  static const serifFallback = ['Noto Serif', 'Noto Serif CJK SC', 'Georgia'];

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

  /// 衬线样式统一出口。用于标题、品牌、空状态大字。
  ///
  /// 默认 `height: 1.25` 比正文紧——衬线大字行距太松会散,
  /// 编辑式排版讲究标题成块。
  static TextStyle serif({
    double size = 24,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.25,
    double letterSpacing = 0,
    FontStyle? style,
  }) {
    return TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
      fontStyle: style,
    );
  }

  /// 品牌字标 PiPilot:衬线 + 轻微字距,像刊物报头。
  static TextStyle wordmark({double size = 22, Color? color}) =>
      serif(size: size, weight: FontWeight.w600, color: color, letterSpacing: 0.5);

  /// AI 回复的衬线小标题(参考图里每段回答上方那行大字)。
  static TextStyle answerHeadline({Color? color}) =>
      serif(size: 21, weight: FontWeight.w500, color: color, height: 1.35);

  /// 页面级衬线大标题(空状态、设置页头)。
  static TextStyle displayTitle({double size = 30, Color? color}) =>
      serif(size: size, weight: FontWeight.w500, color: color, height: 1.2);

  /// 衬线斜体:引文、副标语气(「安静等待」那类文案)。
  static TextStyle serifItalic({double size = 15, Color? color}) => serif(
    size: size,
    color: color,
    style: FontStyle.italic,
    height: 1.45,
  );

  /// 编辑式小标签:全大写 + 宽字距,像杂志栏目名。
  /// 用无衬线——它是功能标签不是气质位。
  static TextStyle eyebrow({Color? color}) => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: color,
    letterSpacing: 1.6,
    height: 1.3,
  );

  /// Material 3 字阶。
  ///
  /// **headline / display 全部换成衬线**——这是气质的主要来源;
  /// title / body / label 保持无衬线,承担信息密度。
  /// 负字距是 SF-Pro 的光学补偿,在 Noto Sans CJK 下会显得发挤,因此去掉。
  static const textTheme = TextTheme(
    displayLarge: TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: 44,
      fontWeight: FontWeight.w500,
      height: 1.18,
    ),
    displayMedium: TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: 36,
      fontWeight: FontWeight.w500,
      height: 1.2,
    ),
    displaySmall: TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: 30,
      fontWeight: FontWeight.w500,
      height: 1.22,
    ),
    headlineLarge: TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: 30,
      fontWeight: FontWeight.w500,
      height: 1.25,
    ),
    headlineMedium: TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: 25,
      fontWeight: FontWeight.w500,
      height: 1.3,
    ),
    headlineSmall: TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: 21,
      fontWeight: FontWeight.w500,
      height: 1.33,
    ),
    // title 起继续用无衬线:它们出现在卡头、列表项、顶栏,信息位。
    titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.5,
      letterSpacing: 0.1,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.43,
      letterSpacing: 0.1,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.55, letterSpacing: 0.1),
    bodyMedium: TextStyle(fontSize: 14, height: 1.5, letterSpacing: 0.15),
    bodySmall: TextStyle(fontSize: 12, height: 1.4, letterSpacing: 0.3),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.43,
      letterSpacing: 0.1,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.33,
      letterSpacing: 0.4,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 1.45,
      letterSpacing: 0.5,
    ),
  );
}
