import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';

/// 聊天页顶部栏 —— 角色名居中，点击进秘密基地，长按改名
class ChatTopBar extends StatefulWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final VoidCallback onTapAvatar;
  final VoidCallback onMenuTap;
  final VoidCallback? onNameChanged; // 改名后通知上层刷新

  const ChatTopBar({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onTapAvatar,
    required this.onMenuTap,
    this.onNameChanged,
  });

  @override
  State<ChatTopBar> createState() => _ChatTopBarState();
}

class _ChatTopBarState extends State<ChatTopBar> {
  late String _displayName;

  @override
  void initState() {
    super.initState();
    _displayName = _resolveDisplayName();
  }

  @override
  void didUpdateWidget(ChatTopBar old) {
    super.didUpdateWidget(old);
    final newName = _resolveDisplayName();
    if (_displayName != newName) {
      _displayName = newName;
    }
  }

  String _resolveDisplayName() {
    // 优先显示当前 Persona 的名字
    if (widget.currentPersona != null && widget.currentPersona!.name.isNotEmpty) {
      return widget.currentPersona!.name;
    }
    return widget.currentLead?.name ?? '沈星回';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        8,
        MediaQuery.of(context).padding.top + 4,
        8,
        8,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0xFF5A4A52).withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: GestureDetector(
              onTap: widget.onTapAvatar,
              onLongPress: () => _renameLead(context),
              child: Center(
                child: Text(
                  _displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6A4A5A),
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: widget.onMenuTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.more_horiz_rounded,
                color: const Color(0xFF6A4A5A).withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _renameLead(BuildContext context) {
    HapticFeedback.mediumImpact();
    final persona = widget.currentPersona;
    final lead = widget.currentLead;
    if (persona == null && lead == null) return;
    final ctrl = TextEditingController(text: _displayName);
    final isPersona = persona != null && persona.id != '${lead!.id}_default';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(isPersona ? '修改角色名' : '修改默认角色名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新名字', border: InputBorder.none),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty) {
                if (isPersona) {
                  persona!.name = newName;
                  CharacterService().updatePersona(lead!.id, persona);
                } else if (lead != null) {
                  lead.name = newName;
                  CharacterService().updateMaleLead(lead);
                }
                setState(() => _displayName = newName);
                widget.onNameChanged?.call();
              }
              Navigator.pop(ctx);
            },
            child: const Text('确定', style: TextStyle(color: Color(0xFFE8A0B8), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
