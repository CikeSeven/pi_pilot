import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 用户明确要求:界面上不要出现「接管 / 释放控制 / 观察模式 / 控制权」这类词。
///
/// 这条测试把那个要求变成 CI 可执行的约束。检查的是**会被用户看到的字符串**
/// 和**会诱导代码回到旧模型的标识符**,不检查注释 —— 解释"为什么这个概念没了"
/// 的注释是有价值的,不该被这条规则赶走。
void main() {
  const bannedInStrings = ['接管', '释放控制', '释放控制权', '观察模式', '控制权', '控制者', '观察者'];
  const bannedIdentifiers = [
    'ownsSource',
    'canControl',
    'canBrowseSessions',
    'acquireControl',
    'releaseControl',
  ];

  test('lib/ 里不出现"接管/释放/观察模式"这类控制模型词汇', () {
    final offences = <String>[];

    for (final file in _dartFiles(Directory('lib'))) {
      final source = file.readAsStringSync();
      final stripped = _stripComments(source);
      final lines = stripped.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        for (final word in bannedInStrings) {
          if (line.contains(word)) {
            offences.add('${file.path}:${i + 1} 出现「$word」');
          }
        }
        for (final identifier in bannedIdentifiers) {
          if (RegExp('\\b$identifier\\b').hasMatch(line)) {
            offences.add('${file.path}:${i + 1} 出现标识符 `$identifier`');
          }
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          '会话切换不该表述成"接管/释放"。请改用活跃度语言'
          '(在电脑上运行 / 在 bridge 上运行 / 已休眠):\n${offences.join('\n')}',
    );
  });
}

Iterable<File> _dartFiles(Directory root) sync* {
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) yield entity;
  }
}

/// 去掉行注释、文档注释和块注释;字符串字面量原样保留。
String _stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < source.length) {
    final char = source[i];
    if (quote != null) {
      out.write(char);
      if (char == r'\') {
        if (i + 1 < source.length) out.write(source[i + 1]);
        i += 2;
        continue;
      }
      if (source.startsWith(quote, i)) {
        i += quote.length;
        quote = null;
        continue;
      }
      i++;
      continue;
    }
    if (source.startsWith("'''", i) || source.startsWith('"""', i)) {
      quote = source.substring(i, i + 3);
      out.write(quote);
      i += 3;
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      out.write(char);
      i++;
      continue;
    }
    if (source.startsWith('//', i)) {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      final stop = end == -1 ? source.length : end + 2;
      // 保留换行,行号才不会漂
      out.write('\n' * '\n'.allMatches(source.substring(i, stop)).length);
      i = stop;
      continue;
    }
    out.write(char);
    i++;
  }
  return out.toString();
}
