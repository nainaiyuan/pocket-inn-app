import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../butler/flow/butler_flow.dart';
import '../../../utils/debug_logger.dart';
import '../../../services/parse_utils.dart';
import '../../../butler/debug_lab/agent_run_trace.dart';
import '../../../butler/debug_lab/trace_store.dart';
import '../../butler/butler_self_test_page.dart';
import '../../butler/butler_skill_library_page.dart';
import '../../debug/debug_toolbox_page.dart';

/// 调试日志弹层（黑底终端风格，可滚动、可选中复制、可按标签筛选）。
/// 两个视图：日志（散行） / 流程（管家流程树，看每步是否顺利）。
///
/// 8-08 13:0x 用户反馈：日志太长找不到关键行 → 加「只看关键日志」开关
/// +「复制关键日志」按钮：只提取锚点行（🔧📦📋▶⏰🔔⏸❌⚠️）一键复制，
/// 直接粘贴发给龙虾定位断点（A/B/C/D 判定）。
/// [initialView] 8-11 22:2x：聊天页📋按钮直达「每轮」视图
void showDebugLogSheet(BuildContext context,
    {DbgView initialView = DbgView.logs}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DebugLogSheet(initialView: initialView),
  );
}

/// 8-11 22:2x：调试弹层三视图（互斥枚举，避免多 bool 状态打架）
enum DbgView { logs, flows, rounds }

class _DebugLogSheet extends StatefulWidget {
  final DbgView initialView;

  const _DebugLogSheet({this.initialView = DbgView.logs});

  @override
  State<_DebugLogSheet> createState() => _DebugLogSheetState();
}

class _DebugLogSheetState extends State<_DebugLogSheet> {
  String _filter = '全部';
  // 8-11 22:2x（用户：开关切换不方便）：三视图互斥枚举，不再多 bool 打架
  late DbgView _view = widget.initialView;
  bool _anchorsOnly = false; // true = 只看关键锚点行（🔧📦📋▶⏰🔔⏸❌⚠️）

  /// 关键锚点标记（断点定位用，对应 A/B/C/D 判定卡）
  static final RegExp _anchorPattern = RegExp(
    r'🔧|📦|📋|▶|⏰|🔔|⏸|❌|⚠️',
  );

