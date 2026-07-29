import 'package:flutter/material.dart';

import 'accent.dart';

/// Editorial Retro 配色:**手工构造**,不再走 `ColorScheme.fromSeed`。
///
/// 为什么弃用 fromSeed:M3 的 tonalSpot 会把任何种子色推导成一套
/// 「现代 App」色阶——中性面永远是冷灰白、容器永远是同色系浅调。
/// 这套设计要的是**纸**:暖奶油底、赤陶点睛、暖炭黑正文、橄榄辅助。
///
/// ## 日间版 / 夜间版 = 同一本杂志的两种印次
///
/// 深浅两套**不是简单反相**,而是共用同一套品牌基因:
/// - 品牌主色:陶土橙(深色下提亮,否则陷进背景)
/// - 情绪辅助:橄榄绿、灰粉
/// - 浅色基底:奶油白、纸张米色
/// - 深色基底:暖炭黑、深咖灰(偏暖偏咖,不是冷科技黑)
/// - **绝不用纯白 #FFFFFF / 纯黑 #000000**
///
/// 配色比例守 70/20/10:70% 中性底、20% 卡片层级、10% 品牌强调。
/// 陶土橙只出现在主按钮、当前状态、进度条、选中标签、插画色块,
/// 铺满会变成活动海报。
abstract final class PiPalette {
  // ══ 浅色:奶油纸张系 ══════════════════════════════════
  /// 页面背景 · 暖奶油白
  static const cream = Color(0xFFF5EDE1);

  /// 一级卡片 · 柔和象牙白
  static const ivory = Color(0xFFFBF6EC);

  /// 二级卡片 · 浅杏纸色
  static const apricot = Color(0xFFEFE3D5);

  /// 输入框背景 · 淡粉杏色
  static const inputLight = Color(0xFFF2E2DA);

  /// 主文字 · 暖炭黑
  static const inkStrong = Color(0xFF2B2825);

  /// 次级文字 · 暖灰棕
  static const inkMuted = Color(0xFF716860);

  /// 弱化文字 · 灰米色
  static const inkFaint = Color(0xFF9B9187);

  /// 分割线/边框 · 纸张棕灰
  static const ruleLight = Color(0xFFD8C9B8);

  // ══ 深色:暖炭黑编辑系 ════════════════════════════════
  /// 页面背景 · 暖炭黑(偏暖偏咖,不是冷科技黑)
  static const charcoal = Color(0xFF272624);

  /// 一级卡片 · 深咖灰。
  ///
  /// 规范给的 #32302D 与页面底 #272624 只差 1.15 —— 底栏用它会糊进背景。
  /// 提一档到 #363430(1.22),再靠 graphite 承担底栏(1.31)。
  static const coffeeGrey = Color(0xFF363430);

  /// 二级卡片 · 暖石墨灰。也是深色底栏用色(与页面底差 1.31,刚好读得出)。
  static const graphite = Color(0xFF3B3935);

  /// 输入框背景 · 深棕灰
  static const inputDark = Color(0xFF403A35);

  /// 主文字 · 奶油白
  static const paperStrong = Color(0xFFF3EBDD);

  /// 次级文字 · 暖灰米色
  static const paperMuted = Color(0xFFBBB0A4);

  /// 弱化文字 · 深米灰
  static const paperFaint = Color(0xFF8D857C);

  /// 分割线/边框 · 暖灰褐
  static const ruleDark = Color(0xFF575149);

  // ══ 品牌基因(两套共用,深色下提亮) ═════════════════════
  /// 品牌主色 · 陶土橙(浅色)
  static const terracotta = Color(0xFFC85A3E);

  /// 品牌主色 · 亮陶土橙(深色)
  static const terracottaLift = Color(0xFFD86B4E);

  /// 品牌深色 · 砖红(浅色按下态)
  static const brick = Color(0xFFA8432E);

  /// 品牌深色 · 深砖红(深色按下态)
  static const brickLift = Color(0xFFB75039);

  /// 辅助绿 · 橄榄绿(浅色)
  static const olive = Color(0xFF727A59);

  /// 辅助绿 · 柔和橄榄绿(深色)
  static const oliveLift = Color(0xFF98A078);

  /// 辅助粉 · 灰粉(浅色)
  static const blush = Color(0xFFD9A79A);

  /// 辅助粉 · 暗灰粉(深色)
  static const blushLift = Color(0xFFC58F82);

  /// 主按钮文字(浅色)
  static const onBrandLight = Color(0xFFFFF8EE);

  /// 主按钮文字(深色)
  static const onBrandDark = Color(0xFFFFF4E8);

