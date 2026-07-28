import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/ansi_text.dart';

/// 思考内容里混进了终端转义序列。
///
/// 来源不是 PiPilot —— 是第三方 pi 扩展 `pi-tool-display` 用终端主题色
/// (tokyo-night：accent `#7aa2f7` = `38;2;122;162;247`)重写了 thinking 文本，
/// 并且在 `message_end` 时把这些转义**写进了会话 JSONL**。所以 headless、
/// 桌面 relay、历史回放三条路全都带着它，只能在渲染层清。
void main() {
  const esc = '\x1B';

  group('sanitizeThinking', () {
    test('清掉真实样本里的真彩转义与 Thinking 前缀', () {
      // 用户实际看到的那一串
      const raw =
          '$esc[38;2;122;162;247mThinking:$esc[39m '
          '$esc[38;2;86;95;137m**Planning project inspection and orientation**'
          '$esc[39m';
      expect(
        sanitizeThinking(raw),
        '**Planning project inspection and orientation**',
      );
    });

    test('16 色与 256 色转义同样清掉', () {
      expect(sanitizeThinking('$esc[38;5;14mThinking: 分析$esc[39m'), '分析');
      expect(sanitizeThinking('$esc[36m$esc[1m推理$esc[0m'), '推理');
    });

    test('中英文冒号的前缀都认', () {
      expect(sanitizeThinking('Thinking: 一二三'), '一二三');
      expect(sanitizeThinking('Thinking：一二三'), '一二三');
      expect(sanitizeThinking('thinking:  一二三'), '一二三');
    });

    test('只去掉开头的前缀,正文里的同名词保留', () {
      expect(
        sanitizeThinking('Thinking: I was thinking: maybe not'),
        'I was thinking: maybe not',
      );
    });

    test('本来就干净的文本原样返回', () {
      expect(sanitizeThinking('先看目录结构'), '先看目录结构');
      expect(sanitizeThinking(''), '');
    });

    test('首尾空白一并收掉', () {
      expect(sanitizeThinking('  $esc[36m 内容 $esc[39m  '), '内容');
    });
  });
}
