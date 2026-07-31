import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/code_block.dart';
import 'package:pi_pilot/ui/chat/widgets/diff_view.dart';
import 'package:pi_pilot/ui/chat/widgets/tool_card.dart';
import 'package:pi_pilot/ui/chat/widgets/tool_group_card.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// 工具组胶囊必须是**唯一**的展开开关。
///
/// 以前展开区为每个工具再套一张 `ToolCard`(自带 Card 外壳 + 自己的折叠态),
/// 于是变成「胶囊点开 → 大卡片 → 再点一次才看到输出」三层。用户看到的
/// 「小卡片下面又有一个大卡片」就是这两层壳。现在点一次胶囊就该直接看到
/// 命令与执行结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 执行中的工具带一个 `CircularProgressIndicator` —— 那是**无限动画**,
  /// `pumpAndSettle` 永远等不到静止,只会超时。所以未完成态一律用固定次数的
  /// `pump` 推进,别用 settle。
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    AskRequest? ask,
    bool settle = true,
    Size size = const Size(400, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          piSessionProvider.overrideWith(
            (ref) => PiState.initial().copyWith(pendingAsk: ask),
          ),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // 折叠动画 300ms:推够时间让展开区落到终态,又不等 spinner。
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  ToolItem done(
    String id, {
    required String name,
    String argsSummary = '',
    Map<String, dynamic>? args,
    String output = '',
    bool isError = false,
  }) =>
      ToolItem('tool:$id', toolCallId: id, name: name)
        ..argsSummary = argsSummary
        ..args = args
        ..output = output
        ..isError = isError
        ..done = true;

  testWidgets('完成态默认只显示摘要,不显示输出', (tester) async {
    final tool = done(
      'a',
      name: 'bash',
      argsSummary: 'ls -la',
      args: {'command': 'ls -la'},
      output: 'total 4\nfile.txt',
    );
    await pump(tester, ToolGroupCard(tools: [tool]));

    // 折叠态:胶囊摘要在,输出不在。
    expect(find.textContaining('bash'), findsOneWidget);
    expect(find.textContaining('file.txt'), findsNothing);
  });

  testWidgets('点一次胶囊就能看到命令和执行结果', (tester) async {
    final tool = done(
      'a',
      name: 'bash',
      argsSummary: 'echo hello',
      args: {'command': 'echo hello'},
      output: 'hello-from-output',
    );
    await pump(tester, ToolGroupCard(tools: [tool]));

    await tester.tap(find.textContaining('echo hello'));
    await tester.pumpAndSettle();

    // 展开一次即可:命令(参数摘要)和执行结果同时可见,不需要第二次点击。
    expect(find.text('echo hello'), findsWidgets);
    expect(find.textContaining('hello-from-output'), findsOneWidget);
  });

  testWidgets('展开后树里不再有 ToolCard(不是卡中卡)', (tester) async {
    final tool = done('a', name: 'bash', argsSummary: 'pwd', output: '/tmp');
    await pump(tester, ToolGroupCard(tools: [tool]));

    await tester.tap(find.textContaining('pwd'));
    await tester.pumpAndSettle();

    expect(find.textContaining('/tmp'), findsOneWidget);
    // 关键回归:展开区不能再嵌 ToolCard —— 那正是被删掉的「下面那张大卡片」。
    expect(find.byType(ToolCard), findsNothing);
    // 也不该出现任何 Card 外壳(工具组自己不套 Card)。
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('多工具:每个工具的名称、参数与输出同时可见', (tester) async {
    final tools = [
      done('a', name: 'bash', argsSummary: 'uname -a', output: 'Linux-out'),
      done('b', name: 'ls', argsSummary: '/etc', output: 'passwd-out'),
    ];
    await pump(tester, ToolGroupCard(tools: tools));

    await tester.tap(find.textContaining('使用了 2 个工具'));
    await tester.pumpAndSettle();

    expect(find.text('bash'), findsOneWidget);
    expect(find.text('ls'), findsOneWidget);
    expect(find.text('uname -a'), findsOneWidget);
    expect(find.text('/etc'), findsOneWidget);
    // 两个工具的输出都要在,不能只展开第一个。
    expect(find.textContaining('Linux-out'), findsOneWidget);
    expect(find.textContaining('passwd-out'), findsOneWidget);
    expect(find.byType(ToolCard), findsNothing);
  });

  testWidgets('结构化渲染仍然生效:read 走 CodeBlock,edit 走 DiffView', (tester) async {
    final tools = [
      done(
        'a',
        name: 'read',
        argsSummary: 'a.dart',
        args: {'path': 'a.dart', 'offset': 5},
        output: 'line1\nline2',
      ),
      done('b', name: 'edit', argsSummary: 'b.dart', output: '-1 old\n+1 new'),
    ];
    await pump(tester, ToolGroupCard(tools: tools));

    await tester.tap(find.textContaining('使用了 2 个工具'));
    await tester.pumpAndSettle();

    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.byType(DiffView), findsOneWidget);
    // read 的行号从 offset 起算,和独立工具卡一致。
    expect(find.text('5\n6'), findsOneWidget);
  });

  testWidgets('执行中强制展开:实时进度不藏在折叠态里', (tester) async {
    final running = ToolItem('tool:r', toolCallId: 'r', name: 'bash')
      ..argsSummary = 'sleep 1'
      ..output = 'partial-out';
    await pump(tester, ToolGroupCard(tools: [running]), settle: false);

    // 没点任何东西,输出就该已经可见。
    expect(find.textContaining('正在执行 bash'), findsOneWidget);
    expect(find.textContaining('partial-out'), findsOneWidget);
  });

  testWidgets('statOnly 统计胶囊不可展开', (tester) async {
    final tool = done('a', name: 'bash', argsSummary: 'pwd', output: '/tmp');
    await pump(tester, ToolGroupCard(tools: [tool], statOnly: true));

    await tester.tap(find.textContaining('pwd'));
    await tester.pumpAndSettle();

    // 轮尾统计行只报数量:执行详情已在消息流原位,不该在这里重复一遍。
    expect(find.textContaining('/tmp'), findsNothing);
    expect(find.byType(ToolCard), findsNothing);
  });

  testWidgets('工具组里的问卷仍然可作答', (tester) async {
    final ask = AskRequest(
      requestId: 'ask:1',
      toolCallId: 'q1',
      questions: const [
        AskQuestion(
          question: '缓存放在哪一层?',
          header: '缓存层',
          options: [
            AskOption(label: '内存 LRU', description: '进程内,重启即失效'),
            AskOption(label: 'Redis', description: '跨进程共享,多一个依赖'),
          ],
        ),
      ],
    );
    final pending = ToolItem(
      'tool:q1',
      toolCallId: 'q1',
      name: 'ask_user_question',
    );
    await pump(
      tester,
      ToolGroupCard(tools: [pending]),
      ask: ask,
      settle: false,
    );

    // 未完成的问卷落在 _anyRunning 里 → 胶囊强制展开,题目与选项直接可见。
    expect(find.text('缓存放在哪一层?'), findsOneWidget);
    expect(find.text('内存 LRU'), findsOneWidget);
    expect(find.text('提交'), findsOneWidget);

    // 选项可以点(可作答,不是只读副本)。
    await tester.tap(find.text('Redis'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长命令在工具组里不溢出', (tester) async {
    final longCommand =
        'find /home/user/projects -type f -name "*.dart" -not -path "*/build/*" '
        '-exec grep -Hn "TODO" {} \\; | sort -u | head -50';
    final tool = done(
      'a',
      name: 'bash',
      argsSummary: longCommand,
      args: {'command': longCommand},
      output: 'ok',
    );
    await pump(tester, ToolGroupCard(tools: [tool]));

    await tester.tap(find.textContaining('find /home/user'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('bash'), findsOneWidget);
  });
}
