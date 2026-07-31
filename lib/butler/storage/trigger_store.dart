/// 触发器存储 — 管家自动触发条件表（butler_triggers 表）
///
/// 触发器 = "当 XXX 发生时，管家自动做 YYY"。
/// 类型：topic(话题) / mood(情绪) / time(时间) / keyword(关键词)
/// 动作：notify_character / remind_user / adjust_config
library;

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';

/// 触发器
class ButlerTrigger {
  final String id;
  final String triggerType; // topic / mood / time / keyword
  final String matchValue;
  final String action;      // notify_character / remind_user / adjust_config
  final String content;
  final bool enabled;

  const ButlerTrigger({
    required this.id,
    required this.triggerType,
    required this.matchValue,
    required this.action,
    this.content = '',
    this.enabled = true,
    this.createdAt,
  });

  /// 创建时间（可空，默认取当前时间）
  final DateTime? createdAt;

  DateTime get createdTime => createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'triggerType': triggerType,
    'matchValue': matchValue,
    'action': action,
    'content': content,
    'enabled': enabled ? 1 : 0,
    'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
  };

  factory ButlerTrigger.fromJson(Map<String, dynamic> json) => ButlerTrigger(
    id: json['id'] as String,
    triggerType: json['triggerType'] as String? ?? 'topic',
    matchValue: json['matchValue'] as String? ?? '',
    action: json['action'] as String? ?? 'remind_user',
    content: json['content'] as String? ?? '',
    enabled: json['enabled'] == 1,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );
}

/// 触发器存储
class TriggerStore extends ButlerStore {
  @override
  String get id => 'trigger';

  @override
  String get name => '触发器';

  static const String table = 'butler_triggers';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        triggerType TEXT NOT NULL,
        matchValue TEXT NOT NULL,
        action TEXT NOT NULL,
        content TEXT DEFAULT '',
        enabled INTEGER DEFAULT 1,
        createdAt TEXT NOT NULL
      )
    ''');
  }

  /// 添加触发器
  Future<void> add(ButlerTrigger trigger) async {
    await insert(table, trigger.toJson());
  }

  /// 获取所有启用的
  Future<List<ButlerTrigger>> active() async {
    final results = await db.query(table, where: 'enabled = 1');
    return results.map((r) => ButlerTrigger.fromJson(r)).toList();
  }

  /// 按类型查询
  Future<List<ButlerTrigger>> byType(String type) async {
    final results = await db.query(
      table,
      where: 'triggerType = ? AND enabled = 1',
      whereArgs: [type],
    );
    return results.map((r) => ButlerTrigger.fromJson(r)).toList();
  }

  /// 切换启用状态
  Future<void> toggle(String id) async {
    final current = await db.query(table, where: 'id = ?', whereArgs: [id]);
    if (current.isNotEmpty) {
      final enabled = current.first['enabled'] == 1 ? 0 : 1;
      await update(table, {'enabled': enabled}, where: 'id = ?', whereArgs: [id]);
    }
  }

  /// 删除
  Future<void> remove(String id) async {
    await delete(table, where: 'id = ?', whereArgs: [id]);
  }
}
