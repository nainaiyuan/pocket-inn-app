import 'dart:io';

import 'package:flutter/material.dart';

import '../../../models/chat_message.dart';
import '../../../models/user_setting.dart';
import '../../../services/chat_character_resolver.dart';

/// 消息气泡
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final UserSetting? userSetting;
  final ResolvedChatCharacter? character;
  final Object inputTapRegionGroupId;
  final bool isLastUserMessageWithoutReply;
  final bool isLastCharacterMessage;
  final bool showActions;
  final bool canEdit;
  final bool canDelete;
  final bool isBusyRegenerating;
  final bool isBusyImpersonating;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onGenerate;
  final VoidCallback? onRegenerate;
  final VoidCallback? onContinue;
  final VoidCallback? onImpersonate;
  final VoidCallback? onSelectPreviousVariant;
  final VoidCallback? onSelectNextVariant;
  final String? characterAvatarPath;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onAvatarLongPress;

  const MessageBubble({
    super.key,
    required this.message,
    this.userSetting,
    this.character,
    required this.inputTapRegionGroupId,
    this.isLastUserMessageWithoutReply = false,
    this.isLastCharacterMessage = false,
    this.showActions = false,
    this.canEdit = false,
    this.canDelete = false,
    this.isBusyRegenerating = false,
    this.isBusyImpersonating = false,
    this.onCopy,
    this.onEdit,
    this.onDelete,
    this.onGenerate,
    this.onRegenerate,
    this.onContinue,
    this.onImpersonate,
    this.onSelectPreviousVariant,
    this.onSelectNextVariant,
    this.characterAvatarPath,
    this.onAvatarTap,
    this.onAvatarLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: message.isMe ? 60 : 16,
        right: message.isMe ? 16 : 60,
        top: 6,
        bottom: 2,
      ),
      child: Column(
        crossAxisAlignment:
            message.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // 头像 + 气泡
          Row(
            mainAxisAlignment:
                message.isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!message.isMe) ...[
                _Avatar(
                  isUser: false,
                  characterAvatarPath: characterAvatarPath,
                  onTap: onAvatarTap,
                  onLongPress: onAvatarLongPress,
                ),
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
                    color: message.isMe
                        ? const Color(0xFFE8A0B8).withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: message.isMe
                          ? const Radius.circular(18)
                          : Radius.zero,
                      bottomRight: message.isMe
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
                      Text(
                        message.text,
                        style: TextStyle(
                          fontSize: 15,
                          color: const Color(0xFF6A4A5A),
                          height: 1.5,
                        ),
                      ),
                      // 操作按钮（仅在 showActions 时显示）
                      if (showActions) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (onCopy != null)
                              _ActionButton(
                                icon: Icons.copy_rounded,
                                onTap: onCopy!,
                              ),
                            if (canEdit && onEdit != null)
                              _ActionButton(
                                icon: Icons.edit_rounded,
                                onTap: onEdit!,
                              ),
                            if (canDelete && onDelete != null)
                              _ActionButton(
                                icon: Icons.delete_outline_rounded,
                                onTap: onDelete!,
                              ),
                            if (message.isMe && onGenerate != null)
                              _ActionButton(
                                icon: Icons.refresh_rounded,
                                onTap: onGenerate!,
                              ),
                            if (!message.isMe && onRegenerate != null)
                              _ActionButton(
                                icon: Icons.replay_rounded,
                                onTap: onRegenerate!,
                              ),
                            if (!message.isMe && onContinue != null)
                              _ActionButton(
                                icon: Icons.play_arrow_rounded,
                                onTap: onContinue!,
                              ),
                            if (message.hasMultiple) ...[
                              if (onSelectPreviousVariant != null)
                                _ActionButton(
                                  icon: Icons.chevron_left_rounded,
                                  onTap: onSelectPreviousVariant!,
                                ),
                              if (onSelectNextVariant != null)
                                _ActionButton(
                                  icon: Icons.chevron_right_rounded,
                                  onTap: onSelectNextVariant!,
                                ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (message.isMe) ...[
                const SizedBox(width: 8),
                _Avatar(isUser: true),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 操作小按钮
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              icon,
              size: 16,
              color: const Color(0xFFB48296).withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final bool isUser;
  final String? characterAvatarPath;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _Avatar({
    required this.isUser,
    this.characterAvatarPath,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    Widget avatarChild;
    if (!isUser && characterAvatarPath != null && File(characterAvatarPath!).existsSync()) {
      avatarChild = ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Image.file(
          File(characterAvatarPath!),
          fit: BoxFit.cover,
          width: 34,
          height: 34,
        ),
      );
    } else {
      avatarChild = Icon(
        isUser
            ? Icons.person_outline_rounded
            : Icons.auto_awesome_mosaic_outlined,
        size: 18,
        color: const Color(0xFFB48296).withValues(alpha: 0.4),
      );
    }

    final avatarWidget = Container(
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
      child: avatarChild,
    );

    // 只有男主头像才包 GestureDetector，用户头像不处理
    if (!isUser && (onTap != null || onLongPress != null)) {
      return GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: avatarWidget,
      );
    }
    return avatarWidget;
  }
}
