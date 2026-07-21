import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';

/// 角色设置侧栏（右页）
///
/// 当前角色的全部配置，长按左页卡片 → 编辑入口
class ChatSidebarRight extends StatefulWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final VoidCallback onDelete; // 删完后切角色用

  const ChatSidebarRight({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onDelete,
  });

  @override
  State<ChatSidebarRight> createState() => _ChatSidebarRightState();
}

class _ChatSidebarRightState extends State<ChatSidebarRight> {
  final _promptCtrl = TextEditingController();
  final _greetingCtrl = TextEditingController();
  final _service = CharacterService();

  // 默认值（本地状态兜底）
  bool _butlerIntervention = true;   // 管家干预自然语言
  bool _shareMemory = true;          // 本体记忆共享
  bool _showingPrompt = true;        // 当前展示 prompt 还是关键词

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void didUpdateWidget(ChatSidebarRight old) {
    super.didUpdateWidget(old);
    if (old.currentPersona?.id != widget.currentPersona?.id) {
      _syncControllers();
    }
  }

  void _syncControllers() {
    if (widget.currentPersona != null) {
      _promptCtrl.text = widget.currentPersona!.prompt;
      _greetingCtrl.text = widget.currentPersona!.greeting;
    } else {
      _promptCtrl.clear();
      _greetingCtrl.clear();
    }
  }

  void _savePrompt() {
    final p = widget.currentPersona;
    final l = widget.currentLead;
    if (p == null || l == null) return;
    final updated = p.copyWith(
      prompt: _promptCtrl.text,
      greeting: _greetingCtrl.text,
    );
    _service.updatePersona(l.id, updated);
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _greetingCtrl.dispose();
    super.dispose();
  }

  // ─── 删除角色（二次确认，放在右侧栏最下方） ───
  Future<void> _confirmDelete() async {
    final l = widget.currentLead;
    if (l == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('删除 "${l.name}"？'),
        content: const Text('所有形象和聊天记录都将被删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _service.deleteMaleLead(l.id);
      widget.onDelete();
    }
  }

  Future<void> _confirmDeletePersona() async {
    final l = widget.currentLead;
    final p = widget.currentPersona;
    if (l == null || p == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('删除 "${p.name}"？'),
        content: const Text('此形象将被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _service.deletePersona(l.id, p.id);
      widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPersona = widget.currentPersona != null;
    final personaName = widget.currentPersona?.name ?? '本体';
    final leadName = widget.currentLead?.name ?? '';

    return Container(
      color: const Color(0xFFF5EEF0),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 56),

            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      hasPersona ? '$leadName · $personaName' : leadName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF3D2C33),
                        letterSpacing: 1,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '角色设定',
                style: TextStyle(fontSize: 12, color: const Color(0xFF8A7A80)),
              ),
            ),
            const SizedBox(height: 12),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  // ─── 角色设定（Prompt + 开场白） ───
                  _SectionCard(
                    title: '角色设定',
                    child: Column(
                      children: [
                        // 开场白
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '首次问候',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: const Color(0xFF5A4A52),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: _greetingCtrl,
                                decoration: const InputDecoration(
                                  hintText: '你好，我是…',
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF3D2C33),
                                ),
                                onChanged: (_) => _savePrompt(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Prompt
                        Container(
                          height: 140,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: TextField(
                            controller: _promptCtrl,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            decoration: const InputDecoration(
                              hintText: '在这里书写角色设定…\n管家会帮你整理分类',
                              hintStyle: TextStyle(
                                color: Color(0xFF8A7A80),
                                fontSize: 13,
                                height: 1.5,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            style: const TextStyle(fontSize: 13, color: Color(0xFF3D2C33), height: 1.5),
                            onChanged: (_) => _savePrompt(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 关键词 / 记忆管理 ───
                  _SectionCard(
                    title: '关键词与记忆',
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          // Tab: Prompt / 关键词切换
                          Row(
                            children: [
                              _TabBtn(label: '系统 Prompt', active: _showingPrompt, onTap: () => setState(() => _showingPrompt = true)),
                              const SizedBox(width: 8),
                              _TabBtn(label: '关键词', active: !_showingPrompt, onTap: () => setState(() => _showingPrompt = false)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (_showingPrompt)
                            // 只读的完整系统 prompt（由管家生成）
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0E8EC),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text(
                                '（系统 Prompt 由管家自动生成，\n可在上方「角色设定」中编辑原始设定）',
                                style: TextStyle(fontSize: 12, color: Color(0xFF8A7A80), height: 1.5),
                              ),
                            )
                          else
                            // 关键词列表（占位，待接入记忆数据）
                            Center(
                              child: Text(
                                '尚未收集到关键词',
                                style: TextStyle(fontSize: 13, color: const Color(0xFF8A7A80)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 全局开关 ───
                  _SectionCard(
                    title: '全局设置',
                    child: Column(
                      children: [
                        // 管家干预用户语言
                        _SwitchTile(
                          label: '管家不干预自然语言',
                          subtitle: '开启后用户输入内容不经过管家处理',
                          value: !_butlerIntervention,
                          onChanged: (v) => setState(() => _butlerIntervention = !v),
                        ),
                        const SizedBox(height: 4),
                        // 本体记忆共享
                        _SwitchTile(
                          label: '本体记忆共享',
                          subtitle: '当前角色的所有形象共享记忆',
                          value: _shareMemory,
                          onChanged: (v) => setState(() => _shareMemory = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 危险操作 ───
                  _SectionCard(
                    title: '危险操作',
                    child: Column(
                      children: [
                        if (widget.currentPersona != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SizedBox(
                              width: double.infinity,
                              child: Material(
                                color: Colors.redAccent.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: _confirmDeletePersona,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent.withValues(alpha: 0.6)),
                                        const SizedBox(width: 6),
                                        Text(
                                          '删除当前形象「${widget.currentPersona!.name}」',
                                          style: TextStyle(fontSize: 13, color: Colors.redAccent.withValues(alpha: 0.8)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: Material(
                            color: Colors.redAccent.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: _confirmDelete,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.delete_forever_rounded, size: 16, color: Colors.redAccent.withValues(alpha: 0.6)),
                                    const SizedBox(width: 6),
                                    Text(
                                      '删除角色「${widget.currentLead?.name ?? ''}」',
                                      style: TextStyle(fontSize: 13, color: Colors.redAccent.withValues(alpha: 0.8)),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 小组件 ───

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF5A4A52), letterSpacing: 1),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchTile({required this.label, required this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF3D2C33))),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle, style: TextStyle(fontSize: 11, color: const Color(0xFF8A7A80).withValues(alpha: 0.7))),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 自定义开关
              Container(
                width: 40,
                height: 22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: value
                      ? const Color(0xFFE8A0B8).withValues(alpha: 0.5)
                      : const Color(0xFF5A4A52).withValues(alpha: 0.12),
                ),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 200),
                      left: value ? 20 : 2,
                      top: 2,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 2)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabBtn({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? const Color(0xFFE8A0B8).withValues(alpha: 0.2) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              color: active ? const Color(0xFFB48296) : const Color(0xFF8A7A80),
            ),
          ),
        ),
      ),
    );
  }
}
