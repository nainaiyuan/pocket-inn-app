import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';

/// 消息区域
class ChatMessageArea extends StatelessWidget {
  final Persona? currentPersona;

  const ChatMessageArea({
    super.key,
    required this.currentPersona,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 40,
              color: const Color(0xFFB48296).withValues(alpha: 0.2),
            ),
            const SizedBox(height: 12),
            Text(
              '开始和 ${currentPersona?.name ?? "TA"} 聊天吧',
              style: TextStyle(
                fontSize: 14,
                color: const Color(0xFF5A4A52).withValues(alpha: 0.25),
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