  // ── 兼容别名:旧代码引用的名字,映射到新色 ────────────────
  /// @Deprecated 用 [ivory] / [apricot]
  static const creamDeep = apricot;

  /// 深色面上的卡(旧名)→ 深咖灰
  static const charcoalSoft = coffeeGrey;

  /// 深色面上抬升的卡(旧名)→ 暖石墨灰
  static const charcoalLift = graphite;

  /// 深色页面底(旧名)→ 暖炭黑
  static const nightPaper = charcoal;
  static const nightCard = coffeeGrey;
  static const nightLift = graphite;

  /// 淡辅助(旧名)→ 柔和橄榄绿
  static const sage = oliveLift;

  /// 描边(旧名)→ 纸张棕灰
  static const mist = ruleLight;

  /// 浅色方案:奶油白背景 + 象牙卡片 + 暖炭黑文字 + 陶土橙按钮 + 橄榄绿点缀。
  ///
  /// `surfaceContainer*` 四档沿 象牙→奶油→浅杏→更深杏 走,
  /// 层次靠**纸的深浅**而不是阴影(设计要求扁平)。
  static ColorScheme lightScheme(AppAccent accent) {
    return ColorScheme(
      brightness: Brightness.light,
      primary: accent.seed,
      onPrimary: onBrandLight,
      primaryContainer: accent.container,
      onPrimaryContainer: accent.onContainer,
      secondary: olive,
      onSecondary: onBrandLight,
      // 容器用**中性纸色**而不是绿色系:secondary 固定是橄榄绿,
      // 若容器也是绿的,accent 选橄榄/鼠尾草时角标压在选中态上就分不开了
      // (同色相 = 同亮度)。绿色只留给 secondary 本身做文字/图标。
      secondaryContainer: apricot,
      onSecondaryContainer: inkStrong,
      tertiary: brick,
      onTertiary: onBrandLight,
      tertiaryContainer: const Color(0xFFF4DED6),
      onTertiaryContainer: const Color(0xFF4A1F14),
      error: const Color(0xFFA84A3D),
      onError: onBrandLight,
      errorContainer: const Color(0xFFF6DCD7),
      onErrorContainer: const Color(0xFF3F1109),
      surface: cream,
      onSurface: inkStrong,
      onSurfaceVariant: inkMuted,
      surfaceContainerLowest: const Color(0xFFFEFBF4),
      surfaceContainerLow: ivory,
      surfaceContainer: const Color(0xFFF3E9DC),
      surfaceContainerHigh: apricot,
      surfaceContainerHighest: const Color(0xFFE7DACA),
      surfaceTint: accent.seed,
      inverseSurface: charcoal,
      onInverseSurface: paperStrong,
      inversePrimary: accent.seedDark,
      outline: const Color(0xFF8E8178),
      outlineVariant: ruleLight,
      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),
    );
  }

  /// 深色方案:暖炭黑背景 + 深咖灰卡片 + 奶油白文字 + 提亮陶土橙 + 柔和橄榄绿。
  ///
  /// 不是浅色的反相——是同一本杂志的夜间版:偏暖、偏咖,像深色书封。
  static ColorScheme darkScheme(AppAccent accent) {
    return ColorScheme(
      brightness: Brightness.dark,
      primary: accent.seedDark,
      onPrimary: const Color(0xFF32130A),
      primaryContainer: accent.containerDark,
      onPrimaryContainer: accent.onContainerDark,
      secondary: oliveLift,
      onSecondary: const Color(0xFF262B1C),
      // 同浅色:容器走中性暖石墨灰,不跟 secondary 撞色相。
      secondaryContainer: graphite,
      onSecondaryContainer: paperStrong,
      tertiary: blushLift,
      onTertiary: const Color(0xFF3F1A10),
      tertiaryContainer: const Color(0xFF5E2C1E),
      onTertiaryContainer: const Color(0xFFF2DDD6),
      error: const Color(0xFFD0695A),
      onError: const Color(0xFF3A0F08),
      errorContainer: const Color(0xFF6B2417),
      onErrorContainer: const Color(0xFFF6DCD7),
      surface: charcoal,
      onSurface: paperStrong,
      onSurfaceVariant: paperMuted,
      surfaceContainerLowest: const Color(0xFF1E1D1B),
      surfaceContainerLow: coffeeGrey,
      surfaceContainer: const Color(0xFF373530),
      surfaceContainerHigh: graphite,
      surfaceContainerHighest: const Color(0xFF454239),
      surfaceTint: accent.seedDark,
      inverseSurface: cream,
      onInverseSurface: inkStrong,
      inversePrimary: accent.seed,
      outline: const Color(0xFF8A8175),
      outlineVariant: ruleDark,
      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),
    );
  }
}
