import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../models/chat_message.dart';
import '../services/chat_storage_service.dart';
import 'message_bubble.dart';

/// 消息区域 —— 渲染消息列表 + 加载历史 + 多选删除
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

  // 多选模式
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  @override
  void didUpdateWidget(ChatMessageArea old) {
    super.didUpdateWidget(old);
    if (old.currentPersona?.id != widget.currentPersona?.id) {
      _exitSelectMode();
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

  /// 追加消息
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

  // ─── 多选模式 ───

  void _exitSelectMode() {
    if (_selecting) {
      setState(() {
        _selecting = false;
        _selectedIds.clear();
      });
    }
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selecting = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('删除 ${_selectedIds.length} 条消息？'),
        content: const Text('此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE55050), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      if (widget.currentPersona == null) return;
      await _storage.deleteMessages(widget.currentPersona!.id, _selectedIds.toList());
      setState(() {
        _messages.removeWhere((m) => _selectedIds.contains(m.id));
        _selecting = false;
        _selectedIds.clear();
      });
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

    return Column(
      children: [
        // 多选模式顶部操作栏
        if (_selecting)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFE8EC),
              border: Border(
                bottom: BorderSide(color: const Color(0xFFE8A0B8).withValues(alpha: 0.2)),
              ),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _exitSelectMode,
                  child: Icon(Icons.close_rounded, size: 20, color: const Color(0xFF6A4A5A)),
                ),
                const SizedBox(width: 10),
                Text(
                  '已选 ${_selectedIds.length} 条',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF3D2C33)),
                ),
                const Spacer(),
                Material(
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _deleteSelected,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
                          const SizedBox(width: 4),
                          Text('删除', style: TextStyle(fontSize: 13, color: Colors.redAccent)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              final mid = msg.id ?? '';
              final selected = _selectedIds.contains(mid);
              return GestureDetector(
                onLongPress: () {
                  if (!_selecting) {
                    setState(() {
                      _selecting = true;
                      _selectedIds.add(mid);
                    });
                  }
                },
                onTap: _selecting ? () => _toggleSelect(mid) : null,
                child: Container(
                  color: selected
                      ? const Color(0xFFFFE8EC).withValues(alpha: 0.4)
                      : Colors.transparent,
                  child: Row(
                    children: [
                      // 多选勾选框
                      if (_selecting)
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: GestureDetector(
                            onTap: () => _toggleSelect(mid),
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selected
                                    ? const Color(0xFFE8A0B8)
                                    : Colors.white.withValues(alpha: 0.5),
                                border: Border.all(
                                  color: selected
                                      ? const Color(0xFFE8A0B8)
                                      : const Color(0xFF8A7A80).withValues(alpha: 0.3),
                                ),
                              ),
                              child: selected
                                  ? Icon(Icons.check_rounded, size: 14, color: Colors.white)
                                  : null,
                            ),
                          ),
                        ),
                      Expanded(
                        child: MessageBubble(
                          message: msg,
                          userSetting: null,
                          character: null,
                          inputTapRegionGroupId: const Object(),
                          isLastUserMessageWithoutReply:
                              index == _messages.length - 1 && msg.isMe,
                          isLastCharacterMessage:
                              index == _messages.length - 1 && !msg.isMe,
                          showActions: false,
                          canEdit: false,
                          canDelete: false,
                          isBusyRegenerating: false,
                          isBusyImpersonating: false,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
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
