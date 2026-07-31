/// 记忆存储 — 管家的记忆数据（butler_memories 表）
///
/// 只管记忆一类数据。建表、增删改查全在这里。
/// 数据库连接来自 ButlerDatabase，表结构版本升级也在 ButlerDatabase 统一管理。
library;

import 'package:sqflite/sqflite.dart';

import '../butler_memory.dart';
import 'butler_store.dart';

/// 记忆存储
class MemoryStore extends ButlerStore {
  @override
  String get id => 'memory';

  @override
  String get name => '记忆';

  /// 表名
  static const String table = 'butler_memories';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        content TEXT NOT NULL,
        maskedContent TEXT DEFAULT '',
        topic TEXT DEFAULT '',
        importance TEXT DEFAULT 'normal',
        keywords TEXT DEFAULT '[]',
        source TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        isArchived INTEGER DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_memories_session ON $table(sessionId)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_memories_topic ON $table(topic)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_memories_importance ON $table(importance)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_memories_created ON $table(createdAt)');
  }

  // ========== 增删改查 ==========

  /// 保存记忆
  Future<void> save(ButlerMemory memory) async {
    await insert(table, memory.toJson());
  }

  /// 批量保存
  Future<void> saveAll(List<ButlerMemory> memories) async {
    final batch = db.batch();
    for (final m in memories) {
      batch.insert(table, m.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 按会话加载
  Future<List<ButlerMemory>> bySession(String sessionId, {int? limit}) async {
    var sql = 'SELECT * FROM $table WHERE sessionId = ? AND isArchived = 0 ORDER BY createdAt ASC';
    final args = <dynamic>[sessionId];
    if (limit != null) {
      sql += ' LIMIT ?';
      args.add(limit);
    }
    final results = await db.rawQuery(sql, args);
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 关键词搜索
  Future<List<ButlerMemory>> search(String query, {int? limit}) async {
    final like = '%$query%';
    var sql = '''
      SELECT * FROM $table
      WHERE isArchived = 0
        AND (content LIKE ? OR topic LIKE ? OR keywords LIKE ?)
      ORDER BY createdAt DESC
    ''';
    final args = <dynamic>[like, like, like];
    if (limit != null) {
      sql += ' LIMIT ?';
      args.add(limit);
    }
    final results = await db.rawQuery(sql, args);
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 按重要性加载
  Future<List<ButlerMemory>> byImportance({int? limit}) async {
    var sql = '''
      SELECT * FROM $table
      WHERE isArchived = 0 AND importance IN ('core', 'normal')
      ORDER BY
        CASE importance
          WHEN 'core' THEN 0
          WHEN 'normal' THEN 1
          WHEN 'temp' THEN 2
        END,
        createdAt DESC
    ''';
    if (limit != null) sql += ' LIMIT $limit';
    final results = await db.rawQuery(sql);
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 最新 N 条
  Future<List<ButlerMemory>> recent(int count) async {
    final results = await db.rawQuery(
      'SELECT * FROM $table WHERE isArchived = 0 ORDER BY createdAt DESC LIMIT ?',
      [count],
    );
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 软删除
  Future<void> archive(String id) async {
    await update(
      table,
      {'isArchived': 1, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新内容
  Future<void> updateContent(String id, String newContent) async {
    await update(
      table,
      {'content': newContent, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 统计
  Future<Map<String, int>> stats() async {
    final total = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $table WHERE isArchived = 0'),
    ) ?? 0;
    final core = Sqflite.firstIntValue(
      await db.rawQuery("SELECT COUNT(*) FROM $table WHERE importance = 'core' AND isArchived = 0"),
    ) ?? 0;
    final temp = Sqflite.firstIntValue(
      await db.rawQuery("SELECT COUNT(*) FROM $table WHERE importance = 'temp' AND isArchived = 0"),
    ) ?? 0;
    return {'total': total, 'core': core, 'temp': temp};
  }
}
