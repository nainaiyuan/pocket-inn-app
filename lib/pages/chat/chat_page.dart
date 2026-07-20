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
/// 左右滑动时，中间页面被推开，露出左侧/右侧页面。
/// 手势在屏幕左右边缘 40px 内触发，不干扰列表滚动。
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

  /// 当前拖拽的偏移量（用于三页联动）
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

  /// 获取中间页面的当前偏移量
  double _getMainOffset(double screenW) {
    final progress = _slideCtrl.value;
    double offset = 0;
    if (_showLeftSidebar) {
      offset = screenW * _sidebarFraction * progress;
    } else if (_showRightSidebar) {
      offset = -screenW * _sidebarFraction * progress;
    }
    // 拖动时叠加拖拽偏移
    if (_isDragging) {
      offset += _dragOffset;
    }
    return offset;
  }

  // ===== 边缘滑动识别 =====
  void _onLeftEdgeHorizontalDragUpdate(DragUpdateDetails details) {
    if (_showRightSidebar || _showPlusMenu) return;
    if (details.primaryDelta == null) return;
    setState(() {
      _isDragging = true;
      _dragOffset += details.primaryDelta!;
      _dragOffset = _dragOffset.clamp(0, MediaQuery.of(context).size.width * _sidebarFraction);
    });
  }

  void _onLeftEdgeDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    final screenW = MediaQuery.of(context).size.width;
    final threshold = screenW * _sidebarFraction * 0.35;
    if (_dragOffset > threshold) {
      _showLeftSidebar = true;
      _slideCtrl.forward(from: (_dragOffset / (screenW * _sidebarFraction)).clamp(0.0, 1.0));
    }
    setState(() {
      _isDragging = false;
      _dragOffset = 0;
    });
  }

  void _onRightEdgeHorizontalDragUpdate(DragUpdateDetails details) {
    if (_showLeftSidebar || _showPlusMenu) return;
    if (details.primaryDelta == null) return;
    setState(() {
      _isDragging = true;
      _dragOffset += details.primaryDelta!;
      _dragOffset = _dragOffset.clamp(
        -(MediaQuery.of(context).size.width * _sidebarFraction),
        0,
      );
    });
  }

  void _onRightEdgeDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    final screenW = MediaQuery.of(context).size.width;
    final threshold = -(screenW * _sidebarFraction * 0.35);
    if (_dragOffset < threshold) {
      _showRightSidebar = true;
      _slideCtrl.forward(from: (-_dragOffset / (screenW * _sidebarFraction)).clamp(0.0, 1.0));
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

  void _onTapMessageArea() {
    if (_showPlusMenu) {
      setState(() => _showPlusMenu = false);
    } else if (_showLeftSidebar || _showRightSidebar) {
      _closeSidebar();
    }
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
    final edgeHitWidth = 35.0; // 边缘触发宽度

    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          // ===== 左侧边栏 =====
          if (_showLeftSidebar || (_isDragging && _dragOffset > 0))
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: screenW * _sidebarFraction,
              child: Container(
                color: const Color(0xFFF5EEF0),
                child: ChatSidebarLeft(
                  currentLead: _currentLead,
                  currentPersona: _currentPersona,
                  onSelectPersona: (entry) {
                    _selectPersona(entry.key, entry.value);
                  },
                ),
              ),
            ),

          // ===== 右侧边栏 =====
          if (_showRightSidebar || (_isDragging && _dragOffset < 0))
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: screenW * _sidebarFraction,
              child: Container(
                color: const Color(0xFFF5EEF0),
                child: const ChatSidebarRight(),
              ),
            ),

          // ===== 遮罩层 =====
          if (sidebarOpen && !_isDragging)
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeSidebar,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: _slideCtrl.value * 0.45,
                  child: Container(color: Colors.black),
                ),
              ),
            ),

          // ===== 中间聊天主页面（含动画+手势） =====
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: mainOffset,
            top: 0,
            right: -mainOffset,
            bottom: 0,
            child: _buildChatContent(edgeHitWidth),
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

  Widget _buildChatContent(double edgeHitWidth) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EEF0),
      body: SafeArea(
        child: Stack(
          children: [
            // 聊天内容主体
            Column(
              children: [
                ChatTopBar(
                  currentLead: _currentLead,
                  currentPersona: _currentPersona,
                  onAvatarTap: _openCharacterWorld,
                  onMenuTap: () => _openSidebar(left: true),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: _onTapMessageArea,
                    child: ChatMessageArea(
                      key: _msgKey,
                      currentPersona: _currentPersona,
                    ),
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

            // 左边缘手势区域（透明覆盖层）
            if (!_showRightSidebar && !_showPlusMenu)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: edgeHitWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: _onLeftEdgeHorizontalDragUpdate,
                  onHorizontalDragEnd: _onLeftEdgeDragEnd,
                  child: Container(), // 透明
                ),
              ),

            // 右边缘手势区域
            if (!_showLeftSidebar && !_showPlusMenu)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: edgeHitWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: _onRightEdgeHorizontalDragUpdate,
                  onHorizontalDragEnd: _onRightEdgeDragEnd,
                  child: Container(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
