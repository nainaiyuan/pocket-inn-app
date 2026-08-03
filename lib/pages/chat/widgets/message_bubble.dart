import 'dart:io';

import 'package:flutter/material.dart';

import '../../../models/chat_message.dart';
import '../../../models/user_setting.dart';
import '../../../services/chat_character_resolver.dart';
import '../state/chat_presence.dart';
import 'thinking_chain_widget.dart';

/// 消息气泡
class MessageBubble extends StatefulWidget {
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

  /// 连续对话分组：本消息是否在组内（组内不显示头像，气泡连一起）
  /// [isGroupStart] 组内第一条（显示头像 + 尾巴），[isGroupEnd] 组内最后一条（底角收尾）
  final bool isGrouped;
  final bool isGroupStart;
  final bool isGroupEnd;

  /// 8-03 18:2x：打字机动效（实时插入的男主消息逐字冒出；历史加载 false）
  final bool typewriting;
  final VoidCallback? onTypewriterDone;

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
    this.isGrouped = false,
    this.isGroupStart = false,
    this.isGroupEnd = false,
    this.typewriting = false,
    this.onTypewriterDone,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  /// 打字机：当前已显示的字数（-1 = 不播，直接全文）
  int _visibleChars = -1;
  AnimationController? _twController;

  @override
  void initState() {
    super.initState();
    if (widget.typewriting && widget.message.text.isNotEmpty) {
      _startTypewriter();
    }
  }

  @override
  void didUpdateWidget(MessageBubble old) {
    super.didUpdateWidget(old);
    // 同一条消息从"实时插入"变"重建"（滚动回收）：若还没播完则继续播
    if (_visibleChars == -1 &&
        widget.typewriting &&
        widget.message.text.isNotEmpty) {
      _startTypewriter();
    }
  }

  void _startTypewriter() {
    final text = widget.message.text;
    // 每字 26ms，封顶 6 秒（长文本加速），最短 350ms 保证有动效感
    final ms = (text.length * 26).clamp(350, 6000);
    _visibleChars = 0;
    _twController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    )
      ..addListener(() {
        if (!mounted) return;
        final n = (text.length * _twController!.value).ceil();
        if (n != _visibleChars) {
          setState(() => _visibleChars = n);
        }
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _visibleChars = -1;
          if (mounted) setState(() {});
          widget.onTypewriterDone?.call();
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _twController?.dispose();
    super.dispose();
  }

  String get _displayText {
    if (_visibleChars >= 0) {
      return widget.message.text.substring(0, _visibleChars);
    }
    return widget.message.text;
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    // 管家工具气泡：男主头像下的小气泡（🔧 正在查记忆…），无头像、小字
    if (message.text.startsWith('[tool]')) {
      return Padding(
        padding: const EdgeInsets.only(left: 60, right: 60, top: 3, bottom: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFC896B4).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🔧',
                      style: TextStyle(fontSize: 11, color: Color(0xFF9A6B84))),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      message.text
                          .replaceFirst('[tool] ', '')
                          .replaceFirst('[tool]', ''),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9A6B84),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(
        left: message.isMe ? 60 : 16,
        right: message.isMe ? 16 : 60,
        top: 6,
        bottom: 2,
      ),
      child: Column(
        crossAxisAlignment: message.isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // 头像 + 气泡 + 气泡框外居中的已读（8-03 18:43 用户要求）：
          // 左消息：头像＋气泡＋已读（气泡右侧，垂直居中）
          // 右消息：已读＋气泡＋头像（气泡左侧，垂直居中）
          // 8-03 19:1x（用户反馈怼穿）：Flexible 必须直接在外层 Row（内层
          // Row 包裹会破坏宽度约束 → 长文本撑穿到用户那边）；crossAxisAlignment
          // 用 center 让已读动态垂直居中于气泡框
          Row(
            mainAxisAlignment: message.isMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 分组模式：只有组内第一条才显示头像（用户没插话 = 连着说）
              if (!message.isMe && (!widget.isGrouped || widget.isGroupStart)) ...[
                _Avatar(
                  isUser: false,
                  characterAvatarPath: widget.characterAvatarPath,
                  onTap: widget.onAvatarTap,
                  onLongPress: widget.onAvatarLongPress,
                ),
                const SizedBox(width: 8),
              ],
              // 用户消息（右对齐）：已读在气泡左侧（男主那一侧）
              if (message.isMe) _ReadTag(message: message),
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
                      // 分组：组首顶角大 + 头像侧尾巴，中间小圆角，组尾底角收尾
                      // 头像在男主左侧（BL 是尾巴侧）/ 用户右侧（BR 是尾巴侧）
                      topLeft: widget.isGrouped && !widget.isGroupStart
                          ? const Radius.circular(6)
                          : const Radius.circular(18),
                      topRight: widget.isGrouped && !widget.isGroupStart
                          ? const Radius.circular(6)
                          : const Radius.circular(18),
                      bottomLeft: message.isMe
                          ? const Radius.circular(18) // 用户左侧恒 18
                          : widget.isGrouped
                          ? widget.isGroupStart
                                ? Radius
                                      .zero // 组首尾巴指向头像
                                : widget.isGroupEnd
                                ? const Radius.circular(18)
                                : const Radius.circular(6)
                          : Radius.zero,
                      bottomRight: message.isMe
                          ? widget.isGrouped
                                ? widget.isGroupStart
                                      ? Radius
                                            .zero // 组首尾巴指向头像
                                      : widget.isGroupEnd
                                      ? const Radius.circular(18)
                                      : const Radius.circular(6)
                                : Radius.zero
                          : const Radius.circular(18), // 男主右侧恒 18
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 8-03 18:43：已读/未读已移出气泡（气泡框外垂直居中，
                      // 见外层 _ReadTag），气泡内不再显示
                      // 8-03 07:01：男主的思考链（reasoning_content）——
                      // 小格式、默认折叠，用户想看再展开，和正文区分
                      if (!message.isMe &&
                          message.thinkingChain != null &&
                          message.thinkingChain!.trim().isNotEmpty) ...[
                        ThinkingChainWidget(
                          thinkingChain: message.thinkingChain!,
                          colorScheme: Theme.of(context).colorScheme,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        _displayText,
                        style: TextStyle(
                          fontSize: 15,
                          color: const Color(0xFF6A4A5A),
                          height: 1.5,
                        ),
                      ),
                      // 操作按钮（仅在 showActions 时显示）
                      if (widget.showActions) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.onCopy != null)
                              _ActionButton(
                                icon: Icons.copy_rounded,
                                onTap: widget.onCopy!,
                              ),
                            if (widget.canEdit && widget.onEdit != null)
                              _ActionButton(
                                icon: Icons.edit_rounded,
                                onTap: widget.onEdit!,
                              ),
                            if (widget.canDelete && widget.onDelete != null)
                              _ActionButton(
                                icon: Icons.delete_outline_rounded,
                                onTap: widget.onDelete!,
                              ),
                            if (message.isMe && widget.onGenerate != null)
                              _ActionButton(
                                icon: Icons.refresh_rounded,
                                onTap: widget.onGenerate!,
                              ),
                            if (!message.isMe && widget.onRegenerate != null)
                              _ActionButton(
                                icon: Icons.replay_rounded,
                                onTap: widget.onRegenerate!,
                              ),
                            if (!message.isMe && widget.onContinue != null)
                              _ActionButton(
                                icon: Icons.play_arrow_rounded,
                                onTap: widget.onContinue!,
                              ),
                            if (message.hasMultiple) ...[
                              if (widget.onSelectPreviousVariant != null)
                                _ActionButton(
                                  icon: Icons.chevron_left_rounded,
                                  onTap: widget.onSelectPreviousVariant!,
                                ),
                              if (widget.onSelectNextVariant != null)
                                _ActionButton(
                                  icon: Icons.chevron_right_rounded,
                                  onTap: widget.onSelectNextVariant!,
                                ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // 男主消息（左对齐）：已读在气泡右侧（用户那一侧）
              if (!message.isMe) _ReadTag(message: message),
              if (message.isMe && (!widget.isGrouped || widget.isGroupStart)) ...[
                const SizedBox(width: 8),
                _Avatar(isUser: true),
              ],
            ],
          ),
          // 时间戳（已读已移到气泡框外，8-03 18:43）
          _MetaLine(message: message),
        ],
      ),
    );
  }
}

