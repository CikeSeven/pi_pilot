import 'package:flutter/material.dart';

import '../../core/background_permission.dart';

/// 后台运行豁免的纯文字引导对话框。
///
/// 曾经这里用 deeplink 尝试直达厂商设置页,但实测走不通:HyperOS V816 把
/// powerkeeper 的整套 HiddenApps 组件(省电策略页)都移除了,AOSP 的
/// IGNORE_BATTERY_OPTIMIZATION_SETTINGS 落到的只是「应用的电池使用情况」
/// 应用列表页,同样到不了「无限制」开关。各厂商组件名来自社区逆向,
/// 版本间不稳定,没有任何可靠的自动跳转路径。
///
/// 所以统一改为纯文字引导:告诉用户开关叫什么、在哪一级菜单,
/// 让用户自己走过去。这是可维护性最差但唯一可靠的方式。
void showBackgroundPermissionGuide(
  BuildContext context,
  BackgroundPermissionStatus status,
) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('如何允许后台运行'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(status.vendor.settingsHint),
            const SizedBox(height: 16),
            Text(
              status.rationale,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
