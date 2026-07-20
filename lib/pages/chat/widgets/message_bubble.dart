import 'package:flutter/material.dart';
import '../models/chat_message.dart';

/// 消息气泡
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final String? personaName;

  const MessageBubble({
    super.key,
    required this.message,
    this.personaName,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: message.isUser ? 60 : 16,
        right: message.isUser ? 16 : 60,
        top: 6,
        bottom: 2,
      ),
      child: Column(
        crossAxisAlignment:
            message.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // 头像 + 气泡
          Row(
            mainAxisAlignment:
                message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!message.isUser) ...[
                // AI头像
                _Avatar(isUser: false),
                const SizedBox(width: 8),
              ],
              // 气泡
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: message.isUser
                        ? const Color(0xFFE8A0B8).withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: message.isUser
                          ? const Radius.circular(18)
                          : Radius.zero,
                      bottomRight: message.isUser
                          ? Radius.zero
                          : const Radius.circular(18),
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (message.imageUrl != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 180,
                              height: 180,
                              color: const Color(0xFFE8A0B8).withValues(alpha: 0.05),
                              child: Center(
                                child: Icon(
                                  Icons.image_outlined,
                                  color: const Color(0xFFB48296).withValues(alpha: 0.3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Text(
                        message.text,
                        style: TextStyle(
                          fontSize: 15,
                          color: const Color(0xFF6A4A5A),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (message.isUser) ...[
                const SizedBox(width: 8),
                _Avatar(isUser: true),
              ],
            ],
          ),
          // 状态指示
          if (message.isUser && message.status != MessageStatus.sent)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 52),
              child: Text(
                message.status == MessageStatus.sending ? '发送中…' : '发送失败',
                style: TextStyle(
                  fontSize: 10,
                  color: message.status == MessageStatus.failed
                      ? const Color(0xFFE57373)
                      : const Color(0xFF5A4A52).withValues(alpha: 0.2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final bool isUser;

  const _Avatar({required this.isUser});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: isUser
              ? [
                  const Color(0xFFE8A0B8).withValues(alpha: 0.15),
                  const Color(0xFFC8A8D8).withValues(alpha: 0.15),
                ]
              : [
                  const Color(0xFFB8D4E8).withValues(alpha: 0.15),
                  const Color(0xFFE8B8C8).withValues(alpha: 0.15),
                ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Icon(
        isUser ? Icons.person_outline_rounded : Icons.auto_awesome_mosaic_outlined,
        size: 18,
        color: const Color(0xFFB48296).withValues(alpha: 0.4),
      ),
    );
  }
}
