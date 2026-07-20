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

  static const double _sidebarFraction = 0.65;

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
    } catch (_) {
      // 第一次打开可能还没有数据
    }
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
      // 没有角色时自动建一个默认的
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
      _showPlusMenu = false; // 关闭加号菜单
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

  /// 处理水平拖动打开/关闭侧边栏
  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_showLeftSidebar || _showRightSidebar) return;
    if (details.primaryDelta == null) return;

    final delta = details.primaryDelta!;
    // 向右滑 -> 打开左侧栏
    if (delta > 20) {
      _openSidebar(left: true);
    }
    // 向左滑 -> 打开右侧栏
    else if (delta < -20) {
      _openSidebar(left: false);
    }
  }

  Future<void> _sendMessage(String text) async {
    if (_currentPersona == null) {
      // 没选角色也能发，只是给一个虚拟回复
    }

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

  void _togglePlusMenu() {
    setState(() {
      // 如果侧边栏开着，先关侧边栏
      if (_showLeftSidebar || _showRightSidebar) {
        _closeSidebar();
        return;
      }
      _showPlusMenu = !_showPlusMenu;
    });
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

    double mainOffset = 0;
    if (sidebarOpen) {
      if (_showLeftSidebar) {
        mainOffset = screenW * _sidebarFraction * progress;
      } else {
        mainOffset = -screenW * _sidebarFraction * progress;
      }
    }

    // 侧边栏按钮 + 手势都用
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          // ===== 左侧边栏 =====
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

          // ===== 暗色遮罩 =====
          if (sidebarOpen)
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeSidebar,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 280),
                  opacity: progress * 0.5,
                  child: Container(color: Colors.black),
                ),
              ),
            ),

          // ===== 中间聊天页 =====
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            left: mainOffset,
            top: 0,
            right: -mainOffset,
            bottom: 0,
            child: GestureDetector(
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              child: _buildChatContent(),
            ),
          ),

          // ===== [+] 弹出菜单（只在侧边栏关闭时显示） =====
          if (_showPlusMenu && !sidebarOpen)
            Positioned.fill(
              child: PlusMenu(
                onDismiss: () => setState(() => _showPlusMenu = false),
              ),
            ),

          // ===== 触发侧边栏的点击按钮层 =====
          // 左侧边缘点击区
          if (!sidebarOpen)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 30,
              child: GestureDetector(
                onTap: () => _openSidebar(left: true),
                behavior: HitTestBehavior.translucent,
              ),
            ),
          // 右侧边缘点击区
          if (!sidebarOpen)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 30,
              child: GestureDetector(
                onTap: () => _openSidebar(left: false),
                behavior: HitTestBehavior.translucent,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChatContent() {
    return Scaffold(
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
    );
  }
}
