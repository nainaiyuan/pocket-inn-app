import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/flow_store.dart';
import '../../services/parse_utils.dart';
import '../../services/pending_queue_store.dart';
import '../../services/tool_cache_store.dart';
import '../../services/tool_catalog.dart';
import '../../services/tool_manual_store.dart';
import '../../services/tool_test_store.dart';
import '../../utils/debug_logger.dart';
import '../../butler/tools/tool_intent_parser.dart';
import '../../models/chat_message.dart';
import '../chat/state/current_character_state.dart';
import '../chat/widgets/tool_group_card.dart';

/// 🛠 修复验证中心（8-08 16:3x 用户要求："每一个东西都要留一个测 bug 的"）
///
/// 把 8-08 所有修复点做成可点击运行的用例 + 实时状态展示：
/// ① 时长/秒数解析（countdown_card/notify_user 带单位）
/// ② 工具名中文解析（manage_frequent_tools）
/// ③ 标签形态剥离（男主自创 <tool_call> 等不漏网）
/// ④ 工具块剥离（ToolIntentParser）
/// ⑤ 实时状态：流程进度/待回复队列/工具缓存/常用表/手册/测试任务
/// ⑥ 一键复制全部结果 → 贴给开发者（龙虾）排查
class FixVerifyPage extends StatefulWidget {
  const FixVerifyPage({super.key});

  @override
  State<FixVerifyPage> createState() => _FixVerifyPageState();
}

class _FixVerifyPageState extends State<FixVerifyPage> {
  String _personaId = '';
  bool _loading = false;

  // 实时状态区
  String _flowInfo = '（未读取）';
  String _queueInfo = '（未读取）';
  String _cacheInfo = '（未读取）';
  String _frequentInfo = '（未读取）';
  String _manualInfo = '（未读取）';
  String _testInfo = '（未读取）';

