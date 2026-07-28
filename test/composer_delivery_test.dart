import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/composer.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap({
    required TextEditingController controller,
    required bool streaming,
    VoidCallback? onSteer,
    VoidCallback? onFollowUp,
    VoidCallback? onInterruptAndSend,
    VoidCallback? onAbort,
  }) => MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Composer(
        controller: controller,
        enabled: true,
        streaming: streaming,
        onSend: () {},
        onSteer: onSteer,
        onFollowUp: onFollowUp,
        onInterruptAndSend: onInterruptAndSend,
        onAbort: onAbort,
      ),
    ),
  );

  testWidgets('空闲时不出现投递方式选择', (tester) async {
    final controller = TextEditingController(text: '写点什么');
    await tester.pumpWidget(wrap(controller: controller, streaming: false));
    await tester.pumpAndSettle();

    expect(find.text('插队'), findsNothing);
    expect(find.text('排队'), findsNothing);
    expect(find.text('中断并发送'), findsNothing);
  });

  testWidgets('生成中且已输入内容时,三种投递方式都可选', (tester) async {
    final controller = TextEditingController(text: '再加一件事');
    await tester.pumpWidget(wrap(controller: controller, streaming: true));
    await tester.pumpAndSettle();

    // 「插队」是 steer:本轮结束后处理,**不是中断** —— 文案必须区分开
    expect(find.text('插队'), findsOneWidget);
    expect(find.text('排队'), findsOneWidget);
    expect(find.text('中断并发送'), findsOneWidget);
  });

  testWidgets('三个投递芯片各自触发对应回调', (tester) async {
    final controller = TextEditingController(text: 'hi');
    final fired = <String>[];
    await tester.pumpWidget(
      wrap(
        controller: controller,
        streaming: true,
        onSteer: () => fired.add('steer'),
        onFollowUp: () => fired.add('followUp'),
        onInterruptAndSend: () => fired.add('interrupt'),
      ),
    );
    await tester.pumpAndSettle();

    // 芯片行是横向滚动的,窄屏下第三个会出屏 —— 先滚到可见再点
    for (final label in ['插队', '排队', '中断并发送']) {
      final chip = find.widgetWithText(ActionChip, label);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pump();
    }

    expect(fired, ['steer', 'followUp', 'interrupt']);
  });

  testWidgets('生成中输入框为空时,发送键变成停止键', (tester) async {
    final controller = TextEditingController();
    var aborted = 0;
    await tester.pumpWidget(
      wrap(controller: controller, streaming: true, onAbort: () => aborted++),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    // 空输入时不该出现投递选择(没有内容可投递)
    expect(find.text('插队'), findsNothing);

    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    expect(aborted, 1);
  });

  testWidgets('输入永远可用:不存在"没有控制权"的禁用态', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(wrap(controller: controller, streaming: false));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);
  });

  testWidgets('输入框是一张能看清边界的悬浮卡片', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(wrap(controller: controller, streaming: false));
    await tester.pumpAndSettle();

    final theme = buildLightTheme();
    // 现在整个 app 内容区都不投影,所以「看得见」只能靠底色差 ——
    // 输入卡的底色必须**不等于** scaffold 背景,否则它会彻底消失。
    // (最早那版是 Container + Border(top:),既无 elevation 也无色差。)
    final cards = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(Composer),
            matching: find.byType(Material),
          ),
        )
        .where((m) => m.color == theme.colorScheme.surfaceContainerHigh);
    expect(cards, isNotEmpty, reason: '输入卡必须有独立底色');

    // 而且是大圆角
    final card = cards.first;
    final shape = card.shape! as RoundedRectangleBorder;
    expect(
      shape.borderRadius.resolve(TextDirection.ltr).topLeft.x,
      greaterThanOrEqualTo(24),
    );
  });

  testWidgets('输入框自己不画边框,视觉容器是外面那张卡', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(wrap(controller: controller, streaming: false));
    await tester.pumpAndSettle();

    // 这里的 InputBorder.none 是**故意的**:两层边框(卡片 + 输入框)会显脏。
    // 设置页的输入框不受影响,仍走 inputDecorationTheme 的描边样式。
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.border, InputBorder.none);
    expect(field.decoration?.filled, isFalse);
  });
}
