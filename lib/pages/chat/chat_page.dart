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

/// 聊天主页面 —— 三页联动侧栏
///
/// 左中右三页像一张纸折两下连在一起。
/// 顶部栏+底部输入框：全宽水平滑动
/// 消息区域左右边缘30px：水平滑动
/// 侧栏展开时：顶层加全屏水平手势层（不挡垂直滚动）
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

  bool _showLeft = false;
  bool _showRight = false;
  late AnimationController _slideCtrl;

  static const double _sidebarFraction = 0.65;

  // 拖动状态
  bool _isDragging = false;
  double _dragOffset = 0;

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

  // ========== 顶部栏 + 底部输入框水平手势 ==========

  void _onHoriDragUpdate(DragUpdateDetails details) {
    if (_showPlusMenu || details.primaryDelta == null) return;
    if (_showLeft || _showRight) return; // 展开时走 overlay 层
    if (!_isDragging) {
      _isDragging = true;
      _dragOffset = 0;
    }
    setState(() {
      _dragOffset += details.primaryDelta!;
      final screenW = MediaQuery.of(context).size.width;
      final maxW = screenW * _sidebarFraction;
      _dragOffset = _dragOffset.clamp(-maxW, maxW);
    });
  }

  void _onHoriDragEnd(DragEndDetails details) {
    _finishDrag();
  }

  // ========== 侧栏已展开时 Listener 手势判定 ==========

  double _touchStartX = 0;
  double _touchStartY = 0;
  bool _listenerClaimed = false;

  void _onListenerPointerDown(PointerDownEvent event) {
    _touchStartX = event.position.dx;
    _touchStartY = event.position.dy;
    _listenerClaimed = false;
  }

  void _onListenerPointerMove(PointerMoveEvent event) {
    // 只在侧栏展开时拦截水平手势
    if (!_showLeft && !_showRight) return;
    if (_showPlusMenu) return;

    final dx = event.position.dx - _touchStartX;
    final dy = event.position.dy - _touchStartY;

    if (!_listenerClaimed) {
      if (dx.abs() < 5 && dy.abs() < 5) return;

      // 水平 √ | 垂直 ×
      if (dx.abs() > dy.abs() * 1.2) {
        _listenerClaimed = true;
      } else {
        return;
      }
    }

    // 只在中间页区域生效（侧栏区域透传）
    final screenW = MediaQuery.of(context).size.width;
    final leftW = screenW * _sidebarFraction;
    if (_showLeft && event.position.dx < leftW) return;      // 左栏展开时，左半屏是侧栏
    if (_showRight && event.position.dx > screenW - leftW) return; // 右栏展开时，右半屏是侧栏

    setState(() {
      _isDragging = true;
      _dragOffset += event.position.dx - _touchStartX;
      final maxW = screenW * _sidebarFraction;
      _dragOffset = _dragOffset.clamp(-maxW, maxW);
    });
    _touchStartX = event.position.dx;
    _touchStartY = event.position.dy;
  }

  void _onListenerPointerUp(PointerUpEvent event) {
    if (!_listenerClaimed || !_isDragging) {
      _isDragging = false;
      _dragOffset = 0;
      return;
    }
    _finishDrag();
  }

  // ========== 消息区域边缘手势（只在中间页时生效） ==========

  void _onEdgeDragUpdate({required bool isRightEdge, required double delta}) {
    if (_showPlusMenu) return;
    if (_showLeft || _showRight) return; // 展开时走 Listener
    if (!_isDragging) {
      _isDragging = true;
      _dragOffset = 0;
    }
    setState(() {
      _dragOffset += delta;
      final screenW = MediaQuery.of(context).size.width;
      final maxW = screenW * _sidebarFraction;
      _dragOffset = isRightEdge
          ? _dragOffset.clamp(0, maxW)    // 右侧边缘右滑→左栏
          : _dragOffset.clamp(-maxW, 0);  // 左侧边缘左滑→右栏
    });
  }

  void _finishDrag() {
    if (!_isDragging) {
      _dragOffset = 0;
      return;
    }

    final screenW = MediaQuery.of(context).size.width;
    final maxW = screenW * _sidebarFraction;
    final threshold = maxW * 0.30;

    if (!_showLeft && !_showRight) {
      if (_dragOffset > threshold) {
        _showLeft = true;
        _slideCtrl.forward(from: (_dragOffset / maxW).clamp(0.0, 1.0));
      } else if (_dragOffset < -threshold) {
        _showRight = true;
        _slideCtrl.forward(from: (-_dragOffset / maxW).clamp(0.0, 1.0));
      }
    } else if (_showLeft && _dragOffset < -threshold) {
      _close();
      setState(() { _dragOffset = 0; _isDragging = false; });
      return;
    } else if (_showRight && _dragOffset > threshold) {
      _close();
      setState(() { _dragOffset = 0; _isDragging = false; });
      return;
    }

    setState(() {
      _dragOffset = 0;
      _isDragging = false;
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
    final edgeZoneW = 30.0;
    final sidebarOpen = _showLeft || _showRight;

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

          // ===== 中间页 =====
          AnimatedPositioned(
            duration: _isDragging
                ? Duration.zero
                : const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: off,
            top: 0,
            right: -off,
            bottom: 0,
            child: _buildChatContent(edgeZoneW, sidebarOpen),
          ),

          // ===== 侧栏展开时：中间页再加一层 Listener =====
          // 只在中间页区域内拦截水平手势，侧栏区域不受影响
          // Listener 不消费事件，所以 ListView 垂直滚动正常
          if (sidebarOpen)
            Positioned.fill(
              child: Listener(
                onPointerDown: _onListenerPointerDown,
                onPointerMove: _onListenerPointerMove,
                onPointerUp: _onListenerPointerUp,
              ),
            ),

          // ===== [+] 弹出菜单 =====
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

  Widget _buildChatContent(double edgeZoneW, bool sidebarOpen) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EEF0),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // 顶部栏（全宽水平滑动 → 中间页模式）
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: _onHoriDragUpdate,
                  onHorizontalDragEnd: _onHoriDragEnd,
                  child: ChatTopBar(
                    currentLead: _currentLead,
                    currentPersona: _currentPersona,
                    onAvatarTap: _openCharacterWorld,
                    onMenuTap: () => _open(left: true),
                  ),
                ),

                // 消息区域
                Expanded(
                  child: Stack(
                    children: [
                      ChatMessageArea(
                        key: _msgKey,
                        currentPersona: _currentPersona,
                      ),

                      // 左边缘30px手势区（仅中间页时生效）
                      if (!sidebarOpen)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: edgeZoneW,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragUpdate: (d) =>
                              _onEdgeDragUpdate(isRightEdge: true, delta: d.primaryDelta ?? 0),
                            onHorizontalDragEnd: (_) => _finishDrag(),
                          ),
                        ),

                      // 右边缘30px手势区（仅中间页时生效）
                      if (!sidebarOpen)
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          width: edgeZoneW,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragUpdate: (d) =>
                              _onEdgeDragUpdate(isRightEdge: false, delta: d.primaryDelta ?? 0),
                            onHorizontalDragEnd: (_) => _finishDrag(),
                          ),
                        ),
                    ],
                  ),
                ),

                // 底部输入框（全宽水平滑动）
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: _onHoriDragUpdate,
                  onHorizontalDragEnd: _onHoriDragEnd,
                  child: ChatInputBar(
                    onCameraTap: () {},
                    onVoiceTap: () {},
                    onPlusTap: _togglePlus,
                    onSendTap: _sendMessage,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
