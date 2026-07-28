import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/source_cursor.dart';

void main() {
  const cursor = SourceCursor(sourceId: 'src', epoch: 'e1', seq: 10);

  group('classify', () {
    test('正好接续 → apply', () {
      expect(
        cursor.classify(sourceId: 'src', epoch: 'e1', seq: 11),
        SourceApply.apply,
      );
    });

    test('已应用过 → duplicate', () {
      expect(
        cursor.classify(sourceId: 'src', epoch: 'e1', seq: 10),
        SourceApply.duplicate,
      );
      expect(
        cursor.classify(sourceId: 'src', epoch: 'e1', seq: 3),
        SourceApply.duplicate,
      );
    });

    test('跳号 → gap(而不是永久拒绝)', () {
      expect(
        cursor.classify(sourceId: 'src', epoch: 'e1', seq: 25),
        SourceApply.gap,
      );
    });

    test('epoch 变化优先于序号判定', () {
      expect(
        cursor.classify(sourceId: 'src', epoch: 'e2', seq: 11),
        SourceApply.epochChanged,
      );
      expect(
        cursor.classify(sourceId: 'src', epoch: 'e2', seq: 3),
        SourceApply.epochChanged,
      );
    });

    test('别的 source → wrongSource', () {
      expect(
        cursor.classify(sourceId: 'other', epoch: 'e1', seq: 11),
        SourceApply.wrongSource,
      );
    });

    test('字段缺失 → wrongSource', () {
      expect(
        cursor.classify(sourceId: null, epoch: 'e1', seq: 11),
        SourceApply.wrongSource,
      );
      expect(
        cursor.classify(sourceId: 'src', epoch: 'e1', seq: null),
        SourceApply.wrongSource,
      );
    });

    test('初始游标(未选定 source)接受任意来源', () {
      const fresh = SourceCursor();
      expect(
        fresh.classify(sourceId: 'src', epoch: 'e1', seq: 1),
        SourceApply.apply,
      );
    });
  });

  test('adopt 跨越断层后从新序号继续', () {
    final adopted = cursor.adopt(sourceId: 'src', epoch: 'e1', seq: 25);
    expect(adopted.seq, 25);
    expect(
      adopted.classify(sourceId: 'src', epoch: 'e1', seq: 26),
      SourceApply.apply,
    );
    expect(
      adopted.classify(sourceId: 'src', epoch: 'e1', seq: 25),
      SourceApply.duplicate,
    );
  });

  test('reset 归零', () {
    final reset = cursor.reset(sourceId: 'src', epoch: 'e2');
    expect(reset.seq, 0);
    expect(
      reset.classify(sourceId: 'src', epoch: 'e2', seq: 1),
      SourceApply.apply,
    );
  });
}
