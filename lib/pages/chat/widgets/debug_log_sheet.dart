import 'package:flutter/material.dart';

import '../../../utils/debug_logger.dart';

/// 调试日志弹层（黑底终端风格，可滚动、可选中复制、可按标签筛选）。
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
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
            const Divider(color: Colors.white24),
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
            Expanded(
              child: SingleChildScrollView(
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
