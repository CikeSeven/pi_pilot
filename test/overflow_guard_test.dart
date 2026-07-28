import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/chat_item_view.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// 长内容不许把布局撑爆。
///
/// 之前 `ToolCard` 把完整的 bash 命令塞进 `MessageCard` 的 `trailing`,而
/// `RenderFlex` 先用 `maxWidth: infinity` 布局所有**非 flex** 子节点 ——
/// 于是 trailing 内部的 `Flexible` 因 `canFlex == false` 退化成普通节点,
/// 它上面的 `maxLines: 1` + `ellipsis` 变成死代码,文本按完整固有宽度渲染。
/// 400dp 屏上一条 120 字符的命令溢出 588px,同时把工具名挤成 0dp。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 手机常见的窄屏。溢出是宽度问题,窄屏才暴露得出来。
  Future<void> pumpNarrow(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final longCommand =
      'find /home/user/projects -type f -name "*.dart" -not -path "*/build/*" '
      '-exec grep -Hn "TODO" {} \\; | sort -u | head -50';

  testWidgets('超长 bash 命令的工具卡不溢出', (tester) async {
    final item = ToolItem('tool:long', toolCallId: 'x', name: 'bash')
      // argsSummary 是独立字段,pi_session 用 _summarizeArgs 填。
      // 只设 args 不会填充它,那样测试根本触发不到溢出路径。
      ..argsSummary = longCommand
      ..args = {'command': longCommand}
      ..output = 'done'
      ..done = true;
    await pumpNarrow(tester, ChatItemView(item: item));

    expect(tester.takeException(), isNull);
    // 工具名不能被挤没 —— 那是同一个 bug 的次要症状
    expect(find.text('bash'), findsOneWidget);
  });

  testWidgets('超长文件路径的工具卡不溢出', (tester) async {
    const longPath =
        '/home/user/very/deeply/nested/project/structure/that/keeps/going/'
        'and/going/lib/src/features/authentication/data/repositories/'
        'remote_user_repository_implementation.dart';
    final item = ToolItem('tool:path', toolCallId: 'y', name: 'read')
      ..argsSummary = longPath
      ..args = {
        'path':
            '/home/user/very/deeply/nested/project/structure/that/keeps/going/'
            'and/going/lib/src/features/authentication/data/repositories/'
            'remote_user_repository_implementation.dart',
      }
      ..output = 'line'
      ..done = true;
    await pumpNarrow(tester, ChatItemView(item: item));

    expect(tester.takeException(), isNull);
    expect(find.text('read'), findsOneWidget);
  });

  testWidgets('超长命令的 bash 卡不溢出', (tester) async {
    final item = BashItem('bash:long', command: longCommand)
      ..output = 'x'
      ..exitCode = 1
      ..done = true;
    await pumpNarrow(tester, ChatItemView(item: item));

    expect(tester.takeException(), isNull);
    expect(find.text('exit 1'), findsOneWidget);
  });

  testWidgets('没有空格的超长串(URL / base64)也不溢出', (tester) async {
    // 无空白字符 = 无法换行,是最恶劣的情况
    final item = ToolItem('tool:url', toolCallId: 'z', name: 'fetch')
      ..argsSummary = 'https://example.com/${'a' * 300}'
      ..args = {'path': 'https://example.com/${'a' * 300}'}
      ..done = true;
    await pumpNarrow(tester, ChatItemView(item: item));

    expect(tester.takeException(), isNull);
  });

  /// trailing 曾经和标题列一样是 flex 子节点(两边 flex 因子都是 1),
  /// `RenderFlex` 于是把可用宽度**对半分**:标题只拿到一半、提前 ellipsis,
  /// 状态图标与展开箭头停在卡片正中间而不是行尾。
  ///
  /// 这里量的是几何位置,不是「有没有抛异常」—— 那个 bug 从不抛异常。
  testWidgets('状态位贴在身份行最右侧,而不是中间', (tester) async {
    final item = ToolItem('tool:right', toolCallId: 'r', name: 'bash')
      ..argsSummary = 'cd /home/sisct/Code/projects/FlutterProjects/PiPilot'
      ..args = {'command': 'cd /home/sisct/Code'}
      ..output = 'ok'
      ..done = true;
    await pumpNarrow(tester, ChatItemView(item: item));

    final cardRight = tester.getRect(find.byType(Card)).right;
    final check = tester.getRect(find.byIcon(Icons.check_circle_outline));
    final chevron = tester.getRect(find.byIcon(Icons.expand_more));

    // 箭头是行内最后一个元素:离卡片右缘不超过 padding(8) + 少量容差
    expect(cardRight - chevron.right, lessThan(16));
    // 顺序正确:状态图标在箭头左侧,两者都在卡片右半区
    expect(check.right, lessThan(chevron.left));
    expect(check.left, greaterThan(cardRight * 0.6));
  });

  testWidgets('长命令的标题拿到身份行的大部分宽度', (tester) async {
    // 对半分的症状之一:标题列只有 ~50% 宽。至少要拿到 55%。
    final item = ToolItem('tool:width', toolCallId: 'w', name: 'bash')
      ..argsSummary = longCommand
      ..args = {'command': longCommand}
      ..output = 'ok'
      ..done = true;
    await pumpNarrow(tester, ChatItemView(item: item));

    final cardWidth = tester.getRect(find.byType(Card)).width;
    final titleWidth = tester.getRect(find.text(longCommand)).width;
    expect(titleWidth, greaterThan(cardWidth * 0.55));
  });

  testWidgets('markdown 围栏带属性时代码块头部不溢出', (tester) async {
    final item = AssistantItem('assistant:fence')
      ..text =
          '```json title="a-very-long-attribute-string-that-would-overflow" '
          'highlight="1-20"\n{"a":1}\n```'
      ..complete = true;
    await pumpNarrow(tester, ChatItemView(item: item));

    expect(tester.takeException(), isNull);
    // 只取第一个 token 当语言名
    expect(find.text('json'), findsOneWidget);
  });
}
