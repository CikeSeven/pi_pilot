import 'package:flutter/material.dart';

/// 圆角词汇。
///
/// Editorial Retro 改版:整体**收敛**圆角。
/// 旧版是「大圆角」(卡片 24 / 对话框 28),那是现代 App 的语言;
/// 编辑式排版讲究版芯方正,纸卡的角是裁切出来的,不是吹圆的。
/// 所以卡片一律 14,只有胶囊类(输入条、chip、按钮)保留 stadium。
abstract final class PiShape {
  /// 内联代码、极小标签
  static const xs = 6.0;

  /// chip、工具头像、系统提示、内嵌小块
  static const sm = 10.0;

  /// 代码井、菜单、snackbar、内容块
  static const md = 12.0;

  /// 卡片主圆角——编辑式纸卡
  static const lg = 14.0;

  /// 大面板、弹层
  static const xl = 18.0;

  /// 底部弹层顶角、全屏卡
  static const xxl = 22.0;

  /// 通用卡片。
  static final card = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(lg),
  );

  /// 消息卡:与通用卡同档——统一的纸卡语言,不再刻意做最大圆角。
  static final messageCard = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(lg),
  );

  static final dialog = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(xl),
  );

  static const sheet = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(xxl)),
  );

  /// 带细描边的纸卡形状。Editorial Retro 的核心组件语言:
  /// **零阴影 + 1px 描边**,层次靠描边和纸色深浅,不靠投影。
  static RoundedRectangleBorder outlinedCard(Color border, {double radius = lg}) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: border),
      );
}
