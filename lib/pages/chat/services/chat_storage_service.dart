import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../../../models/chat_message.dart';
import '../state/chat_presence.dart';

/// 聊天消息持久化服务（SQLite）
///
/// === 表结构 ===
/// messages:   消息本体（id / persona_id / text / is_me / created_at）
/// memories:   男主对本次聊天的总结（persona_id / summary / created_at）
///              给管家用：即使清空聊天记录，总结也在
class ChatStorageService {
  static final ChatStorageService _instance = ChatStorageService._();
  factory ChatStorageService() => _instance;
  ChatStorageService._();

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'pocket_inn_chat.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id TEXT NOT NULL,
            persona_id TEXT NOT NULL,
            text TEXT NOT NULL,
            is_me INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (id, persona_id)
          )
        ''');
        await db.execute('CREATE INDEX idx_messages_persona ON messages(persona_id)');
        await db.execute('CREATE INDEX idx_messages_time ON messages(created_at)');

        // 记忆总结表（管家写入，即使清空聊天记录也保留）
        await db.execute('''
          CREATE TABLE memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            persona_id TEXT NOT NULL,
            summary TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_memories_persona ON memories(persona_id)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS memories (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              persona_id TEXT NOT NULL,
              summary TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_memories_persona ON memories(persona_id)');
        }
      },
    );
    return _db!;
  }

  // ═══════════════════════════════════
  // 消息操作
  // ═══════════════════════════════════

  Future<List<ChatMessage>> loadMessages(String personaId) async {
    try {
      final d = await db;
      final rows = await d.query('messages',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'created_at ASC',
        limit: 200,
      );
      // 记录消息时间戳（聊天界面"时间/已读"展示用）
      final ts = <String, DateTime>{};
      for (final r in rows) {
        final id = r['id'] as String?;
        final created = r['created_at'] as int?;
        if (id != null && created != null) {
          ts[id] = DateTime.fromMillisecondsSinceEpoch(created);
        }
      }
      ChatPresence.instance.recordTimestampsMap(ts);
      return rows.map((r) => _rowToMessage(r)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessages(String personaId, List<ChatMessage> messages) async {
    try {
      final d = await db;
      await d.transaction((txn) async {
        await txn.delete('messages', where: 'persona_id = ?', whereArgs: [personaId]);
        final trimmed = messages.length > 200
            ? messages.sublist(messages.length - 200)
            : messages;
        for (final m in trimmed) {
          await txn.insert('messages', _messageToRow(personaId, m));
        }
      });
    } catch (_) {}
  }

  Future<void> appendMessage(String personaId, ChatMessage message) async {
    try {
      final d = await db;
      await d.insert('messages', _messageToRow(personaId, message));
      // 新消息时间戳立即可用（聊天界面展示）
      ChatPresence.instance.recordTimestampsMap({
        if (message.id != null) message.id!: DateTime.now(),
      });
    } catch (_) {}
  }

  Future<void> updateMessage(
      String personaId, String messageId, ChatMessage updated) async {
    try {
      final d = await db;
      await d.update('messages', {
        'text': updated.text,
        'is_me': updated.isMe ? 1 : 0,
      }, where: 'id = ? AND persona_id = ?',
        whereArgs: [messageId, personaId]);
    } catch (_) {}
  }

  Future<void> deleteMessages(String personaId, List<String> messageIds) async {
    try {
      final d = await db;
      await d.transaction((txn) async {
        for (final mid in messageIds) {
          await txn.delete('messages',
            where: 'id = ? AND persona_id = ?',
            whereArgs: [mid, personaId]);
        }
      });
    } catch (_) {}
  }

  /// 清空消息（记忆总结不受影响）
  Future<void> deleteAllMessages(String personaId) async {
    try {
      final d = await db;
      await d.delete('messages',
        where: 'persona_id = ?',
        whereArgs: [personaId]);
    } catch (_) {}
  }

  /// 按时间段查询消息
  Future<List<ChatMessage>> queryMessages({
    required String personaId,
    DateTime? from,
    DateTime? to,
    int limit = 1000,
  }) async {
    try {
      final d = await db;
      final conditions = <String>['persona_id = ?'];
      final args = <dynamic>[personaId];
      if (from != null) { conditions.add('created_at >= ?'); args.add(from.millisecondsSinceEpoch); }
      if (to != null)   { conditions.add('created_at <= ?'); args.add(to.millisecondsSinceEpoch); }
      final rows = await d.query('messages',
        where: conditions.join(' AND '),
        whereArgs: args,
        orderBy: 'created_at ASC',
        limit: limit,
      );
      return rows.map((r) => _rowToMessage(r)).toList();
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════
  // 记忆总结（管家写入，用户清空消息后仍保留）
  // ═══════════════════════════════════

  /// 写入男主对本次聊天的总结
  Future<void> saveMemory(String personaId, String summary) async {
    try {
      final d = await db;
      await d.insert('memories', {
        'persona_id': personaId,
        'summary': summary,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  /// 读取某个角色最近的 N 条记忆总结
  Future<List<Map<String, dynamic>>> getMemories(
    String personaId, {
    int limit = 10,
  }) async {
    try {
      final d = await db;
      return await d.query('memories',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'created_at DESC',
        limit: limit,
      );
    } catch (_) {
      return [];
    }
  }

  /// 删除某个角色的所有记忆总结（很少用，仅用户手动清除）
  Future<void> deleteMemories(String personaId) async {
    try {
      final d = await db;
      await d.delete('memories',
        where: 'persona_id = ?',
        whereArgs: [personaId]);
    } catch (_) {}
  }

  // ─── 辅助 ───

  ChatMessage _rowToMessage(Map<String, dynamic> row) {
    return ChatMessage(
      id: row['id'] as String,
      text: row['text'] as String,
      isMe: (row['is_me'] as int) == 1,
    );
  }

  Map<String, dynamic> _messageToRow(String personaId, ChatMessage m) {
    return {
      'id': m.id,
      'persona_id': personaId,
      'text': m.text,
      'is_me': m.isMe ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
  }
}
