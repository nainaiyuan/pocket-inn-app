import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../../../models/chat_message.dart';
import '../../../utils/debug_logger.dart';
import '../state/chat_presence.dart';

/// 聊天消息持久化服务（SQLite）
///
/// === 表结构 ===
/// messages:   消息本体（id / persona_id / text / is_me / created_at）
/// memories:   男主对本次聊天的总结（persona_id / summary / created_at）
///              给管家用：即使清空聊天记录，总结也在
/// prompt_logs:每次发给男主的完整内容（persona_id / prompt_text / created_at）
///              8-04 16:4x（用户反馈"完整内容没收录、没按时间存"）：
///              发送的完整 prompt 落库，左上角 📄 弹窗重启后也能看，
///              且按时间可查——不再只是内存里的临时变量。
/// context_raw_logs:对话原文镜像（persona_id / role / text / created_at）
///              8-04 16:4x（用户"男主切换AI后失忆"）：ContextManager 的
///              话题原文是内存态，重启即丢。这里存【假面层替换后的干净
///              文本】（feed 时同步写），restore 时重建原文 → 重启/切换
///              AI 后男主还记得聊过什么；不存原始文本（避免泄露真实称呼，
///              用户 8-03 20:04 指示）。
class ChatStorageService {
  static final ChatStorageService _instance = ChatStorageService._();
  factory ChatStorageService() => _instance;
  ChatStorageService._();

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'pocket_inn_chat.db'),
      version: 6,
      onCreate: (db, version) async {
        // ⚠️ 8-04 16:2x 血泪教训：8-03 加 thinking_chain 列时只改了
        // onUpgrade 分支，忘了 onCreate —— 全新安装的库 messages 表
        // 缺这列，每次 insert 都报错被静默吞掉 → "退出重进对话全没了"
        // （用户实测：prompt_logs 2 条成功、messages 0 条）。两边必须同步！
        await db.execute('''
          CREATE TABLE messages (
            id TEXT NOT NULL,
            persona_id TEXT NOT NULL,
            text TEXT NOT NULL,
            is_me INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            thinking_chain TEXT,
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
        await db.execute('''
          CREATE TABLE prompt_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            persona_id TEXT NOT NULL,
            prompt_text TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_prompt_logs_persona_time ON prompt_logs(persona_id, created_at DESC)');
        // 8-04 16:4x：对话原文镜像（干净文本，restore 重建用）
        await db.execute('''
          CREATE TABLE context_raw_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            persona_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_context_raw_persona_time ON context_raw_logs(persona_id, created_at)');
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
        // 8-03 07:01：消息表加 thinking_chain 列（男主思考链随消息持久化）
        if (oldVersion < 3) {
          await db.execute(
              "ALTER TABLE messages ADD COLUMN thinking_chain TEXT");
        }
        // 8-04 16:4x：新增 prompt_logs 表（发给男主的完整内容，按时间存）
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS prompt_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              persona_id TEXT NOT NULL,
              prompt_text TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_prompt_logs_persona_time ON prompt_logs(persona_id, created_at DESC)');
        }
        // 8-04 16:2x 修复：老库 messages 表可能缺 thinking_chain 列
        // （v4 全新安装的库 onCreate 漏了这列）→ 检查补列，否则 insert 全失败
        if (oldVersion < 5) {
          final cols = await db.rawQuery('PRAGMA table_info(messages)');
          final hasThinkingChain =
              cols.any((c) => c['name'] == 'thinking_chain');
          if (!hasThinkingChain) {
            await db.execute(
                "ALTER TABLE messages ADD COLUMN thinking_chain TEXT");
          }
        }
        // 8-04 16:4x：对话原文镜像表（v6）
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS context_raw_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              persona_id TEXT NOT NULL,
              role TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_context_raw_persona_time ON context_raw_logs(persona_id, created_at)');
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
    } catch (e) {
      DebugLogger.log('存储', '❌ 消息加载失败（persona=$personaId）：$e');
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
    } catch (e) {
      // 8-04 16:2x：之前静默吞掉 → "退出重进对话全没了"查不出原因。
      // 落库失败必须留痕（运行日志可见）。
      DebugLogger.log(
        '存储',
        '❌ 消息落库失败（${message.isMe ? '用户' : '男主'}，'
            'id=${message.id ?? 'null'}，persona=$personaId）：$e',
      );
    }
  }

  /// 插到指定消息之前（8-03 18:2x：工具气泡挂男主第一句话头上）。
  /// 列表按 created_at ASC 排序 → 新消息的 created_at 取目标消息的
  /// 前一刻（按 [seq] 递减，多条插入顺序稳定），保证重载后位置一致。
  Future<void> insertMessageBefore(
    String personaId,
    ChatMessage message,
    String beforeId, {
    int seq = 0,
  }) async {
    try {
      final d = await db;
      final target = await d.query('messages',
        where: 'id = ? AND persona_id = ?',
        whereArgs: [beforeId, personaId],
        limit: 1,
      );
      if (target.isEmpty) {
        await appendMessage(personaId, message);
        return;
      }
      final targetTime = (target.first['created_at'] as int?) ??
          DateTime.now().millisecondsSinceEpoch;
      final row = _messageToRow(personaId, message);
      // seq 越大时间差越小 → ASC 排序后先插入的（seq 小）在上，顺序稳定
      row['created_at'] = targetTime - (600 - seq % 600) * 1000;
      await d.insert('messages', row);
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

  // ═══════════════════════════════════
  // 完整 prompt 记录（8-04 16:4x：发给男主的完整内容，按时间持久化）
  // ═══════════════════════════════════

  /// 保存一次发给男主的完整内容
  Future<void> savePromptLog(String personaId, String promptText) async {
    if (promptText.trim().isEmpty) return;
    try {
      final d = await db;
      await d.insert('prompt_logs', {
        'persona_id': personaId,
        'prompt_text': promptText,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  /// 读取某个角色最近的完整 prompt（弹窗用：内存为空时从 DB 兜底）
  Future<String?> loadLatestPromptLog(String personaId) async {
    try {
      final d = await db;
      final rows = await d.query('prompt_logs',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['prompt_text'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 按时间段列出某个角色的完整 prompt 记录（记忆树/会话记录入口用）
  Future<List<Map<String, dynamic>>> queryPromptLogs(
    String personaId, {
    DateTime? from,
    DateTime? to,
    int limit = 20,
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
      return await d.query('prompt_logs',
        where: conditions.join(' AND '),
        whereArgs: args,
        orderBy: 'created_at DESC',
        limit: limit,
      );
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════
  // 对话原文镜像（8-04 16:4x：ContextManager 原文内存态 → 落库重建）
  // 只存【假面层替换后的干净文本】（feed 时同步写），不存原始文本
  // ═══════════════════════════════════

  /// 追加一条原文镜像（role: '用户' / '男主'）
  Future<void> appendContextRaw(
      String personaId, String role, String text) async {
    if (text.trim().isEmpty) return;
    try {
      final d = await db;
      await d.insert('context_raw_logs', {
        'persona_id': personaId,
        'role': role,
        'text': text,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      // 只保留最近 600 条（防无限膨胀；600 条足够重建上下文）
      final rows = await d.rawQuery(
          'SELECT COUNT(*) AS c FROM context_raw_logs WHERE persona_id = ?',
          [personaId]);
      final count = (rows.first['c'] as int?) ?? 0;
      if (count > 600) {
        await d.rawDelete(
          'DELETE FROM context_raw_logs WHERE id IN '
          '(SELECT id FROM context_raw_logs WHERE persona_id = ? '
          'ORDER BY created_at ASC LIMIT ?)',
          [personaId, count - 600],
        );
      }
    } catch (_) {}
  }

  /// 加载最近的原文镜像（按时间正序返回，restore 重建 raw 用）
  Future<List<({String role, String text, int createdAt})>> loadContextRaw(
    String personaId, {
    int limit = 200,
  }) async {
    try {
      final d = await db;
      final rows = await d.query('context_raw_logs',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.reversed.map((r) => (
        role: (r['role'] as String? ?? '用户'),
        text: (r['text'] as String? ?? ''),
        createdAt: (r['created_at'] as int? ?? 0),
      )).toList();
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
      // 8-03 07:01：思考链随消息持久化（历史消息也能展开看）
      thinkingChain: row['thinking_chain'] as String?,
    );
  }

  Map<String, dynamic> _messageToRow(String personaId, ChatMessage m) {
    return {
      'id': m.id,
      'persona_id': personaId,
      'text': m.text,
      'is_me': m.isMe ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'thinking_chain': m.thinkingChain,
    };
  }
}
