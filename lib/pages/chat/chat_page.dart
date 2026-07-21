import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/male_lead.dart';
import '../../services/character_service.dart';
import '../../models/chat_message.dart';
import 'services/ai_chat_service.dart';
import 'widgets/chat_sidebar_left.dart';
import 'widgets/chat_sidebar_right.dart';
import 'widgets/chat_top_bar.dart';
import 'widgets/chat_message_area.dart';
import 'widgets/chat_input_bar.dart';
import 'widgets/plus_menu.dart';
import 'widgets/character_world_page.dart';

/// 聊天主页面 —— 三页独立模块 + 边缘手势
///
/// 中间页全屏时，左右各 40px 边缘可左右滑切换。
/// 中间区域（聊天内容）正常上下滚动，不受干扰。
///
/// 左页展开时：
///   - 左页(65%)：左页内容正常交互
///   - 右侧(35%)：只认左滑收回，不响应其他手势
/// 右页展开时对称。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  static const int _center = 0, _left = 1, _right = 2;
  int _state = _center;
  late AnimationController _anim;

  final _charSvc = CharacterService();
  final _aiSvc = AiChatService();
  MaleLead? _lead;
  Persona? _persona;
  bool _showPlus = false;
  final GlobalKey<ChatMessageAreaState> _msgKey = GlobalKey();

  static const double _sideFrac = 0.65;
  static const double _edgeSize = 40.0; // 边缘手势触发宽度
  static const double _speedThreshold = 250.0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() { if (mounted) setState(() {}); });
    _load();
  }

  Future<void> _load() async {
    try { await _charSvc.load(); } catch (_) {}
    if (!mounted) return;
    final ls = _charSvc.leads;
    if (ls.isNotEmpty) {
      setState(() { _lead = ls.first; _persona = ls.first.personas.isNotEmpty ? ls.first.personas.first : null; });
    } else {
      await _charSvc.addMaleLead(MaleLead(id: 'd', name: '沈星回'));
      if (!mounted) return;
      await _charSvc.load();
      if (_charSvc.leads.isNotEmpty && mounted)
        setState(() { _lead = _charSvc.leads.first; _persona = _charSvc.leads.first.personas.isNotEmpty ? _charSvc.leads.first.personas.first : null; });
    }
  }

  double get _midOff {
    final sw = MediaQuery.of(context).size.width * _sideFrac;
    if (_state == _left) return sw * _anim.value;
    if (_state == _right) return -sw * _anim.value;
    return 0;
  }

  void _goLeft() { if (_state == _left) return; setState(() { _state = _left; _showPlus = false; }); _anim.forward(from: 0); HapticFeedback.mediumImpact(); }
  void _goRight() { if (_state == _right) return; setState(() { _state = _right; _showPlus = false; }); _anim.forward(from: 0); HapticFeedback.mediumImpact(); }
  void _goCenter() { if (_state == _center) return; _anim.reverse().then((_) { if (mounted) setState(() => _state = _center); }); }

  void _togglePlus() { if (_state != _center) { _goCenter(); return; } setState(() => _showPlus = !_showPlus); }
  void _selectPersona(MaleLead l, Persona p) { setState(() { _lead = l; _persona = p; }); _goCenter(); HapticFeedback.lightImpact(); }

  Future<void> _sendMsg(String t) async {
    _msgKey.currentState?.appendMessage(ChatMessage(id: DateTime.now().millisecondsSinceEpoch.toString(), text: t, isMe: true));
    final r = await _aiSvc.generateReply(t, _persona?.id ?? 'd');
    _msgKey.currentState?.appendMessage(ChatMessage(id: '${DateTime.now().millisecondsSinceEpoch}_ai', text: r, isMe: false));
  }

  void _openWorld() {
    if (_lead == null || _persona == null) return;
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => CharacterWorldPage(lead: _lead!, persona: _persona!),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      transitionDuration: const Duration(milliseconds: 300),
    ));
  }

  @override
  void dispose() { _anim.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sideFrac;
    final off = _midOff;
    final leftShown = _state == _left;
    final rightShown = _state == _right;

    return Stack(
      children: [
        // ===== 左页 =====
        Positioned(left: 0, top: 0, width: sideW, height: double.infinity,
          child: Container(color: const Color(0xFFEED9DC),
            child: IgnorePointer(ignoring: !leftShown || _anim.value < 0.95,
              child: ChatSidebarLeft(
                currentLead: _lead, currentPersona: _persona,
                onSelectPersona: (entry) => _selectPersona(entry.key, entry.value),
              ),
            ),
          ),
        ),

        // ===== 中间页 =====
        Positioned(
          left: off, top: 0, right: -off, bottom: 0,
          child: Stack(
            children: [
              // 中间页内容
              Material(
                color: const Color(0xFFF5EEF0),
                child: SafeArea(
                  child: Column(children: [
                    ChatTopBar(currentLead: _lead, currentPersona: _persona,
                      onAvatarTap: _openWorld, onMenuTap: _goLeft),
                    Expanded(child: ChatMessageArea(key: _msgKey, currentPersona: _persona)),
                    ChatInputBar(onCameraTap: () {}, onVoiceTap: () {},
                      onPlusTap: _togglePlus, onSendTap: _sendMsg),
                  ]),
                ),
              ),

              // ===== 左边缘手势区（40px）=====
              // center 状态：右滑 → 左页展开
              Positioned(left: 0, top: 0, bottom: 0, width: _edgeSize,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (d) {
                    if (_showPlus) return;
                    if (d.primaryVelocity == null) return;
                    if (_state == _center && d.primaryVelocity! > _speedThreshold) _goLeft();
                  },
                ),
              ),

              // ===== 右边缘手势区（40px）=====
              // center 状态：左滑 → 右页展开
              Positioned(right: 0, top: 0, bottom: 0, width: _edgeSize,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (d) {
                    if (_showPlus) return;
                    if (d.primaryVelocity == null) return;
                    if (_state == _center && d.primaryVelocity! < -_speedThreshold) _goRight();
                  },
                ),
              ),

              // ===== 左页展开时：整个中间页露出区域用来左滑收回 =====
              if (_state == _left)
                Positioned(left: _edgeSize, top: 0, right: 0, bottom: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: (d) {
                      if (d.primaryVelocity != null && d.primaryVelocity! < -_speedThreshold) _goCenter();
                    },
                  ),
                ),

              // ===== 右页展开时：整个中间页露出区域用来右滑收回 =====
              if (_state == _right)
                Positioned(left: 0, top: 0, right: _edgeSize, bottom: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: (d) {
                      if (d.primaryVelocity != null && d.primaryVelocity! > _speedThreshold) _goCenter();
                    },
                  ),
                ),
            ],
          ),
        ),

        // ===== 右页 =====
        Positioned(right: 0, top: 0, width: sideW, height: double.infinity,
          child: Container(color: const Color(0xFFDCE4EE),
            child: IgnorePointer(ignoring: !rightShown || _anim.value < 0.95,
              child: const ChatSidebarRight(),
            ),
          ),
        ),

        // ===== [+] 菜单 =====
        if (_showPlus)
          Positioned.fill(child: PlusMenu(onDismiss: () => setState(() => _showPlus = false))),
      ],
    );
  }
}
