import 'package:flutter/material.dart';

import 'accent.dart';

/// Material 3 配色:整套方案由强调色种子推导。
///
/// 选 `tonalSpot` 变体的理由:
/// - primary 色度收敛(≈36),色相保留种子的个性但**饱和度不高**
///   ——这是「色彩丰富但不刺眼」的来源,也是 Material You 默认的高级感路线;
/// - neutral / neutralVariant 带轻微种子色调,表面不至于死灰,仍有一丝暖意;
/// - tertiary 自动旋转 20–35°,白送一个第二强调色。
///
/// 曾用 `vibrant`:primary 色度拉满,叠上 Apple 系高饱和种子后整屏发艳,
/// 被审美要求「低饱和高级感」否决。
///
/// 不用 `.copyWith(primary: seed)` 强行还原种子:M3 保证 primary 与 onPrimary
/// 的对比度曲线,强改会脱钩 `ToneDeltaPair` 并复现旧的白字低对比问题。
abstract final class PiPalette {
  static const variant = DynamicSchemeVariant.tonalSpot;

  static ColorScheme lightScheme(AppAccent accent) => ColorScheme.fromSeed(
    seedColor: accent.seed,
    brightness: Brightness.light,
    dynamicSchemeVariant: variant,
  );

  static ColorScheme darkScheme(AppAccent accent) => ColorScheme.fromSeed(
    seedColor: accent.seed,
    brightness: Brightness.dark,
    dynamicSchemeVariant: variant,
  );
}
