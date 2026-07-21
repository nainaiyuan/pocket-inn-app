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
/// 像一张纸折了两下，分成左中右三页。
/// 全屏水平滑动：
///   右滑 → 露出/收回左侧页
///   左滑 → 露出/收回右侧页
/// 侧栏展开后可全屏反方向滑动关闭。
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

  bool _showLeftSidebar = false;
  bool _showRightSidebar = false;
  late AnimationController _slideCtrl;

  static const double _sidebarFraction = 0.65;

  // 手势状态
  double _currentDrag = 0;
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
          _currentDrag = 0;
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

  /// 返回当前中间页偏移量
  double _getOffset(double screenW) {
    final baseW = screenW * _sidebarFraction;
    double offset = _currentDrag;

    if (!_isDragging) {
      if (_showLeftSidebar) {
        offset = baseW * _slideCtrl.value;
      } else if (_showRightSidebar) {
        offset = -baseW * _slideCtrl.value;
      } else {
        offset = 0;
      }
    }
    return offset;
  }

  // ========== 全屏手势处理 ==========

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_showPlusMenu) return;
    if (details.primaryDelta == null) return;

    if (!_isDragging) {
      // 初次检测到水平滑动，开始拖动
      _isDragging = true;
      _currentDrag = 0;
    }

    setState(() {
      _currentDrag += details.primaryDelta!;
      final screenW = MediaQuery.of(context).size.width;
      final maxW = screenW * _sidebarFraction;
      _currentDrag = _currentDrag.clamp(-maxW, maxW);
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_isDragging) {
      _currentDrag = 0;
      return;
    }

    final screenW = MediaQuery.of(context).size.width;
    final baseW = screenW * _sidebarFraction;
    final threshold = baseW * 0.30;

    if (!_showLeftSidebar && !_showRightSidebar) {
      // 中间页占满 → 根据最后滑动的方向打开对应侧栏
      if (_currentDrag > threshold) {
        _showLeftSidebar = true;
        _slideCtrl.forward(from: (_currentDrag / baseW).clamp(0.0, 1.0));
      } else if (_currentDrag < -threshold) {
        _showRightSidebar = true;
        _slideCtrl.forward(from: (-_currentDrag / baseW).clamp(0.0, 1.0));
      }
      // 没到阈值弹回
      _currentDrag = 0;
      _isDragging = false;
      return;
    }

    // 左栏已展开
    if (_showLeftSidebar) {
      // 往左滑超过阈值 → 收回
      if (_currentDrag < -threshold) {
        _closeSidebar();
      } else {
        // 弹回完全展开
        _slideCtrl.forward();
        _currentDrag = 0;
        _isDragging = false;
      }
      return;
    }

    // 右栏已展开
    if (_showRightSidebar) {
      // 往右滑超过阈值 → 收回
      if (_currentDrag > threshold) {
        _closeSidebar();
      } else {
        _slideCtrl.forward();
        _currentDrag = 0;
        _isDragging = false;
      }
    }
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
    final offset = _getOffset(screenW);
    final leftVisible = _showLeftSidebar || (_isDragging && _currentDrag > 0);
    final rightVisible = _showRightSidebar || (_isDragging && _currentDrag < 0);
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          // ===== 左侧边栏（深暖色） =====
          if (leftVisible)
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
          if (rightVisible)
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
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: offset,
            top: 0,
            right: -offset,
            bottom: 0,
            child: _buildChatContent(),
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

  Widget _buildChatContent() {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EEF0),
      body: GestureDetector(
        onHorizontalDragStart: (_) => _isDragging = false,
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        child: SafeArea(
          child: Column(
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
        ),
      ),
    );
  }
}
