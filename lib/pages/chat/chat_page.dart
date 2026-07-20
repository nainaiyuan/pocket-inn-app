import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/male_lead.dart';
import '../../services/character_service.dart';
import 'models/chat_message.dart';
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

  static const _sidebarFraction = 0.65;

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
    await _characterService.load();
    final leads = _characterService.leads;
    if (leads.isNotEmpty && mounted) {
      setState(() {
        _currentLead = leads.first;
        _currentPersona = leads.first.personas.isNotEmpty
            ? leads.first.personas.first
            : null;
      });
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
    setState(() {
      _showLeftSidebar = left;
      _showRightSidebar = !left;
    });
    _slideCtrl.forward();
    HapticFeedback.mediumImpact();
  }

  void _closeSidebar() {
    setState(() {
      _showLeftSidebar = false;
      _showRightSidebar = false;
    });
    _slideCtrl.reverse();
  }

  Future<void> _sendMessage(String text) async {
    if (_currentPersona == null) return;

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    );
    _msgKey.currentState?.appendMessage(userMsg);

    final reply = await _aiService.generateReply(text, _currentPersona!.id);
    final aiMsg = ChatMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}_ai',
      personaId: _currentPersona!.id,
      text: reply,
      timestamp: DateTime.now(),
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
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        final v = details.primaryVelocity!;
        if (v > 300 && !_showLeftSidebar && !_showRightSidebar) {
          _openSidebar(left: true);
        } else if (v < -300 && !_showLeftSidebar && !_showRightSidebar) {
          _openSidebar(left: false);
        } else if (v > 300 && _showRightSidebar) {
          _closeSidebar();
        } else if (v < -300 && _showLeftSidebar) {
          _closeSidebar();
        }
      },
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    final screenW = MediaQuery.of(context).size.width;
    final progress = _slideCtrl.value;
    final sidebarOpen = _showLeftSidebar || _showRightSidebar;

    // 主页面偏移量
    double mainOffset = 0;
    if (_showLeftSidebar) mainOffset = _sidebarFraction * screenW * progress;
    if (_showRightSidebar) mainOffset = -_sidebarFraction * screenW * progress;

    return Stack(
      children: [
        // ===== 背景层 =====
        Container(
          color: const Color(0xFFFff5f7),
          child: Stack(
            children: [
              Positioned(
                top: -80, left: -60,
                child: Container(
                  width: 300, height: 300,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFFB5C5).withValues(alpha: 0.2),
                  ),
                ),
              ),
              Positioned(
                bottom: 40, right: -40,
                child: Container(
                  width: 200, height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFC5B5FF).withValues(alpha: 0.15),
                  ),
                ),
              ),
            ],
          ),
        ),

        // ===== 左侧边栏（在聊天页下面，不会覆盖） =====
        if (_showLeftSidebar)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: 0,
            top: 0,
            bottom: 0,
            width: screenW * _sidebarFraction,
            child: ChatSidebarLeft(
              currentLead: _currentLead,
              currentPersona: _currentPersona,
              onSelectPersona: (entry) {
                _selectPersona(entry.key, entry.value);
              },
            ),
          ),

        // ===== 右侧边栏 =====
        if (_showRightSidebar)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            right: 0,
            top: 0,
            bottom: 0,
            width: screenW * _sidebarFraction,
            child: const ChatSidebarRight(),
          ),

        // ===== 阴影遮罩（点击可关闭） =====
        if (sidebarOpen && progress > 0.01)
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeSidebar,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: progress,
                child: Container(
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                ),
              ),
            ),
          ),

        // ===== 主聊天页面（盖在侧边栏上方，被推开露出侧栏） =====
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          left: mainOffset,
          top: 0,
          right: -mainOffset,
          bottom: 0,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 300),
            scale: sidebarOpen ? 0.96 : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(sidebarOpen ? 12 : 0),
                boxShadow: sidebarOpen
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: sidebarOpen ? Clip.antiAlias : Clip.none,
              child: _buildChatContent(),
            ),
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
    );
  }

  Widget _buildChatContent() {
    return Scaffold(
      backgroundColor: Colors.white.withValues(alpha: 0.85),
      body: Column(
        children: [
          ChatTopBar(
            currentLead: _currentLead,
            currentPersona: _currentPersona,
            onAvatarTap: _openCharacterWorld,
            onMenuTap: () {},
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
            onPlusTap: () => setState(() => _showPlusMenu = !_showPlusMenu),
            onSendTap: _sendMessage,
          ),
        ],
      ),
    );
  }
}
