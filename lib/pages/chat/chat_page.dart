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
      duration: const Duration(milliseconds: 350),
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
      _showLeftSidebar = false;
    });
    _slideCtrl.reverse();
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

    // 走AI回复
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
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(opacity: anim, child: child);
        },
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
      child: Stack(
        children: [
          _buildBackground(),
          _buildAnimatedLayout(),
          if (_showPlusMenu) PlusMenu(onDismiss: () {
            setState(() => _showPlusMenu = false);
          }),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return Container(
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
    );
  }

  Widget _buildAnimatedLayout() {
    final progress = _slideCtrl.value;
    final offset = _showLeftSidebar
        ? _sidebarFraction * progress
        : _showRightSidebar
            ? -_sidebarFraction * progress
            : 0.0;

    return Stack(
      children: [
        // 阴影
        if (_showLeftSidebar || _showRightSidebar)
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeSidebar,
              child: Container(
                color: const Color(0xFF5A4A52).withValues(alpha: 0.15 * progress),
              ),
            ),
          ),

        // 侧边栏
        if (_showLeftSidebar)
          FractionallySizedBox(
            widthFactor: _sidebarFraction,
            alignment: Alignment.centerLeft,
            child: ChatSidebarLeft(
              currentLead: _currentLead,
              currentPersona: _currentPersona,
              onSelectPersona: (entry) {
                _selectPersona(entry.key, entry.value);
              },
            ),
          ),

        if (_showRightSidebar)
          FractionallySizedBox(
            widthFactor: _sidebarFraction,
            alignment: Alignment.centerRight,
            child: const ChatSidebarRight(),
          ),

        // 主页面
        Transform.translate(
          offset: Offset(offset * MediaQuery.of(context).size.width, 0),
          child: Transform.scale(
            scale: 1 - 0.03 * progress,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16 * progress),
                boxShadow: progress > 0.01
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08 * progress),
                          blurRadius: 20,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: progress > 0.01 ? Clip.antiAlias : Clip.none,
              child: _buildChatContent(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatContent() {
    return Scaffold(
      backgroundColor: Colors.white.withValues(alpha: 0.55),
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
