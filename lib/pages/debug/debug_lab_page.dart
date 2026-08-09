import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../butler/debug_lab/agent_run_trace.dart';
import '../../butler/debug_lab/trace_analyzer.dart';
import '../../butler/debug_lab/trace_session.dart';
import '../../butler/debug_lab/trace_store.dart';

/// Debug Lab —— 找 bug 实验室
///
/// 用法（三步）：
/// 1. 正常跟男主聊天（轨迹自动记录，无需操作）
/// 2. 打开本页看最近几次对话的健康报告（男主记没记住自己调过工具）
/// 3. 点【一键复制报告】→ 粘贴发给龙虾 → 龙虾分析定位问题
class DebugLabPage extends StatefulWidget {
  const DebugLabPage({super.key});

  @override
  State<DebugLabPage> createState() => _DebugLabPageState();
}

class _DebugLabPageState extends State<DebugLabPage> {
  List<AgentRunTrace> _traces = [];
  bool _enabled = true;
  String? _selfTestText;
  bool _selfTesting = false;

  @override
  void initState() {
    super.initState();
    _enabled = TraceSession.instance.enabled;
    _load();
  }

  Future<void> _load() async {
    final traces = await TraceStore.instance.all(limit: 10);
    if (!mounted) return;
    setState(() => _traces = traces);
  }

