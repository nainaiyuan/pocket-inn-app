import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';

/// 左滑侧边栏 —— 选择男主/形象
class ChatSidebarLeft extends StatefulWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final ValueChanged<MapEntry<MaleLead, Persona>> onSelectPersona;

  const ChatSidebarLeft({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onSelectPersona,
  });

  @override
  State<ChatSidebarLeft> createState() => _ChatSidebarLeftState();
}

class _ChatSidebarLeftState extends State<ChatSidebarLeft> {
  final _service = CharacterService();
  String? _expandedLeadId;

  @override
  void initState() {
    super.initState();
    _service.load();
    if (widget.currentLead != null) {
      _expandedLeadId = widget.currentLead!.id;
    }
  }

  void _toggleExpand(String id) {
    setState(() {
      _expandedLeadId = _expandedLeadId == id ? null : id;
    });
  }

  Future<void> _addNewLead() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: 0.85),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('新建男主'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入名字',
            border: InputBorder.none,
          ),
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
    if (name != null && name.isNotEmpty) {
      await _service.addMaleLead(MaleLead(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
      ));
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final leads = _service.leads;

    return Container(
      color: const Color(0xFFF5F0F2),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 56),

            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    '角色',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6A4A5A).withValues(alpha: 0.6),
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 角色列表
            Expanded(
              child: leads.isEmpty
                  ? Center(
                      child: Text(
                        '还没有角色，点击下方 + 新建',
                        style: TextStyle(
                          color: const Color(0xFF6A4A5A).withValues(alpha: 0.2),
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: leads.length,
                      itemBuilder: (context, index) {
                        final lead = leads[index];
                        final isExpanded = _expandedLeadId == lead.id;
                        final isActive = widget.currentLead?.id == lead.id;

                        return _LeadCard(
                          lead: lead,
                          isExpanded: isExpanded,
                          isActive: isActive,
                          currentPersona: isActive ? widget.currentPersona : null,
                          onToggle: () => _toggleExpand(lead.id),
                          onSelectPersona: (persona) {
                            widget.onSelectPersona(MapEntry(lead, persona));
                          },
                        );
                      },
                    ),
            ),

            // 底部新建按钮
            Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                8,
                12,
                MediaQuery.of(context).padding.bottom + 16,
              ),
              child: SizedBox(
                width: double.infinity,
                child: Material(
                  color: Colors.white.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _addNewLead,
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
                            '新建男主',
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
      ),
    );
  }
}

/// 单个男主卡片（可展开）
class _LeadCard extends StatelessWidget {
  final MaleLead lead;
  final bool isExpanded;
  final bool isActive;
  final Persona? currentPersona;
  final VoidCallback onToggle;
  final ValueChanged<Persona> onSelectPersona;

  const _LeadCard({
    required this.lead,
    required this.isExpanded,
    required this.isActive,
    required this.currentPersona,
    required this.onToggle,
    required this.onSelectPersona,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: isActive ? 0.5 : 0.3),
        borderRadius: BorderRadius.circular(18),
        border: isActive
            ? Border.all(
                color: const Color(0xFFE8A0B8).withValues(alpha: 0.2),
              )
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 收起状态：立绘+姓名+语录+当前身份
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // 立绘占位
                  Container(
                    width: 56,
                    height: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFE8A0B8).withValues(alpha: 0.15),
                          const Color(0xFFC8A8D8).withValues(alpha: 0.15),
                        ],
                      ),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.person_outline_rounded,
                        size: 28,
                        color: const Color(0xFFB48296).withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // 文字信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lead.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF6A4A5A),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '"你好，我是${lead.name}"',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF5A4A52).withValues(alpha: 0.25),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        if (currentPersona != null && isActive) ...[
                          const SizedBox(height: 2),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8A0B8).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '当前：${currentPersona!.name}',
                              style: TextStyle(
                                fontSize: 11,
                                color: const Color(0xFFB48296).withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // 展开箭头
                  Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.2),
                  ),
                ],
              ),
            ),
          ),

          // 展开状态：形象列表
          if (isExpanded) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  ...lead.personas.map((persona) => _PersonaTile(
                        persona: persona,
                        isActive: isActive && currentPersona?.id == persona.id,
                        onTap: () => onSelectPersona(persona),
                      )),
                  // 新建形象按钮
                  _AddPersonaTile(leadId: lead.id),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 形象选择行
class _PersonaTile extends StatelessWidget {
  final Persona persona;
  final bool isActive;
  final VoidCallback onTap;

  const _PersonaTile({
    required this.persona,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isActive
            ? const Color(0xFFE8A0B8).withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? const Color(0xFFE8A0B8).withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.3),
                    border: isActive
                        ? Border.all(
                            color: const Color(0xFFE8A0B8).withValues(alpha: 0.4),
                            width: 1.5,
                          )
                        : Border.all(
                            color: Colors.white.withValues(alpha: 0.3),
                          ),
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: const Color(0xFFE8A0B8).withValues(alpha: 0.15),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    Icons.face_6_outlined,
                    size: 16,
                    color: isActive
                        ? const Color(0xFFB48296)
                        : const Color(0xFFB48296).withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  persona.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                    color: isActive
                        ? const Color(0xFF6A4A5A)
                        : const Color(0xFF6A4A5A).withValues(alpha: 0.6),
                  ),
                ),
                if (isActive) ...[
                  const Spacer(),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFE8A0B8),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 新建形象按钮
class _AddPersonaTile extends StatefulWidget {
  final String leadId;
  const _AddPersonaTile({required this.leadId});

  @override
  State<_AddPersonaTile> createState() => _AddPersonaTileState();
}

class _AddPersonaTileState extends State<_AddPersonaTile> {
  final _service = CharacterService();

  Future<void> _addPersona() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: 0.85),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('新建形象'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '如：校园版',
            border: InputBorder.none,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _service.addPersona(widget.leadId, Persona(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        maleLeadId: widget.leadId,
        name: name,
      ));
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _addPersona,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE8A0B8).withValues(alpha: 0.08),
                    border: Border.all(
                      color: const Color(0xFFE8A0B8).withValues(alpha: 0.15),
                    ),
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    size: 18,
                    color: const Color(0xFFB48296).withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '新建身份',
                  style: TextStyle(
                    fontSize: 14,
                    color: const Color(0xFFB48296).withValues(alpha: 0.5),
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
