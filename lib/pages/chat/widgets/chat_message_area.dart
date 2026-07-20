import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../models/chat_message.dart';
import '../services/chat_storage_service.dart';
import 'message_bubble.dart';

/// 消息区域 —— 渲染消息列表 + 加载历史
class ChatMessageArea extends StatefulWidget {
  final Persona? currentPersona;

  const ChatMessageArea({
    super.key,
    required this.currentPersona,
  });

  @override
  State<ChatMessageArea> createState() => ChatMessageAreaState();
}

class ChatMessageAreaState extends State<ChatMessageArea> {
  final _storage = ChatStorageService();
  final _scrollCtrl = ScrollController();

  List<ChatMessage> _messages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  @override
  void didUpdateWidget(ChatMessageArea old) {
    super.didUpdateWidget(old);
    if (old.currentPersona?.id != widget.currentPersona?.id) {
      _loadMessages();
    }
  }

  Future<void> _loadMessages() async {
    if (widget.currentPersona == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final msgs = await _storage.loadMessages(widget.currentPersona!.id);
    if (mounted) {
      setState(() {
        _messages = msgs;
        _loading = false;
      });
      _scrollToBottom();
    }
  }

    /// 追加消息（外部通过 GlobalKey 调用）
  void appendMessage(ChatMessage msg) {
    if (widget.currentPersona == null) return;
    setState(() => _messages.add(msg));
    _storage.appendMessage(widget.currentPersona!.id, msg);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.currentPersona == null) {
      return _buildEmpty('选择一个角色开始聊天');
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_messages.isEmpty) {
      return _buildEmpty('开始和 ${widget.currentPersona!.name} 聊天吧');
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        return MessageBubble(
          message: _messages[index],
          userSetting: null,
          character: null,
          inputTapRegionGroupId: const Object(),
          isLastUserMessageWithoutReply:
              index == _messages.length - 1 && _messages[index].isMe,
          isLastCharacterMessage:
              index == _messages.length - 1 && !_messages[index].isMe,
          showActions: false,
          canEdit: false,
          canDelete: false,
          isBusyRegenerating: false,
          isBusyImpersonating: false,
        );
      },
    );
  }

  Widget _buildEmpty(String text) {
    return Center(
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
            text,
            style: TextStyle(
              fontSize: 14,
              color: const Color(0xFF5A4A52).withValues(alpha: 0.25),
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}
