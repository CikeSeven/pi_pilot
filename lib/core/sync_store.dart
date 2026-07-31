import 'dart:async';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 本地同步存储:让"下次打开只拉增量"成为可能。
///
/// 设计要点(对应 docs/p2p-final-plan.md v3 模块 5):
/// - 主键与 hubId 解耦:bridge 重启后 hubId 必变,缓存标 stale 而不是删除,
///  entryId rebase 成功即刷新元数据继续用,只有 rebase 失败才清。
/// - 事务规则:应用 sequenced event = 单事务 {upsert entry → update cursor},
///  **游标永不先于数据落盘**(旧实现 gap 分支先推进游标后应用事件,
///  进程被杀就会静默丢一段)。
/// - 缓存只渲染不定序:定序永远以 seq 为准,sync 完成即覆盖。
class SyncStore {
  SyncStore._(this._db);

  final Database _db;
  static const _version = 2;
  static SyncStore? _instance;

  /// 打开(或复用)全局实例;失败时返回 null,调用方降级为纯内存。
  /// [factory]/[path] 仅供测试注入(如 sqflite_common_ffi)。
  static Future<SyncStore?> open({DatabaseFactory? factory, String? path}) async {
    final existing = _instance;
    if (existing != null) return existing;
    try {
      final resolvedPath =
          path ?? '${(await getApplicationDocumentsDirectory()).path}/pipilot_sync.db';
      final db = await (factory ?? databaseFactory).openDatabase(
        resolvedPath,
        options: OpenDatabaseOptions(
          version: _version,
          onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)',
          );
          await db.execute(
            'CREATE TABLE sources(hub_id TEXT, source_id TEXT, epoch TEXT, '
            'payload TEXT, stale INTEGER NOT NULL DEFAULT 0, updated_at INTEGER, '
            'PRIMARY KEY(hub_id, source_id))',
          );
          await db.execute(
            'CREATE TABLE sessions(hub_id TEXT, session_id TEXT, payload TEXT, '
            'updated_at INTEGER, PRIMARY KEY(hub_id, session_id))',
          );
          await db.execute(
            'CREATE TABLE entries(source_key TEXT, entry_id TEXT, '
            'seq INTEGER, epoch TEXT, payload TEXT, updated_at INTEGER, '
            'PRIMARY KEY(source_key, entry_id))',
          );
          await db.execute(
            'CREATE INDEX idx_entries_seq ON entries(source_key, seq)',
          );
          await db.execute(
            'CREATE TABLE cursors(source_key TEXT PRIMARY KEY, payload TEXT)',
          );
          await db.execute(
            'CREATE TABLE op_log(op_id TEXT PRIMARY KEY, client_id TEXT, '
            'device_key TEXT, '
            'source_id TEXT, session_id TEXT, type TEXT, payload_hash TEXT, '
            'status TEXT, created_at INTEGER, updated_at INTEGER)',
          );
          },
          // v2:op_log 增加 device_key。多设备共用一个库后,排队写操作必须
          // 按设备隔离——A 设备的 pending op 绝不能被 B 设备的重连对账冲掉。
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 2) {
              await db.execute(
                'ALTER TABLE op_log ADD COLUMN device_key TEXT',
              );
            }
          },
        ),
      );
      _instance = SyncStore._(db);
      return _instance;
    } catch (_) {
      // 数据库不可用时降级为纯内存:功能不退化,只是丢掉持久化收益。
      return null;
    }
  }

  static Future<void> closeForTest() async {
    final existing = _instance;
    _instance = null;
    if (existing != null) await existing._db.close();
  }

  // -- cursor -----------------------------------------------------------------

  /// 读取游标(cursor v2 JSON);无记录或解析失败返回 null。
  /// [sourceKey] 与 hubId/sourceId 解耦(通常 sessionId),bridge/桌面
  /// 重启后游标仍能找到 —— 这是 entryId rebase 的前提。
  Future<Map<String, dynamic>?> loadCursor(String sourceKey) async {
    final rows = await _db.query(
      'cursors',
      columns: ['payload'],
      where: 'source_key = ?',
      whereArgs: [sourceKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      final decoded = jsonDecode(rows.first['payload'] as String);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 事务化写入:entry 型事件与游标在同一事务落盘,游标永不先于数据。
  Future<void> commitEventWithCursor({
    required String sourceKey,
    required Map<String, dynamic> cursor,
    Map<String, dynamic>? entry,
    String? entryId,
    int? seq,
    String? epoch,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      if (entry != null && entryId != null) {
        txn.insert(
          'entries',
          {
            'source_key': sourceKey,
            'entry_id': entryId,
            'seq': seq,
            'epoch': epoch,
            'payload': jsonEncode(entry),
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      txn.insert(
        'cursors',
        {'source_key': sourceKey, 'payload': jsonEncode(cursor)},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  // -- entries 首屏缓存 ---------------------------------------------------------

  /// 读最近 [limit] 条缓存 entries(按写入顺序升序返回),供首屏先渲染再对账。
  /// 快照 entries 没有 seq,顺序由 rowid(插入序)保证。
  Future<List<Map<String, dynamic>>> loadRecentEntries(
    String sourceKey, {
    int limit = 200,
  }) async {
    final rows = await _db.rawQuery(
      'SELECT payload FROM entries WHERE source_key = ? '
      'ORDER BY rowid DESC LIMIT ?',
      [sourceKey, limit],
    );
    final out = <Map<String, dynamic>>[];
    for (final row in rows.reversed) {
      try {
        final decoded = jsonDecode(row['payload'] as String);
        if (decoded is Map<String, dynamic>) out.add(decoded);
      } catch (_) {}
    }
    return out;
  }

  /// 批量覆盖一个 source 的 entries(快照应用后);保留游标不变。
  Future<void> replaceEntries(
    String sourceKey,
    List<({String id, int? seq, Map<String, dynamic> payload})> entries,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      txn.delete('entries', where: 'source_key = ?', whereArgs: [sourceKey]);
      for (final entry in entries) {
        txn.insert('entries', {
          'source_key': sourceKey,
          'entry_id': entry.id,
          'seq': entry.seq,
          'payload': jsonEncode(entry.payload),
          'updated_at': now,
        });
      }
    });
  }

  /// 每 source 持久化 entries 的行数上限。
  ///
  /// 20MB / 5,000 条量级的会话下,不设上限会让 SQLite 无界增长:实测过
  /// 10.27MB / 4,592 条的单场会话,多个 source 累积后手机存储会被吃光。
  /// 保留 1,200 条足够覆盖"缓存优先渲染最新 200 条 + 往前翻几页",
  /// 更早的历史一律回 bridge 分页取。
  static const maxPersistedEntries = 1200;

  /// 修剪:每 source 最多保留 [maxRows] 条(按写入序从最旧删),防无限增长。
  Future<void> pruneEntries(String sourceKey, int maxRows) async {
    await _db.rawDelete(
      'DELETE FROM entries WHERE source_key = ? AND rowid NOT IN ('
      'SELECT rowid FROM entries WHERE source_key = ? '
      'ORDER BY rowid DESC LIMIT ?)',
      [sourceKey, sourceKey, maxRows],
    );
  }

  /// hubId 变化:把该 hub 的旧缓存标 stale(rebase 成功前不删)。
  Future<void> markStale(String oldHubId) async {
    await _db.update(
      'sources',
      {'stale': 1},
      where: 'hub_id = ?',
      whereArgs: [oldHubId],
    );
  }

  /// rebase 失败/epoch 作废:清掉一个 source 的 entries 与游标。
  Future<void> clearSource(String sourceKey) async {
    await _db.transaction((txn) async {
      txn.delete('entries', where: 'source_key = ?', whereArgs: [sourceKey]);
      txn.delete('cursors', where: 'source_key = ?', whereArgs: [sourceKey]);
    });
  }

  // -- op_log -----------------------------------------------------------------

  /// [deviceKey] 为本 app 侧 DeviceProfile.id。旧行(升级前)该列为 NULL,
  /// 属于单设备时代的遗留,视为「任何设备都可认领」。
  Future<void> insertOp({
    required String opId,
    required String clientId,
    required String type,
    String? deviceKey,
    String? sourceId,
    String? sessionId,
    String? payloadHash,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insert('op_log', {
      'op_id': opId,
      'client_id': clientId,
      'device_key': deviceKey,
      'source_id': sourceId,
      'session_id': sessionId,
      'type': type,
      'payload_hash': payloadHash,
      'status': 'pending',
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> updateOpStatus(String opId, String status) async {
    await _db.update(
      'op_log',
      {'status': status, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'op_id = ?',
      whereArgs: [opId],
    );
  }

  /// 恢复时对账:还挂着 pending 的写操作。
  /// 传 [deviceKey] 时只回本设备 + 遗留(NULL)的 op,不拿别设备的。
  Future<List<Map<String, dynamic>>> pendingOps({String? deviceKey}) async {
    return _db.query(
      'op_log',
      where: deviceKey == null
          ? 'status = ?'
          : "status = ? AND (device_key IS NULL OR device_key = ?)",
      whereArgs: deviceKey == null
          ? ['pending']
          : ['pending', deviceKey],
      orderBy: 'created_at ASC',
    );
  }
}
