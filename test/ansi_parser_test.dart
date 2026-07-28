import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/ansi_text.dart';
import 'package:pi_pilot/ui/theme/semantic_colors.dart';

void main() {
  const base = TextStyle(color: Colors.white);
  final ansi16 = PiColors.dark.ansi;

  List<TextSpan> spansOf(String input) =>
      parseAnsi(input, base, ansi16).children!.cast<TextSpan>();

  group('parseAnsi', () {
    test('无转义时原样输出', () {
      final spans = spansOf('hello');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'hello');
      expect(spans.single.style?.color, Colors.white);
    });

    test('标准前景色 31 → 红', () {
      final spans = spansOf('\x1B[31mred\x1B[0mplain');
      expect(spans[0].text, 'red');
      expect(spans[0].style?.color, ansi16[1]);
      expect(spans[1].text, 'plain');
      expect(spans[1].style?.color, Colors.white);
    });

    test('亮色 92 → bright green', () {
      final spans = spansOf('\x1B[92mok');
      expect(spans.single.style?.color, ansi16[10]);
    });

    test('粗体/斜体/下划线与取消', () {
      final spans = spansOf('\x1B[1;3;4mx\x1B[22;23;24my');
      expect(spans[0].style?.fontWeight, FontWeight.bold);
      expect(spans[0].style?.fontStyle, FontStyle.italic);
      expect(spans[0].style?.decoration, TextDecoration.underline);
      expect(spans[1].style?.fontWeight, isNot(FontWeight.bold));
    });

    test('组合参数 1;31 同时生效', () {
      final spans = spansOf('\x1B[1;31mboldred');
      expect(spans.single.style?.fontWeight, FontWeight.bold);
      expect(spans.single.style?.color, ansi16[1]);
    });

    test('xterm256 前景 38;5;n', () {
      final spans = spansOf('\x1B[38;5;196mx');
      expect(spans.single.style?.color, const Color(0xFFFF0000));
    });

    test('xterm256 灰度带', () {
      final spans = spansOf('\x1B[38;5;232mx');
      expect(spans.single.style?.color, const Color(0xFF080808));
    });

    test('truecolor 38;2;r;g;b', () {
      final spans = spansOf('\x1B[38;2;18;52;86mx');
      expect(spans.single.style?.color, const Color(0xFF123456));
    });

    test('背景色 41 与 49 复位', () {
      final spans = spansOf('\x1B[41mbg\x1B[49mnone');
      expect(spans[0].style?.backgroundColor, ansi16[1]);
      expect(spans[1].style?.backgroundColor, isNull);
    });

    test('非 SGR CSI(光标/清屏)被剥离', () {
      final spans = spansOf('a\x1B[2Kb\x1B[1Ac');
      expect(spans.map((s) => s.text).join(), 'abc');
    });
  });

  test('stripAnsi 去掉全部转义', () {
    expect(stripAnsi('\x1B[31mred\x1B[0m \x1B[2K!'), 'red !');
  });
}
