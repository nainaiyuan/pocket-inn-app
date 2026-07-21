import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';

/// 聊天页顶部栏 —— 无头像，角色名居中，长按可改名
class ChatTopBar extends StatelessWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final VoidCallback onTapAvatar;
  final VoidCallback onMenuTap;

  const ChatTopBar({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onTapAvatar,
    required this.onMenuTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = currentLead?.name ?? '沈星回';
    final personaName = currentPersona?.name ?? '';

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
          const SizedBox(width: 40), // 左侧留白平衡
          Expanded(
            child: GestureDetector(
              onTap: onTapAvatar,   // 点击 → 秘密基地
              onLongPress: () => _renameLead(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6A4A5A),
                      letterSpacing: 1,
                    ),
                  ),
                  if (personaName.isNotEmpty)
                    Text(
                      '与 $personaName 聊天中',
                      style: TextStyle(
                        fontSize: 11,
                        color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                        letterSpacing: 0.5,
                      ),
                    ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: onMenuTap,
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
    final lead = currentLead;
    if (lead == null) return;
    final ctrl = TextEditingController(text: lead.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('修改角色名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新名字', border: InputBorder.none),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty) {
                lead.name = newName;
                CharacterService().updateMaleLead(lead);
              }
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
