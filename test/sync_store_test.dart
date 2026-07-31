import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  SyncStore? store;

  setUp(() async {
    await SyncStore.closeForTest();
    store = await SyncStore.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    await SyncStore.closeForTest();
  });

  test('游标与事件同事务提交,读回一致', () async {
    final s = store!;
    await s.commitEventWithCursor(
      sourceKey: 'sess-1',
      cursor: const {'v': 2, 'seq': 5, 'lastEntryId': 'e5'},
      entry: const {'id': 'e5', 'text': 'hello'},
      entryId: 'e5',
      seq: 5,
      epoch: 'ep1',
    );
    final cursor = await s.loadCursor('sess-1');
    expect(cursor?['seq'], 5);
    expect(cursor?['lastEntryId'], 'e5');
    final entries = await s.loadRecentEntries('sess-1');
    expect(entries.single['id'], 'e5');
  });

  test('loadRecentEntries 按 seq 升序返回最近 N 条', () async {
    final s = store!;
    for (var i = 0; i < 10; i++) {
      await s.commitEventWithCursor(
        sourceKey: 'sess-1',
        cursor: {'v': 2, 'seq': i, 'lastEntryId': 'e$i'},
        entry: {'id': 'e$i', 'n': i},
        entryId: 'e$i',
        seq: i,
      );
    }
    final entries = await s.loadRecentEntries('sess-1', limit: 3);
    expect(entries.map((e) => e['id']), ['e7', 'e8', 'e9']);
  });

  test('replaceEntries 覆盖后 prune 保留最新', () async {
    final s = store!;
    await s.replaceEntries('sess-1', [
      for (var i = 0; i < 5; i++) (id: 'e$i', seq: i, payload: {'id': 'e$i'}),
    ]);
    await s.pruneEntries('sess-1', 2);
    final entries = await s.loadRecentEntries('sess-1');
    expect(entries.map((e) => e['id']), ['e3', 'e4']);
  });

  test('clearSource 清掉 entries 与游标(rebase 失败路径)', () async {
    final s = store!;
    await s.commitEventWithCursor(
      sourceKey: 'sess-1',
      cursor: const {'v': 2, 'seq': 1},
      entry: const {'id': 'e1'},
      entryId: 'e1',
      seq: 1,
    );
    await s.clearSource('sess-1');
    expect(await s.loadCursor('sess-1'), isNull);
    expect(await s.loadRecentEntries('sess-1'), isEmpty);
  });

  test('op_log: pending 写入与状态更新', () async {
    final s = store!;
    await s.insertOp(opId: 'op-1', clientId: 'app-x', type: 'prompt');
    await s.insertOp(opId: 'op-2', clientId: 'app-x', type: 'abort');
    expect((await s.pendingOps()).length, 2);
    await s.updateOpStatus('op-1', 'executed');
    final pending = await s.pendingOps();
    expect(pending.single['op_id'], 'op-2');
  });
}
