/// 用户记忆存储 — 用户记忆表（user_memories）
///
/// 用户想让男主记住的事，持久化到 SQLite。
/// 重启 APP 后记忆不丢。
library;

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';
import '../memory/user_memory.dart';

/// 用户记忆存储
class UserMemoryStore extends ButlerStore {
  static const String table = 'user_memories';

  @override
  String get id => 'user_memory';

  @override
  String get name => '用户记忆';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        subject TEXT DEFAULT '我',
        with_whom TEXT,
        time TEXT,
        action TEXT NOT NULL,
        feeling TEXT,
        category TEXT DEFAULT '日常',
        tags TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_user_created INTEGER DEFAULT 0
      )
    ''');
  }

  /// 保存一条记忆（覆盖写）
  Future<void> save(UserMemory memory) async {
    await insert(table, memory.toMap());
  }

  /// 加载全部记忆
  Future<List<UserMemory>> loadAll() async {
    final rows = await query(table, orderBy: 'updated_at DESC');
    return rows.map((r) => UserMemory.fromMap(r)).toList();
  }

  /// 删除一条记忆
  Future<void> deleteById(String id) async {
    await db.delete(table, where: 'id = ?', whereArgs: [id]);
  }
}
