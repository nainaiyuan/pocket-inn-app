import 'package:flutter/material.dart';

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
              '不用手动聊天，直接跑 3 条测试消息验证管家全流程：\n'
              '① "今天天气真好啊" → 语义情绪 + 聊天流程\n'
              '② "我今天心情好差，感觉好累" → 触发【情绪状态洞察】+ 工具调用\n'
              '③ "我妈妈说我太懒了" → 假面层处理\n\n'
              '自检不真实调用 AI（模拟回复）、不写情绪落库、不污染真实会话。\n'
              '详细过程：日志页 🐞 → 「流程」视图。',
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
        ],
      ),
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
        ],
      ),
    );
  }
}
