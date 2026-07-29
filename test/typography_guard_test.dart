import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 界面代码不许再手写字号。
///
/// 重构前 `lib/ui/` 有 28 处内联 `TextStyle(fontSize:)`,占显式样式的 40%,
/// 用的字号是 10.5 / 11.5 / 12.5 / 13 / 13.5 / 17 —— 字阶(11/12/14/16/22/
/// 24/28/32)里一个都没有。10.5sp 还低于 M3 最小 label 步进。这是「看起来
/// 丑、不大方」最直接的来源:同一屏上六种对不齐的字号。
///
/// 字号只允许出现在 `lib/ui/theme/`(字阶定义)里。
void main() {
  test('lib/ui/ 里不再手写 fontSize', () {
    final offenders = <String>[];
    for (final file in _dartFiles(Directory('lib/ui'))) {
      // 字阶本身与等宽字梯度定义在 theme/ 里,豁免。
      // 用正规化路径判断 —— Windows 上分隔符是 `\`,写死 '/theme/' 会漏掉豁免。
      if (_inThemeDir(file)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'\bfontSize\s*:').hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}  ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '请改用 Theme.of(context).textTheme.* 或 AppType.mono*,'
          '不要手写字号:\n${offenders.join('\n')}',
    );
  });

  test('lib/ui/ 里不再手写小于 16 的圆角', () {
    // 圆角走 PiShape token(xs 6 / sm 10 / md 12 / lg 14 / xl 18 / xxl 22)。
    // 直接写数字会绕开「编辑式收敛圆角」这条设计约束。
    final offenders = <String>[];
    final radius = RegExp(r'BorderRadius\.circular\(\s*(\d+(?:\.\d+)?)\s*\)');
    for (final file in _dartFiles(Directory('lib/ui'))) {
      if (_inThemeDir(file)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final match in radius.allMatches(lines[i])) {
          offenders.add('${file.path}:${i + 1}  ${match.group(0)}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '圆角请用 PiShape token:\n${offenders.join('\n')}',
    );
  });
}

/// 该文件是否在 `lib/ui/theme/` 下(跨平台:统一成 `/` 再判断)。
bool _inThemeDir(File file) =>
    file.path.replaceAll(r'\', '/').contains('/theme/');

Iterable<File> _dartFiles(Directory root) sync* {
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) yield entity;
  }
}