  static const _tags = [
    '全部',
    '管家流程',
    '管家情绪',
    'Prompt',
    'AI路由',
    '检索',
    '温控',
    '其他',
  ];

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      minChildSize: 0.3,
      builder: (ctx, scrollCtrl) => Container(
        color: const Color(0xFF1A1A2E),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '🪲 调试日志',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // 视图切换：日志 / 流程
                ChoiceChip(
                  label: const Text('日志', style: TextStyle(fontSize: 11)),
                  selected: _view == DbgView.logs,
                  selectedColor: const Color(0xFFC896B4),
                  labelStyle: TextStyle(
                    color: _view == DbgView.logs ? Colors.white : Colors.white70,
                  ),
                  side: BorderSide(
                    color: _view == DbgView.logs
                        ? const Color(0xFFC896B4)
                        : Colors.white24,
                  ),
                  onSelected: (_) => setState(() => _view = DbgView.logs),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('流程', style: TextStyle(fontSize: 11)),
                  selected: _view == DbgView.flows,
                  selectedColor: const Color(0xFFC896B4),
                  labelStyle: TextStyle(
                    color: _view == DbgView.flows ? Colors.white : Colors.white70,
                  ),
                  side: BorderSide(
                    color: _view == DbgView.flows
                        ? const Color(0xFFC896B4)
                        : Colors.white24,
                  ),
                  onSelected: (_) => setState(() => _view = DbgView.flows),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('每轮', style: TextStyle(fontSize: 11)),
                  selected: _view == DbgView.rounds,
                  selectedColor: const Color(0xFF7FB5B5),
                  labelStyle: TextStyle(
                    color: _view == DbgView.rounds ? Colors.white : Colors.white70,
                  ),
                  side: BorderSide(
                    color: _view == DbgView.rounds
                        ? const Color(0xFF7FB5B5)
                        : Colors.white24,
                  ),
                  onSelected: (_) => setState(() => _view = DbgView.rounds),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭', style: TextStyle(color: Colors.white70)),
                ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      ctx,
                      MaterialPageRoute(
                        builder: (_) => const ButlerSkillLibraryPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.extension, size: 14, color: Color(0xFFC896B4)),
                  label: const Text(
                    '技能库',
                    style: TextStyle(color: Color(0xFFC896B4), fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      ctx,
                      MaterialPageRoute(
                        builder: (_) => const DebugToolboxPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.build_circle_outlined, size: 14, color: Color(0xFFC896B4)),
                  label: const Text(
                    '工具箱',
                    style: TextStyle(color: Color(0xFFC896B4), fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      ctx,
                      MaterialPageRoute(
                        builder: (_) => const ButlerSelfTestPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.healing, size: 14, color: Color(0xFFC896B4)),
                  label: const Text(
                    '一键自检',
                    style: TextStyle(color: Color(0xFFC896B4), fontSize: 12),
                  ),
                ),
              ],
            ),
            const Divider(color: Colors.white24),
            if (_view == DbgView.rounds) ...[
              // 8-11 21:5x（用户：看不见男主每轮 prompt 发生了什么）：
              // 每轮输入（动态块，固定设定已过滤）+ 男主回复命令 + 变化标记
              _RoundsView(scrollController: scrollCtrl),
            ] else if (_view == DbgView.flows) ...[
              _FlowTreeView(scrollController: scrollCtrl),
            ] else ...[
              // 只看关键锚点 + 一键复制（08-08 新增：日志太长找不到关键行）
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: const Text('🔍 只看关键', style: TextStyle(fontSize: 11)),
                      selected: _anchorsOnly,
                      selectedColor: const Color(0xFFC896B4),
                      labelStyle: TextStyle(
                        color: _anchorsOnly ? Colors.white : Colors.white70,
                      ),
                      side: BorderSide(
                        color: _anchorsOnly
                            ? const Color(0xFFC896B4)
                            : Colors.white24,
                      ),
                      onSelected: (v) =>
                          setState(() => _anchorsOnly = v),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '🔧📦📋▶⏰🔔⏸❌⚠️',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _copyAnchorLogs,
                      icon: const Icon(Icons.copy, size: 14, color: Color(0xFFC896B4)),
                      label: const Text(
                        '复制关键日志',
                        style: TextStyle(color: Color(0xFFC896B4), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              // 标签筛选
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final tag in _tags)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(
                            tag,
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: _filter == tag,
                          selectedColor: const Color(0xFFC896B4),
                          labelStyle: TextStyle(
                            color: _filter == tag
                                ? Colors.white
                                : Colors.white70,
                          ),
                          side: BorderSide(
                            color: _filter == tag
                                ? const Color(0xFFC896B4)
                                : Colors.white24,
                          ),
                          onSelected: (_) => setState(() => _filter = tag),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
            Expanded(
              child: _view == DbgView.flows
                  ? _FlowTreeView(scrollController: scrollCtrl)
                  : SingleChildScrollView(
                      controller: scrollCtrl,
                      child: SelectableText(
                        _filteredText.isEmpty ? '暂无日志' : _filteredText,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String get _filteredText {
    final all = DebugLogger.recentLogs;
    // 锚点过滤（只看关键行，叠加在标签筛选之上）
    Iterable<String> base;
    if (_filter == '全部') {
      base = all;
    } else if (_filter == '其他') {
      base = all
          .where((l) => !_tags.sublist(1).any((t) => l.contains('[$t]')));
    } else {
      base = all.where((l) => l.contains('[$_filter]'));
    }
    if (_anchorsOnly) {
      base = base.where((l) => _anchorPattern.hasMatch(l));
    }
    return base.join('\n');
  }

  /// 复制关键锚点日志到剪贴板（不受标签筛选影响，取全部锚点行按时间顺序）
  Future<void> _copyAnchorLogs() async {
    final all = DebugLogger.recentLogs;
    final anchors =
        all.where((l) => _anchorPattern.hasMatch(l)).toList(growable: false);
    if (anchors.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有关键日志，先跑一次再复制')),
      );
      return;
    }
    final text = [
      '===== 关键锚点日志（${DateTime.now().toString()}）=====',
      ...anchors,
      '===== 结束 =====',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${anchors.length} 行关键日志，直接粘贴发给龙虾即可')),
    );
  }
}

/// 流程树视图：看每个流程的每步是否顺利
class _FlowTreeView extends StatelessWidget {
  final ScrollController scrollController;

  const _FlowTreeView({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final flows = ButlerFlowRunner.instance.history;
    final current = ButlerFlowRunner.instance.current;

    if (flows.isEmpty && current == null) {
      return const Center(
        child: Text(
          '还没有流程记录。\n发一条消息给男主，就能看到完整的聊天流程。',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.6),
        ),
      );
    }

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        if (current != null) ...[
          _FlowCard(flow: current, isCurrent: true),
          const SizedBox(height: 10),
        ],
        for (final flow in flows) ...[
          _FlowCard(flow: flow),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _FlowCard extends StatelessWidget {
  final ButlerFlow flow;
  final bool isCurrent;

  const _FlowCard({required this.flow, this.isCurrent = false});

  @override
  Widget build(BuildContext context) {
    final ok = flow.status == ButlerFlowStatus.success;
    final failed = flow.status == ButlerFlowStatus.failed;
    final icon = isCurrent
        ? '🔄'
        : failed
            ? '✖'
            : ok
                ? '✓'
                : '⏸';
    final color = failed
        ? const Color(0xFFFF8A8A)
        : ok
            ? const Color(0xFF9CE8A8)
            : Colors.white70;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: failed
              ? const Color(0xFFFF8A8A).withValues(alpha: 0.5)
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${flow.name}${isCurrent ? '（进行中）' : ''}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                failed
                    ? '第 ${flow.steps.indexWhere((s) => s.status == ButlerFlowStepStatus.failed) + 1} 步出错'
                    : '${flow.totalElapsedMs}ms',
                style: TextStyle(color: color, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final step in flow.steps)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 14,
                    child: Text(
                      _stepIcon(step.status),
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.name,
                          style: TextStyle(
                            color: step.status == ButlerFlowStepStatus.failed
                                ? const Color(0xFFFF8A8A)
                                : Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        if (step.result != null)
                          Text(
                            step.result!,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 10,
                            ),
                          ),
                        if (step.error != null)
                          Text(
                            '判定错误: ${step.error}',
                            style: const TextStyle(
                              color: Color(0xFFFF8A8A),
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    step.elapsedMs > 0 ? '${step.elapsedMs}ms' : '',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          // 工具调用链：技能执行时调用了哪些工具、输入输出
          if (flow.toolCalls.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '🔧 工具调用',
                style: TextStyle(color: Color(0xFFC896B4), fontSize: 10),
              ),
            ),
            for (final call in flow.toolCalls)
              Padding(
                padding: const EdgeInsets.only(top: 3, left: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      call.error != null ? '✖' : '✔',
                      style: TextStyle(
                        fontSize: 10,
                        color: call.error != null
                            ? const Color(0xFFFF8A8A)
                            : const Color(0xFF9CE8A8),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            call.toolName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (call.argsSummary.isNotEmpty)
                            Text(
                              '入: ${call.argsSummary}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.35),
                                fontSize: 9,
                              ),
                            ),
                          if (call.resultSummary != null)
                            Text(
                              '出: ${call.resultSummary}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 9,
                              ),
                            ),
                          if (call.error != null)
                            Text(
                              '错: ${call.error}',
                              style: const TextStyle(
                                color: Color(0xFFFF8A8A),
                                fontSize: 9,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      call.elapsedMs > 0 ? '${call.elapsedMs}ms' : '',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _stepIcon(ButlerFlowStepStatus s) {
    switch (s) {
      case ButlerFlowStepStatus.success:
        return '✔';
      case ButlerFlowStepStatus.failed:
        return '✖';
      case ButlerFlowStepStatus.running:
        return '…';
      case ButlerFlowStepStatus.skipped:
        return '·';
      case ButlerFlowStepStatus.pending:
        return '○';
    }
  }
}

// ────────────────────────────────────────────────────────────
// 每轮视图（8-11 21:5x 用户：看不见男主每轮 prompt 收到什么/回了什么）
// ────────────────────────────────────────────────────────────
class _RoundsView extends StatefulWidget {
  final ScrollController scrollController;

  const _RoundsView({required this.scrollController});

  @override
  State<_RoundsView> createState() => _RoundsViewState();
}

class _RoundsViewState extends State<_RoundsView> {
  late Future<List<AgentRunTrace>> _future;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _future = TraceStore.instance.all(limit: 30);
    // 8-11 22:2x（用户：还要我自己刷新？）：新轨迹落盘自动重读，
    // 面板开着时每轮结束自动冒出来，零手动操作
    _sub = TraceStore.revisionStream.listen((_) {
      if (!mounted) return;
      setState(() {
        _future = TraceStore.instance.all(limit: 30);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _future = TraceStore.instance.all(limit: 30);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('每轮记录（最近30条）',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            const Spacer(),
            TextButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 13, color: Color(0xFF7FB5B5)),
              label: const Text('刷新',
                  style: TextStyle(color: Color(0xFF7FB5B5), fontSize: 11)),
            ),
          ],
        ),
        Expanded(
          child: FutureBuilder<List<AgentRunTrace>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(
                  child: Text('读取轨迹…',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                );
              }
              final rounds = snap.data ?? const <AgentRunTrace>[];
              if (rounds.isEmpty) {
                return const Center(
                  child: Text(
                    '还没有每轮记录。\n发一条消息给男主，这里就能看到\n'
                    '他每轮收到什么、回了什么命令。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white38, fontSize: 12, height: 1.6),
                  ),
                );
              }
              return ListView.builder(
                controller: widget.scrollController,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: rounds.length,
                itemBuilder: (context, i) {
                  // 上一轮 = 更新的轮次（all 倒序：最新在前）
                  final prev = i + 1 < rounds.length ? rounds[i + 1] : null;
                  return _RoundCard(round: rounds[i], prev: prev);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RoundCard extends StatefulWidget {
  final AgentRunTrace round;
  final AgentRunTrace? prev; // 上一轮（更早一次回复），diff 参照

  const _RoundCard({required this.round, this.prev});

  @override
  State<_RoundCard> createState() => _RoundCardState();
}

class _RoundCardState extends State<_RoundCard> {
  bool _expanded = false;

  /// 本轮输入块（固定块已过滤）——标题行 = 块首行，正文 = 剩余
  List<(String, String, String)> get _inputBlocks {
    final out = <(String, String, String)>[];
    for (final m in widget.round.firstMessages) {
      final c = m.content.trim();
      if (c.isEmpty && m.toolCalls.isEmpty) continue;
      final title = c.split('\n').first;
      final body = c.length > title.length ? c.substring(title.length).trim() : '';
      out.add((m.role, title, body));
    }
    for (final m in widget.round.secondMessages) {
      final c = m.content.trim();
      if (c.isEmpty && m.toolCalls.isEmpty) continue;
      final title = c.split('\n').first;
      final body = c.length > title.length ? c.substring(title.length).trim() : '';
      out.add((m.role, title, body));
    }
    return out;
  }

  /// diff：上一轮没有的块 = 🆕 新增；有但内容不同 = 🔄 变化；相同 = 未变
  String _diffMark(String title, String body, int index) {
    final prev = widget.prev;
    if (prev == null) return '🆕';
    final prevBlocks = <String>[];
    for (final m in [...prev.firstMessages, ...prev.secondMessages]) {
      final c = m.content.trim();
      if (c.isEmpty) continue;
      prevBlocks.add('${m.role}|${c.split('\n').first}|${c.substring(c.split('\n').first.length).trim()}');
    }
    final mine = '$title|$body';
    // 同位置或任意位置有同标题 → 比内容
    for (final p in prevBlocks) {
      final pTitle = p.split('|')[1];
      if (pTitle == title) {
        return p == mine ? '·' : '🔄';
      }
    }
    return '🆕';
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.round;
    final kind = r.isToolRound ? '🔧工具轮' : '💬用户轮';
    final time = _fmtTime(r.startedAt);
    final blocks = _inputBlocks;
    final toolCalls = r.modelToolCalls;
    final exit = parseExitSignal(r.modelText ?? '');
    final next = parseNextAction(r.modelText ?? '');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF232342),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(kind, style: const TextStyle(color: Color(0xFF7FB5B5), fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Text(time, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  const Spacer(),
                  if (exit == true)
                    const Text('🔚结束', style: TextStyle(color: Color(0xFFE0A0A0), fontSize: 11))
                  else if (exit == false)
                    const Text('🔁续命', style: TextStyle(color: Color(0xFFA0C8E0), fontSize: 11)),
                  if (toolCalls.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text('🛠${toolCalls.length}', style: const TextStyle(color: Color(0xFFC896B4), fontSize: 11)),
                  ],
                  const SizedBox(width: 6),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: Colors.white38, size: 18),
                ],
              ),
              if (r.userInput.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '她：${_short(r.userInput, 60)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
              if (_expanded) ...[
                const Divider(color: Colors.white12, height: 16),
                // 输入动态块
                if (blocks.isEmpty)
                  const Text('（本轮只有固定设定，无动态块）',
                      style: TextStyle(color: Colors.white38, fontSize: 11))
                else
                  for (var i = 0; i < blocks.length; i++) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 26,
                          child: Text(
                            _diffMark(blocks[i].$2, blocks[i].$3, i),
                            style: TextStyle(
                              color: _diffMark(blocks[i].$2, blocks[i].$3, i) == '·'
                                  ? Colors.white24
                                  : const Color(0xFFFFD28A),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${blocks[i].$1 == 'user' ? '📨' : '🧩'} ${blocks[i].$2}'
                            '${blocks[i].$3.isNotEmpty ? '\n${blocks[i].$3}' : ''}',
                            style: TextStyle(
                              color: _diffMark(blocks[i].$2, blocks[i].$3, i) == '·'
                                  ? Colors.white30
                                  : Colors.white70,
                              fontSize: 11,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                  ],
                // 男主回复命令
                const Divider(color: Colors.white12, height: 16),
                const Text('➡️ 男主回复命令',
                    style: TextStyle(color: Color(0xFFC896B4), fontSize: 11, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                if (toolCalls.isNotEmpty)
                  for (final tc in toolCalls)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '🛠 ${tc.name}(${_argsBrief(tc.arguments)})',
                        style: const TextStyle(color: Color(0xFFA8D8B9), fontSize: 11),
                      ),
                    ),
                if ((r.modelText ?? '').trim().isNotEmpty)
                  Text(
                    '💬 ${r.modelText!.trim()}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.5),
                  ),
                if (next != null && next != 'merge')
                  Text('🔀 next_action=$next',
                      style: const TextStyle(color: Color(0xFFA0C8E0), fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _fmtTime(DateTime? dt) {
  if (dt == null) return '--:--';
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String _short(String s, int max) =>
    s.length > max ? '${s.substring(0, max)}…' : s;

String _argsBrief(Map<String, dynamic> args) {
  if (args.isEmpty) return '';
  final parts = args.entries.map((e) => '${e.key}=${_short(e.value.toString(), 24)}');
  return parts.join('，');
}

