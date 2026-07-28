import 'package:flutter/material.dart';

/// 可选主题色。枚举名即持久化键(`ui.accentColor`)。
///
/// 只保存种子色:整套 ColorScheme 由 `ColorScheme.fromSeed` 推导,
/// 不再手写 on-色。手写 on-色正是旧实现的对比度 bug 来源
/// (白字配 #FF9500 只有 2.1:1)。
enum AppAccent {
  blue('蓝色', Color(0xFF007AFF)),
  purple('紫色', Color(0xFFAF52DE)),
  pink('粉色', Color(0xFFFF2D55)),
  orange('橙色', Color(0xFFFF9500)),
  green('绿色', Color(0xFF34C759)),
  teal('青色', Color(0xFF30B0C7));

  const AppAccent(this.label, this.seed);

  /// 设置页展示名。
  final String label;

  /// 生成整套配色的种子色(也是色板上显示的那个颜色)。
  final Color seed;

  /// 未知/缺失回退蓝色(向前兼容)。
  static AppAccent fromName(String? name) =>
      AppAccent.values.asNameMap()[name] ?? AppAccent.blue;
}
