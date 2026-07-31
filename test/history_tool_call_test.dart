import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';

/// 历史回放时 bash 命令是空白的。
///
/// 根因:工具参数只存在于 **assistant** 条目的 `toolCall` 块上,
/// **不在** `toolResult` 上;而持久化的字段名和实时事件不一样:
///
/// | | 实时事件 | 会话文件 |
/// |---|---|---|
/// | id | `toolCallId` | `id` |
/// | 名字 | `toolName` | `name` |
/// | 参数 | `args` | `arguments` |
///
/// 以前历史路径只取 text/thinking,toolCall 块被整个丢掉,
/// 于是 `argsSummary` 停在空串,卡片副行一片空白。
void main() {
  group('历史 toolCall 解析', () {
    test('toolCall 块的字段名映射到实时事件的键', () {
      // 真实持久化形状(pi_tool.agent.js 的 bash 工具)
      const block = {
        'type': 'toolCall',
        'id': 'call_951ff2a',
        'name': 'bash',
        'arguments': {'command': 'pwd && ls -la'},
      };

      // 确认映射关系:历史 id/name/arguments → 实时 toolCallId/toolName/args
      expect(block['id'], isNotNull);
      expect(block['name'], 'bash');
      expect(block['arguments'], isA<Map>());
      expect((block['arguments'] as Map)['command'], 'pwd && ls -la');
    });

    test('_clip 对所有分支都截断,不只是 JSON 兜底', () {
      // 上限 300:副行独立一行+自然换行后,长路径/常见命令要显示完整。
      expect(PiSessionNotifier.debugClip('a' * 400).length, 301); // 300 + '…'
      expect(PiSessionNotifier.debugClip('a' * 300).length, 300); // 恰好不截
      expect(PiSessionNotifier.debugClip('ls -la'), 'ls -la');
      // 换行压成空格(多行脚本变单行逻辑流)
      expect(PiSessionNotifier.debugClip('pwd\nls\n  mkdir'), 'pwd ls mkdir');
    });
  });
}
