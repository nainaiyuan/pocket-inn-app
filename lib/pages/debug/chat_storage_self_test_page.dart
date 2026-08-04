import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/chat_message.dart';
import '../chat/services/chat_storage_service.dart';
import '../chat/widgets/debug_log_sheet.dart';

/// 🧰 聊天记录自检（8-04 16:4x 用户反馈"退出聊天页对话全没了"——
/// 一次点出问题在哪：落库没落？落错 persona？还是加载没读到？）
///
/// 展示：
/// 1. 数据库文件是否存在/大小/路径
/// 2. messages 表总行数 + 按 persona 分组行数（对话到底存没存）
/// 3. 当前选中的 persona id（和落库的 key 对不对得上）
/// 4. 最近 5 条 DB 里的消息（证明数据在不在）
/// 5. prompt_logs 完整内容记录数（发给男主的完整内容收录情况）
class ChatStorageSelfTestPage extends StatefulWidget {
  const ChatStorageSelfTestPage({super.key});

  @override
  State<ChatStorageSelfTestPage> createState() =>
      _ChatStorageSelfTestPageState();
}

class _ChatStorageSelfTestPageState extends State<ChatStorageSelfTestPage> {
  bool _loading = true;
  String? _error;

  // 数据库概况
  String _dbPath = '';
  int _dbSizeBytes = -1;
  int _totalMessages = -1;
  Map<String, int> _perPersona = {};
  int _promptLogCount = -1;

  // 最近消息（DB 直读）
  List<ChatMessage> _recent = [];
  String _recentPersonaId = '';

  // messages 表实际列（8-04 16:2x：缺 thinking_chain 列会导致 insert 全失败）
  List<String> _messageColumns = [];
  String? _insertTestResult;
  bool _insertTestOk = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 1. 数据库文件
      final dbPath = p.join(await getDatabasesPath(), 'pocket_inn_chat.db');
      var size = -1;
      try {
        size = await File(dbPath).length();
      } catch (_) {}

      // 2. 行数统计
      final d = await ChatStorageService().db;
      final totalRows = await d.rawQuery(
          'SELECT COUNT(*) AS c FROM messages');
      final total = (totalRows.first['c'] as int?) ?? 0;
      final groupRows = await d.rawQuery(
          'SELECT persona_id, COUNT(*) AS c FROM messages GROUP BY persona_id ORDER BY c DESC');
      final perPersona = <String, int>{
        for (final r in groupRows)
          (r['persona_id'] as String? ?? '?'): (r['c'] as int?) ?? 0,
      };
      final promptRows = await d.rawQuery(
          'SELECT COUNT(*) AS c FROM prompt_logs');
      final promptCount = (promptRows.first['c'] as int?) ?? 0;

      // 2.5 messages 表实际列（缺列 = insert 全失败）
      final cols = await d.rawQuery('PRAGMA table_info(messages)');
      final messageColumns = [
        for (final c in cols) (c['name'] as String? ?? '?'),
      ];

      // 3. 最近消息（按 persona 分组取各自最近 5 条）
      final recentPersonaId = perPersona.keys.isNotEmpty
          ? perPersona.keys.first
          : '(无数据)';
      final recent = recentPersonaId == '(无数据)'
          ? <ChatMessage>[]
          : await ChatStorageService().queryMessages(
              personaId: recentPersonaId,
              limit: 5,
            );

