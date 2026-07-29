import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/code_block.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('languageForPath', () {
    test('常见扩展名', () {
      expect(languageForPath('a/b/main.dart'), 'dart');
      expect(languageForPath('x.ts'), 'typescript');
      expect(languageForPath('x.yml'), 'yaml');
      expect(languageForPath('run.sh'), 'bash');
      expect(languageForPath('index.html'), 'xml');
    });

    test('未知/无扩展名 → null', () {
      expect(languageForPath('Makefile.unknownext'), isNull);
      expect(languageForPath('noext'), isNull);
    });
  });

  group('highlightCode', () {
    test('已知语言产出多个着色片段', () {
      final span = highlightCode('final x = 1;', 'dart', Brightness.dark);
      expect(span.toPlainText(), 'final x = 1;');
      expect(span.children, isNotNull);
    });

    test('未知语言退化为纯文本', () {
      final span = highlightCode('whatever', 'nolang', Brightness.dark);
      expect(span.text, 'whatever');
    });
  });

  group('CodeBlock widget', () {
    testWidgets('显示语言标签与复制按钮', (tester) async {
      await tester.pumpWidget(
        _wrap(const CodeBlock(code: 'print(1)', language: 'python')),
      );
      expect(find.text('python'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    });

    testWidgets('复制按钮写入剪贴板', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      await tester.pumpWidget(
        _wrap(const CodeBlock(code: 'abc', language: 'text')),
      );
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();
      final copy = calls.where((c) => c.method == 'Clipboard.setData');
      expect(copy, isNotEmpty);
      expect((copy.first.arguments as Map)['text'], 'abc');
      // 复制后有个 1.2s 的对勾回退定时器(code_block 的「闪一下」反馈),
      // 不把它跑完测试结束时会留下 pending timer。
      await tester.pump(const Duration(milliseconds: 1300));
    });

    testWidgets('行号 gutter 从 firstLineNumber 起算', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const CodeBlock(
            code: 'a\nb\nc',
            showLineNumbers: true,
            firstLineNumber: 10,
          ),
        ),
      );
      expect(find.text('10\n11\n12'), findsOneWidget);
    });
  });
}
