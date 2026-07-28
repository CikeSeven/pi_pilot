import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/chat_item_view.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// todo 列表的适配。
///
/// pi 真实发的是 `customType: "todo-progress-state"`,字段是
/// `status: "todo"|"partial"|"done"`。之前只把 `status == 'completed'`
/// 当完成,而 pi 用的是 **`done`** —— 线上每一条已完成任务都渲染成了
/// 未勾选(实测 219 条)。partial(进行中)以前和未开始长得一样。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );

  testWidgets('done / partial / todo 三态各画各的', (tester) async {
    final item = CustomItem(
      'custom:todo:1',
      customType: 'todo-progress-state',
      text: 'fallback',
      details: {
        'visible': true,
        'goal': '修完这个 bug',
        'items': [
          {'status': 'done', 'text': '定位根因'},
          {'status': 'partial', 'text': '改代码'},
          {'status': 'todo', 'text': '写测试'},
        ],
      },
    );
    await tester.pumpWidget(wrap(ChatItemView(item: item)));
    await tester.pumpAndSettle();

    // 各恰好一个
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.pending_outlined), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

    // 三条文本都在
    expect(find.text('定位根因'), findsOneWidget);
    expect(find.text('改代码'), findsOneWidget);
    expect(find.text('写测试'), findsOneWidget);

    // goal 不再是丢掉的 —— 显示成列表标题
    expect(find.text('修完这个 bug'), findsOneWidget);
  });

  testWidgets('visible:false 的 todo 面板不占位置', (tester) async {
    final item = CustomItem(
      'custom:todo:2',
      customType: 'todo-progress-state',
      text: 'fallback',
      details: {
        'visible': false,
        'items': [
          {'status': 'done', 'text': '别画我'},
        ],
      },
    );
    await tester.pumpWidget(wrap(ChatItemView(item: item)));
    await tester.pumpAndSettle();

    expect(find.text('别画我'), findsNothing);
  });

  testWidgets('标题是「任务清单 已完成/总数」,不是原样的 customType', (tester) async {
    final item = CustomItem(
      'custom:todo:3',
      customType: 'todo-progress-state',
      text: 'fallback',
      details: {
        'visible': true,
        'items': [
          {'status': 'done', 'text': 'a'},
          {'status': 'done', 'text': 'b'},
          {'status': 'todo', 'text': 'c'},
        ],
      },
    );
    await tester.pumpWidget(wrap(ChatItemView(item: item)));
    await tester.pumpAndSettle();

    expect(find.text('任务清单 2/3'), findsOneWidget);
    // 不该把内部类型名原样打出来
    expect(find.text('todo-progress-state'), findsNothing);
  });
}
