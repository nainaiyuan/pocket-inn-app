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

/// 聊天主页面
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

  // 手势跟踪
  double _dragStartX = 0;
  bool _isDragging = false;

  static const double _sidebarFraction = 0.65;
  static const double _dragThreshold = 30.0;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
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
    // 如果有 PlusMenu，先关上
    if (_showPlusMenu) {
      setState(() => _showPlusMenu = false);
    }
    setState(() {
      _showLeftSidebar = left;
      _showRightSidebar = !left;
    });
    _slideCtrl.forward();
    HapticFeedback.mediumImpact();
  }

  void _closeSidebar() {
    if (!_showLeftSidebar && !_showRightSidebar) return;
    _slideCtrl.reverse().then((_) {
      if (mounted) {
        setState(() {
          _showLeftSidebar = false;
          _showRightSidebar = false;
        });
      }
    });
  }

  void _togglePlusMenu() {
    // 如果侧边栏开着，先关侧边栏（反之亦然）
    if (_showLeftSidebar || _showRightSidebar) {
      _closeSidebar();
      return;
    }
    setState(() {
      _showPlusMenu = !_showPlusMenu;
    });
  }

  // ===== 手势处理：连续跟踪拖动距离，超过阈值触发 =====
  void _onPanStart(DragStartDetails details) {
    if (_showLeftSidebar || _showRightSidebar || _showPlusMenu) return;
    _dragStartX = details.globalPosition.dx;
    _isDragging = true;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    final currentX = details.globalPosition.dx;
    final delta = currentX - _dragStartX;

    // 向右拖动超过阈值 → 打开左侧栏
    if (delta > _dragThreshold && !_showLeftSidebar) {
      _isDragging = false;
      _openSidebar(left: true);
    }
    // 向左拖动超过阈值 → 打开右侧栏（屏幕右侧1/3区域开始拖才有效，避免误触）
    else if (delta < -_dragThreshold && !_showRightSidebar) {
      // 只在屏幕右半部分开始的左滑才触发右侧栏
      if (_dragStartX > MediaQuery.of(context).size.width * 0.5) {
        _isDragging = false;
        _openSidebar(left: false);
      }
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _isDragging = false;
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

  /// 点击消息区域（关闭 PlusMenu 或侧边栏）
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
    final progress = _slideCtrl.value;
    final sidebarOpen = _showLeftSidebar || _showRightSidebar;

    // 计算主页面偏移
    // 左侧栏打开时：向右推，left=正，right=负
    // 右侧栏打开时：向左推，left=负，right=正
    double mainLeft = 0;
    double mainRight = 0;
    if (sidebarOpen) {
      if (_showLeftSidebar) {
        final offset = screenW * _sidebarFraction * progress;
        mainLeft = offset;
        mainRight = -offset;
      } else {
        final offset = screenW * _sidebarFraction * progress;
        mainLeft = -offset;
        mainRight = offset;
      }
    }

    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          // ===== 左侧边栏 =====
          if (_showLeftSidebar)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: screenW * _sidebarFraction,
              child: Container(
                color: const Color(0xFFF8F2F4),
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
          if (_showRightSidebar)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: screenW * _sidebarFraction,
              child: Container(
                color: const Color(0xFFF8F2F4),
                child: const ChatSidebarRight(),
              ),
            ),

          // ===== 暗色遮罩层 =====
          // 当侧边栏动画进行中但还没完全展开时，遮罩也有过渡
          if (_showLeftSidebar || _showRightSidebar)
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeSidebar,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 280),
                  opacity: progress.clamp(0.0, 0.45),
                  child: Container(color: Colors.black),
                ),
              ),
            ),

          // ===== 中间聊天主页面 =====
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            left: mainLeft,
            top: 0,
            right: mainRight,
            bottom: 0,
            child: _buildChatContent(),
          ),

          // ===== [+] 弹出菜单 =====
          // 只在侧边栏关闭时显示 PlusMenu
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

  Widget _buildChatContent() {
    // 如果 PlusMenu 打开时，拖动手势由 PlusMenu 自己处理
    // 如果侧边栏打开时，不需要手势识别
    final sidebarOpen = _showLeftSidebar || _showRightSidebar;
    final needsGesture = !sidebarOpen && !_showPlusMenu;

    Widget chatContent = Scaffold(
      backgroundColor: const Color(0xFFF5EEF0),
      body: SafeArea(
        child: Column(
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
      ),
    );

    // 仅在需要手势识别时包裹 GestureDetector
    if (needsGesture) {
      chatContent = GestureDetector(
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: chatContent,
      );
    }

    return chatContent;
  }
}
