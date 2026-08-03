import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../models/chat_message.dart';
import '../services/chat_storage_service.dart';
import '../state/chat_presence.dart';
import 'message_bubble.dart';

/// 消息区域 —— 渲染消息列表 + 加载历史 + 多选删除
class ChatMessageArea extends StatefulWidget {
  final Persona? currentPersona;
  final String? characterAvatarPath;
  final VoidCallback? onAvatarTap;

  const ChatMessageArea({
    super.key,
    required this.currentPersona,
    this.characterAvatarPath,
    this.onAvatarTap,
  });

  @override
  State<ChatMessageArea> createState() => ChatMessageAreaState();
}

class ChatMessageAreaState extends State<ChatMessageArea> {
  final _storage = ChatStorageService();
  final _scrollCtrl = ScrollController();

  List<ChatMessage> _messages = [];
  bool _loading = true;

  /// 当前消息列表（管家记忆提取用）
  List<ChatMessage> get messages => List.unmodifiable(_messages);

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
      // 切换角色：清掉"正在输入"状态
      ChatPresence.instance.setTyping(false);
      _loadMessages();
    }
  }

  /// 外部调用：重新加载消息（清空聊天记录后刷新）
  Future<void> reloadMessages() async {
    await _loadMessages();
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
      // 历史加载不播打字机（清空实时插入标记）
      _typewritingIds.clear();
      // 历史男主消息默认已读（用户在看历史 = 已读）
      ChatPresence.instance.markAllCharacterRead();
      _scrollToBottom();
    }
  }

  /// 追加消息
  /// [insertBeforeId] 不为空时插到该消息之前（工具气泡挂男主第一句话头上）
  void appendMessage(ChatMessage msg, {String? insertBeforeId}) {
    if (widget.currentPersona == null) return;
    // 实时插入的男主消息 → 打字机动效 + 未读（历史加载不播）
    if (!msg.isMe && !msg.text.startsWith('[tool]')) {
      _typewritingIds.add(msg.id ?? '');
      if (msg.id != null) ChatPresence.instance.markCharacterUnread(msg.id!);
    }
    setState(() {
      if (insertBeforeId != null) {
        final idx = _messages.indexWhere((m) => m.id == insertBeforeId);
        if (idx >= 0) {
          _messages.insert(idx, msg);
        } else {
          _messages.add(msg);
        }
      } else {
        _messages.add(msg);
      }
    });
    if (insertBeforeId != null) {
      _storage.insertMessageBefore(
        widget.currentPersona!.id,
        msg,
        insertBeforeId,
        seq: _toolInsertSeq++,
      );
    } else {
      _storage.appendMessage(widget.currentPersona!.id, msg);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// 实时插入的男主消息 id（打字机动画用，历史加载不播）
  final Set<String> _typewritingIds = {};

  /// 工具气泡插入序号（决定与目标消息的时间差，保持重载顺序稳定）
  int _toolInsertSeq = 0;

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

  /// 进入多选模式并选中指定消息
  void _enterSelectMode(String messageId) {
    if (!_selecting) {
      setState(() {
        _selecting = true;
        _selectedIds.add(messageId);
      });
    }
  }

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
                          characterAvatarPath: widget.characterAvatarPath,
                          onAvatarTap: widget.onAvatarTap,
                          onAvatarLongPress: () => _enterSelectMode(msg.id ?? ''),
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
                          // 8-03 18:2x：实时插入的男主消息播打字机动效；
                          // 播完 = 用户看完 = 标记已读（并从集合移除，滚动回收不重播）
                          typewriting: _typewritingIds.contains(msg.id ?? ''),
                          onTypewriterDone: () {
                            _typewritingIds.remove(msg.id ?? '');
                            if (msg.id != null) {
                              ChatPresence.instance.markRead(msg.id!);
                            }
                            // 打字机播完：气泡长定型，滚到底让全文可见
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              if (mounted) _scrollToBottom();
                            });
                          },
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
