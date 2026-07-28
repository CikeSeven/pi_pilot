import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/chat_item_view.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// 插件 `@juicesharp/rpiv-ask-user-question` 的问卷是电脑端 TUI 的覆盖层
/// (`ctx.ui.custom()`),不走 pi 的 select/confirm/input/editor 对话框协议,
/// 所以手机收不到 `extension_ui_request`,也没有任何可编程应答入口。
///
/// 但题目和选项本来就随 `tool_execution_start` 的 args 一起到了手机 ——
/// 以前没人渲染,卡片上只剩一个转不完的圈,看不出在等人作答。
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

  group('问卷工具卡', () {
    // 未作答的卡片 trailing 是 CircularProgressIndicator —— 无限动画,
    // pumpAndSettle 永远等不到静止。这里推进固定时长让 AnimatedSize 展开完。
    testWidgets('未作答时展开显示全部题目与选项,而不是一个空转的圈', (tester) async {
      await tester.pumpWidget(_wrap(ChatItemView(item: pending())));
      await tester.pump(const Duration(milliseconds: 400));

      // 题干
      expect(find.text('缓存放在哪一层?'), findsOneWidget);
      expect(find.text('要开启哪些特性?'), findsOneWidget);
      // 选项标签与说明
      expect(find.text('内存 LRU'), findsOneWidget);
      expect(find.text('进程内,重启即失效'), findsOneWidget);
      expect(find.text('Redis'), findsOneWidget);
      // header 标签与多选标记
      expect(find.text('缓存层'), findsOneWidget);
      expect(find.text('可多选'), findsOneWidget);
      // 带 preview 的选项要标出来(预览内容只有电脑上看得到)
      expect(find.text('含预览'), findsOneWidget);
    });

    testWidgets('未作答时明确告知只能在电脑上回答', (tester) async {
      await tester.pumpWidget(_wrap(ChatItemView(item: pending())));
      await tester.pump(const Duration(milliseconds: 400));

      // 手机上无法应答是硬约束(插件没有可编程应答入口),必须说清楚,
      // 否则用户会一直等这张卡自己动。
      expect(find.textContaining('电脑端正在等你作答'), findsOneWidget);
    });

    testWidgets('作答完成后撤掉等待提示并显示结果', (tester) async {
      final item = pending()
        ..output = 'Question: 缓存放在哪一层?\nAnswer: Redis'
        ..done = true;
      await tester.pumpWidget(_wrap(ChatItemView(item: item)));
      // 完成态默认折叠
      await tester.tap(find.text('ask_user_question'));
      await tester.pumpAndSettle();

      expect(find.textContaining('电脑端正在等你作答'), findsNothing);
      expect(find.textContaining('Answer: Redis'), findsOneWidget);
      // 题目仍然留着,便于对照模型问了什么
      expect(find.text('缓存放在哪一层?'), findsOneWidget);
    });

    testWidgets('参数丢失时回落到普通工具卡,不崩也不显示空问卷', (tester) async {
      // 历史 toolResult 常常没有 args,断层重放同理
      final item =
          ToolItem('tool:bare', toolCallId: 'bare', name: 'ask_user_question')
            ..output = 'Answer: Redis'
            ..done = true;
      await tester.pumpWidget(_wrap(ChatItemView(item: item)));
      await tester.tap(find.text('ask_user_question'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Answer: Redis'), findsOneWidget);
      expect(find.textContaining('电脑端正在等你作答'), findsNothing);
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
