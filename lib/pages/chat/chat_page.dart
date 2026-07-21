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

/// 聊天主页面 —— 三页独立模块
///
/// 左/中/右三个独立 Widget，不互相嵌套。
/// 中间页通过 AnimatedPositioned 左右移动来露/藏两侧页。
/// 屏幕最上层有一个 Listener 做水平滑动侦测（只读，不消费事件）。
///
/// 三态切换：
///   中间页 → 右滑 → 左页展开（中间页右移露出左页）
///   中间页 → 左滑 → 右页展开（中间页左移露出右页）
///   左页展开 → 左滑 → 回中间
///   右页展开 → 右滑 → 回中间
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

  // Listener 手势缓存
  double _downX = 0, _downY = 0;
  bool _moveHappened = false;

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

  // ========== Listener 水平滑动手势（不消费事件，不影响 ListView） ==========

  void _onPointerDown(PointerDownEvent e) {
    _downX = e.position.dx;
    _downY = e.position.dy;
    _moveHappened = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_showPlus) return;
    final dx = e.position.dx - _downX;
    final dy = e.position.dy - _downY;

    if (!_moveHappened) {
      if (dx.abs() < 6 && dy.abs() < 6) return;
      _moveHappened = true;

      // 判定是否为水平滑动
      if (dy.abs() > dx.abs() * 2) return; // 垂直为主，跳过

      if (_state == _center) {
        // 中间：右滑 → 左页，左滑 → 右页
        if (dx > 0) _goLeft();
        else _goRight();
      } else if (_state == _left && dx < -20) {
        // 左页展开且左滑 → 收回
        _goCenter();
      } else if (_state == _right && dx > 20) {
        // 右页展开且右滑 → 收回
        _goCenter();
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {}

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final sw = w * _sideFrac;
    final off = _midOff;
    final leftShown = _state == _left;
    final rightShown = _state == _right;

    return Stack(
      children: [
        // ===== 左页 =====
        // IgnorePointer: 完全展开时才可交互
        Positioned(left: 0, top: 0, width: sw, height: double.infinity,
          child: Container(color: const Color(0xFFEED9DC),
            child: IgnorePointer(ignoring: !leftShown || _anim.value < 0.95,
              child: ChatSidebarLeft(
                currentLead: _lead, currentPersona: _persona,
                onSelectPersona: (entry) => _selectPersona(entry.key, entry.value),
              ),
            ),
          ),
        ),

        // ===== 中间页（可移动） =====
        Positioned(
          left: off, top: 0, right: -off, bottom: 0,
          child: Material(
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
        ),

        // ===== 右页 =====
        Positioned(right: 0, top: 0, width: sw, height: double.infinity,
          child: Container(color: const Color(0xFFDCE4EE),
            child: IgnorePointer(ignoring: !rightShown || _anim.value < 0.95,
              child: const ChatSidebarRight(),
            ),
          ),
        ),

        // ===== 全屏 Listener（只读，不消费事件） =====
        Positioned.fill(
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
          ),
        ),

        // ===== [+] 菜单 =====
        if (_showPlus)
          Positioned.fill(child: PlusMenu(onDismiss: () => setState(() => _showPlus = false))),
      ],
    );
  }
}
