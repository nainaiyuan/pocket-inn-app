/// 关系记录存储 — 关系记录表（relation_records）
///
/// 8-07 01:13 用户：统一记录格式（谁→谁→什么 + 原话 + 时间 + 归属），
/// 情绪、记忆、规律都用它。SQLite 持久化。
library;

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';
import '../memory/relation_record.dart';

class RelationStore extends ButlerStore {
  static const String table = 'relation_records';

  @override
  String get id => 'relation';

  @override
  String get name => '关系记录';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        subject TEXT NOT NULL,
        predicate TEXT NOT NULL,
        object TEXT NOT NULL,
        quote TEXT NOT NULL,
        time TEXT,
        character_id TEXT,
        category TEXT DEFAULT '记忆',
        created_at TEXT NOT NULL
      )
    ''');
    // 查询加速：按主体/客体找
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relation_subject ON $table(subject)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relation_object ON $table(object)',
    );
  }

  /// 保存一条关系记录
  Future<void> save(RelationRecord record) async {
    await insert(table, record.toMap());
  }

  /// 加载全部（新的在前）
  Future<List<RelationRecord>> loadAll() async {
    final rows = await query(table, orderBy: 'created_at DESC');
    return rows.map((r) => RelationRecord.fromMap(r)).toList();
  }

  /// 按实体查（作为主体或客体出现过）
  Future<List<RelationRecord>> loadByEntity(String entity) async {
    final rows = await query(
      table,
      where: 'subject = ? OR object = ?',
      whereArgs: [entity, entity],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => RelationRecord.fromMap(r)).toList();
  }

  /// 删除一条
  Future<void> deleteById(String id) async {
    await db.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  /// 清空
  Future<void> clearAll() async {
    await db.delete(table);
  }
}
