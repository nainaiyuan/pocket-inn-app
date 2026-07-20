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
/// 左右滑动推开中间页露出侧边栏，无遮罩。
/// 侧边栏用不同颜色区分：左侧深暖色，右侧暖粉色。
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

  // 侧边栏
  bool _showLeftSidebar = false;
  bool _showRightSidebar = false;
  late AnimationController _slideCtrl;

  static const double _sidebarFraction = 0.65;
  static const double _edgeHitWidth = 55.0; // 边缘触发宽度

  /// 拖动偏移量
  double _dragOffset = 0;
  bool _isDragging = false;

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
    _closeSidebar();
    HapticFeedback.lightImpact();
  }

  void _openSidebar({required bool left}) {
    if (_showLeftSidebar || _showRightSidebar) return;
    setState(() {
      _showLeftSidebar = left;
      _showRightSidebar = !left;
      _showPlusMenu = false;
    });
    _slideCtrl.forward(from: 0.0);
    HapticFeedback.mediumImpact();
  }

  void _closeSidebar() {
    if (!_showLeftSidebar && !_showRightSidebar) return;
    _slideCtrl.reverse().then((_) {
      if (mounted) {
        setState(() {
          _showLeftSidebar = false;
          _showRightSidebar = false;
          _isDragging = false;
          _dragOffset = 0;
        });
      }
    });
  }

  void _togglePlusMenu() {
    if (_showLeftSidebar || _showRightSidebar) {
      _closeSidebar();
      return;
    }
    setState(() => _showPlusMenu = !_showPlusMenu);
  }

  double _getMainOffset(double screenW) {
    double offset = 0;
    if (_showLeftSidebar) {
      offset = screenW * _sidebarFraction * _slideCtrl.value;
    } else if (_showRightSidebar) {
      offset = -(screenW * _sidebarFraction * _slideCtrl.value);
    }
    if (_isDragging) {
      offset += _dragOffset;
    }
    return offset;
  }

  // ===== 左边缘滑动手势（露出右侧栏） =====
  void _onRightEdgeDragUpdate(DragUpdateDetails details) {
    if (_showLeftSidebar || _showPlusMenu) return;
    if (details.primaryDelta == null) return;
    final screenW = MediaQuery.of(context).size.width;
    setState(() {
      _isDragging = true;
      _dragOffset -= details.primaryDelta!; // 左滑为负 -> 右栏滑入
      _dragOffset = _dragOffset.clamp(-screenW * _sidebarFraction, 0);
    });
  }

  void _onRightEdgeDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    final screenW = MediaQuery.of(context).size.width;
    final absOffset = _dragOffset.abs();
    final threshold = screenW * _sidebarFraction * 0.35;
    if (absOffset > threshold && _dragOffset < 0) {
      _showRightSidebar = true;
      _slideCtrl.forward(from: (absOffset / (screenW * _sidebarFraction)).clamp(0.0, 1.0));
    }
    setState(() {
      _isDragging = false;
      _dragOffset = 0;
    });
  }

  // ===== 右边缘滑动手势（露出左侧栏） =====
  void _onLeftEdgeDragUpdate(DragUpdateDetails details) {
    if (_showRightSidebar || _showPlusMenu) return;
    if (details.primaryDelta == null) return;
    final screenW = MediaQuery.of(context).size.width;
    setState(() {
      _isDragging = true;
      _dragOffset += details.primaryDelta!; // 右滑为正 -> 左栏滑入
      _dragOffset = _dragOffset.clamp(0, screenW * _sidebarFraction);
    });
  }

  void _onLeftEdgeDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    final screenW = MediaQuery.of(context).size.width;
    if (_dragOffset > screenW * _sidebarFraction * 0.35) {
      _showLeftSidebar = true;
      _slideCtrl.forward(from: (_dragOffset / (screenW * _sidebarFraction)).clamp(0.0, 1.0));
    }
    setState(() {
      _isDragging = false;
      _dragOffset = 0;
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
    final mainOffset = _getMainOffset(screenW);
    final sidebarOpen = _showLeftSidebar || _showRightSidebar;
    final canLeftSwipe = !_showRightSidebar && !_showPlusMenu;  // 可以左滑
    final canRightSwipe = !_showLeftSidebar && !_showPlusMenu;  // 可以右滑

    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          // ===== 左侧边栏（深暖色） =====
          if (_showLeftSidebar || (_isDragging && _dragOffset > 0))
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: screenW * _sidebarFraction,
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

          // ===== 右侧边栏（浅灰蓝） =====
          if (_showRightSidebar || (_isDragging && _dragOffset < 0))
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

          // ===== 中间聊天主页面 =====
          // 无遮罩，无遮盖
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: mainOffset,
            top: 0,
            right: -mainOffset,
            bottom: 0,
            child: _buildChatContent(screenW, canLeftSwipe, canRightSwipe),
          ),

          // ===== [+] 弹出菜单 =====
          if (_showPlusMenu && !sidebarOpen)
            Positioned.fill(
              child: PlusMenu(
                onDismiss: () => setState(() => _showPlusMenu = false),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChatContent(double screenW, bool canLeftSwipe, bool canRightSwipe) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EEF0),
      body: SafeArea(
        child: Stack(
          children: [
            // 聊天主体
            Column(
              children: [
                ChatTopBar(
                  currentLead: _currentLead,
                  currentPersona: _currentPersona,
                  onAvatarTap: _openCharacterWorld,
                  onMenuTap: () => _openSidebar(left: true),
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
                  onPlusTap: _togglePlusMenu,
                  onSendTap: _sendMessage,
                ),
              ],
            ),

            // ===== 右侧手势区域（左滑露出右侧栏） =====
            if (canLeftSwipe)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: _edgeHitWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: _onRightEdgeDragUpdate,
                  onHorizontalDragEnd: _onRightEdgeDragEnd,
                ),
              ),

            // ===== 左侧手势区域（右滑露出左侧栏） =====
            if (canRightSwipe)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _edgeHitWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: _onLeftEdgeDragUpdate,
                  onHorizontalDragEnd: _onLeftEdgeDragEnd,
                ),
              ),

            // 侧边栏关闭按钮（仅侧边栏打开时在边缘显示）
            if (_showLeftSidebar)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 20,
                child: GestureDetector(
                  onTap: _closeSidebar,
                  behavior: HitTestBehavior.translucent,
                ),
              ),
            if (_showRightSidebar)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 20,
                child: GestureDetector(
                  onTap: _closeSidebar,
                  behavior: HitTestBehavior.translucent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
