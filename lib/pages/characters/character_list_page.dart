import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/male_lead.dart';
import '../../services/character_service.dart';

/// 男主列表页 —— 显示所有男主
class CharacterListPage extends StatefulWidget {
  const CharacterListPage({super.key});

  @override
  State<CharacterListPage> createState() => _CharacterListPageState();
}

class _CharacterListPageState extends State<CharacterListPage> {
  final _service = CharacterService();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _service.load();
    if (mounted) setState(() {});
  }

  Future<void> _addMaleLead() async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: 0.85),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('新建男主'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入男主名字',
            border: InputBorder.none,
          ),
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _service.addMaleLead(MaleLead(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: result,
      ));
      if (mounted) setState(() {});
    }
  }

  Future<void> _deleteMaleLead(MaleLead lead) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: 0.85),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('删除「${lead.name}」？'),
        content: const Text('所有形象和聊天记录也会一同删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _service.deleteMaleLead(lead.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final leads = _service.leads;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: leads.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.favorite_border,
                    size: 48,
                    color: Color(0xFFD4A0B8),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '还没有男主',
                    style: TextStyle(
                      fontSize: 15,
                      color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildAddButton(),
                ],
              ),
            )
          : Column(
              children: [
                // 标题区
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 60, 24, 16),
                  child: Row(
                    children: [
                      Text(
                        '我的男主',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 2,
                          color: const Color(0xFF6A4A5A).withValues(alpha: 0.7),
                        ),
                      ),
                      const Spacer(),
                      _buildAddButton(),
                    ],
                  ),
                ),
                // 列表
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: leads.length,
                    itemBuilder: (context, index) {
                      final lead = leads[index];
                      return _MaleLeadCard(
                        lead: lead,
                        onTap: () => _openDetail(lead),
                        onDelete: () => _deleteMaleLead(lead),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildAddButton() {
    return Material(
      color: Colors.white.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _addMaleLead,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 18,
                color: const Color(0xFFB48296),
              ),
              const SizedBox(width: 4),
              Text(
                '新建',
                style: TextStyle(
                  fontSize: 14,
                  color: const Color(0xFFB48296),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(MaleLead lead) {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (ctx, a1, a2) => _CharacterDetailPage(lead: lead),
        transitionsBuilder: (ctx, anim, a2, child) {
          return FadeTransition(opacity: anim, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }
}

/// 男主卡片
class _MaleLeadCard extends StatelessWidget {
  final MaleLead lead;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _MaleLeadCard({
    required this.lead,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // 头像
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFFE8A0B8).withValues(alpha: 0.2),
                        const Color(0xFFC8A8D8).withValues(alpha: 0.2),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Icon(
                    Icons.person_outline,
                    size: 26,
                    color: Color(0xFFB48296),
                  ),
                ),
                const SizedBox(width: 16),
                // 信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lead.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6A4A5A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${lead.personas.length} 个形象',
                        style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                        ),
                      ),
                    ],
                  ),
                ),
                // 更多
                GestureDetector(
                  onTap: onDelete,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: const Color(0xFF5A4A52).withValues(alpha: 0.2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 男主详情页 —— 显示该男主下的所有形象
class _CharacterDetailPage extends StatefulWidget {
  final MaleLead lead;
  const _CharacterDetailPage({required this.lead});

  @override
  State<_CharacterDetailPage> createState() => _CharacterDetailPageState();
}

class _CharacterDetailPageState extends State<_CharacterDetailPage> {
  final _service = CharacterService();

  MaleLead get _lead => widget.lead;

  Future<void> _addPersona() async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: 0.85),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('为「${_lead.name}」新建形象'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入形象名称（如：校园版）',
            border: InputBorder.none,
          ),
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _service.addPersona(_lead.id, Persona(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        maleLeadId: _lead.id,
        name: result,
      ));
      if (mounted) setState(() {});
    }
  }

  void _editPersona(Persona persona) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (ctx, a1, a2) => _PersonaEditPage(
          maleLead: _lead,
          persona: persona,
        ),
        transitionsBuilder: (ctx, anim, a2, child) {
          return FadeTransition(opacity: anim, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _deletePersona(Persona persona) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: 0.85),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('删除「${persona.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _service.deletePersona(_lead.id, persona.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // 顶部
          Padding(
            padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 8, 8, 0),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: const Color(0xFF6A4A5A).withValues(alpha: 0.5),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
                const Spacer(),
                Text(
                  _lead.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6A4A5A),
                    letterSpacing: 2,
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 48),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // 形象列表
          Expanded(
            child: _lead.personas.isEmpty
                ? Center(
                    child: Text(
                      '还没有形象，点击右上角新建',
                      style: TextStyle(
                        fontSize: 13,
                        color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _lead.personas.length,
                    itemBuilder: (context, index) {
                      final p = _lead.personas[index];
                      return _PersonaCard(
                        persona: p,
                        onTap: () => _editPersona(p),
                        onDelete: () => _deletePersona(p),
                      );
                    },
                  ),
          ),

          // 底部创建按钮
          Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              8,
              24,
              MediaQuery.of(context).padding.bottom + 16,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Material(
                color: Colors.white.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _addPersona,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_rounded,
                          size: 20,
                          color: const Color(0xFFB48296),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '新建形象',
                          style: TextStyle(
                            fontSize: 15,
                            color: const Color(0xFFB48296),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 形象卡片
class _PersonaCard extends StatelessWidget {
  final Persona persona;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PersonaCard({
    required this.persona,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFFC8A8D8).withValues(alpha: 0.15),
                        const Color(0xFFE8A0B8).withValues(alpha: 0.15),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Icon(
                    Icons.face_6_outlined,
                    size: 22,
                    color: Color(0xFFB48296),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        persona.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6A4A5A),
                        ),
                      ),
                      if (persona.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          persona.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 形象编辑页
class _PersonaEditPage extends StatefulWidget {
  final MaleLead maleLead;
  final Persona persona;

  const _PersonaEditPage({
    required this.maleLead,
    required this.persona,
  });

  @override
  State<_PersonaEditPage> createState() => _PersonaEditPageState();
}

class _PersonaEditPageState extends State<_PersonaEditPage> {
  late TextEditingController _nameCtrl;
  late TextEditingController _promptCtrl;
  late TextEditingController _greetingCtrl;
  late TextEditingController _descCtrl;
  final _service = CharacterService();

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.persona.name);
    _promptCtrl = TextEditingController(text: widget.persona.prompt);
    _greetingCtrl = TextEditingController(text: widget.persona.greeting);
    _descCtrl = TextEditingController(text: widget.persona.description);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    _greetingCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final updated = widget.persona.copyWith(
      name: _nameCtrl.text.trim(),
      prompt: _promptCtrl.text.trim(),
      greeting: _greetingCtrl.text.trim(),
      description: _descCtrl.text.trim(),
    );
    await _service.updatePersona(widget.maleLead.id, updated);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // 顶栏
          Padding(
            padding: EdgeInsets.fromLTRB(
              8,
              MediaQuery.of(context).padding.top + 8,
              8,
              0,
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: const Color(0xFF6A4A5A).withValues(alpha: 0.5),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
                const Spacer(),
                Text(
                  '编辑形象',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF6A4A5A).withValues(alpha: 0.7),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _save,
                  child: Text(
                    '保存',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFB48296),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 表单
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
              children: [
                _FieldCard(
                  label: '形象名称',
                  controller: _nameCtrl,
                  hint: '如：校园版、吸血鬼伯爵…',
                ),
                const SizedBox(height: 12),
                _FieldCard(
                  label: '简介',
                  controller: _descCtrl,
                  hint: '一句话描述这个形象',
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                _FieldCard(
                  label: '开场白',
                  controller: _greetingCtrl,
                  hint: '第一次对话时男主说的话',
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                _FieldCard(
                  label: 'Prompt（角色设定）',
                  controller: _promptCtrl,
                  hint:
                      '描述这个形象的性格、说话风格、背景故事……',
                  maxLines: 8,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  const _FieldCard({
    required this.label,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: controller,
              maxLines: maxLines,
              minLines: 1,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.15),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              style: const TextStyle(
                fontSize: 15,
                color: Color(0xFF5A4A52),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
