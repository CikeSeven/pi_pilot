import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/chat/widgets/diff_view.dart';

void main() {
  group('looksLikeUnifiedDiff', () {
    test('有 @@ hunk 头 → true', () {
      expect(looksLikeUnifiedDiff('@@ -1,2 +1,2 @@\n-a\n+b'), isTrue);
    });

    test('pi edit 风格(+NNN/-NNN 混排)→ true', () {
      expect(looksLikeUnifiedDiff('-12 old line\n+12 new line'), isTrue);
    });

    test('纯文本 → false', () {
      expect(looksLikeUnifiedDiff('just some text\nanother line'), isFalse);
    });

    test('仅加号(markdown 列表等)→ false', () {
      expect(looksLikeUnifiedDiff('+ item one\n+ item two'), isFalse);
    });
  });

  group('parseUnifiedDiff', () {
    test('行类型划分正确', () {
      final lines = parseUnifiedDiff(
        '--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n ctx',
      );
      expect(lines.map((l) => l.kind), [
        DiffLineKind.meta,
        DiffLineKind.meta,
        DiffLineKind.hunk,
        DiffLineKind.del,
        DiffLineKind.add,
        DiffLineKind.context,
      ]);
    });
  });

  group('computeLineDiff', () {
    test('单行替换', () {
      final lines = computeLineDiff('a\nb\nc', 'a\nx\nc');
      expect(lines.map((l) => l.text), [' a', '-b', '+x', ' c']);
    });

    test('纯新增', () {
      final lines = computeLineDiff('a', 'a\nb');
      expect(lines.map((l) => l.kind), [
        DiffLineKind.context,
        DiffLineKind.add,
      ]);
    });

    test('相同文本无 add/del', () {
      final lines = computeLineDiff('a\nb', 'a\nb');
      expect(lines.every((l) => l.kind == DiffLineKind.context), isTrue);
    });
  });
}
