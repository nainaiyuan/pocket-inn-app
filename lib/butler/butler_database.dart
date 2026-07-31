import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'butler_memory.dart';

/// 管家记忆数据库
/// SQLite 存储，只存真实信息，永不上传
class ButlerDatabase {
  static ButlerDatabase? _instance;
  Database? _db;

  ButlerDatabase._();

  static ButlerDatabase get instance {
    _instance ??= ButlerDatabase._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_db != null) return;

    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'pocket_inn_data', 'butler_memory.db');

    _db = await openDatabase(
      dbPath,
      version: 4,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createInteractionsTable(db);
          await _createBlocklistTable(db);
        }
        if (oldVersion < 3) {
          await _createVaultIndexTable(db);
        }
        if (oldVersion < 4) {
          await _createTriggerTable(db);
        }
        if (oldVersion < 4) {
          await _createTriggerTable(db);
        }
      },
    );
  }

  Future<void> _createTables(Database db) async {
    // 主记忆表
    await db.execute('''
      CREATE TABLE butler_memories (
        id TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        content TEXT NOT NULL,
        maskedContent TEXT DEFAULT '',
        topic TEXT DEFAULT '',
        importance TEXT DEFAULT 'normal',
        keywords TEXT DEFAULT '[]',
        source TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        isArchived INTEGER DEFAULT 0
      )
    ''');

        // 假面层映射表（真实 → 代号的对应关系）
        await db.execute('''
          CREATE TABLE identity_mappings (
            id TEXT PRIMARY KEY,
            realLabel TEXT NOT NULL,
            category TEXT DEFAULT '',
            relationType TEXT DEFAULT '',
            importance TEXT DEFAULT 'normal',
            attitude TEXT,
            createdAt TEXT NOT NULL
          )
        ''');

        // 会话映射表（session → identity → code）
        await db.execute('''
          CREATE TABLE session_mappings (
            sessionId TEXT NOT NULL,
            identityId TEXT NOT NULL,
            code TEXT NOT NULL,
            relationSummary TEXT,
            createdAt TEXT NOT NULL,
            PRIMARY KEY (sessionId, identityId)
          )
        ''');

        // 索引
        await db.execute('CREATE INDEX idx_memories_session ON butler_memories(sessionId)');
        await db.execute('CREATE INDEX idx_memories_topic ON butler_memories(topic)');
        await db.execute('CREATE INDEX idx_memories_importance ON butler_memories(importance)');
        await db.execute('CREATE INDEX idx_memories_created ON butler_memories(createdAt)');

        // 互动记录表（记录用户→男主→用户反应的完整链路）
        await _createInteractionsTable(db);

        // 禁区表
        await _createBlocklistTable(db);

        // 保险箱索引表
        await _createVaultIndexTable(db);

        // 触发器表
        await _createTriggerTable(db);
  }

  Future<void> _createInteractionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS interaction_records (
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
    await db.execute('CREATE INDEX IF NOT EXISTS idx_interactions_char ON interaction_records(characterId)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_interactions_pattern ON interaction_records(pattern)');
  }

  Future<void> _createBlocklistTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS blocklist_patterns (
        id TEXT PRIMARY KEY,
        pattern TEXT NOT NULL,
        label TEXT DEFAULT '',
        createdAt TEXT NOT NULL
      )
    ''');
  }

  /// 创建保险箱索引表
  Future<void> _createVaultIndexTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vault_index (
        id TEXT PRIMARY KEY,
        fileName TEXT NOT NULL,
        fileType TEXT DEFAULT 'other',
        fileSize INTEGER DEFAULT 0,
        category TEXT DEFAULT '默认',
        note TEXT,
        createdAt TEXT NOT NULL,
        lastAccessedAt TEXT NOT NULL
      )
    ''');
  }

  /// 创建触发器表
  Future<void> _createTriggerTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS butler_triggers (
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

  /// 检查表是否存在
  Future<bool> _tableExists(String tableName) async {
    final result = await _db!.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [tableName],
    );
    return result.isNotEmpty;
  }

  // ========== 记忆操作 ==========

  /// 保存记忆
  Future<void> saveMemory(ButlerMemory memory) async {
    _ensureDb();
    await _db!.insert('butler_memories', memory.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 批量保存
  Future<void> saveMemories(List<ButlerMemory> memories) async {
    _ensureDb();
    final batch = _db!.batch();
    for (final m in memories) {
      batch.insert('butler_memories', m.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 按会话加载记忆
  Future<List<ButlerMemory>> loadSessionMemories(String sessionId, {int? limit}) async {
    _ensureDb();

    var query = 'SELECT * FROM butler_memories WHERE sessionId = ? AND isArchived = 0 ORDER BY createdAt ASC';
    final args = <dynamic>[sessionId];

    if (limit != null) {
      query += ' LIMIT ?';
      args.add(limit);
    }

    final results = await _db!.rawQuery(query, args);
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 按关键词搜索记忆
  Future<List<ButlerMemory>> searchMemories(String query, {int? limit}) async {
    _ensureDb();

    final like = '%$query%';
    var sql = '''
      SELECT * FROM butler_memories
      WHERE isArchived = 0
        AND (content LIKE ? OR topic LIKE ? OR keywords LIKE ?)
      ORDER BY createdAt DESC
    ''';
    final args = <dynamic>[like, like, like];

    if (limit != null) {
      sql += ' LIMIT ?';
      args.add(limit);
    }

    final results = await _db!.rawQuery(sql, args);
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 按重要性加载
  Future<List<ButlerMemory>> loadImportantMemories({int? limit}) async {
    _ensureDb();

    var sql = '''
      SELECT * FROM butler_memories
      WHERE isArchived = 0 AND importance IN ('core', 'normal')
      ORDER BY
        CASE importance
          WHEN 'core' THEN 0
          WHEN 'normal' THEN 1
          WHEN 'temp' THEN 2
        END,
        createdAt DESC
    ''';

    if (limit != null) sql += ' LIMIT $limit';

    final results = await _db!.rawQuery(sql);
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 获取最新 N 条记忆
  Future<List<ButlerMemory>> getRecentMemories(int count) async {
    _ensureDb();

    final results = await _db!.rawQuery(
      'SELECT * FROM butler_memories WHERE isArchived = 0 ORDER BY createdAt DESC LIMIT ?',
      [count],
    );
    return results.map((r) => ButlerMemory.fromJson(r)).toList();
  }

  /// 删除记忆（软删除）
  Future<void> archiveMemory(String id) async {
    _ensureDb();
    await _db!.update(
      'butler_memories',
      {'isArchived': 1, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新记忆内容
  Future<void> updateMemory(String id, String newContent) async {
    _ensureDb();
    await _db!.update(
      'butler_memories',
      {'content': newContent, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ========== 身份映射操作 ==========

  /// 保存身份
  Future<void> saveIdentity(Map<String, dynamic> identity) async {
    _ensureDb();
    await _db!.insert('identity_mappings', identity,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 加载所有身份
  Future<List<Map<String, dynamic>>> loadAllIdentities() async {
    _ensureDb();
    return _db!.query('identity_mappings');
  }

  /// 保存会话映射
  Future<void> saveSessionMapping(String sessionId, String identityId, String code, String? relationSummary) async {
    _ensureDb();
    await _db!.insert('session_mappings', {
      'sessionId': sessionId,
      'identityId': identityId,
      'code': code,
      'relationSummary': relationSummary,
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 加载会话的所有映射
  Future<Map<String, String>> loadSessionMappings(String sessionId) async {
    _ensureDb();
    final results = await _db!.query(
      'session_mappings',
      where: 'sessionId = ?',
      whereArgs: [sessionId],
    );
    final map = <String, String>{};
    for (final row in results) {
      map[row['identityId'] as String] = row['code'] as String;
    }
    return map;
  }

  /// 清除会话映射
  Future<void> clearSessionMappings(String sessionId) async {
    _ensureDb();
    await _db!.delete('session_mappings', where: 'sessionId = ?', whereArgs: [sessionId]);
  }

  /// 获取记忆数量统计
  Future<Map<String, int>> getStats() async {
    _ensureDb();
    final total = Sqflite.firstIntValue(
      await _db!.rawQuery('SELECT COUNT(*) FROM butler_memories WHERE isArchived = 0'),
    ) ?? 0;
    final core = Sqflite.firstIntValue(
      await _db!.rawQuery("SELECT COUNT(*) FROM butler_memories WHERE importance = 'core' AND isArchived = 0"),
    ) ?? 0;
    final temp = Sqflite.firstIntValue(
      await _db!.rawQuery("SELECT COUNT(*) FROM butler_memories WHERE importance = 'temp' AND isArchived = 0"),
    ) ?? 0;
    final identities = Sqflite.firstIntValue(
      await _db!.rawQuery('SELECT COUNT(*) FROM identity_mappings'),
    ) ?? 0;

    return {
      'total': total,
      'core': core,
      'temp': temp,
      'identities': identities,
    };
  }

  /// 获取互动统计
  Future<Map<String, int>> getInteractionStats() async {
    _ensureDb();
    final total = Sqflite.firstIntValue(
      await _db!.rawQuery('SELECT COUNT(*) FROM interaction_records'),
    ) ?? 0;
    final positive = Sqflite.firstIntValue(
      await _db!.rawQuery("SELECT COUNT(*) FROM interaction_records WHERE pattern = 'positive'"),
    ) ?? 0;
    final negative = Sqflite.firstIntValue(
      await _db!.rawQuery("SELECT COUNT(*) FROM interaction_records WHERE pattern = 'negative'"),
    ) ?? 0;
    final conflict = Sqflite.firstIntValue(
      await _db!.rawQuery("SELECT COUNT(*) FROM interaction_records WHERE pattern = 'conflict'"),
    ) ?? 0;

    return {
      'total': total,
      'positive': positive,
      'negative': negative,
      'conflict': conflict,
    };
  }

  // ========== 互动记录 ==========

  /// 保存一条互动记录
  Future<void> saveInteraction(Map<String, dynamic> data) async {
    _ensureDb();
    await _db!.insert('interaction_records', {
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
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 获取某个男主的互动模式统计
  Future<List<Map<String, dynamic>>> getInteractionPatterns({String? characterId}) async {
    _ensureDb();
    if (characterId != null) {
      return _db!.rawQuery('''
        SELECT characterId, pattern, COUNT(*) as count
        FROM interaction_records
        WHERE characterId = ?
        GROUP BY characterId, pattern
        ORDER BY count DESC
      ''', [characterId]);
    }
    return _db!.rawQuery('''
      SELECT characterId, pattern, COUNT(*) as count
      FROM interaction_records
      GROUP BY characterId, pattern
      ORDER BY count DESC
    ''');
  }

  /// 获取某个男主最近的互动记录
  Future<List<Map<String, dynamic>>> getRecentInteractions(String characterId, {int limit = 20}) async {
    _ensureDb();
    return _db!.query(
      'interaction_records',
      where: 'characterId = ?',
      whereArgs: [characterId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
  }

  // ========== 禁区管理 ==========

  /// 添加禁区模式
  Future<void> addBlocklistPattern(String pattern, {String label = ''}) async {
    _ensureDb();
    await _db!.insert('blocklist_patterns', {
      'id': pattern,
      'pattern': pattern,
      'label': label,
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 加载所有禁区模式
  Future<List<Map<String, dynamic>>> loadBlocklistPatterns() async {
    _ensureDb();
    return _db!.query('blocklist_patterns');
  }

  /// 删除禁区模式
  Future<void> removeBlocklistPattern(String pattern) async {
    _ensureDb();
    await _db!.delete('blocklist_patterns', where: 'id = ?', whereArgs: [pattern]);
  }

  // ========== 身份衰减 ==========

  /// 执行身份衰减
  /// 普通身份超过30天未使用 → 标记可清理
  Future<int> decayIdentities() async {
    _ensureDb();
    final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();

    final stale = await _db!.rawQuery('''
      SELECT id FROM identity_mappings
      WHERE importance = 'normal'
      AND id NOT IN (
        SELECT DISTINCT identityId FROM session_mappings
        WHERE createdAt >= ?
      )
    ''', [thirtyDaysAgo]);

    for (final row in stale) {
      print('身份 ${row['id']} 已超过30天未使用，建议清理');
    }
    return stale.length;
  }

  // ========== 触发器管理 ==========

  /// 添加触发器
  Future<void> addTrigger(Map<String, dynamic> data) async {
    _ensureDb();
    await _db!.insert('butler_triggers', {
      'id': data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      'triggerType': data['triggerType'] ?? 'topic',
      'matchValue': data['matchValue'] ?? '',
      'action': data['action'] ?? 'remind_user',
      'content': data['content'] ?? '',
      'enabled': data['enabled'] ?? 1,
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 获取所有启用的触发器
  Future<List<Map<String, dynamic>>> getActiveTriggers() async {
    _ensureDb();
    return _db!.query('butler_triggers', where: 'enabled = 1');
  }

  /// 按类型查询触发器
  Future<List<Map<String, dynamic>>> getTriggersByType(String type) async {
    _ensureDb();
    return _db!.query('butler_triggers', where: 'triggerType = ? AND enabled = 1', whereArgs: [type]);
  }

  /// 切换触发器启用状态
  Future<void> toggleTrigger(String id) async {
    _ensureDb();
    final current = await _db!.query('butler_triggers', where: 'id = ?', whereArgs: [id]);
    if (current.isNotEmpty) {
      final enabled = current.first['enabled'] == 1 ? 0 : 1;
      await _db!.update('butler_triggers', {'enabled': enabled}, where: 'id = ?', whereArgs: [id]);
    }
  }

  /// 删除触发器
  Future<void> removeTrigger(String id) async {
    _ensureDb();
    await _db!.delete('butler_triggers', where: 'id = ?', whereArgs: [id]);
  }

  void _ensureDb() {
    if (_db == null) {
      throw StateError('ButlerDatabase 未初始化，请先调用 initialize()');
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
