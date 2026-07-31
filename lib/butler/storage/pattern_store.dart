/// 规律存储 — 规律组合表（pattern_combos）
///
/// 管家发现 + 用户手动添加的规律，持久化到 SQLite。
/// 重启 APP 后规律不丢。
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';

/// 规律存储
class PatternStore extends ButlerStore {
  static const String table = 'pattern_combos';

  @override
  String get id => 'patterns';

  @override
  String get name => '规律';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        combo_key TEXT PRIMARY KEY,
        keywords TEXT NOT NULL,
        count INTEGER DEFAULT 0,
        shifts TEXT DEFAULT '{}',
        ranges TEXT DEFAULT '{}',
        confidence REAL DEFAULT 0,
        confirmed INTEGER DEFAULT 0,
        last_seen TEXT,
        source TEXT DEFAULT 'auto'
      )
    ''');
  }

  /// 保存一条规律（覆盖写）
  Future<void> savePattern({
    required String comboKey,
    required List<String> keywords,
    required int count,
    required Map<String, double> shifts,
    required Map<String, double> ranges,
    required double confidence,
    required bool confirmed,
    required DateTime lastSeen,
    String source = 'auto',
  }) async {
    await insert(table, {
      'combo_key': comboKey,
      'keywords': jsonEncode(keywords),
      'count': count,
      'shifts': jsonEncode(shifts),
      'ranges': jsonEncode(ranges),
      'confidence': confidence,
      'confirmed': confirmed ? 1 : 0,
      'last_seen': lastSeen.toIso8601String(),
      'source': source,
    });
  }

  /// 加载全部规律
  Future<List<Map<String, dynamic>>> loadAll() async {
    return query(table);
  }

  /// 删除一条规律
  Future<void> deletePattern(String comboKey) async {
    await db.delete(table, where: 'combo_key = ?', whereArgs: [comboKey]);
  }

  /// 清空（调试用）
  Future<void> clearAll() async {
    await db.delete(table);
  }
}