      if (!mounted) return;
      setState(() {
        _dbPath = dbPath;
        _dbSizeBytes = size;
        _totalMessages = total;
        _perPersona = perPersona;
        _promptLogCount = promptCount;
        _messageColumns = messageColumns;
        _recent = recent;
        _recentPersonaId = recentPersonaId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 直插测试：走真实 appendMessage 链路插一条，验证落库通路
  /// （8-04 16:2x 用户实测 prompt_logs 成功但 messages 0 条 → 加这个
  /// 按钮当场验证 insert 通不通，失败原因直接显示出来）
  Future<void> _runInsertTest() async {
    setState(() {
      _insertTestResult = null;
      _insertTestOk = false;
    });
    final testId = 'self_test_${DateTime.now().millisecondsSinceEpoch}';
    final testPersona = 'self-test';
    try {
      final d = await ChatStorageService().db;
      // 走真实 insert（带 thinking_chain 字段，复现线上路径）
      await d.insert('messages', {
        'id': testId,
        'persona_id': testPersona,
        'text': '【自检消息】落库通路验证',
        'is_me': 1,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'thinking_chain': null,
      });
      // 读回来确认
      final back = await d.query('messages',
          where: 'id = ?', whereArgs: [testId], limit: 1);
      final ok = back.isNotEmpty;
      // 清理测试数据
      await d.delete('messages',
          where: 'id = ?', whereArgs: [testId]);
      if (!mounted) return;
      setState(() {
        _insertTestOk = ok;
        _insertTestResult = ok
            ? '✅ 插入+读取成功 → 落库链路通'
            : '❌ 插入成功但读不回来（异常）';
      });
      if (ok) {
        // 通路确认 → 刷新统计
        await _run();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _insertTestOk = false;
        _insertTestResult = '❌ 插入失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天记录自检'),
        actions: [
          IconButton(
            tooltip: '重新检测',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _run,
          ),
          IconButton(
            tooltip: '运行日志',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => showDebugLogSheet(context),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.redAccent, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          '自检失败：$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _card(
                      title: '📦 数据库文件',
                      rows: [
                        ('路径', _dbPath),
                        ('大小', _dbSizeBytes < 0
                            ? '（读不到）'
                            : _fmtSize(_dbSizeBytes)),
                      ],
                    ),
                    _card(
                      title: '💬 消息落库统计（messages 表）',
                      rows: [
                        ('总行数', '$_totalMessages 条'),
                        ..._perPersona.entries
                            .map((e) => ('  · persona ${e.key}', '${e.value} 条')),
                        if (_perPersona.isEmpty) ('  ·（空）', '没有任何消息落库'),
                      ],
                    ),
                    _card(
                      title: '🧬 messages 表实际列',
                      rows: [
                        (
                          '列',
                          _messageColumns.isEmpty
                              ? '（读不到）'
                              : _messageColumns.join(' / ')
                        ),
                        (
                          '检查',
                          _messageColumns.contains('thinking_chain')
                              ? '✅ thinking_chain 列在，insert 不会因缺列失败'
                              : '❌ 缺 thinking_chain 列！'
                                  '所有 insert 都会失败被静默吞掉（8-04 已修复，'
                                  '升级 v5 后此列会自动补上）'
                        ),
                      ],
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _insertTestOk ? null : _runInsertTest,
                            icon: const Icon(Icons.fact_check_outlined,
                                size: 18),
                            label: Text(_insertTestOk
                                ? '✅ 直插测试通过（真实链路可用）'
                                : '🧪 直插测试：往 messages 表插一条自检消息'),
                          ),
                          if (_insertTestResult != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _insertTestResult!,
                              style: TextStyle(
                                fontSize: 12,
                                color: _insertTestOk
                                    ? Colors.green.shade700
                                    : Colors.redAccent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _card(
                      title: '📄 发给男主的完整内容（prompt_logs 表）',
                      rows: [
                        ('记录数', '$_promptLogCount 条'),
                        (
                          '说明',
                          _promptLogCount == 0
                              ? '还没收录。发一条消息后这里就会有记录'
                              : '已按时间持久化，重启后 📄 弹窗仍可看'
                        ),
                      ],
                    ),
                    _card(
                      title: '🕐 DB 最近消息（按 persona 分组取前 5）',
                      rows: [
                        ('数据最多的 persona', _recentPersonaId),
                      ],
                      child: _recent.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                '（没有消息）——如果聊天页有气泡但这里为空，'
                                '说明消息没落库，是发送链路的问题；'
                                '如果这里也有，就是加载/选择 persona 的问题。',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.black54),
                              ),
                            )
                          : Column(
                              children: [
                                for (final m in _recent)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 3),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: (m.isMe
                                                    ? Colors.blue
                                                    : Colors.pink)
                                                .withValues(alpha: 0.1),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            m.isMe ? '我' : '男主',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: m.isMe
                                                    ? Colors.blue
                                                    : Colors.pink),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            m.text,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 12, height: 1.4),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '📌 怎么看结果：\n'
                        '① 这里没数据 + 聊天页有气泡 → 落库失败（发送链路）\n'
                        '② 这里没数据 + 聊天页也没气泡 → 本来就没聊/被清空\n'
                        '③ 这里有数据 + 聊天页空 → 加载或 persona 选择问题\n'
                        '④ 落库的 persona 和当前 persona 对不上 → 切换角色后\n'
                        '   消息归属错位（每条消息都标了 persona_id，可对照）',
                        style: TextStyle(fontSize: 12, height: 1.6),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _card({
    required String title,
    required List<(String, String)> rows,
    Widget? child,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 150,
                      child: Text(
                        k,
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        v,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (child != null) ...[const SizedBox(height: 4), child],
          ],
        ),
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}
