import 'package:flutter/material.dart';

import '../../butler/tools/tool_intent_parser.dart';
import '../../services/chat_database_service.dart';
import '../../services/chat_memory_service.dart';
import '../../services/chat_service.dart';
import '../../utils/debug_logger.dart';

/// 一键自检页 — 不用手动聊天，直接跑管家全流程验证
///
/// 点「开始自检」→ 3 条测试消息依次走完整管家流程
/// （技能匹配 → 假面替换 → Prompt 组装 → 发送(模拟) → 拆分存储 → 情绪识别），
/// 每条消息的流程树自动出现在日志页「流程」视图（🐞 → 流程）。
class ButlerSelfTestPage extends StatefulWidget {
  const ButlerSelfTestPage({super.key});

  @override
  State<ButlerSelfTestPage> createState() => _ButlerSelfTestPageState();
}

class _ButlerSelfTestPageState extends State<ButlerSelfTestPage> {
  bool _running = false;
  ButlerSelfTestReport? _report;
  bool _toolRunning = false;
  ButlerSelfTestReport? _toolReport;
  final _simController = TextEditingController();
  List<Map<String, dynamic>>? _simCalls;
  String _simStripped = '';

  /// 模拟男主回复（用户 8-03 05:59：不走 AI，直接喂男主说的话给管家解析）
  /// 把男主在日志页的回复原文粘进来 → 立刻知道管家抓不抓得住
  void _simulateButlerReply(String input) {
    final calls = ToolIntentParser.extract(input);
    final stripped = ToolIntentParser.stripToolBlocks(input);
    setState(() {
      _simCalls = calls;
      _simStripped = stripped;
    });
    DebugLogger.log('工具自测', '▶ 模拟男主回复: ${input.length > 60 ? input.substring(0, 60) + '…' : input}');
    DebugLogger.log('工具自测',
        '■ 解析结果: ${calls == null ? '（没抓到工具）' : calls.map((c) => c['name']).join('、')}');
  }

  void _fillSimPreset(String label, String text) {
    _simController.text = text;
    _simulateButlerReply(text);
  }

  @override
  void dispose() {
    _simController.dispose();
    super.dispose();
  }

