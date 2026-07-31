/// 禁区存储 — 拦截模式表（blocklist_patterns 表）
///
/// 禁区 = 用户明确不想聊/不想被 AI 看到的内容模式。
/// 命中禁区 → 消息被拦截，不发给男主。
library;

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';

/// 禁区模式
class BlocklistPattern {
  final String pattern;
  final String label;

  /// 创建时间（可空，默认取当前时间）
  final DateTime? createdAt;

  BlocklistPattern({
    required this.pattern,
    this.label = '',
    this.createdAt,
  });

  DateTime get createdTime => createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': pattern,
    'pattern': pattern,
    'label': label,
    'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
  };

  factory BlocklistPattern.fromJson(Map<String, dynamic> json) =>
      BlocklistPattern(
        pattern: json['pattern'] as String,
        label: json['label'] as String? ?? '',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      );
}

/// 禁区存储
class BlocklistStore extends ButlerStore {
  @override
  String get id => 'blocklist';

  @override
  String get name => '禁区';

  static const String table = 'blocklist_patterns';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        pattern TEXT NOT NULL,
        label TEXT DEFAULT '',
        createdAt TEXT NOT NULL
      )
    ''');
  }

  /// 添加禁区模式
  Future<void> add(String pattern, {String label = ''}) async {
    await insert(
      table,
      BlocklistPattern(pattern: pattern, label: label).toJson(),
    );
  }

  /// 加载全部
  Future<List<BlocklistPattern>> all() async {
    final results = await db.query(table);
    return results.map((r) => BlocklistPattern.fromJson(r)).toList();
  }

  /// 删除
  Future<void> remove(String pattern) async {
    await delete(table, where: 'id = ?', whereArgs: [pattern]);
  }

  /// 检查文本是否命中禁区
  /// 返回命中的模式列表（未命中返回空）
  Future<List<BlocklistPattern>> match(String text) async {
    final patterns = await all();
    return patterns.where((p) => text.contains(p.pattern)).toList();
  }

  /// 数量
  Future<int> countAll() => super.count(table);
}
