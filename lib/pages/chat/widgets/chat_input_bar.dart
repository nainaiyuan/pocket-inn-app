import 'package:flutter/material.dart';

/// 底部输入栏
///
/// [📷] [输入框] [🎤] [+]
class ChatInputBar extends StatefulWidget {
  final VoidCallback onCameraTap;
  final VoidCallback onVoiceTap;
  final VoidCallback onPlusTap;
  final ValueChanged<String> onSendTap;

  /// 8-08 15:1x：外部传入的输入框 controller（插话按钮要读输入框内容，
  /// 支持"打字→点插话=直接发出去"）。null 时内部自建。
  final TextEditingController? externalCtrl;

  const ChatInputBar({
    super.key,
    required this.onCameraTap,
    required this.onVoiceTap,
    required this.onPlusTap,
    required this.onSendTap,
    this.externalCtrl,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  late final TextEditingController _ctrl =
      widget.externalCtrl ?? TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final has = _ctrl.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    // 外部传入的 controller 由外部（chat_page）负责 dispose
    if (widget.externalCtrl == null) _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    widget.onSendTap(text);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: const Color(0xFF5A4A52).withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 📷 拍照
          _IconButton(
            icon: Icons.camera_alt_outlined,
            onTap: widget.onCameraTap,
          ),
          const SizedBox(width: 8),

          // 输入框
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 100),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      maxLines: null,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: '输入文字…',
                        hintStyle: TextStyle(
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.15),
                          fontSize: 15,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                        isDense: true,
                      ),
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF5A4A52),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),

          // 🎤 语音 / 发送
          if (_hasText)
            _IconButton(
              icon: Icons.send_rounded,
              color: const Color(0xFFE8A0B8),
              onTap: _send,
            )
          else
            _IconButton(
              icon: Icons.keyboard_voice_rounded,
              onTap: widget.onVoiceTap,
            ),

          const SizedBox(width: 2),

          // [+] 更多
          _IconButton(
            icon: Icons.add_circle_outline_rounded,
            size: 26,
            onTap: widget.onPlusTap,
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  final VoidCallback onTap;

  const _IconButton({
    required this.icon,
    this.size = 22,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          icon,
          size: size,
          color: color ?? const Color(0xFFB48296).withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
