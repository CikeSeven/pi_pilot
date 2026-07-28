import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../common/tokens.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/typography.dart';

enum DiffLineKind { hunk, add, del, context, meta }

class DiffLine {
  const DiffLine(this.kind, this.text);
  final DiffLineKind kind;
  final String text;
}

/// 判断文本是否像 unified diff(有 @@ hunk 头,或混有 +/- 行)。
bool looksLikeUnifiedDiff(String text) {
  if (text.contains(RegExp(r'^@@ -', multiLine: true))) return true;
  var add = 0;
  var del = 0;
  for (final line in text.split('\n')) {
    if (line.startsWith('+') && !line.startsWith('+++')) add++;
    if (line.startsWith('-') && !line.startsWith('---')) del++;
  }
  return add >= 1 && del >= 1 && add + del >= 2;
}

List<DiffLine> parseUnifiedDiff(String text) {
  final lines = <DiffLine>[];
  for (final raw in text.split('\n')) {
    final kind = raw.startsWith('@@')
        ? DiffLineKind.hunk
        : raw.startsWith('+++') || raw.startsWith('---')
        ? DiffLineKind.meta
        : raw.startsWith('+')
        ? DiffLineKind.add
        : raw.startsWith('-')
        ? DiffLineKind.del
        : DiffLineKind.context;
    lines.add(DiffLine(kind, raw));
  }
  // 去掉尾部空 context 行
  while (lines.isNotEmpty &&
      lines.last.kind == DiffLineKind.context &&
      lines.last.text.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// 行级 LCS diff(old/new 文本兜底路径)。规模过大时退化为整段替换。
List<DiffLine> computeLineDiff(String oldText, String newText) {
  final a = oldText.split('\n');
  final b = newText.split('\n');
  if (a.length * b.length > 400 * 400) {
    return [
      for (final line in a) DiffLine(DiffLineKind.del, '-$line'),
      for (final line in b) DiffLine(DiffLineKind.add, '+$line'),
    ];
  }
  // LCS 长度表
  final dp = List.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  final lines = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      lines.add(DiffLine(DiffLineKind.context, ' ${a[i]}'));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      lines.add(DiffLine(DiffLineKind.del, '-${a[i]}'));
      i++;
    } else {
      lines.add(DiffLine(DiffLineKind.add, '+${b[j]}'));
      j++;
    }
  }
  while (i < a.length) {
    lines.add(DiffLine(DiffLineKind.del, '-${a[i]}'));
    i++;
  }
  while (j < b.length) {
    lines.add(DiffLine(DiffLineKind.add, '+${b[j]}'));
    j++;
  }
  return lines;
}

/// 彩色 diff 渲染:add/del 全宽着色行,@@ hunk 头,横向滚动。
class DiffView extends StatelessWidget {
  const DiffView({super.key, this.diffText, this.lines, this.maxHeight})
    : assert(diffText != null || lines != null);

  final String? diffText;
  final List<DiffLine>? lines;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final piColors = PiColors.of(context);
    final colors = Theme.of(context).colorScheme;
    final parsed = lines ?? parseUnifiedDiff(diffText!);
    final style = AppType.mono(size: 12, height: 1.45);

    Widget row(DiffLine line) {
      final (bg, fg) = switch (line.kind) {
        DiffLineKind.add => (piColors.diffAddBg, piColors.diffAddFg),
        DiffLineKind.del => (piColors.diffDelBg, piColors.diffDelFg),
        // hunk 头给一层浅底,长 diff 里才能一眼看出段落边界
        DiffLineKind.hunk => (colors.surfaceContainerHigh, piColors.diffHunkFg),
        DiffLineKind.meta => (null, colors.onSurfaceVariant),
        DiffLineKind.context => (null, colors.onSurfaceVariant),
      };
      return Container(
        width: double.infinity,
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
          line.text.isEmpty ? ' ' : line.text,
          style: style.copyWith(color: fg),
          softWrap: false,
        ),
      );
    }

    Widget body = LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 6),
                for (final line in parsed) row(line),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    );
    if (maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight!),
        child: SingleChildScrollView(child: body),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: piColors.codeWellBg,
        borderRadius: BorderRadius.circular(PiShape.md),
        border: Border.all(color: piColors.codeWellBorder),
      ),
      child: body,
    );
  }
}
