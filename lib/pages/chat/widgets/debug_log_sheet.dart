import 'package:flutter/material.dart';

import '../../../butler/flow/butler_flow.dart';
import '../../../utils/debug_logger.dart';

/// 调试日志弹层（黑底终端风格，可滚动、可选中复制、可按标签筛选）。
/// 两个视图：日志（散行） / 流程（管家流程树，看每步是否顺利）。
void showDebugLogSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _DebugLogSheet(),
  );
}

class _DebugLogSheet extends StatefulWidget {
  const _DebugLogSheet();

  @override
  State<_DebugLogSheet> createState() => _DebugLogSheetState();
}

class _DebugLogSheetState extends State<_DebugLogSheet> {
  String _filter = '全部';
  bool _showFlows = false; // false = 日志行视图，true = 流程树视图

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
                  selected: !_showFlows,
                  selectedColor: const Color(0xFFC896B4),
                  labelStyle: TextStyle(
                    color: !_showFlows ? Colors.white : Colors.white70,
                  ),
                  side: BorderSide(
                    color: !_showFlows
                        ? const Color(0xFFC896B4)
                        : Colors.white24,
                  ),
                  onSelected: (_) => setState(() => _showFlows = false),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('流程', style: TextStyle(fontSize: 11)),
                  selected: _showFlows,
                  selectedColor: const Color(0xFFC896B4),
                  labelStyle: TextStyle(
                    color: _showFlows ? Colors.white : Colors.white70,
                  ),
                  side: BorderSide(
                    color: _showFlows
                        ? const Color(0xFFC896B4)
                        : Colors.white24,
                  ),
                  onSelected: (_) => setState(() => _showFlows = true),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
            const Divider(color: Colors.white24),
            if (!_showFlows) ...[
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
              child: _showFlows
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
    if (_filter == '全部') return all.join('\n');
    if (_filter == '其他') {
      return all
          .where((l) => !_tags.sublist(1).any((t) => l.contains('[$t]')))
          .join('\n');
    }
    return all.where((l) => l.contains('[$_filter]')).join('\n');
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
