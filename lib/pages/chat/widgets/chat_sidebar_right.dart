import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';

/// 角色设置侧栏（右页）
class ChatSidebarRight extends StatefulWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final VoidCallback onDelete;

  const ChatSidebarRight({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onDelete,
  });

  @override
  State<ChatSidebarRight> createState() => _ChatSidebarRightState();
}

/// 角色设定结构化字段
class _RoleFields {
  String world;        // 世界观·背景
  String relation;     // 与用户的关系
  String traits;       // 喜好·性格·习惯
  String connections;  // 亲朋好友
  String history;      // 经历

  _RoleFields({
    this.world = '',
    this.relation = '',
    this.traits = '',
    this.connections = '',
    this.history = '',
  });

  static _RoleFields fromPrompt(String prompt) {
    if (prompt.isEmpty) return _RoleFields();
    try {
      final m = jsonDecode(prompt) as Map<String, dynamic>;
      return _RoleFields(
        world: m['world'] as String? ?? '',
        relation: m['relation'] as String? ?? '',
        traits: m['traits'] as String? ?? '',
        connections: m['connections'] as String? ?? '',
        history: m['history'] as String? ?? '',
      );
    } catch (_) {
      return _RoleFields(world: prompt);
    }
  }

  String toPrompt() {
    final m = <String, String>{
      'world': world,
      'relation': relation,
      'traits': traits,
      'connections': connections,
      'history': history,
    };
    return jsonEncode(m);
  }
}

class _ChatSidebarRightState extends State<ChatSidebarRight> {
  final _greetingCtrl = TextEditingController();
  final _service = CharacterService();

  // 5个设定控制器
  late List<TextEditingController> _fieldCtrls;
  _RoleFields _fields = _RoleFields();

  // 开关
  bool _butlerIntervention = true;
  bool _shareMemory = true;
  bool _showingPrompt = true;

  @override
  void initState() {
    super.initState();
    _fieldCtrls = List.generate(5, (_) => TextEditingController());
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
    final p = widget.currentPersona;
    if (p == null) return;
    _greetingCtrl.text = p.greeting;

    _fields = _RoleFields.fromPrompt(p.prompt);
    _fieldCtrls[0].text = _fields.world;
    _fieldCtrls[1].text = _fields.relation;
    _fieldCtrls[2].text = _fields.traits;
    _fieldCtrls[3].text = _fields.connections;
    _fieldCtrls[4].text = _fields.history;
  }

  void _saveAll() {
    final p = widget.currentPersona;
    final l = widget.currentLead;
    if (p == null || l == null) return;

    _fields = _RoleFields(
      world: _fieldCtrls[0].text,
      relation: _fieldCtrls[1].text,
      traits: _fieldCtrls[2].text,
      connections: _fieldCtrls[3].text,
      history: _fieldCtrls[4].text,
    );

    final updated = p.copyWith(
      prompt: _fields.toPrompt(),
      greeting: _greetingCtrl.text,
    );
    _service.updatePersona(l.id, updated);
  }

  @override
  void dispose() {
    for (final c in _fieldCtrls) {
      c.dispose();
    }
    _greetingCtrl.dispose();
    super.dispose();
  }

  // ─── 删除 ───
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
    final isLead = widget.currentPersona == null || widget.currentPersona?.name == '默认';
    final personaName = widget.currentPersona?.name ?? '本体';
    final leadName = widget.currentLead?.name ?? '';

    return Container(
      color: const Color(0xFFF5EEF0),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 56),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      isLead ? leadName : '$leadName · $personaName',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF3D2C33), letterSpacing: 1),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(isLead ? '本体设定' : '时间线设定', style: TextStyle(fontSize: 12, color: const Color(0xFF8A7A80))),
            ),
            const SizedBox(height: 12),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  // ─── 角色设定（5个结构化字段） ───
                  _SectionCard(
                    title: isLead ? '角色设定（同步到所有形象）' : '角色设定',
                    child: Column(
                      children: [
                        _FieldBox(label: '首次问候', ctrl: _greetingCtrl, onChanged: _saveAll, maxLines: 2),
                        const SizedBox(height: 8),

                        // 5个设定框
                        // 1. 世界观/背景
                        _FieldBox(label: '世界观 · 背景', hint: '世界是什么样子的？', ctrl: _fieldCtrls[0], onChanged: _saveAll),
                        const SizedBox(height: 8),
                        // 2. 与用户的关系
                        _FieldBox(label: '与用户的关系', hint: 'ta叫你什么？你们是什么关系？', ctrl: _fieldCtrls[1], onChanged: _saveAll),
                        const SizedBox(height: 8),
                        // 3. 喜好·性格·习惯
                        _FieldBox(label: '喜好 · 性格 · 习惯', hint: '喜欢什么？性格怎么样？', ctrl: _fieldCtrls[2], onChanged: _saveAll),
                        const SizedBox(height: 8),
                        // 4. 亲朋好友
                        _FieldBox(label: '亲朋好友', hint: '身边有哪些重要的人？', ctrl: _fieldCtrls[3], onChanged: _saveAll),
                        const SizedBox(height: 8),
                        // 5. 经历
                        _FieldBox(label: '经历', hint: '过去发生过什么重要的故事？', ctrl: _fieldCtrls[4], onChanged: _saveAll),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 关键词 / 记忆 ───
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
                          Row(
                            children: [
                              _TabBtn(label: '系统 Prompt', active: _showingPrompt, onTap: () => setState(() => _showingPrompt = true)),
                              const SizedBox(width: 8),
                              _TabBtn(label: '关键词', active: !_showingPrompt, onTap: () => setState(() => _showingPrompt = false)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (_showingPrompt)
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0E8EC),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text(
                                '（系统 Prompt 由管家自动生成，可在上方编辑原始设定）',
                                style: TextStyle(fontSize: 12, color: Color(0xFF8A7A80), height: 1.5),
                              ),
                            )
                          else
                            Center(
                              child: Text('尚未收集到关键词', style: TextStyle(fontSize: 13, color: const Color(0xFF8A7A80))),
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
                        _SwitchTile(
                          label: '管家不干预自然语言',
                          subtitle: '开启后用户输入不经过管家处理',
                          value: !_butlerIntervention,
                          onChanged: (v) => setState(() => _butlerIntervention = !v),
                        ),
                        const SizedBox(height: 4),
                        _SwitchTile(
                          label: '本体记忆共享',
                          subtitle: '所有形象共用本体记忆',
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
                        // 只有 persona 才显示「删除形象」
                        if (!isLead && widget.currentPersona != null)
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
          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF5A4A52), letterSpacing: 1)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _FieldBox extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController ctrl;
  final VoidCallback onChanged;
  final int maxLines;

  const _FieldBox({
    required this.label,
    this.hint = '',
    required this.ctrl,
    required this.onChanged,
    this.maxLines = 3,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF5A4A52), fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            maxLines: maxLines,
            decoration: InputDecoration(
              hintText: hint,
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(fontSize: 13, color: Color(0xFF3D2C33)),
            onChanged: (_) => onChanged(),
          ),
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
              Container(
                width: 40,
                height: 22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: value ? const Color(0xFFE8A0B8).withValues(alpha: 0.5) : const Color(0xFF5A4A52).withValues(alpha: 0.12),
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
