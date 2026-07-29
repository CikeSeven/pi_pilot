import 'package:flutter/material.dart';

/// 可选主题色。枚举名即持久化键(`ui.accentColor`)。
///
/// Editorial Retro:整组色种是**低饱和复古色**——赤陶、砖红、橄榄、鼠尾草、
/// 灰粉、灰蓝。色板里没有一个纯蓝,这是「不走科技蓝」这条设计要求的落点。
///
/// ## 每个 accent 六个色值,不靠推导
///
/// `ColorScheme.fromSeed` 会把复古色重新推成现代高饱和色阶,恰好抹掉这套
/// 设计要的「褪色感」,所以浅深两套的容器色都手工指定。
///
/// **深色的种子必须比浅色亮一档**:复古色本身明度低,直接放到暖炭黑背景上
/// 会陷进去(用户原话「陶土橙在深色模式中需要稍微提亮」)。
/// 所以 `seedDark` 不是 `seed` 的反相,而是同色相提亮 + 略降饱和。
///
/// ## 对比度门槛分层
///
/// 品牌色 `#C85A3E` 配奶油白文字的对比度上限是 4.21 —— 物理上到不了 4.5。
/// 要么压暗品牌色(那就不是陶土橙了),要么按文字尺寸分层。这里选后者:
///
/// - **primary / onPrimary 对 >= 3.0**:它们只用在主按钮、角标、用户消息卡,
///   文字都是 >= 14sp 粗体,符合 WCAG 对 large text 的 3:1 标准;
/// - **正文、代码井、diff、工具卡容器仍守 4.5**:那些是小字,一个不放松。
///
/// 见 theme_test 的两组对比度守卫。
enum AppAccent {
  /// 默认:陶土橙。品牌主色。
  terracotta(
    '赤陶',
    Color(0xFFC85A3E),
    container: Color(0xFFF4DED6),
    onContainer: Color(0xFF4A1F14),
    seedDark: Color(0xFFD86B4E),
    containerDark: Color(0xFF6B3423),
    onContainerDark: Color(0xFFF6E1D8),
  ),

  /// 砖红:更沉、更书卷气。
  brick(
    '砖红',
    Color(0xFFA8432E),
    container: Color(0xFFF0D8D0),
    onContainer: Color(0xFF3D160C),
    seedDark: Color(0xFFCE6549),
    containerDark: Color(0xFF5E2718),
    onContainerDark: Color(0xFFF2DBD3),
  ),

  /// 橄榄绿:植物、纸、旧书封。
  olive(
    '橄榄',
    Color(0xFF727A59),
    container: Color(0xFFDFE3D2),
    onContainer: Color(0xFF2C3124),
    seedDark: Color(0xFF98A078),
    containerDark: Color(0xFF404733),
    onContainerDark: Color(0xFFDCE2CC),
  ),

  /// 鼠尾草:最淡的一档绿。
  sage(
    '鼠尾草',
    Color(0xFF687560),
    container: Color(0xFFDEE5D8),
    onContainer: Color(0xFF2A3227),
    seedDark: Color(0xFF9DAA8E),
    containerDark: Color(0xFF3C4739),
    onContainerDark: Color(0xFFDBE3D5),
  ),

  /// 灰粉:雾感、柔和。
  blush(
    '灰粉',
    Color(0xFFB0655A),
    container: Color(0xFFF3DFDA),
    onContainer: Color(0xFF44201A),
    seedDark: Color(0xFFC58F82),
    containerDark: Color(0xFF64362E),
    onContainerDark: Color(0xFFF4E2DD),
  ),

  /// 灰蓝:唯一的冷色,刻意做旧到接近牛仔蓝。
  slate(
    '灰蓝',
    Color(0xFF5B6B78),
    container: Color(0xFFDAE1E6),
    onContainer: Color(0xFF232D34),
    seedDark: Color(0xFF9BAEB9),
    containerDark: Color(0xFF3A464F),
    onContainerDark: Color(0xFFD9E2E7),
  );

  const AppAccent(
    this.label,
    this.seed, {
    required this.container,
    required this.onContainer,
    required this.seedDark,
    required this.containerDark,
    required this.onContainerDark,
  });

  /// 设置页展示名。
  final String label;

  /// 浅色主题主强调色(也是色板上显示的那个颜色)。
  final Color seed;

  /// 浅色:主强调容器 / 其上前景。
  final Color container;
  final Color onContainer;

  /// 深色主题主强调色——提亮一档,否则陷进暖炭黑背景。
  final Color seedDark;
  final Color containerDark;
  final Color onContainerDark;

  /// 按亮度取对应主题的主色。
  Color seedFor(Brightness brightness) =>
      brightness == Brightness.dark ? seedDark : seed;

  /// 未知/缺失回退赤陶(向前兼容;旧值 blue/purple/pink/orange/green/teal
  /// 不在枚举里,会走这条回退)。
  static AppAccent fromName(String? name) =>
      AppAccent.values.asNameMap()[name] ?? AppAccent.terracotta;
}
