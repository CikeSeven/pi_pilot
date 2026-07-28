import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/chat_item_view.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// relay 用 `tool_call` 钩子在插件的 `execute` 跑起来之前截下整次调用,把题目转到
/// 手机作答(见 ask_answerable_test.dart)。所以这里覆盖的是**没转过来**的那半:
/// 没手机在看、认领超时、或用户点了「在电脑上作答」。
///
/// 那种情形下只给一行交代,不再摊开一份不能点的只读问卷 —— 摊开反而让人以为
/// 「能选却选不动」。
Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Map<String, dynamic> _args() => {
  'questions': [
    {
      'question': '缓存放在哪一层?',
      'header': '缓存层',
      'options': [
        {'label': '内存 LRU', 'description': '进程内,重启即失效'},
        {'label': 'Redis', 'description': '跨进程共享,多一个依赖'},
      ],
    },
    {
      'question': '要开启哪些特性?',
      'header': '特性',
      'multiSelect': true,
      'options': [
        {'label': '压缩', 'description': '省带宽,费 CPU'},
        {
          'label': '预热',
          'description': '启动慢一点,首次请求快',
          'preview': '# 预热配置\nwarmup: true',
        },
      ],
    },
  ],
};

void main() {
  ToolItem pending() =>
      ToolItem('tool:ask', toolCallId: 'ask', name: 'ask_user_question')
        ..args = _args()
        ..argsSummary = PiSessionNotifier.debugSummarizeArgs(_args());

  group('问卷未转到手机时', () {
    // 未作答的卡片 trailing 是 CircularProgressIndicator —— 无限动画,
    // pumpAndSettle 永远等不到静止。这里推进固定时长让 AnimatedSize 展开完。
    testWidgets('只给一行交代,不摊开一份不能点的只读问卷', (tester) async {
      await tester.pumpWidget(_wrap(ChatItemView(item: pending())));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('这份问卷在电脑上作答'), findsOneWidget);
      // 回归:以前这里画整张只读问卷(题干 + 选项 + 「手机上只能查看」),
      // 让人以为能选却选不动。
      expect(find.text('缓存放在哪一层?'), findsNothing);
      expect(find.text('内存 LRU'), findsNothing);
      expect(find.textContaining('手机上只能查看'), findsNothing);
      // 也不能出现可作答那份的提交键
      expect(find.text('提交'), findsNothing);
    });

    testWidgets('作答完成后撤掉交代行,显示结果', (tester) async {
      final item = pending()
        ..output = 'Q: 缓存放在哪一层?\nA: Redis'
        ..done = true;
      await tester.pumpWidget(_wrap(ChatItemView(item: item)));
      // 完成态默认折叠
      await tester.tap(find.text('ask_user_question'));
      await tester.pumpAndSettle();

      expect(find.text('这份问卷在电脑上作答'), findsNothing);
      expect(find.textContaining('A: Redis'), findsOneWidget);
    });

    testWidgets('手机作答回来的答案剥掉给模型看的信封头,也不标红', (tester) async {
      // relay 拦截只能返回 {block, reason},pi 的 agent-loop 把 block 分支写死
      // isError: true —— 那是一次成功的作答,不能当报错渲染。
      final item = pending()
        ..output =
            'The user answered this questionnaire on their phone through '
            'PiPilot. This is a SUCCESSFUL answer, NOT an error.\n\n'
            'Q: 缓存放在哪一层?\nA: Redis'
        ..done = true
        ..isError = true;
      await tester.pumpWidget(_wrap(ChatItemView(item: item)));
      await tester.tap(find.text('ask_user_question'));
      await tester.pumpAndSettle();

      expect(find.textContaining('A: Redis'), findsOneWidget);
      // 信封头是写给模型的,用户不必读
      expect(find.textContaining('SUCCESSFUL answer'), findsNothing);
      // 不套错误图标
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('参数丢失时回落到普通工具卡,不崩', (tester) async {
      // 历史 toolResult 常常没有 args,断层重放同理
      final item =
          ToolItem('tool:bare', toolCallId: 'bare', name: 'ask_user_question')
            ..output = 'A: Redis'
            ..done = true;
      await tester.pumpWidget(_wrap(ChatItemView(item: item)));
      await tester.tap(find.text('ask_user_question'));
      await tester.pumpAndSettle();

      expect(find.textContaining('A: Redis'), findsOneWidget);
      expect(find.text('这份问卷在电脑上作答'), findsNothing);
    });
  });

  group('问卷副行摘要', () {
    test('取题目的 header 拼接,不把整个 Map 塞进副行', () {
      final summary = PiSessionNotifier.debugSummarizeArgs(_args());
      expect(summary, '缓存层 · 特性');
      // 回归:通用分支会输出 "questions: [{question: ..., header: ...}]"
      expect(summary, isNot(contains('question:')));
      expect(summary, isNot(contains('{')));
    });

    test('没有 header 时退回计数', () {
      final summary = PiSessionNotifier.debugSummarizeArgs({
        'questions': [
          {'question': 'a'},
          {'question': 'b'},
        ],
      });
      expect(summary, '2 个问题');
    });

    test('questions 不是列表时交回通用分支', () {
      expect(
        PiSessionNotifier.debugSummarizeArgs({'path': 'a.dart'}),
        'a.dart',
      );
      expect(
        PiSessionNotifier.debugSummarizeArgs({'questions': 'oops'}),
        contains('questions'),
      );
    });
  });
}
