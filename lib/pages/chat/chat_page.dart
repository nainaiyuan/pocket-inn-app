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

/// 聊天主页面 —— 三页一起动的侧栏
///
/// 像一张纸折两下，左中右三页永远连在一起。
/// 中间页全屏时，全屏右滑三页整体右移露出左页，左滑整体左移露出右页。
/// 用角度判定区分水平和垂直手势：水平角度走侧栏，垂直角度透给 ListView。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  final _characterService = CharacterService();
  final _aiService = AiChatService();

  MaleLead? _currentLead;
  Persona? _currentPersona;
  final GlobalKey<ChatMessageAreaState> _msgKey = GlobalKey();

  bool _showPlusMenu = false;

  // 侧栏状态
  bool _showLeft = false;
  bool _showRight = false;
  late AnimationController _slideCtrl;

  static const double _sidebarFraction = 0.65;

  // 拖动状态
  bool _isDragging = false;
  double _dragOffset = 0;
  double _dragDeltaX = 0;
  double _dragDeltaY = 0;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _initCharacter();
  }

  Future<void> _initCharacter() async {
    try {
      await _characterService.load();
    } catch (_) {}
    if (!mounted) return;
    final leads = _characterService.leads;
    if (leads.isNotEmpty) {
      setState(() {
        _currentLead = leads.first;
        _currentPersona = leads.first.personas.isNotEmpty
            ? leads.first.personas.first
            : null;
      });
    } else {
      await _characterService.addMaleLead(MaleLead(
        id: 'default',
        name: '沈星回',
      ));
      if (!mounted) return;
      await _characterService.load();
      if (_characterService.leads.isNotEmpty && mounted) {
        setState(() {
          _currentLead = _characterService.leads.first;
          _currentPersona = _characterService.leads.first.personas.isNotEmpty
              ? _characterService.leads.first.personas.first
              : null;
        });
      }
    }
  }

  void _selectPersona(MaleLead lead, Persona persona) {
    setState(() {
      _currentLead = lead;
      _currentPersona = persona;
    });
    _close();
    HapticFeedback.lightImpact();
  }

  void _open({required bool left}) {
    if (_showLeft || _showRight) return;
    setState(() {
      _showLeft = left;
      _showRight = !left;
      _showPlusMenu = false;
    });
    _slideCtrl.forward(from: 0.0);
    HapticFeedback.mediumImpact();
  }

  void _close() {
    if (!_showLeft && !_showRight) return;
    _slideCtrl.reverse().then((_) {
      if (mounted) {
        setState(() {
          _showLeft = false;
          _showRight = false;
          _isDragging = false;
          _dragOffset = 0;
        });
      }
    });
  }

  void _togglePlus() {
    if (_showLeft || _showRight) {
      _close();
      return;
    }
    setState(() {
      _showPlusMenu = !_showPlusMenu;
      if (_showPlusMenu) {
        _showLeft = false;
        _showRight = false;
      }
    });
  }

  double _offset(double screenW) {
    final w = screenW * _sidebarFraction;
    if (_isDragging) return _dragOffset;
    if (_showLeft) return w * _slideCtrl.value;
    if (_showRight) return -w * _slideCtrl.value;
    return 0;
  }

  // ========== 智能手势 ==========

  void _onPanStart(DragStartDetails details) {
    _isDragging = false;
    _dragOffset = 0;
    _dragDeltaX = 0;
    _dragDeltaY = 0;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_showPlusMenu) return;
    final dx = details.delta.dx;
    final dy = details.delta.dy;
    _dragDeltaX += dx;
    _dragDeltaY += dy;

    if (!_isDragging) {
      // 判断方向：水平还是垂直
      if (_dragDeltaX.abs() > 5 || _dragDeltaY.abs() > 5) {
        // 水平分量 > 垂直分量 → 水平拖动
        if (_dragDeltaX.abs() > _dragDeltaY.abs() * 1.5) {
          _isDragging = true;
          _dragOffset = 0;
        } else {
          // 垂直拖动 → 不处理，透给 ListView
          return;
        }
      } else {
        return;
      }
    }

    setState(() {
      _dragOffset += dx;
      final screenW = MediaQuery.of(context).size.width;
      final maxW = screenW * _sidebarFraction;
      _dragOffset = _dragOffset.clamp(-maxW, maxW);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_isDragging) {
      _dragOffset = 0;
      _dragDeltaX = 0;
      _dragDeltaY = 0;
      return;
    }

    final screenW = MediaQuery.of(context).size.width;
    final maxW = screenW * _sidebarFraction;
    final threshold = maxW * 0.30;

    if (!_showLeft && !_showRight) {
      // 中间页 → 滑动决定打开哪边
      if (_dragOffset > threshold) {
        _showLeft = true;
        _slideCtrl.forward(from: (_dragOffset / maxW).clamp(0.0, 1.0));
      } else if (_dragOffset < -threshold) {
        _showRight = true;
        _slideCtrl.forward(from: (-_dragOffset / maxW).clamp(0.0, 1.0));
      }
      _dragOffset = 0;
      _isDragging = false;
      _dragDeltaX = 0;
      _dragDeltaY = 0;
      return;
    }

    if (_showLeft) {
      if (_dragOffset < -threshold) {
        _close();
      } else {
        _slideCtrl.forward();
      }
    }
    if (_showRight) {
      if (_dragOffset > threshold) {
        _close();
      } else {
        _slideCtrl.forward();
      }
    }

    setState(() {
      _dragOffset = 0;
      _isDragging = false;
      _dragDeltaX = 0;
      _dragDeltaY = 0;
    });
  }

  Future<void> _sendMessage(String text) async {
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      isMe: true,
    );
    _msgKey.currentState?.appendMessage(userMsg);
    final reply = await _aiService.generateReply(
      text,
      _currentPersona?.id ?? 'default',
    );
    final aiMsg = ChatMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}_ai',
      text: reply,
      isMe: false,
    );
    _msgKey.currentState?.appendMessage(aiMsg);
  }

  void _openCharacterWorld() {
    if (_currentLead == null || _currentPersona == null) return;
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => CharacterWorldPage(
          lead: _currentLead!,
          persona: _currentPersona!,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final off = _offset(screenW);
    final leftW = screenW * _sidebarFraction;
    final showLeftLayer = _showLeft || (_isDragging && _dragOffset > 0);
    final showRightLayer = _showRight || (_isDragging && _dragOffset < 0);

    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          // ===== 左侧页 =====
          if (showLeftLayer)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: leftW,
              child: Container(
                color: const Color(0xFFEED9DC),
                child: ChatSidebarLeft(
                  currentLead: _currentLead,
                  currentPersona: _currentPersona,
                  onSelectPersona: (entry) {
                    _selectPersona(entry.key, entry.value);
                  },
                ),
              ),
            ),

          // ===== 右侧页 =====
          if (showRightLayer)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: screenW * _sidebarFraction,
              child: Container(
                color: const Color(0xFFDCE4EE),
                child: const ChatSidebarRight(),
              ),
            ),

          // ===== 中间页（永远在最上层移动） =====
          AnimatedPositioned(
            duration: _isDragging
                ? Duration.zero
                : const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: off,
            top: 0,
            right: -off,
            bottom: 0,
            child: _buildChatContent(),
          ),

          // ===== [+] 弹出菜单（在最上层） =====
          if (_showPlusMenu)
            Positioned.fill(
              child: PlusMenu(
                onDismiss: () => setState(() => _showPlusMenu = false),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChatContent() {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EEF0),
      body: GestureDetector(
        // 用 onPan 来做角度判断：水平走侧栏，垂直透给 ListView
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: SafeArea(
          child: Column(
            children: [
              ChatTopBar(
                currentLead: _currentLead,
                currentPersona: _currentPersona,
                onAvatarTap: _openCharacterWorld,
                onMenuTap: () => _open(left: true),
              ),
              Expanded(
                child: ChatMessageArea(
                  key: _msgKey,
                  currentPersona: _currentPersona,
                ),
              ),
              ChatInputBar(
                onCameraTap: () {},
                onVoiceTap: () {},
                onPlusTap: _togglePlus,
                onSendTap: _sendMessage,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
