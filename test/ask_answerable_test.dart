import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/chat_item_view.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// relay 用 `tool_call` 钩子在插件的 `execute` 跑起来**之前**截下整次调用,
/// 把题目经 hub 转到手机。所以手机上这张卡必须是**可作答**的,而不是只读的。
///
/// 认账靠 toolCallId:接错卡等于把问卷画到别的工具上,所以不匹配时必须
/// 老老实实退回只读渲染。
///
/// 多设备改造后 piSessionProvider 是「当前设备状态」代理(`Provider<PiState>`),
/// 渲染类测试直接给它一个假状态即可,不需要假 notifier。
Widget _wrap(ChatItem item, {AskRequest? ask}) => ProviderScope(
  overrides: [
    piSessionProvider.overrideWith(
      (ref) => PiState.initial().copyWith(pendingAsk: ask),
    ),
  ],
  child: MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: SingleChildScrollView(child: ChatItemView(item: item)),
    ),
  ),
);

AskRequest _ask({String toolCallId = 'call-1'}) => AskRequest(
  requestId: 'ask:1',
  toolCallId: toolCallId,
  questions: const [
    AskQuestion(
      question: '缓存放在哪一层?',
      header: '缓存层',
      options: [
        AskOption(label: '内存 LRU', description: '进程内,重启即失效'),
        AskOption(label: 'Redis', description: '跨进程共享,多一个依赖'),
      ],
    ),
    AskQuestion(
      question: '要开启哪些特性?',
      header: '特性',
      multiSelect: true,
      options: [
        AskOption(label: '压缩', description: '省带宽,费 CPU'),
        AskOption(label: '预热', description: '启动慢一点', hasPreview: true),
      ],
    ),
  ],
);

ToolItem _pending({String toolCallId = 'call-1'}) => ToolItem(
  'tool:$toolCallId',
  toolCallId: toolCallId,
  name: 'ask_user_question',
);

void main() {
  group('可作答问卷卡', () {
    testWidgets('转到手机时渲染可点选项与提交按钮', (tester) async {
      await tester.pumpWidget(_wrap(_pending(), ask: _ask()));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('电脑端在等这份问卷'), findsOneWidget);
      expect(find.text('缓存放在哪一层?'), findsOneWidget);
      expect(find.text('Redis'), findsOneWidget);
      expect(find.text('提交'), findsOneWidget);
      expect(find.text('在电脑上作答'), findsOneWidget);
      // 单选题给 radio,多选题给 checkbox
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
      expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(2));
      // 只读版的「只能查看」提示不能出现
      expect(find.textContaining('手机上只能查看'), findsNothing);
    });

    testWidgets('答满所有题之前提交键不可用', (tester) async {
      await tester.pumpWidget(_wrap(_pending(), ask: _ask()));
      await tester.pump(const Duration(milliseconds: 400));

      FilledButton submit() => tester.widget<FilledButton>(
        find.ancestor(of: find.text('提交'), matching: find.byType(FilledButton)),
      );
      expect(submit().onPressed, isNull, reason: '一题都没答');

      await tester.tap(find.text('Redis'));
      await tester.pump();
      expect(submit().onPressed, isNull, reason: '第二题还没答');

      await tester.tap(find.text('压缩'));
      await tester.pump();
      expect(submit().onPressed, isNotNull, reason: '两题都答了');
    });

    testWidgets('单选题改选会顶掉前一个,多选题可以叠加', (tester) async {
      await tester.pumpWidget(_wrap(_pending(), ask: _ask()));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('内存 LRU'));
      await tester.pump();
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

      await tester.tap(find.text('Redis'));
      await tester.pump();
      // 仍然只有一个选中 —— 单选题不能同时选两个
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

      await tester.tap(find.text('压缩'));
      await tester.tap(find.text('预热'));
      await tester.pump();
      expect(find.byIcon(Icons.check_box), findsNWidgets(2));
    });

    testWidgets('自定义输入折叠着,点开后单独能满足一道题', (tester) async {
      await tester.pumpWidget(_wrap(_pending(), ask: _ask()));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('自己写一条').first);
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);

      // 第一题只写自定义文本、第二题勾一个,就该能提交
      await tester.enterText(find.byType(TextField), '直接不做缓存');
      await tester.tap(find.text('压缩'));
      await tester.pump();
      final submit = tester.widget<FilledButton>(
        find.ancestor(of: find.text('提交'), matching: find.byType(FilledButton)),
      );
      expect(submit.onPressed, isNotNull);
    });

    testWidgets('toolCallId 对不上时不作答,不把问卷接到别的卡上', (tester) async {
      // 在途问卷属于另一次调用
      await tester.pumpWidget(
        _wrap(
          _pending(toolCallId: 'call-1'),
          ask: _ask(toolCallId: 'call-9'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('提交'), findsNothing);
      expect(find.textContaining('电脑端在等这份问卷'), findsNothing);
    });

    testWidgets('没有在途问卷时是普通的等待卡', (tester) async {
      await tester.pumpWidget(_wrap(_pending()));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('提交'), findsNothing);
    });
  });

  group('问卷参数解析', () {
    test('读出题干、header、多选与选项', () {
      final parsed = PiSessionNotifier.debugParseAskQuestions([
        {
          'question': '缓存放在哪一层?',
          'header': '缓存层',
          'multiSelect': true,
          'options': [
            {'label': 'Redis', 'description': '跨进程', 'preview': '# 配置'},
          ],
        },
      ]);
      expect(parsed, hasLength(1));
      expect(parsed.single.question, '缓存放在哪一层?');
      expect(parsed.single.header, '缓存层');
      expect(parsed.single.multiSelect, isTrue);
      expect(parsed.single.options.single.label, 'Redis');
      expect(parsed.single.options.single.description, '跨进程');
      expect(parsed.single.options.single.hasPreview, isTrue);
    });

    test('丢掉没有选项或没有题干的题(那种题手机上答不了)', () {
      final parsed = PiSessionNotifier.debugParseAskQuestions([
        {'question': '没有选项'},
        {
          'question': '',
          'options': [
            {'label': 'x'},
          ],
        },
        {
          'question': '好题',
          'options': [
            {'label': 'ok'},
          ],
        },
      ]);
      expect(parsed.map((q) => q.question), ['好题']);
    });

    test('形状不对时给空列表,不抛', () {
      expect(PiSessionNotifier.debugParseAskQuestions(null), isEmpty);
      expect(PiSessionNotifier.debugParseAskQuestions('oops'), isEmpty);
      expect(PiSessionNotifier.debugParseAskQuestions([1, 'a', null]), isEmpty);
    });
  });
}
