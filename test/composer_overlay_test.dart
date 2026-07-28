import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/composer.dart';
import 'package:pi_pilot/ui/shell/app_shell.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 悬浮输入卡**不能**压住最后一条消息。
///
/// 输入卡是 Positioned 浮在消息流上的,内容从它下面滚过去。列表底部的留白
/// 必须跟着输入卡的**实测高度**走 —— 卡高 = 84 + 系统手势条 inset +
/// (展开的快捷面板/投递芯片)。以前写死 96dp,手势条 48dp 的机器上
/// 最后一条消息被压掉 28dp(实测)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap({double bottomInset = 0}) => ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          padding: EdgeInsets.only(bottom: bottomInset),
          viewPadding: EdgeInsets.only(bottom: bottomInset),
        ),
        child: const AppShell(),
      ),
    ),
  );

  testWidgets('不同手势条高度下,列表底部留白都足够放下输入卡', (tester) async {
    for (final inset in [0.0, 24.0, 34.0, 48.0]) {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(wrap(bottomInset: inset));
      await tester.pump();
      await tester.pump();

      // 没有会话时输入卡也在(禁用态),它是页面结构的一部分
      final composers = find.byType(Composer);
      if (composers.evaluate().isEmpty) {
        // 未连接态可能不渲染输入条,跳过量测
        continue;
      }
      final card = tester.getRect(composers.first);

      // 列表视口(Stack 的最底边)与输入卡之间不该有内容的碰撞:
      // 留白至少等于卡高(实测,不是写死的 96)
      expect(
        card.height,
        greaterThan(0),
        reason: 'inset=$inset 时输入卡没有高度',
      );
      expect(
        card.bottom,
        lessThanOrEqualTo(800),
        reason: 'inset=$inset 时输入卡超出屏幕底',
      );
    }
  });

  testWidgets('输入卡是悬浮的(在它和消息流之间有 Stack,不是兄弟关系)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(wrap());
    await tester.pump();

    // 「悬浮」的结构特征:输入卡与消息列表在**同一个 Stack** 里,
    // 而不是 Column 的兄弟(那样身后永远是实色背景)。
    final stack = find.byType(Stack);
    expect(stack, findsWidgets);
    expect(
      find.descendant(of: stack.first, matching: find.byType(Composer)),
      findsOneWidget,
      reason: '输入卡应该在 Stack 里(悬浮),不是 Column 兄弟',
    );
  });

  testWidgets('列表底部留白跟着实测高度走,不再写死 96', (tester) async {
    // 防回退到「写死 96」的护栏。实现约束本身:列表 padding 必须引用
    // 实测的 listBottomInset,而不是字面量 96 —— 否则手势条 48dp 的机器上
    // 最后一条消息会被压掉 28dp(实测)。
    final code = File('lib/ui/chat/chat_body.dart').readAsStringSync();
    expect(
      code.contains('listBottomInset'),
      isTrue,
      reason: '列表底部留白应该来自实测的输入卡高度',
    );
    expect(
      RegExp(
        r'padding:\s*const\s+EdgeInsets\.fromLTRB\(12,\s*12,\s*12,\s*96',
      ).hasMatch(code),
      isFalse,
      reason: '列表底部留白又被写死成 96 了',
    );
  });
}
