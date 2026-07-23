import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../../../models/chat_message.dart';

/// 聊天消息持久化服务（SQLite）
///
/// 每条消息存储：id / persona_id / text / is_me / created_at
/// 支持按时间段查询（用于管家规律分析）
class ChatStorageService {
  static final ChatStorageService _instance = ChatStorageService._();
  factory ChatStorageService() => _instance;
  ChatStorageService._();

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'pocket_inn_chat.db'),
      version: 1,
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
      },
    );
    return _db!;
  }

  /// 加载某个角色的聊天记录（最多200条，按时间正序）
  Future<List<ChatMessage>> loadMessages(String personaId) async {
    try {
      final d = await db;
      final rows = await d.query('messages',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'created_at ASC',
        limit: 200,
      );
      return rows.map((r) => _rowToMessage(r)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存消息列表（全量替换）
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

  /// 追加一条消息
  Future<void> appendMessage(String personaId, ChatMessage message) async {
    try {
      final d = await db;
      await d.insert('messages', _messageToRow(personaId, message));
    } catch (_) {}
  }

  /// 更新一条消息
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

  /// 批量删除消息
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

  /// 清空某个角色的所有聊天记录
  Future<void> deleteAllMessages(String personaId) async {
    try {
      final d = await db;
      await d.delete('messages',
        where: 'persona_id = ?',
        whereArgs: [personaId]);
    } catch (_) {}
  }

  /// 按时间段查询消息（用于规律分析）
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
      if (from != null) {
        conditions.add('created_at >= ?');
        args.add(from.millisecondsSinceEpoch);
      }
      if (to != null) {
        conditions.add('created_at <= ?');
        args.add(to.millisecondsSinceEpoch);
      }
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
