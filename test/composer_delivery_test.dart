import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/chat/widgets/composer.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

/// 新版输入框内嵌 ModelPicker / _ContextRing(Riverpod consumer),
/// 测试必须给 ProviderScope;会话态用假的就行,不用真连接。
/// piSessionProvider 现在是「当前设备状态」代理(`Provider<PiState>`),
/// override 一个状态值即可。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap({
    required TextEditingController controller,
    required bool streaming,
    bool compacting = false,
    VoidCallback? onSteer,
    VoidCallback? onFollowUp,
    VoidCallback? onInterruptAndSend,
    VoidCallback? onAbort,
  }) => ProviderScope(
    overrides: [piSessionProvider.overrideWith((ref) => PiState.initial())],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: Composer(
          controller: controller,
          enabled: true,
          streaming: streaming,
          compacting: compacting,
          onSend: () {},
          onSteer: onSteer,
          onFollowUp: onFollowUp,
          onInterruptAndSend: onInterruptAndSend,
          onAbort: onAbort,
        ),
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

  // pi 0.82.1 没有「压缩后发送」队列。压缩态只能明确中断,
  // 不能展示看似可用、实际会绕过压缩控制器的插队/排队入口。
  testWidgets('压缩中且已输入内容时,只提供中断并发送', (tester) async {
    final controller = TextEditingController(text: '先停压缩再干这个');
    await tester.pumpWidget(
      wrap(controller: controller, streaming: false, compacting: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('插队'), findsNothing);
    expect(find.text('排队'), findsNothing);
    expect(find.text('中断并发送'), findsOneWidget);
  });

  testWidgets('压缩中的输入框提示可中断后发送', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      wrap(controller: controller, streaming: false, compacting: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('压缩中 · 可中断后发送'), findsOneWidget);
  });

  testWidgets('压缩中且输入框为空时,发送键变成可中断的停止键', (tester) async {
    final controller = TextEditingController();
    var aborted = 0;
    await tester.pumpWidget(
      wrap(
        controller: controller,
        streaming: false,
        compacting: true,
        onAbort: () => aborted++,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    expect(aborted, 1);
  });

  testWidgets('压缩中有输入时,主发送键也走中断确认回调', (tester) async {
    final controller = TextEditingController(text: '先停再发');
    var interrupted = 0;
    await tester.pumpWidget(
      wrap(
        controller: controller,
        streaming: false,
        compacting: true,
        onInterruptAndSend: () => interrupted++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    expect(interrupted, 1);
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

    // 液态玻璃:渐变 + 描边(聚焦时描边加粗转主色),不再是旧版的
    // Material 胶囊。层次靠渐变和描边承担,不靠投影。
    final decorations = tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byType(Composer),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.gradient != null)
        .toList();
    expect(decorations, isNotEmpty, reason: '输入卡必须有液态玻璃渐变');
    expect(decorations.first.border, isNotNull, reason: '输入卡必须有描边');
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
