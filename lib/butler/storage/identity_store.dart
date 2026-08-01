/// 身份映射存储 — 假面层映射表（identity_mappings + session_mappings）
///
/// 假面层 = 把用户身边的真实人物（老板、前任、闺蜜）替换成代号，
/// 男主 AI 只看到代号，看不到真实身份。这里存真实↔代号对应关系。
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';

/// 身份映射
class IdentityEntry {
  final String id;
  final String realLabel; // 真实称呼（如 "妈妈"）
  final String category; // 分类（family / friend / work / stranger）
  final List<String> descriptions; // 描述池：每条 = 一段说明/经历/情感，轮换随机取
  final String relationType; // 旧版字段（兼容历史数据，新 UI 不再使用）
  final String importance; // core / normal / temp（内部用，UI 不再让用户选）
  final String? attitude; // 用户对该人的态度（保留兼容）

  const IdentityEntry({
    required this.id,
    required this.realLabel,
    this.category = '',
    this.descriptions = const [],
    this.relationType = '',
    this.importance = 'normal',
    this.attitude,
    this.createdAt,
  });

  /// 创建时间（可空，默认取当前时间）
  final DateTime? createdAt;

  DateTime get createdTime => createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'realLabel': realLabel,
    'category': category,
    'descriptions': _encodeDescriptions(descriptions),
    'relationType': relationType,
    'importance': importance,
    'attitude': attitude,
    'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
  };

  factory IdentityEntry.fromJson(Map<String, dynamic> json) => IdentityEntry(
    id: json['id'] as String,
    realLabel: json['realLabel'] as String,
    category: json['category'] as String? ?? '',
    descriptions: _decodeDescriptions(json['descriptions']),
    relationType: json['relationType'] as String? ?? '',
    importance: json['importance'] as String? ?? 'normal',
    attitude: json['attitude'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );

  static String _encodeDescriptions(List<String> list) {
    try {
      return const JsonEncoder().convert(list);
    } catch (_) {
      return '[]';
    }
  }

  static List<String> _decodeDescriptions(dynamic raw) {
    if (raw == null || raw.toString().isEmpty) return const [];
    try {
      final decoded = const JsonDecoder().convert(raw.toString());
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return const [];
  }
}

/// 身份映射存储
class IdentityStore extends ButlerStore {
  @override
  String get id => 'identity';

  @override
  String get name => '身份映射';

  static const String table = 'identity_mappings';
  static const String sessionTable = 'session_mappings';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        realLabel TEXT NOT NULL,
        category TEXT DEFAULT '',
        relationType TEXT DEFAULT '',
        descriptions TEXT DEFAULT '[]',
        importance TEXT DEFAULT 'normal',
        attitude TEXT,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $sessionTable (
        sessionId TEXT NOT NULL,
        identityId TEXT NOT NULL,
        code TEXT NOT NULL,
        relationSummary TEXT,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (sessionId, identityId)
      )
    ''');
  }

  /// 保存身份
  Future<void> save(IdentityEntry entry) async {
    await insert(table, entry.toJson());
  }

  /// 数据库升级：旧版本没有 descriptions 列时补上
  static Future<void> upgradeFromV4(Database db) async {
    // 检查列是否存在（PRAGMA 不抛错，列已存在时跳过）
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final hasDescriptions = cols.any((c) => c['name'] == 'descriptions');
    if (!hasDescriptions) {
      await db.execute(
        "ALTER TABLE $table ADD COLUMN descriptions TEXT DEFAULT '[]'",
      );
    }
  }

  /// 加载所有
  Future<List<IdentityEntry>> all() async {
    final results = await db.query(table);
    return results.map((r) => IdentityEntry.fromJson(r)).toList();
  }

  /// 保存会话映射
  Future<void> saveSessionMapping({
    required String sessionId,
    required String identityId,
    required String code,
    String? relationSummary,
  }) async {
    await insert(sessionTable, {
      'sessionId': sessionId,
      'identityId': identityId,
      'code': code,
      'relationSummary': relationSummary,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  /// 加载会话所有映射（identityId → code）
  Future<Map<String, String>> sessionMappings(String sessionId) async {
    final results = await db.query(
      sessionTable,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
    );
    return {
      for (final row in results)
        row['identityId'] as String: row['code'] as String,
    };
  }

  /// 清除会话映射
  Future<void> clearSessionMappings(String sessionId) async {
    await delete(
      sessionTable,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
    );
  }

  /// 身份衰减：普通身份超过30天未使用 → 返回可清理列表
  Future<List<String>> decayCandidates() async {
    final thirtyDaysAgo = DateTime.now()
        .subtract(const Duration(days: 30))
        .toIso8601String();
    final stale = await db.rawQuery('''
      SELECT id FROM $table
      WHERE importance = 'normal'
      AND id NOT IN (
        SELECT DISTINCT identityId FROM $sessionTable
        WHERE createdAt >= ?
      )
    ''', [thirtyDaysAgo]);
    return stale.map((r) => r['id'] as String).toList();
  }

  /// 数量
  Future<int> countAll() => super.count(table);
}
