/// 存储基类 — 所有管家数据存储的公共形状
///
/// 分类原则：
/// - 一个 Store 只管一类数据（记忆/互动/禁区/触发器/保险箱…）
/// - Store 之间不互相调用，只通过 ButlerDatabase 拿连接
/// - 加新数据类型 = 新建一个 Store 文件 + 建表，不动其他 Store
library;

import 'package:sqflite/sqflite.dart';

import '../butler_database.dart';

/// 数据存储基类
abstract class ButlerStore {
  /// 存储标识（如 'memory'、'interaction'）
  String get id;

  /// 存储名（中文，展示用）
  String get name;

  /// 负责建表（数据库初始化时调用）
  Future<void> createTables(Database db);

  /// 负责升级（数据库版本升级时调用）
  Future<void> upgradeTables(Database db, int oldVersion, int newVersion) async {}

  /// 获取数据库连接（已初始化）
  /// 子类直接用 [db] 访问
  Database get db {
    final database = ButlerDatabase.instance.rawDatabase;
    if (database == null) {
      throw StateError('ButlerDatabase 未初始化，请先调用 initialize()');
    }
    return database;
  }

  /// 便捷查询
  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
  }) {
    return db.query(
      table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    );
  }

  /// 便捷插入
  Future<void> insert(String table, Map<String, dynamic> row) {
    return db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 便捷更新
  Future<void> update(
    String table,
    Map<String, dynamic> values, {
    required String where,
    required List<dynamic> whereArgs,
  }) {
    return db.update(table, values, where: where, whereArgs: whereArgs);
  }

  /// 便捷删除
  Future<void> delete(String table, {required String where, required List<dynamic> whereArgs}) {
    return db.delete(table, where: where, whereArgs: whereArgs);
  }

  /// 便捷计数
  Future<int> count(String table, {String? where, List<dynamic>? whereArgs}) async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM $table${where != null ? ' WHERE $where' : ''}',
      whereArgs,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