  // 用例结果区
  final List<Map<String, String>> _caseResults = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final st = CurrentCharacterState();
      await st.init();
      await st.tryAutoSelect();
      _personaId = st.personaId ?? '';
      DebugLogger.log('修复验证', 'personaId=$_personaId');
    } catch (e) {
      DebugLogger.log('修复验证', '✖ 读角色失败: $e');
    }
    await _refreshAll();
    _runCases();
    unawaited(_runFlowCases()); // ⑧ 流程状态机（异步，独立跑）
    if (mounted) setState(() {});
  }

  Future<void> _refreshAll() async {
    setState(() => _loading = true);
    try {
      if (_personaId.isNotEmpty) {
        FlowStore.warm(_personaId);
        PendingQueueStore.warm(_personaId);
        ToolCacheStore.warm(_personaId);
        ToolManualStore.warm(_personaId);
        ToolTestStore.warm(_personaId);
        FrequentToolsStore.warm(_personaId);
        // 流程
        final flow = await FlowStore.get(_personaId);
        if (flow == null) {
          _flowInfo = '（无流程）';
        } else {
          final steps = (flow['steps'] as List?) ?? [];
          final cur = (flow['currentStep'] as num?)?.toInt() ?? 0;
          final tl = FlowStore.taskList(_personaId);
          _flowInfo = '状态=${flow['status']}　目标=${flow['goal']}\n'
              '进度=${cur + 1}/${steps.length}\n'
              '${tl ?? ''}';
        }
        // 待回复队列
        final q = PendingQueueStore.list(_personaId);
        _queueInfo = q.isEmpty
            ? '（空）'
            : q.map((e) => '#${e['id']} ${e['text']}').join('\n');
        // 工具缓存
        final c = ToolCacheStore.text(_personaId);
        _cacheInfo = c.trim().isEmpty ? '（空）' : c;
        // 常用工具表
        final f = FrequentToolsStore.text(_personaId);
        _frequentInfo = (f == null || f.trim().isEmpty) ? '（空）' : f;
        // 手册
        final m = await ToolManualStore.list(_personaId);
        _manualInfo = m.trim().isEmpty ? '（空）' : m;
        // 测试任务
        final t = await ToolTestStore.status(_personaId);
        _testInfo = t;
      } else {
        _flowInfo = '（未找到角色，先在聊天页选一个男主）';
      }
    } catch (e) {
      DebugLogger.log('修复验证', '✖ 刷新状态失败: $e');
      _flowInfo = '✖ 刷新失败: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- 用例 ----
  void _runCases() {
    final cases = <Map<String, String>>[];

    // ① 时长解析（分钟）
    const minCases = <(Object, int?)>[
      (30, 30), ('90', 90), ('30分钟', 30), ('30分', 30), ('30min', 30),
      ('1小时', 60), ('1h', 60), ('2小时30分钟', 150), ('0.5小时', 30),
      ('45秒', 1), ('abc', null), ('', null),
    ];
    for (final (input, expected) in minCases) {
      final actual = parseMinutesArg(input);
      final pass = actual == expected;
      cases.add({
        'group': '① 时长→分钟',
        'input': '$input',
        'expected': '$expected',
        'actual': '$actual',
        'pass': pass ? '✅' : '❌',
      });
    }

    // ② 秒数解析
    const secCases = <(Object, int?)>[
      (30, 30), ('4秒', 4), ('4s', 4), ('2分钟', 120), ('1小时', 3600), ('xx', null),
    ];
    for (final (input, expected) in secCases) {
      final actual = parseSecondsArg(input);
      final pass = actual == expected;
      cases.add({
        'group': '② 时长→秒',
        'input': '$input',
        'expected': '$expected',
        'actual': '$actual',
        'pass': pass ? '✅' : '❌',
      });
    }

    // ③ 工具名中文解析
    const nameCases = <(String, String?)>[
      ('record_memory', 'record_memory'),
      ('记她的事', 'record_memory'),
      ('便签', 'manage_pad'),
      ('查日志', 'query_logs'),
      ('不存在的工具xyz', null),
    ];
    for (final (input, expected) in nameCases) {
      final actual = ToolCatalog.resolveName(input);
      final pass = actual == expected;
      cases.add({
        'group': '③ 工具名解析',
        'input': '$input',
        'expected': '$expected',
        'actual': '$actual',
        'pass': pass ? '✅' : '❌',
      });
    }

    // ④ 标签形态剥离
    const tagCases = <(String, String)>[
      ('<tool_call>x</tool_call>', 'x'),
      ('<|im_start|>', ''),
      ('好的<invoke name="a">嗯', '好的嗯'),
      ('<3 爱你', '<3 爱你'), // 数字开头不误伤
      ('a<b 比较', 'a<b 比较'), // 不是标签
      ('他说<她笑了>真可爱', '他说真可爱'), // 中文标签
    ];
    for (final (input, expected) in tagCases) {
      final actual = stripTagShapes(input);
      final pass = actual == expected;
      cases.add({
        'group': '④ 标签剥离',
        'input': '$input',
        'expected': '$expected',
        'actual': '$actual',
        'pass': pass ? '✅' : '❌',
      });
    }

    // ⑤ 工具块剥离
    const blockCases = <(String, String)>[
      ('好的 工具:manage_flow 动作=next 我们继续', '好的 我们继续'),
      // 8-08 18:4x：用例改用现行协议（⟨工具:⟩⟨/工具⟩ 严格块）；
      // 旧的 <tool>…</tool> 不是协议格式（男主写这个会被标签剥离兜底清壳）
      ('好的 ⟨工具:record_memory⟩{"内容":"她喜欢狗"}⟨/工具⟩收到', '好的 收到'),
      ('工具:list_tools 然后我等你', '然后我等你'), // 无参数暗号 + 后面自然话
      ('工具:还不错 这个不错', '工具:还不错 这个不错'), // 非英文工具名不剥
    ];
    for (final (input, expected) in blockCases) {
      final actual = ToolIntentParser.stripToolBlocks(input).trim();
      final pass = actual == expected;
      cases.add({
        'group': '⑤ 工具块剥离',
        'input': '$input',
        'expected': '$expected',
        'actual': '$actual',
        'pass': pass ? '✅' : '❌',
      });
    }

    // ⑥ 结束检查退出信号（8-08 18:1x GPT 意见：续话=一次检查机会，
    // 男主输出 need_continue:false / next_action:null → 冻结唤醒）
    const exitCases = <(String, bool?)>[
      ('好啦先这样~ {"need_continue": false}', true),
      ('<sys>need_continue:false</sys>', true),
      ('need_continue:false', true),
      ('{"msg":"继续","need_continue": true}', false),
      ('{"next_action": null}', true),
      ('next_action:none', true),
      ('next_action:无', true),
      ('我还有事要做', null), // 没输出信号
      ('好的，我现在去查资料', null),
      ('', null),
    ];
    for (final (input, expected) in exitCases) {
      final actual = parseExitSignal(input);
      final pass = actual == expected;
      cases.add({
        'group': '⑥ 退出信号',
        'input': '$input',
        'expected': '$expected',
        'actual': '$actual',
        'pass': pass ? '✅' : '❌',
      });
    }

    // ⑦ 退出标记剥离（标记不能漏给用户看）
    const stripCases = <(String, String)>[
      ('好啦先这样~ {"need_continue": false}', '好啦先这样~'),
      ('继续做 {"need_continue": true}', '继续做'),
      ('need_continue:false 结束', '结束'),
      // JSON 块由多气泡解析器丢弃未知字段，这里不动（保持原样即正确）
      ('{"msg":"好啦","need_continue":false}', '{"msg":"好啦","need_continue":false}'),
      ('普通文本', '普通文本'),
    ];
    for (final (input, expected) in stripCases) {
      final actual = stripExitSignal(input);
      final pass = actual == expected;
      cases.add({
        'group': '⑦ 标记剥离',
        'input': '$input',
        'expected': '$expected',
        'actual': '$actual',
        'pass': pass ? '✅' : '❌',
      });
    }

    _caseResults
      ..clear()
      ..addAll(cases);
    if (mounted) setState(() {});
  }

  // ---- ⑧ 流程状态机（8-08 19:0x：paused_by_user 插话暂挂）----
  // 用独立测试 pid，跑完清理，不碰真实角色数据
  Future<void> _runFlowCases() async {
    const pid = '__verify_flow__';
    final results = <Map<String, String>>[];
    void add(String input, String expected, String actual) {
      results.add({
        'group': '⑧ 流程状态机',
        'input': input,
        'expected': expected,
        'actual': actual,
        'pass': actual == expected ? '✅' : '❌',
      });
    }

    try {
      await FlowStore.clear(pid);
      // create → running
      await FlowStore.create(pid, '测试流程', ['步骤A']);
      add('create → isRunning', 'true', '${FlowStore.isRunning(pid)}');
      // 插话暂挂
      await FlowStore.pauseByUser(pid, userMessage: '插话测试');
      final f1 = await FlowStore.get(pid);
      add('pauseByUser → status', 'paused_by_user', '${f1?['status']}');
      add('paused → isRunning', 'false', '${FlowStore.isRunning(pid)}');
      add('paused → isActive', 'true', '${FlowStore.isActive(pid)}');
      // 恢复
      await FlowStore.resume(pid);
      add('resume → isRunning', 'true', '${FlowStore.isRunning(pid)}');
      // 取消
      await FlowStore.cancel(pid);
      add('cancel → isActive', 'false', '${FlowStore.isActive(pid)}');
      // 已取消不能再 resume
      final r2 = await FlowStore.resume(pid);
      add('cancelled 再 resume → 拒绝', 'true', '${r2.contains('不在暂停状态')}');
      // 清理
      await FlowStore.clear(pid);
      add('clear → get null', 'null', '${await FlowStore.get(pid)}');
      // ── 8-08 19:4x 新用例（BUG-1/2/4 回归）──
      // BUG-1：next() 最后一步自动收尾（不再卡 running → 停止框消失）
      // 用 ai_output 类型步骤（产出类型，next 带 result 即完成，不需要工具）
      await FlowStore.create(pid, '收尾测试', [
        {'name': '步骤A', 'doneType': 'ai_output'},
        {'name': '步骤B', 'doneType': 'ai_output'},
      ]);
      await FlowStore.next(pid, result: 'A 的产出'); // 步骤A 完成
      await FlowStore.next(pid, result: 'B 的产出'); // 最后一步 → 自动 done
      add('next 最后一步 → status', 'done', '${(await FlowStore.get(pid))?['status']}');
      // BUG-2：summary 完成态不再显示"第 3/2 步"越界
      final sm = FlowStore.summary(pid);
      add('summary 完成态不越界', '已完成', '${sm?.contains('已完成') ?? false}');
      // BUG-4：done 后 update → 回 running（新任务能跑）
      await FlowStore.update(pid, goal: '新任务', steps: [
        {'name': '步骤C', 'doneType': 'ai_output'},
      ]);
      add('done 后 update → running', 'true', '${FlowStore.isRunning(pid)}');
      // BUG-1 完整链路收尾
      await FlowStore.next(pid, result: 'C 的产出');
      add('新任务 next 收尾 → done', 'done', '${(await FlowStore.get(pid))?['status']}');
      // 清理
      await FlowStore.clear(pid);
      // ── 8-08 20:2x ⑨ 工具卡聚合（用户+GPT 定稿：连续 [tool] 合并，
      // 遇用户消息/男主文本回复/[act] 切断）──
      ChatMessage toolMsg(String text) =>
          ChatMessage(id: 't_$text', text: '[tool] $text', isMe: false);
      final agg1 = groupToolMessages([
        toolMsg('正在查记忆…'),
        toolMsg('✅ 查到 3 条'),
        toolMsg('正在写便签…'),
      ]);
      add('⑨ 连续3条tool → 1个卡(3条)', '1/3',
          '${agg1.whereType<ToolGroupData>().length}/'
          '${agg1.whereType<ToolGroupData>().first.msgs.length}');
      final agg2 = groupToolMessages([
        toolMsg('正在查记忆…'),
        ChatMessage(id: 'u1', text: '用户插话', isMe: true),
        toolMsg('正在写便签…'),
      ]);
      add('⑨ 用户消息切断 → 2个卡', '2', '${agg2.whereType<ToolGroupData>().length}');
      final agg3 = groupToolMessages([
        toolMsg('正在查记忆…'),
        ChatMessage(id: 'a1', text: '[act] 他微微一笑', isMe: false),
        toolMsg('正在写便签…'),
      ]);
      add('⑨ act切断 → 2个卡', '2', '${agg3.whereType<ToolGroupData>().length}');
      final agg4 = groupToolMessages([
        ChatMessage(id: 'm1', text: '男主说话', isMe: false),
        toolMsg('正在查记忆…'),
        toolMsg('✅ 完成'),
      ]);
      add('⑨ 文本在前工具在后 → 1个卡', '1/2',
          '${agg4.whereType<ToolGroupData>().length}/'
          '${agg4.whereType<ToolGroupData>().first.msgs.length}');
      final agg5 = groupToolMessages([]);
      add('⑨ 空列表 → 0', '0', '${agg5.length}');
    } catch (e) {
      add('执行异常', '无', '$e');
    }
    _caseResults.addAll(results);
    if (mounted) setState(() {});
  }

  // ---- 复制 ----
  String _buildReport() {
    final sb = StringBuffer();
    sb.writeln('🛠 修复验证中心报告（8-08）');
    sb.writeln('personaId: $_personaId');
    sb.writeln('时间: ${DateTime.now()}');
    sb.writeln();
    final failed = _caseResults.where((c) => c['pass'] == '❌').length;
    sb.writeln('用例：${_caseResults.length} 个，失败 $failed 个');
    for (final c in _caseResults) {
      sb.writeln(
          '${c['pass']} [${c['group']}] 输入=${c['input']} 期望=${c['expected']} 实际=${c['actual']}');
    }
    sb.writeln();
    sb.writeln('--- 实时状态 ---');
    sb.writeln('【流程】\n$_flowInfo');
    sb.writeln('【待回复队列】\n$_queueInfo');
    sb.writeln('【工具缓存】\n$_cacheInfo');
    sb.writeln('【常用工具表】\n$_frequentInfo');
    sb.writeln('【工具手册】\n$_manualInfo');
    sb.writeln('【工具测试任务】\n$_testInfo');
    return sb.toString();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _buildReport()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制全部结果，直接粘贴发给我'), duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final failed = _caseResults.where((c) => c['pass'] == '❌').length;
    return Scaffold(
      appBar: AppBar(title: const Text('🛠 修复验证中心')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFDF7F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前角色：$_personaId',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text(
                  '这里验证 8-08 所有修复点。用例自动跑，红❌=有问题；'
                  '状态区显示男主当前的真实数据。有任何异常点「复制全部」贴给龙虾。',
                  style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF8A7A80)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _copyAll,
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('📋 复制全部结果'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _refreshAll,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('刷新状态'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('🧪 解析用例（${_caseResults.length} 个，失败 $failed 个）',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          if (_caseResults.isEmpty)
            const Text('用例运行中…', style: TextStyle(fontSize: 12))
          else
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final c in _caseResults)
                    ListTile(
                      dense: true,
                      leading: Text(c['pass']!,
                          style: const TextStyle(fontSize: 16)),
                      title: Text(
                        '${c['group']}：${c['input']}',
                        style: const TextStyle(fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '期望=${c['expected']}　实际=${c['actual']}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          const Text('📋 GPT 10 问落地清单（8-08 13:20 用户转达）',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '1. 并行执行 → 未做（GPT 定案：第一版默认串行）\n'
                '2. 手册预算 → ✅ ToolManualStore 600 字注入\n'
                '3. 目标对照 → ✅ FlowStore.taskList 机械生成\n'
                '4. ai_output → ✅ next() 结构化提交 result/summary/next_action\n'
                '5. autoAdvance → ✅ 工具轮后严格判定自动推进\n'
                '6. APP 重启恢复 → ✅ 重开自动续跑（_checkRestartResume）\n'
                '7. 软提示区 → ⚠️ 未做专区（用【系统】前缀块代替）\n'
                '8. 无进展判定 → ✅ currentStep+工具历史，3 轮熔断\n'
                '9. resume_mode → ✅ silent 已实现（normal 未做）\n'
                '10. 测试任务冲突 → ✅ 优先级降级（聊天>请求>后台测试）\n'
                '11. 结束检查轮 → ✅ 8-08 18:1x：续话=一次检查机会，'
                '男主输出 {"need_continue": false} 或 next_action:null → '
                '冻结唤醒（🔚 男主判定结束 / 🔒 续话冻结 锚点）\n\n'
                '🔍 行为类修复（插话/续话/自动续跑/结束检查）验证方法：'
                '工具箱 → 运行日志 → 🔍 只看关键，看 ⏰/🔔/💬/⏸/🔚/🔒 锚点',
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('📊 男主实时状态', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _statusCard('流程（含任务清单）', _flowInfo),
          _statusCard('待回复队列', _queueInfo),
          _statusCard('工具缓存', _cacheInfo),
          _statusCard('常用工具表', _frequentInfo),
          _statusCard('工具手册', _manualInfo),
          _statusCard('工具测试任务', _testInfo),
        ],
      ),
    );
  }

  Widget _statusCard(String title, String content) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              content,
              style: const TextStyle(fontSize: 12, height: 1.5, fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
