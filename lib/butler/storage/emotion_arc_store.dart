/// 情绪弧线事件存储
///
/// 落库 EmotionArc（情感基线视图的数据基础）：
/// - 按时间聚合 → 月度趋势
/// - 按 characterId 聚合 → 各男主基线
/// - triggerKeywords → 触发因素

library;

import 'package:sqflite/sqflite.dart';

import '../memory/emotion_arc.dart';
import 'butler_store.dart';

class EmotionArcStore extends ButlerStore {
  @override
  String get id => 'emotion_arcs';

  @override
  String get name => '情绪弧线';

  static const String table = 'emotion_arcs';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        time TEXT NOT NULL,
        characterId TEXT,
        triggerKeywords TEXT DEFAULT '[]',
        topic TEXT,
        startMood TEXT DEFAULT '{}',
        peakMood TEXT DEFAULT '{}',
        endMood TEXT DEFAULT '{}',
        returnedToBaseline INTEGER DEFAULT 1,
        durationMinutes INTEGER DEFAULT 0,
        summary TEXT
      )
    ''');
  }

  /// 保存一条情绪弧线
  Future<void> save(EmotionArc arc) async {
    await insert(table, arc.toJson());
  }

  /// 读取全部弧线（按时间倒序）
  Future<List<EmotionArc>> loadAll() async {
    try {
      final d = await db;
      final rows = await d.query(table, orderBy: 'time ASC');
      return rows.map((r) => EmotionArc.fromJson(r)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 按男主读取弧线
  Future<List<EmotionArc>> loadByCharacter(String characterId) async {
    try {
      final d = await db;
      final rows = await d.query(
        table,
        where: 'characterId = ?',
        whereArgs: [characterId],
        orderBy: 'time ASC',
      );
      return rows.map((r) => EmotionArc.fromJson(r)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 删除某关键词相关的所有弧线（配合规律删除）
  Future<void> deleteByKeyword(String keyword) async {
    try {
      final d = await db;
      final rows = await d.query(table);
      for (final r in rows) {
        final arc = EmotionArc.fromJson(r);
        if (arc.triggerKeywords.contains(keyword)) {
          await d.delete(table, where: 'id = ?', whereArgs: [arc.id]);
        }
      }
    } catch (_) {}
  }
}