  /// 工具链路自测（用户 8-03 05:44：管家对调用工具没反应，要能定位卡点）
  /// 逐层测：解析器识别 → 记忆库读写 → 日记库读写，哪层挂了一目了然。
  Future<void> _runToolTest() async {
    if (_toolRunning) return;
    setState(() {
      _toolRunning = true;
      _toolReport = null;
    });
    DebugLogger.log('工具自测', '▶ 工具链路自测开始…');
    final items = <ButlerSelfTestItem>[];
    final stopwatch = Stopwatch()..start();

    // ── 第 1 层：解析器识别（纯函数，男主写什么格式都能认）──
    void addParserCase(String label, String input, String expectName) {
      final calls = ToolIntentParser.extract(input);
      final actualNames =
          calls?.map((c) => c['name']).join('、') ?? '（没识别到）';
      final hit = calls?.any((c) => c['name'] == expectName) ?? false;
      items.add(ButlerSelfTestItem(
        message: '解析器：$label',
        expected: '识别出 $expectName',
        actual: actualNames,
        passed: hit,
        failedReason: hit ? null : '输入: $input',
        guidance: '检查 SYSTEM_CORE【工具】段是否引导男主写 ⟨工具:…⟩ 块；'
            '或检查男主实际回复格式（日志页看 AI路由）',
      ));
    }

    addParserCase('⟨工具:⟩块', '⟨工具:record_memory⟩{"content":"自测"}⟨/工具⟩', 'record_memory');
    addParserCase('JSON指令', '{"name":"recall_memory","arguments":{"query":"自测"}}', 'recall_memory');
    addParserCase('中文词', '记住我喜欢喝美式咖啡', 'record_memory');
    // 纯聊天必须零副作用
    {
      const input = '今天天气真好';
      final calls = ToolIntentParser.extract(input);
      items.add(ButlerSelfTestItem(
        message: '解析器：纯聊天零副作用',
        expected: '不识别任何工具',
        actual: calls == null ? '（无工具，正常）' : '误识别: ${calls.map((c) => c['name']).join('、')}',
        passed: calls == null,
        failedReason: calls == null ? null : '纯聊天被误判成工具调用',
        guidance: '中文词表太宽泛？检查 tool_intent_parser.dart 的 chineseIntents',
      ));
    }

    // ── 第 2 层：记忆库读写（绕过弹窗直接测数据库）──
    // 8-03 05:53：chat_memories.session_id 有外键 → 必须先用真实会话，
    // 否则 FOREIGN KEY constraint failed（自测第一次就是这么挂的）
    final testSession = await ChatDatabaseService.instance.createSession(
      characterId: '__tool_selftest__',
      title: '工具自测（可删）',
    );
    try {
      final node = await ChatMemoryService.instance.addMemory(
        sessionId: testSession.id,
        branchLeafId: '__tool_selftest__',
        content: '[日常] 工具链路自测标记',
      );
      final found = await ChatMemoryService.instance
          .searchMemories(testSession.id, keyword: '工具链路自测标记');
      if (node.id.isNotEmpty && found.isNotEmpty) {
        await ChatMemoryService.instance.deleteMemory(node.id);
        items.add(ButlerSelfTestItem(
          message: '记忆库读写',
          expected: '写入→查到→删除 全通',
          actual: '写入 ${node.id.substring(0, 8)}… → 查到 ${found.length} 条 → 已删除',
          passed: true,
        ));
      } else {
        items.add(ButlerSelfTestItem(
          message: '记忆库读写',
          expected: '写入→查到 全通',
          actual: found.isEmpty ? '写入了但查不到' : '写入失败',
          passed: false,
          failedReason: 'addMemory 或 searchMemories 异常',
          guidance: '检查 chat_memory_service.dart / chat_database_service.dart 记忆表',
        ));
      }
    } catch (e) {
      items.add(ButlerSelfTestItem(
        message: '记忆库读写',
        expected: '写入→查到→删除 全通',
        actual: '异常: $e',
        passed: false,
        failedReason: '记忆库抛异常',
        guidance: '看日志页具体报错；检查 chat_memories 外键（session 需先存在于 chat_sessions）',
      ));
    } finally {
      await ChatDatabaseService.instance.deleteSession(testSession.id);
    }

    // ── 第 3 层：日记库读写 ──
    try {
      await ChatDatabaseService.instance
          .saveDiaryEntry('__tool_selftest__', '[自测] 工具链路测试');
      final found = await ChatDatabaseService.instance
          .searchDiary('__tool_selftest__', keyword: '[自测]');
      items.add(ButlerSelfTestItem(
        message: '日记库读写',
        expected: '写入→查到 全通',
        actual: found.isNotEmpty ? '写入 → 查到 ${found.length} 条' : '写入了但查不到',
        passed: found.isNotEmpty,
        failedReason: found.isEmpty ? 'saveDiaryEntry 或 searchDiary 异常' : null,
        guidance: '检查 chat_database_service.dart butler_diary 表',
      ));
    } catch (e) {
      items.add(ButlerSelfTestItem(
        message: '日记库读写',
        expected: '写入→查到 全通',
        actual: '异常: $e',
        passed: false,
        failedReason: '日记库抛异常',
        guidance: '看日志页具体报错；检查 butler_diary 表',
      ));
    }

    stopwatch.stop();
    if (!mounted) return;
    setState(() {
      _toolReport =
          ButlerSelfTestReport(items: items, elapsed: stopwatch.elapsed);
      _toolRunning = false;
    });
    DebugLogger.log('工具自测',
        '■ 工具自测完成：${items.where((i) => i.passed).length}/${items.length} 通过');
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _report = null;
    });
    DebugLogger.log('管家自检', '▶ 开始一键自检…');
    try {
      final report = await ChatService.instance.runSelfTest();
      if (!mounted) return;
      setState(() {
        _report = report;
        _running = false;
      });
      DebugLogger.log(
        '管家自检',
        '■ 自检完成：${report.passCount}/${report.items.length} 通过'
        '（${report.elapsed.inSeconds}s）',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      DebugLogger.log('管家自检', '■ 自检异常: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('自检失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;

    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        elevation: 0,
        title: const Text(
          '管家一键自检',
          style: TextStyle(
            color: Color(0xFF6A4A5A),
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF6A4A5A)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '不用手动聊天，直接跑 5 条测试消息验证管家全流程：\n'
              '① "今天天气真好啊" → 语义情绪 + 聊天流程\n'
              '② "我今天心情好差，感觉好累" → 触发【情绪状态洞察】+ 工具调用\n'
              '③ "我妈妈说我太懒了" → 假面层处理\n'
              '④ "你还记得我之前说过喜欢喝什么吗" → 触发【记忆检索】\n'
              '⑤ "我发现自己一聊到工作就烦" → 触发【情绪规律查询】\n\n'
              '自检不真实调用 AI（模拟回复）、不写情绪落库、不污染真实会话。\n'
              '失败会给出"怎么办"指引；详细过程：日志页 🐞 → 「流程」视图。',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running ? '自检中…' : '开始自检'),
          ),
          if (report != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: report.allPassed
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    report.allPassed ? Icons.check_circle : Icons.error,
                    color: report.allPassed
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFFF8A8A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${report.passCount}/${report.items.length} 项通过'
                      '（耗时 ${report.elapsed.inSeconds}s）',
                      style: const TextStyle(
                        color: Color(0xFF6A4A5A),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final item in report.items) _ResultCard(item: item),
          ],
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE8D5DE)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '🔧 工具链路自测（用户 8-03 05:44：管家对调用工具没反应时用）\n'
              '逐层验证，卡在哪一层一目了然：\n'
              '① 解析器识别：⟨工具:⟩块 / JSON指令 / 中文词 / 纯聊天零副作用\n'
              '② 记忆库读写：写入 → 查到 → 删除\n'
              '③ 日记库读写：写入 → 查到\n\n'
              '如果①②③全过 → 问题在男主没写工具指令（看日志 AI路由）\n'
              '如果②③挂 → 数据库问题；①挂 → 解析器问题。',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _toolRunning ? null : _runToolTest,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8FA8C8),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: _toolRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.build),
            label: Text(_toolRunning ? '自测中…' : '开始工具链路自测'),
          ),
          if (_toolReport != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _toolReport!.allPassed
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _toolReport!.allPassed ? Icons.check_circle : Icons.error,
                    color: _toolReport!.allPassed
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFFF8A8A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_toolReport!.passCount}/${_toolReport!.items.length} 项通过'
                      '（耗时 ${_toolReport!.elapsed.inSeconds}s）',
                      style: const TextStyle(
                        color: Color(0xFF6A4A5A),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final item in _toolReport!.items) _ResultCard(item: item),
          ],
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE8D5DE)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '🗣 模拟男主回复（用户 8-03 05:59：不走 AI，直接找 bug）\n'
              '把男主在日志页「AI路由」里的回复原文粘进来，'
              '立刻看管家抓不抓得住工具指令、剥离后用户看到什么。\n\n'
              '预设格式点下面的标签一键填入：',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PresetChip(
                label: '代码块JSON',
                onTap: () => _fillSimPreset('代码块JSON',
                    '```json\n{"name": "list_tools", "arguments": {}}\n```'),
              ),
              _PresetChip(
                label: '嵌套JSON',
                onTap: () => _fillSimPreset('嵌套JSON',
                    '{"name": "record_memory", "arguments": {"content": "喜欢美式", "category": "喜好"}}'),
              ),
              _PresetChip(
                label: '⟨工具:⟩块',
                onTap: () => _fillSimPreset('⟨工具:⟩块',
                    '我记住啦。\n⟨工具:record_memory⟩{"content":"喜欢美式","category":"喜好"}⟨/工具⟩'),
              ),
              _PresetChip(
                label: '中文词',
                onTap: () => _fillSimPreset('中文词', '记住我喜欢喝美式咖啡'),
              ),
              _PresetChip(
                label: '纯聊天',
                onTap: () => _fillSimPreset('纯聊天', '今天天气真好，我们去散步吧'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _simController,
            maxLines: 4,
            minLines: 2,
            decoration: InputDecoration(
              hintText: '粘贴男主回复原文…',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8D5DE)),
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => _simulateButlerReply(_simController.text),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6A8FA8),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.mic_none),
            label: const Text('模拟男主回复 → 管家解析'),
          ),
          if (_simCalls != null || _simStripped.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_simCalls != null && _simCalls!.isNotEmpty)
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (_simCalls != null && _simCalls!.isNotEmpty)
                        ? '✅ 管家抓到 ${_simCalls!.length} 个工具: '
                            '${_simCalls!.map((c) => c['name']).join('、')}'
                        : '❌ 管家没抓到工具指令',
                    style: TextStyle(
                      color: (_simCalls != null && _simCalls!.isNotEmpty)
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFD0503A),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  if (_simCalls != null && _simCalls!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (final c in _simCalls!)
                      Text(
                        '参数: ${c['arguments']}',
                        style: const TextStyle(
                            color: Colors.black54, fontSize: 11),
                      ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '👀 用户实际看到的: "${_simStripped}"',
                    style: const TextStyle(
                        color: Colors.black45, fontSize: 11, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PresetChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: const Color(0xFFF3E8EE),
      side: const BorderSide(color: Color(0xFFE8D5DE)),
      labelStyle: const TextStyle(color: Color(0xFF6A4A5A)),
      onPressed: onTap,
    );
  }
}

class _ResultCard extends StatelessWidget {
  final ButlerSelfTestItem item;

  const _ResultCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: item.passed
              ? const Color(0xFFD5E8D8)
              : const Color(0xFFF2C9C0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                item.passed ? Icons.check_circle : Icons.cancel,
                size: 18,
                color: item.passed
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFFFF8A8A),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '"${item.message}"',
                  style: const TextStyle(
                    color: Color(0xFF6A4A5A),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '预期: ${item.expected}',
            style: const TextStyle(color: Colors.black45, fontSize: 11),
          ),
          const SizedBox(height: 3),
          Text(
            '实际: ${item.actual}',
            style: TextStyle(
              color: item.passed ? Colors.black54 : const Color(0xFFD0503A),
              fontSize: 11,
            ),
          ),
          if (item.failedReason != null) ...[
            const SizedBox(height: 3),
            Text(
              '✖ 未通过: ${item.failedReason}',
              style: const TextStyle(
                color: Color(0xFFD0503A),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (item.guidance != null) ...[
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '💡 怎么办: ${item.guidance}',
                style: const TextStyle(
                  color: Color(0xFF8D6E00),
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