  /// 一键复制：最近 10 条轨迹的健康报告（摘要，几行字）
  Future<void> _copyReport() async {
    final text = _buildReportText(_traces);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ 报告已复制，直接粘贴发给龙虾吧'), duration: Duration(seconds: 2)),
    );
  }

  /// 复制单条轨迹的完整 JSON（排查细节用）
  Future<void> _copyTraceJson(AgentRunTrace t) async {
    await Clipboard.setData(ClipboardData(text: jsonEncode(t.toJson())));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ 已复制轨迹 ${t.runId} 完整数据'), duration: Duration(seconds: 2)),
    );
  }

  /// 跑示例自测：构造好/坏两条轨迹验证检查器（不碰真实聊天记录）
  Future<void> _runSelfTest() async {
    if (_selfTesting) return;
    setState(() {
      _selfTesting = true;
      _selfTestText = null;
    });
    await Future.delayed(const Duration(milliseconds: 50));

    // 坏轨迹：工具结果丢失（男主看不到自己调过什么）
    final bad = AgentRunTrace(
      runId: 'demo_bad',
      startedAt: DateTime.now(),
      personaId: 'demo',
      userInput: '帮我查一下今天天气怎么样',
      firstMessages: [
        TraceMessage(role: 'system', content: '【当前情况】状态：正常对话'),
        TraceMessage(role: 'user', content: '帮我查一下今天天气怎么样'),
      ],
      modelToolCalls: [
        TraceToolCall(id: 'call_xyz789', name: 'query_weather', arguments: {'city': '上海'}),
      ],
      toolExecutions: [
        TraceToolExecution(name: 'query_weather', args: {'city': '上海'}, ok: true, resultText: '28°C 多云'),
      ],
      // 注意：secondMessages 为空 = 工具结果没回传 → 应被抓
      finalReply: '等我看一下',
    );
    final badReport = const TraceAnalyzer().analyze(bad);

    // 好轨迹：工具结果正常回传
    final good = AgentRunTrace(
      runId: 'demo_good',
      startedAt: DateTime.now(),
      personaId: 'demo',
      userInput: '帮我查一下天气',
      firstMessages: [
        TraceMessage(role: 'system', content: '【当前情况】状态：正常对话'),
        TraceMessage(role: 'user', content: '帮我查一下天气'),
      ],
      modelToolCalls: [
        TraceToolCall(id: 'call_1', name: 'query_weather', arguments: {'city': '上海'}),
      ],
      toolExecutions: [
        TraceToolExecution(name: 'query_weather', args: {'city': '上海'}, ok: true, resultText: '28°C 多云'),
      ],
      secondMessages: [
        TraceMessage(role: 'system', content: '【当前情况】状态：正常对话'),
        TraceMessage(role: 'assistant', content: '', toolCalls: [
          TraceToolCall(id: 'call_1', name: 'query_weather'),
        ]),
        TraceMessage(role: 'tool', content: '28°C 多云', toolCallId: 'call_1'),
        TraceMessage(role: 'user', content: '【用户当前消息】帮我查一下天气'),
      ],
      finalReply: '上海今天 28°C 多云，不用带伞～',
    );
    final goodReport = const TraceAnalyzer().analyze(good);

    final badCaught = badReport.failed.any((c) => c.checkId == 't3');
    final goodClean = goodReport.failed.isEmpty;

    final lines = <String>[
      '【示例自测】检查器工作正常吗？',
      '',
      badCaught
          ? '✅ 坏轨迹被抓到：工具结果丢失 → 正是"男主不知道自己调过什么"'
          : '❌ 坏轨迹没抓到（检查器失效了）',
      goodClean
          ? '✅ 好轨迹全绿（不误报）'
          : '❌ 好轨迹误报：${goodReport.failed.map((c) => c.checkId).join('、')}',
      '',
      '坏轨迹问题明细：',
      ...badReport.failed.map((c) => '  ❌ ${c.checkId} ${c.name}：${c.detail}'),
      '',
      '💡 说明：这是示例数据，真实数据来自你平时聊天自动记录的轨迹。',
    ];
    if (!mounted) return;
    setState(() {
      _selfTesting = false;
      _selfTestText = lines.join('\n');
    });
  }

  String _buildReportText(List<AgentRunTrace> traces) {
    final sb = StringBuffer();
    sb.writeln('🧪 Agent Debug Lab 报告 · ${_now()}\n');
    if (traces.isEmpty) {
      sb.writeln('（还没有轨迹——先跟男主聊几句、让他调个工具试试）');
      return sb.toString();
    }
    for (var i = 0; i < traces.length; i++) {
      final t = traces[i];
      final report = const TraceAnalyzer().analyze(t);
      sb.writeln('【${i + 1}】${_hm(t.startedAt)} · ${t.userInput.isEmpty ? '(工具轮)' : t.userInput}');
      if (t.toolExecutions.isNotEmpty) {
        sb.writeln('  工具: ${t.toolExecutions.map((e) => '${e.name} ${e.ok ? "✅" : "❌"}').join(' | ')}');
      }
      if (t.finalReply != null && t.finalReply!.trim().isNotEmpty) {
        final r = t.finalReply!.trim();
        sb.writeln('  回复: ${r.length > 50 ? "${r.substring(0, 50)}…" : r}');
      }
      sb.writeln('  健康: ${report.memoryStatus} 记忆 | ${report.toolStatus} 工具 | ${report.stateStatus} 状态 | ${report.contextStatus} 上下文');
      if (report.failed.isNotEmpty) {
        for (final c in report.failed) {
          sb.writeln('  ⚠️ ${c.checkId} ${c.name}：${c.detail}');
        }
      } else {
        sb.writeln('  ✅ 本轮无问题');
      }
      sb.writeln('');
    }
    sb.writeln('— 由 Debug Lab 自动生成，发给我即可 —');
    return sb.toString();
  }

  static String _now() {
    final n = DateTime.now();
    return '${n.month}月${n.day}日 ${_two(n.hour)}:${_two(n.minute)}';
  }

  static String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        elevation: 0,
        title: const Text(
          'Debug Lab · 找bug实验室',
          style: TextStyle(color: Color(0xFF6A4A5A), fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF6A4A5A)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _infoCard(),
          const SizedBox(height: 12),
          _switchCard(),
          const SizedBox(height: 12),
          _actionRow(),
          const SizedBox(height: 12),
          if (_selfTestText != null) _selfTestCard(),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('最近轨迹',
                  style: TextStyle(color: Color(0xFF6A4A5A), fontWeight: FontWeight.bold, fontSize: 15)),
              const Spacer(),
              TextButton(onPressed: _load, child: const Text('刷新')),
            ],
          ),
          if (_traces.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('还没有轨迹\n正常跟男主聊天（让他调个工具）就会自动记录',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black38, fontSize: 13, height: 1.6)),
              ),
            )
          else
            ..._traces.map((t) => _traceCard(t)),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _infoCard() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8D5DE)),
        ),
        child: const Text(
          '它是干嘛的：每次男主回复，自动记录他"看到了什么、调了什么工具、结果如何"，'
          '然后检查"他记不记得自己干过什么"。\n\n'
          '怎么用：① 正常聊天（男主调工具最好）→ ② 回来看报告 → ③ 点【一键复制】发给我。',
          style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
        ),
      );

  Widget _switchCard() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8D5DE)),
        ),
        child: Row(
          children: [
            const Text('自动记录轨迹', style: TextStyle(color: Colors.black87, fontSize: 14)),
            const Spacer(),
            Switch(
              value: _enabled,
              activeColor: const Color(0xFF6A4A5A),
              onChanged: (v) {
                TraceSession.instance.enabled = v;
                setState(() => _enabled = v);
              },
            ),
          ],
        ),
      );

  Widget _actionRow() => Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6A4A5A)),
              onPressed: _copyReport,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('一键复制报告', style: TextStyle(fontSize: 13)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF6A4A5A),
                side: const BorderSide(color: Color(0xFF6A4A5A)),
              ),
              onPressed: _selfTesting ? null : _runSelfTest,
              icon: const Icon(Icons.bug_report, size: 18),
              label: Text(_selfTesting ? '自测中…' : '跑示例自测', style: const TextStyle(fontSize: 13)),
            ),
          ),
        ],
      );

  Widget _selfTestCard() => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF8E1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFF0E0B0)),
        ),
        child: Text(_selfTestText!,
            style: const TextStyle(color: Colors.black87, fontSize: 12, height: 1.6)),
      );

  Widget _traceCard(AgentRunTrace t) {
    final report = const TraceAnalyzer().analyze(t);
    final dims = {
      '记忆': report.memoryStatus,
      '工具': report.toolStatus,
      '状态': report.stateStatus,
      '上下文': report.contextStatus,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: report.failed.isEmpty
              ? const Color(0xFFD8E8D8)
              : const Color(0xFFE8C8C8),
        ),
      ),
      child: ExpansionTile(
        shape: const Border(),
        title: Text(
          '${_hm(t.startedAt)} ${t.userInput.isEmpty ? "🔧 工具轮" : t.userInput}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, color: Colors.black87),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '${t.toolExecutions.isEmpty ? "无工具" : t.toolExecutions.map((e) => e.name).join("、")} · '
            '${dims["记忆"]}记忆 ${dims["工具"]}工具 ${dims["状态"]}状态 ${dims["上下文"]}上下文',
            style: const TextStyle(fontSize: 11.5, color: Colors.black45),
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (report.failed.isEmpty)
                  const Text('✅ 本轮无问题', style: TextStyle(fontSize: 12, color: Colors.green))
                else
                  ...report.failed.map((c) => Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text('❌ ${c.checkId} ${c.name}：${c.detail}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFFB04040))),
                      )),
                if (report.suggestions.isNotEmpty)
                  ...report.suggestions.map((s) => Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('💡 $s', style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
                      )),
                const SizedBox(height: 6),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => _copyTraceJson(t),
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('复制完整数据', style: TextStyle(fontSize: 11.5)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('检查 ${report.checks.length} 项 · 失败 ${report.failed.length}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 11, color: Colors.black38)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
