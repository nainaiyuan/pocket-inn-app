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
  final String gender; // 性别：female / male / ''（用户 18:58：添加性别，男主可用"她/他"）

  const IdentityEntry({
    required this.id,
    required this.realLabel,
    this.category = '',
    this.descriptions = const [],
    this.relationType = '',
    this.importance = 'normal',
    this.attitude,
    this.gender = '',
    this.createdAt,
  });

  /// 创建时间（可空，默认取当前时间）
  final DateTime? createdAt;

  DateTime get createdTime => createdAt ?? DateTime.now();

  /// 性别代词（描述用）：女→她，男→他，未知→ta
  String get pronoun => gender == 'female' ? '她' : (gender == 'male' ? '他' : 'ta');

  Map<String, dynamic> toJson() => {
    'id': id,
    'realLabel': realLabel,
    'category': category,
    'descriptions': _encodeDescriptions(descriptions),
    'relationType': relationType,
    'importance': importance,
    'attitude': attitude,
    'gender': gender,
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
    gender: json['gender'] as String? ?? '',
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

/// 身份记忆条目（#A# 记忆：男主写的、用户确认的、跟随身份不跟随代号）
class IdentityMemory {
  final String id;
  final String identityId;
  final String content;
  final String status; // pending / confirmed / rejected
  final DateTime createdAt;

  const IdentityMemory({
    required this.id,
    required this.identityId,
    required this.content,
    this.status = 'pending',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'identityId': identityId,
    'content': content,
    'status': status,
    'createdAt': createdAt.toIso8601String(),
  };

  factory IdentityMemory.fromJson(Map<String, dynamic> json) => IdentityMemory(
    id: json['id'] as String,
    identityId: json['identityId'] as String,
    content: json['content'] as String,
    status: json['status'] as String? ?? 'pending',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.now(),
  );
}

/// 身份映射存储
class IdentityStore extends ButlerStore {
  @override
  String get id => 'identity';

  @override
  String get name => '身份映射';

  static const String table = 'identity_mappings';
  static const String sessionTable = 'session_mappings';
  static const String memoryTable = 'identity_memories';

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
        gender TEXT DEFAULT '',
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
    // 身份记忆区（用户 18:58：#A# 记忆，跟随身份不跟随代号）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $memoryTable (
        id TEXT PRIMARY KEY,
        identityId TEXT NOT NULL,
        content TEXT NOT NULL,
        status TEXT DEFAULT 'pending',
        createdAt TEXT NOT NULL
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
    // 37批：gender 列（老库没有时补上）
    final hasGender = cols.any((c) => c['name'] == 'gender');
    if (!hasGender) {
      await db.execute(
        "ALTER TABLE $table ADD COLUMN gender TEXT DEFAULT ''",
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

  // ── 身份记忆区（#A# 记忆，跟随身份不跟随代号）──

  /// 新增一条身份记忆（男主写的，默认 pending 待用户确认）
  Future<void> addIdentityMemory({
    required String identityId,
    required String content,
  }) async {
    await insert(memoryTable, IdentityMemory(
      id: '${identityId}_${DateTime.now().millisecondsSinceEpoch}',
      identityId: identityId,
      content: content,
      createdAt: DateTime.now(),
    ).toJson());
  }

  /// 加载某身份的已确认记忆（注入用）
  Future<List<IdentityMemory>> confirmedMemories(String identityId) async {
    final results = await db.query(
      memoryTable,
      where: 'identityId = ? AND status = ?',
      whereArgs: [identityId, 'confirmed'],
      orderBy: 'createdAt DESC',
    );
    return results.map((r) => IdentityMemory.fromJson(r)).toList();
  }

  /// 加载全部待确认记忆（用户确认页）
  Future<List<IdentityMemory>> pendingMemories() async {
    final results = await db.query(
      memoryTable,
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'createdAt DESC',
    );
    return results.map((r) => IdentityMemory.fromJson(r)).toList();
  }

  /// 更新记忆状态（pending → confirmed / rejected）
  Future<void> updateMemoryStatus(String id, String status) async {
    await update(
      memoryTable,
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
