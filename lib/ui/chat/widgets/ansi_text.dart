import 'package:flutter/material.dart';

import '../../theme/semantic_colors.dart';

/// CSI 序列(ESC[ ... 终结字节)。非 SGR(终结字节非 m)一律剥离不渲染。
final _csi = RegExp('\x1B\\[([0-9;?]*)([A-Za-z])');

/// 去掉所有 ANSI 转义(复制/纯文本场景用)。
String stripAnsi(String input) => input.replaceAll(_csi, '');

/// 「Thinking:」及其变体的前缀,可能带尾随空白。
final _thinkingPrefix = RegExp(r'^\s*thinking\s*[:：]\s*', caseSensitive: false);

/// 清洗思考内容。
///
/// pi 的第三方扩展 `pi-tool-display` 会用终端主题色重写 thinking 文本
/// (`thinking-label.ts` 里的 `theme.fg(...)`),而且在 `message_end` 时把这些
/// 转义**持久化进会话 JSONL** —— 所以 headless、桌面 relay、历史回放三条路
/// 全都带着它,只能在渲染层清。
///
/// 这里选剥离而不是用 `AnsiText` 上色:那些颜色来自终端主题(tokyo-night),
/// 塞进 Material 界面会和 6 个强调色全部打架;而思考内容按设计就该是弱化的
/// 灰斜体,上色反而抢戏。前缀 `Thinking:` 也和我们自己的标题重复。
String sanitizeThinking(String raw) =>
    stripAnsi(raw).replaceFirst(_thinkingPrefix, '').trim();

class _SgrState {
  Color? fg;
  Color? bg;
  bool bold = false;
  bool italic = false;
  bool underline = false;

  void reset() {
    fg = null;
    bg = null;
    bold = false;
    italic = false;
    underline = false;
  }

  TextStyle apply(TextStyle base) => base.copyWith(
    color: fg ?? base.color,
    backgroundColor: bg ?? base.backgroundColor,
    fontWeight: bold ? FontWeight.bold : base.fontWeight,
    fontStyle: italic ? FontStyle.italic : base.fontStyle,
    decoration: underline ? TextDecoration.underline : base.decoration,
  );
}

/// 解析 SGR 着色文本为 TextSpan。[ansi16] 为 SGR 30-37/90-97 色板。
TextSpan parseAnsi(String input, TextStyle base, List<Color> ansi16) {
  final children = <TextSpan>[];
  final sgr = _SgrState();
  var last = 0;
  void flushText(int end) {
    if (end > last) {
      children.add(
        TextSpan(text: input.substring(last, end), style: sgr.apply(base)),
      );
    }
  }

  for (final m in _csi.allMatches(input)) {
    flushText(m.start);
    last = m.end;
    if (m[2] != 'm') continue;
    final params = (m[1]!.isEmpty ? '0' : m[1]!)
        .split(';')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    var i = 0;
    while (i < params.length) {
      final code = params[i];
      switch (code) {
        case 0:
          sgr.reset();
        case 1:
          sgr.bold = true;
        case 3:
          sgr.italic = true;
        case 4:
          sgr.underline = true;
        case 22:
          sgr.bold = false;
        case 23:
          sgr.italic = false;
        case 24:
          sgr.underline = false;
        case 39:
          sgr.fg = null;
        case 49:
          sgr.bg = null;
        case >= 30 && <= 37:
          sgr.fg = ansi16[code - 30];
        case >= 90 && <= 97:
          sgr.fg = ansi16[code - 82];
        case >= 40 && <= 47:
          sgr.bg = ansi16[code - 40];
        case >= 100 && <= 107:
          sgr.bg = ansi16[code - 92];
        case 38 || 48:
          final (color, consumed) = _extendedColor(params, i, ansi16);
          if (code == 38) {
            sgr.fg = color ?? sgr.fg;
          } else {
            sgr.bg = color ?? sgr.bg;
          }
          i += consumed;
        default:
          break;
      }
      i++;
    }
  }
  flushText(input.length);
  return TextSpan(children: children);
}

/// 38;5;n(xterm256)/ 38;2;r;g;b(truecolor)。返回 (颜色, 额外消耗的参数个数)。
(Color?, int) _extendedColor(List<int> params, int i, List<Color> ansi16) {
  if (i + 1 >= params.length) return (null, 0);
  switch (params[i + 1]) {
    case 5:
      if (i + 2 >= params.length) return (null, 1);
      return (_xterm256(params[i + 2], ansi16), 2);
    case 2:
      if (i + 4 >= params.length) return (null, params.length - i - 1);
      return (
        Color.fromARGB(
          255,
          params[i + 2].clamp(0, 255),
          params[i + 3].clamp(0, 255),
          params[i + 4].clamp(0, 255),
        ),
        4,
      );
    default:
      return (null, 0);
  }
}

Color? _xterm256(int n, List<Color> ansi16) {
  if (n < 0 || n > 255) return null;
  if (n < 16) return ansi16[n];
  if (n < 232) {
    // 6×6×6 色立方
    final v = n - 16;
    const steps = [0, 95, 135, 175, 215, 255];
    return Color.fromARGB(
      255,
      steps[v ~/ 36],
      steps[(v % 36) ~/ 6],
      steps[v % 6],
    );
  }
  final gray = 8 + (n - 232) * 10;
  return Color.fromARGB(255, gray, gray, gray);
}

/// 带 ANSI 着色的可选中文本;按 (text, brightness) 记忆化解析结果。
class AnsiText extends StatefulWidget {
  const AnsiText({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<AnsiText> createState() => _AnsiTextState();
}

class _AnsiTextState extends State<AnsiText> {
  TextSpan? _span;
  String? _parsedText;
  Brightness? _parsedBrightness;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    if (_span == null ||
        _parsedText != widget.text ||
        _parsedBrightness != brightness) {
      _span = parseAnsi(widget.text, widget.style, PiColors.of(context).ansi);
      _parsedText = widget.text;
      _parsedBrightness = brightness;
    }
    return SelectableText.rich(_span!);
  }
}
