import 'package:flutter/material.dart';

import '../butler/system_template.dart';

/// 系统提示查看页 — 看每次聊天到底带了什么 system 信息
///
/// 用户 8-03 02:49 改造：
/// ① 没发消息也能看固定模板（preview 兜底，不再依赖 lastBuilt）
/// ② 可编辑 SYSTEM_CORE（尽量不改，但想改能改）
/// ③ 可恢复默认（改坏了一键还原出厂）
class SystemViewPage extends StatefulWidget {
  const SystemViewPage({super.key});

  @override
  State<SystemViewPage> createState() => _SystemViewPageState();
}

class _SystemViewPageState extends State<SystemViewPage> {
  @override
  void initState() {
    super.initState();
    SystemTemplate.loadCoreOverride();
  }

  Future<void> _editCore() async {
    final controller = TextEditingController(
      text: SystemTemplate.effectiveSystemCore,
    );
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFDF7F9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '编辑固定模板（SYSTEM_CORE）',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6A4A5A),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '这是所有男主共用的系统核心（角色设定、工具规则不在这里）。'
              '建议尽量不改——改动会影响所有角色的行为。想恢复原样点"恢复默认"。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF8A7A80),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 14,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(
                    '取消',
                    style: TextStyle(color: Color(0xFF8A7A80)),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC896B4),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      await SystemTemplate.saveCoreOverride(controller.text);
      if (mounted) setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('固定模板已更新，下次聊天生效'),
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  Future<void> _resetCore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('恢复默认固定模板？'),
        content: const Text(
          '会丢掉你修改过的 SYSTEM_CORE，回到出厂版本。确定吗？',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC896B4)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await SystemTemplate.resetCoreOverride();
      if (mounted) setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已恢复默认固定模板'),
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lastBuilt = SystemTemplate.lastBuilt;
    final hasOverride = SystemTemplate.coreOverride != null;
    final content = lastBuilt ?? SystemTemplate.preview();
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        foregroundColor: const Color(0xFF6A4A5A),
        elevation: 0,
        title: const Text(
          '系统提示',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '恢复默认',
            onPressed: hasOverride ? _resetCore : null,
            icon: const Icon(Icons.restore),
            color: hasOverride
                ? const Color(0xFF6A4A5A)
                : const Color(0xFFC9B8C0),
          ),
          IconButton(
            tooltip: '编辑固定模板',
            onPressed: _editCore,
            icon: const Icon(Icons.edit_outlined),
            color: const Color(0xFF6A4A5A),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFC896B4).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                lastBuilt == null
                    ? '还没聊过天，这是固定模板预览（SYSTEM_CORE + 男主设定骨架）。'
                        '聊过之后这里会显示实际发送给男主的完整内容。'
                        '右上角可编辑固定模板，改坏了可一键恢复默认。'
                    : '这是最近一次聊天实际发送给男主的系统提示。'
                        '结构 = 固定模板（所有男主通用）+ 男主专属人设 + 实时注入。'
                        '右上角可编辑固定模板，改坏了可一键恢复默认。'
                        '${hasOverride ? '\n当前使用你编辑过的固定模板。' : ''}',
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Color(0xFF6A4A5A),
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: SelectableText(
                content,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: Color(0xFF4A3A42),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