/// 气泡框外、垂直居中的已读/未读小标（8-03 18:43 用户要求）：
/// - 用户消息（右对齐）：在气泡左侧（男主那一侧）
/// - 男主消息（左对齐）：在气泡右侧（用户那一侧）
class _ReadTag extends StatelessWidget {
  final ChatMessage message;

  const _ReadTag({required this.message});

  @override
  Widget build(BuildContext context) {
    final presence = ChatPresence.instance;
    final read = presence.isRead(message.id);
    if (read == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        read ? '已读' : '未读',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: read
              ? const Color(0xFF7BA88F) // 柔和绿（已读）
              : const Color(0xFFC8966A), // 柔和琥珀（未读）
        ),
      ),
    );
  }
}

/// 气泡下方的小字：时间戳（已读/未读已移到气泡顶部角，8-03 18:2x）
/// 只有记录了时间的消息才显示（旧数据没有时间戳自动隐藏）
class _MetaLine extends StatelessWidget {
  final ChatMessage message;

  const _MetaLine({required this.message});

  @override
  Widget build(BuildContext context) {
    final presence = ChatPresence.instance;
    final time = presence.timestampOf(message.id);

    // 没有时间就不显示（保持界面干净）
    if (time == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 3, right: 4, left: 4),
      child: Text(
        ChatPresence.formatTime(time),
        style: TextStyle(
          fontSize: 10,
          color: const Color(0xFF6A4A5A).withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

/// 操作小按钮
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ActionButton({required this.icon, required this.onTap});

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
    if (!isUser &&
        characterAvatarPath != null &&
        File(characterAvatarPath!).existsSync()) {
      avatarChild = ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Image.file(
          File(characterAvatarPath!),
          fit: BoxFit.cover,
          width: 34,
          height: 34,
          key: ValueKey(
            'chat_avatar_${characterAvatarPath}_${File(characterAvatarPath!).lastModifiedSync().millisecondsSinceEpoch}',
          ),
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
