import 'package:flutter/material.dart';

import '../../../models/chat_message.dart';
import 'message_bubble.dart';

/// 8-08 20:1x（用户 + GPT 定稿）：工具气泡收纳——连续 [tool] 消息聚成工具卡。
///
/// - 折叠态：一行小卡「🛠 调用了 N 个工具 ▾」/ 执行中「🛠 正在调用：X…（m/N）」
/// - 展开态：段内每条气泡原样渲染（复用 [MessageBubble]，和现在的气泡一模一样）
/// - 纯展示层聚合：不改 DB、不改 _appendToolBubble 调用点、不改消息模型
/// - 分组规则（GPT 定稿）：连续 [tool] 消息合并；遇到用户消息/男主文本回复/
///   [act] 动作气泡切断；工具卡不跨用户消息
/// - 展开策略（GPT 定稿）：执行中自动展开（能看到进度）；完成后保持用户
///   当前展开状态（不自动收起）；用户手动点过之后不再自动干预
class ToolGroupData {
  final List<ChatMessage> msgs;
  const ToolGroupData(this.msgs);
}

/// 展示层聚合：正序消息列表 → 混合列表（ChatMessage | ToolGroupData）
List<Object> groupToolMessages(List<ChatMessage> msgs) {
  final out = <Object>[];
  var buf = <ChatMessage>[];
  void flush() {
    if (buf.isEmpty) return;
    out.add(ToolGroupData(List.of(buf)));
    buf = [];
  }

  for (final m in msgs) {
    if (m.text.startsWith('[tool]')) {
      buf.add(m); // 连续工具消息 → 入段
    } else {
      flush(); // 用户消息/男主文本回复/[act] → 切断
      out.add(m);
    }
  }
  flush();
  return out;
}

class ToolGroupCard extends StatefulWidget {
  const ToolGroupCard({
    super.key,
    required this.group,
    required this.inputTapRegionGroupId,
  });

  final ToolGroupData group;
  final Object inputTapRegionGroupId;

  @override
  State<ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<ToolGroupCard> {
  bool _expanded = false;
  bool _userTouched = false; // 用户手动点过 → 之后不再自动展开

  /// 段内是否执行中（8-08 21:3x 用户："一直 3/6" 根因修复）：
  /// 之前用"段内任何消息含'正在'"——工具消息是历史落库文本，完成态
  /// 不改写它 → running 永远 true → 标题永远"正在调用：X…（m/N）"。
  /// 改：执行中 = 段内【最后一条】消息是"正在…"（工具轮还在追加）；
  /// 最后一条是 ✅/❌（_appendToolResultBubble 统一出口）→ 轮已结束。
  bool get _running {
    if (widget.group.msgs.isEmpty) return false;
    return widget.group.msgs.last.text.contains('正在');
  }

  /// 当前执行中的工具名（最后一条"正在…"消息）
  String? get _currentTool {
    for (final m in widget.group.msgs.reversed) {
      final t = m.text;
      final idx = t.indexOf('正在');
      if (idx >= 0) {
        var name = t.substring(idx + 2).trim();
        name = name.replaceAll(RegExp(r'[…。！？!?~～：:]+$'), '').trim();
        if (name.isEmpty) name = '处理';
        return name;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    if (_running) _expanded = true; // 加载时就在执行中 → 自动展开
  }

  @override
  void didUpdateWidget(covariant ToolGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新消息进段（段变长/变 running）且用户没手动操作过 → 自动展开看进度；
    // 完成不自动收起（保持用户当前状态，GPT 定稿）
    if (_running && !_userTouched) _expanded = true;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.group.msgs.length;
    final running = _running;
    final current = _currentTool;
    // 8-08 21:3x（用户："3/6 不要这样显示"）：去掉 m/N 计数——
    // 计数会停在中间值（3/6）让人以为卡住。执行中只显示工具名，
    // 结束显示总数。
    final title = running
        ? '🛠 正在调用：$current…'
        : '🛠 调用了 $total 个工具';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() {
            _userTouched = true;
            _expanded = !_expanded;
          }),
          child: Container(
            margin: const EdgeInsets.only(left: 60, right: 60, top: 3, bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFC896B4).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9A6B84),
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 14,
                  color: const Color(0xFF9A6B84),
                ),
              ],
            ),
          ),
        ),
        // 展开态 = 现有气泡原样（MessageBubble 对 [tool] 有独立小气泡样式）
        if (_expanded)
          ...widget.group.msgs.map(
            (m) => MessageBubble(
              key: ValueKey(m.id),
              message: m,
              inputTapRegionGroupId: widget.inputTapRegionGroupId,
            ),
          ),
      ],
    );
  }
}
