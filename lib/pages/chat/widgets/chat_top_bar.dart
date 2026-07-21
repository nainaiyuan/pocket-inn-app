import 'dart:io';
import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';

/// 聊天页顶部栏
class ChatTopBar extends StatelessWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final VoidCallback onAvatarLongPress;
  final VoidCallback onMenuTap;

  const ChatTopBar({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onAvatarLongPress,
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
          // 男主头像（长按进秘密基地）
          GestureDetector(
            onLongPress: onAvatarLongPress,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFFE8A0B8).withValues(alpha: 0.2),
                    const Color(0xFFC8A8D8).withValues(alpha: 0.2),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.5),
                  width: 1.5,
                ),
                image: (currentLead?.avatarPath.isNotEmpty == true)
                    ? DecorationImage(
                        image: FileImage(File(currentLead!.avatarPath)),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: (currentLead?.avatarPath.isNotEmpty != true)
                  ? Icon(
                      Icons.person_outline_rounded,
                      size: 22,
                      color: const Color(0xFFB48296).withValues(alpha: 0.6),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 12),

          // 名字 + 当前形象
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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

          // 更多按钮
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
}
