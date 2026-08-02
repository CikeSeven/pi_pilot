import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/chat_item_view.dart';
import 'package:pi_pilot/ui/chat/widgets/code_block.dart';
import 'package:pi_pilot/ui/chat/widgets/diff_view.dart';
import 'package:pi_pilot/ui/chat/widgets/markdown_body.dart';
import 'package:pi_pilot/ui/chat/widgets/streaming_cursor.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

Widget _wrap(Widget child, {required bool dark}) => ProviderScope(
  child: MaterialApp(
    theme: dark ? buildDarkTheme() : buildLightTheme(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  for (final dark in [true, false]) {
    final label = dark ? '深色' : '浅色';
    group('$label主题渲染', () {
      testWidgets('用户气泡', (tester) async {
        final item = UserItem('user:1', text: 'hi', time: DateTime(2026));
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        expect(find.text('hi'), findsOneWidget);
      });

      testWidgets('用户气泡在松散父约束下仍然贴右', (tester) async {
        // 回归:chat_body 给带时间戳的行包一个 Column,它曾经用默认的 center
        // 对齐 —— 子项拿到松散宽度,短消息的气泡收缩成内容宽后被挤到屏幕
        // 中间。现在气泡自己撑满整行,不管父级给什么约束都贴右。
        final item = UserItem(
          'user:right',
          text: '安装到手机',
          time: DateTime(2026),
        );
        await tester.pumpWidget(_wrap(
          Column(children: [ChatItemView(item: item)]), // 默认 center = 案发现场
          dark: dark,
        ));
        final bubble = tester.getRect(
          find.ancestor(
            of: find.byType(SelectableText),
            // 只有气泡的 Material 带形状,Scaffold/MaterialApp 的是平面。
            matching: find.byWidgetPredicate(
              (w) => w is Material && w.shape != null,
            ),
          ),
        );
        // 默认测试画布宽 800,UserBubble 右 padding 10 → 右缘应贴在 790。
        expect(bubble.right, moreOrLessEquals(790, epsilon: 1));
      });

      testWidgets('流式助手 → 纯文本 + 闪烁光标 widget', (tester) async {
        final item = AssistantItem('assistant:1')..text = 'partial';
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        // 光标不再是拼接的 '▍' 字符 —— 那个写法会跟着文本末尾一起跳、也不会闪。
        // 现在是独立的 StreamingCursor widget,嵌在富文本末尾的 WidgetSpan 里。
        expect(find.textContaining('partial'), findsOneWidget);
        expect(find.byType(StreamingCursor), findsOneWidget);
        expect(find.byType(PiMarkdown), findsNothing);
      });

      testWidgets('完成的助手 → Markdown', (tester) async {
        final item = AssistantItem('assistant:2')
          ..text = 'done **bold**'
          ..complete = true;
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        await tester.pumpAndSettle();
        expect(find.byType(PiMarkdown), findsOneWidget);
      });

      testWidgets('edit 工具卡渲染 DiffView', (tester) async {
        final item = ToolItem('tool:1', toolCallId: '1', name: 'edit')
          ..output = '-1 old\n+1 new'
          ..done = true;
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        await tester.tap(find.text('edit')); // 完成态默认折叠,点开
        await tester.pumpAndSettle();
        expect(find.byType(DiffView), findsOneWidget);
      });

      // 回归:多块 edit 的 output 只是 "Successfully replaced N block(s)" 文案,
      // 不含任何 diff。以前只认单块,多块会掉到默认分支把这句文案直接显示出来。
      testWidgets('多块 edit 仍渲染 DiffView 而不是成功文案', (tester) async {
        final item = ToolItem('tool:multi', toolCallId: 'm', name: 'edit')
          ..args = {
            'path': 'a.dart',
            'edits': [
              {'oldText': 'alpha', 'newText': 'ALPHA'},
              {'oldText': 'beta', 'newText': 'BETA'},
            ],
          }
          ..output = 'Successfully replaced 2 block(s) in a.dart.'
          ..done = true;
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        await tester.tap(find.text('edit'));
        await tester.pumpAndSettle();

        expect(find.byType(DiffView), findsOneWidget);
        expect(find.textContaining('Successfully replaced'), findsNothing);
        expect(find.textContaining('-alpha'), findsOneWidget);
        expect(find.textContaining('+ALPHA'), findsOneWidget);
        expect(find.textContaining('-beta'), findsOneWidget);
        expect(find.textContaining('+BETA'), findsOneWidget);
        // 两块之间应有分隔用的 hunk 头
        expect(find.textContaining('第 1/2 处修改'), findsOneWidget);
        expect(find.textContaining('第 2/2 处修改'), findsOneWidget);
      });

      testWidgets('read 工具卡渲染带行号 CodeBlock', (tester) async {
        final item = ToolItem('tool:2', toolCallId: '2', name: 'read')
          ..args = {'path': 'a.dart', 'offset': 5}
          ..output = 'line1\nline2'
          ..done = true;
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        await tester.tap(find.text('read')); // 完成态默认折叠,点开
        await tester.pumpAndSettle();
        expect(find.byType(CodeBlock), findsOneWidget);
        expect(find.text('5\n6'), findsOneWidget);
      });

      testWidgets('bash 卡与 exit 徽标', (tester) async {
        final item = BashItem('bash:1', command: 'ls -la')
          ..output = 'file'
          ..exitCode = 1
          ..done = true;
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        expect(find.text('ls -la'), findsOneWidget);
        expect(find.text('exit 1'), findsOneWidget);
      });

      testWidgets('系统提示', (tester) async {
        final item = SystemItem('sys:1', text: 'note', kind: SystemKind.error);
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        expect(find.text('note'), findsOneWidget);
      });

      testWidgets('自定义消息 todo 列表', (tester) async {
        final item = CustomItem(
          'custom:todo:1',
          customType: 'todo-state',
          text: 'fallback',
          details: {
            'todos': [
              {'text': '写代码', 'done': true},
              {'text': '写测试', 'done': false},
            ],
          },
        );
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        expect(find.text('写代码'), findsOneWidget);
        expect(find.text('写测试'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle), findsOneWidget);
      });

      testWidgets('压缩摘要可展开', (tester) async {
        final item = SummaryItem(
          'compaction:1',
          kind: 'compaction',
          summary: 'summary body',
        );
        await tester.pumpWidget(_wrap(ChatItemView(item: item), dark: dark));
        expect(find.text('summary body'), findsNothing);
        await tester.tap(find.textContaining('上下文已压缩'));
        await tester.pumpAndSettle();
        expect(find.text('summary body'), findsOneWidget);
      });
    });
  }
}
