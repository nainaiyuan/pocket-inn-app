/// 作息规律存储 — 聊天作息表（chat_schedule）
///
/// 用户 02:11 设计（日记触发逻辑）：规律引擎记两个节点——
///   - 平均开始聊天时间（用户一般几点来找男主）
///   - 平均结束聊天时间（用户一般聊到几点）
/// 用途：判定"用户睡觉了" → 该写当天日记了；
///       "第二天用户要来了"（平均开始聊节点）→ 最晚 deadline。
/// 21:13 用户补充：上下文要没了（token 快满）也要强制写日记。
///
/// 数据：每天一行（date=yyyy-MM-dd），存当天首次聊天/结束信号时刻（分钟数）。
/// 平均 = 最近 N 天的滚动平均（N=14，够稳定又跟得上作息变化）。
library;

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';

/// 作息规律存储
class ScheduleStore extends ButlerStore {
  static const String table = 'chat_schedule';
  static const int rollingDays = 14;

  @override
  String get id => 'schedule';

  @override
  String get name => '作息规律';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        date TEXT PRIMARY KEY,
        start_minute INTEGER,
        end_minute INTEGER,
        updated_at TEXT
      )
    ''');
  }

  /// 记录某天首次聊天时间（分钟数 0-1439）
  Future<void> recordStart(int minute) async {
    final date = _todayKey();
    final row = await query(
      table,
      where: 'date = ?',
      whereArgs: [date],
    );
    if (row.isNotEmpty) {
      // 只记当天最早一次（首次聊天）
      final existing = (row.first['start_minute'] as num?)?.toInt();
      if (existing != null && existing <= minute) return;
      await db.update(
        table,
        {
          'start_minute': minute,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'date = ?',
        whereArgs: [date],
      );
    } else {
      await db.insert(table, {
        'date': date,
        'start_minute': minute,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// 记录当天结束聊时间（结束信号时刻，分钟数 0-1439）
  Future<void> recordEnd(int minute) async {
    final date = _todayKey();
    final row = await query(
      table,
      where: 'date = ?',
      whereArgs: [date],
    );
    if (row.isNotEmpty) {
      // 只记当天最晚一次（结束信号）
      final existing = (row.first['end_minute'] as num?)?.toInt();
      if (existing != null && existing >= minute) return;
      await db.update(
        table,
        {
          'end_minute': minute,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'date = ?',
        whereArgs: [date],
      );
    } else {
      await db.insert(table, {
        'date': date,
        'start_minute': null,
        'end_minute': minute,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// 平均开始聊天时间（分钟数；样本不足返回 null）
  /// 判定"用户一般几点来找男主"
  Future<int?> avgStartMinute() async {
    final rows = await query(
      table,
      orderBy: 'date DESC',
      limit: rollingDays,
    );
    final samples = rows
        .map((r) => (r['start_minute'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    if (samples.isEmpty) return null;
    return (samples.reduce((a, b) => a + b) / samples.length).round();
  }

  /// 平均结束聊天时间（分钟数；样本不足返回 null）
  /// 判定"用户一般聊到几点睡"
  Future<int?> avgEndMinute() async {
    final rows = await query(
      table,
      orderBy: 'date DESC',
      limit: rollingDays,
    );
    final samples = rows
        .map((r) => (r['end_minute'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    if (samples.isEmpty) return null;
    return (samples.reduce((a, b) => a + b) / samples.length).round();
  }

  /// 今天是否已经记录过开始（防重复触发记录）
  Future<bool> hasStartToday() async {
    final row = await query(
      table,
      where: 'date = ?',
      whereArgs: [_todayKey()],
    );
    return row.isNotEmpty && (row.first['start_minute'] as num?) != null;
  }

  static String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }
}
