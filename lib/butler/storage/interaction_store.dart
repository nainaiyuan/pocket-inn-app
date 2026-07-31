/// 互动记录存储 — 用户→男主→用户反应的完整链路（interaction_records 表）
///
/// 用于分析"男主怎么接 → 用户反应如何"的模式。
library;

import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';

/// 互动记录
class InteractionRecord {
  final String id;
  final DateTime createdAt;
  final String characterId;
  final String userTextSummary;
  final String characterResponse;
  final String? userFollowup;
  final String pattern; // neutral / positive / negative / conflict
  final List<String> keywords;
  final List<String> identityRefs;
  final int moodBefore;
  final int moodAfter;

  const InteractionRecord({
    required this.id,
    required this.createdAt,
    required this.characterId,
    this.userTextSummary = '',
    this.characterResponse = '',
    this.userFollowup,
    this.pattern = 'neutral',
    this.keywords = const [],
    this.identityRefs = const [],
    this.moodBefore = 0,
    this.moodAfter = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'characterId': characterId,
    'userTextSummary': userTextSummary,
    'characterResponse': characterResponse,
    'userFollowup': userFollowup,
    'pattern': pattern,
    'keywords': jsonEncode(keywords),
    'identityRefs': jsonEncode(identityRefs),
    'moodBefore': moodBefore,
    'moodAfter': moodAfter,
  };

  factory InteractionRecord.fromJson(Map<String, dynamic> json) =>
      InteractionRecord(
        id: json['id'] as String,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        characterId: json['characterId'] as String? ?? '',
        userTextSummary: json['userTextSummary'] as String? ?? '',
        characterResponse: json['characterResponse'] as String? ?? '',
        userFollowup: json['userFollowup'] as String?,
        pattern: json['pattern'] as String? ?? 'neutral',
        keywords: _decodeList(json['keywords']),
        identityRefs: _decodeList(json['identityRefs']),
        moodBefore: json['moodBefore'] as int? ?? 0,
        moodAfter: json['moodAfter'] as int? ?? 0,
      );

  static List<String> _decodeList(dynamic value) {
    if (value is List) return value.cast<String>();
    if (value is String) {
      try {
        return (jsonDecode(value) as List).cast<String>();
      } on Object {
        return const [];
      }
    }
    return const [];
  }
}

/// 互动记录存储
class InteractionStore extends ButlerStore {
  @override
  String get id => 'interaction';

  @override
  String get name => '互动记录';

  static const String table = 'interaction_records';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        createdAt TEXT NOT NULL,
        characterId TEXT NOT NULL,
        userTextSummary TEXT DEFAULT '',
        characterResponse TEXT DEFAULT '',
        userFollowup TEXT DEFAULT '',
        pattern TEXT DEFAULT 'neutral',
        keywords TEXT DEFAULT '[]',
        identityRefs TEXT DEFAULT '[]',
        moodBefore INTEGER DEFAULT 0,
        moodAfter INTEGER DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_interactions_char ON $table(characterId)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_interactions_pattern ON $table(pattern)');
  }

  /// 保存一条互动记录
  Future<void> save(InteractionRecord record) async {
    await insert(table, record.toJson());
  }

  /// 保存（兼容旧 Map 格式）
  Future<void> saveFromMap(Map<String, dynamic> data) async {
    await insert(table, {
      'id': data['id'] ?? '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}',
      'createdAt': data['createdAt'] ?? DateTime.now().toIso8601String(),
      'characterId': data['characterId'] ?? '',
      'userTextSummary': data['userTextSummary'] ?? '',
      'characterResponse': data['characterResponse'] ?? '',
      'userFollowup': data['userFollowup'] ?? '',
      'pattern': data['pattern'] ?? 'neutral',
      'keywords': data['keywords'] != null ? jsonEncode(data['keywords']) : '[]',
      'identityRefs': data['identityRefs'] != null ? jsonEncode(data['identityRefs']) : '[]',
      'moodBefore': data['moodBefore'] ?? 0,
      'moodAfter': data['moodAfter'] ?? 0,
    });
  }

  /// 某男主的互动模式统计
  Future<List<Map<String, dynamic>>> patterns({String? characterId}) async {
    if (characterId != null) {
      return db.rawQuery('''
        SELECT characterId, pattern, COUNT(*) as count
        FROM $table
        WHERE characterId = ?
        GROUP BY characterId, pattern
        ORDER BY count DESC
      ''', [characterId]);
    }
    return db.rawQuery('''
      SELECT characterId, pattern, COUNT(*) as count
      FROM $table
      GROUP BY characterId, pattern
      ORDER BY count DESC
    ''');
  }

  /// 某男主最近的互动记录
  Future<List<InteractionRecord>> recentByCharacter(
    String characterId, {
    int limit = 20,
  }) async {
    final results = await db.query(
      table,
      where: 'characterId = ?',
      whereArgs: [characterId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return results.map((r) => InteractionRecord.fromJson(r)).toList();
  }

  /// 最近互动（不区分角色，给检索调度用）
  Future<List<InteractionRecord>> recentAny({int limit = 10}) async {
    final results = await db.query(
      table,
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return results.map((r) => InteractionRecord.fromJson(r)).toList();
  }

  /// 互动统计
  Future<Map<String, int>> stats() async {
    final total = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $table'),
    ) ?? 0;
    final positive = Sqflite.firstIntValue(
      await db.rawQuery("SELECT COUNT(*) FROM $table WHERE pattern = 'positive'"),
    ) ?? 0;
    final negative = Sqflite.firstIntValue(
      await db.rawQuery("SELECT COUNT(*) FROM $table WHERE pattern = 'negative'"),
    ) ?? 0;
    final conflict = Sqflite.firstIntValue(
      await db.rawQuery("SELECT COUNT(*) FROM $table WHERE pattern = 'conflict'"),
    ) ?? 0;
    return {'total': total, 'positive': positive, 'negative': negative, 'conflict': conflict};
  }
}
