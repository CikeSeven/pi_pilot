import 'package:flutter/material.dart';

/// Material 3 圆角词汇。整体偏大——「大圆角」是明确的设计要求。
abstract final class PiShape {
  /// 内联代码、tooltip
  static const xs = 8.0;

  /// chip、工具头像、系统提示
  static const sm = 12.0;

  /// 代码井、菜单、snackbar、小 FAB
  static const md = 16.0;

  /// 面板、输入框、FAB
  static const lg = 20.0;

  /// 卡片与气泡
  static const xl = 24.0;

  /// 对话框、弹窗顶角、输入条、搜索框
  static const xxl = 28.0;

  static final card = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(xl),
  );

  /// 消息卡:全 app 最大的圆角,用户明确要求「大圆角」。
  static final messageCard = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(xxl),
  );
  static final dialog = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(xxl),
  );
  static const sheet = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(xxl)),
  );
}
