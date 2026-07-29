import 'package:flutter/material.dart';

import 'squircle.dart';

/// 圆角词汇。**Squircle(连续曲率圆角)+ 三档收敛**。
///
/// 旧版有 6 档(xs/sm/md/lg/xl/xxl),差值太小(6/10/12/14/18/22),
/// 肉眼看不出区别反而显得随机。收敛到 **3 档**(小/中/大),
/// 每档差距明显、用途固定。
///
/// 所有圆角统一用 **Squircle**(超椭圆连续曲率),不再用普通圆弧圆角--
/// 那个在直线到弧线的连接处有曲率突变(折角),squircle 平滑过渡,
/// 这就是苹果圆角看着更柔的原因。
abstract final class PiShape {
  /// 小:chip、工具头像、内嵌小块、图标印章
  static const sm = 8.0;

  /// 中:卡片、代码井、菜单、内容块、按钮、输入框
  static const md = 14.0;

  /// 大:对话框、底部弹层、全屏卡、抽屉
  static const lg = 22.0;

  /// 超椭圆指数,越大越方。
  static const smoothing = 5.0;

  /// 通用卡片:中档 squircle。
  static final card = SquircleBorder(
    borderRadius: BorderRadius.circular(md),
    smoothing: smoothing,
  );

  /// 消息卡:与通用卡同档。
  static final messageCard = SquircleBorder(
    borderRadius: BorderRadius.circular(md),
    smoothing: smoothing,
  );

  /// 对话框:大档。
  static final dialog = SquircleBorder(
    borderRadius: BorderRadius.circular(lg),
    smoothing: smoothing,
  );

  /// 底部弹层:顶部大圆角。
  static final sheet = SquircleBorder(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(lg)),
    smoothing: smoothing,
  );

  /// 带描边的纸卡。零阴影 + 1px 描边 = 编辑式骨架线。
  static SquircleBorder outlinedCard(Color border, {double radius = md}) =>
      SquircleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: border),
        smoothing: smoothing,
      );
}
