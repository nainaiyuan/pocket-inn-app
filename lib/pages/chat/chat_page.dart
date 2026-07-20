import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/male_lead.dart';
import '../../services/character_service.dart';
import 'widgets/chat_message_area.dart';
import 'widgets/chat_input_bar.dart';
import 'widgets/chat_top_bar.dart';
import 'widgets/chat_sidebar_left.dart';
import 'widgets/chat_sidebar_right.dart';
import 'widgets/chat_top_bar.dart';
import 'widgets/chat_message_area.dart';
import 'widgets/chat_input_bar.dart';

/// 聊天主页面
///
/// 悬浮球3号位 → 聊天页
/// 支持左右滑推开主页面露出侧边栏
/// 左滑 → 选角色，右滑 → 设置
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  final _characterService = CharacterService();

  // 当前选中
  MaleLead? _currentLead;
  Persona? _currentPersona;

  // 侧边栏状态
  bool _showLeftSidebar = false;
  bool _showRightSidebar = false;

  // 滑动动画
  late AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;

  // 侧边栏宽度比例
  static const _sidebarFraction = 0.65;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(0, 0),
    ).animate(CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.easeOutCubic,
    ));
    _initCharacter();
  }

  Future<void> _initCharacter() async {
    await _characterService.load();
    final leads = _characterService.leads;
    if (leads.isNotEmpty && mounted) {
      setState(() {
        _currentLead = leads.first;
        if (leads.first.personas.isNotEmpty) {
          _currentPersona = leads.first.personas.first;
        }
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

  void _openLeftSidebar() {
    setState(() {
      _showLeftSidebar = true;
      _showRightSidebar = false;
    });
    _slideCtrl.forward();
    HapticFeedback.mediumImpact();
  }

  void _openRightSidebar() {
    setState(() {
      _showRightSidebar = true;
      _showLeftSidebar = false;
    });
    _slideCtrl.forward();
    HapticFeedback.mediumImpact();
  }

  void _closeSidebar() {
    final wasOpen = _showLeftSidebar || _showRightSidebar;
    setState(() {
      _showLeftSidebar = false;
      _showRightSidebar = false;
    });
    _slideCtrl.reverse();
    if (wasOpen) HapticFeedback.lightImpact();
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
        // 左右滑动切换侧边栏
        if (details.primaryVelocity == null) return;
        if (details.primaryVelocity! > 300 && !_showLeftSidebar && !_showRightSidebar) {
          _openLeftSidebar();
        } else if (details.primaryVelocity! < -300 && !_showLeftSidebar && !_showRightSidebar) {
          _openRightSidebar();
        } else if (details.primaryVelocity! > 300 && _showRightSidebar) {
          _closeSidebar();
        } else if (details.primaryVelocity! < -300 && _showLeftSidebar) {
          _closeSidebar();
        }
      },
      child: Stack(
        children: [
          // ===== 背景层 =====
          _buildBackground(),

          // ===== 主页面 + 侧边栏 =====
          AnimatedBuilder(
            animation: _slideCtrl,
            builder: (context, child) {
              final progress = _slideCtrl.value;
              final offset = _showLeftSidebar
                  ? _sidebarFraction * progress
                  : _showRightSidebar
                      ? -_sidebarFraction * progress
                      : _showLeftSidebar
                          ? _sidebarFraction * (1 - progress)
                          : _showRightSidebar
                              ? -_sidebarFraction * (1 - progress)
                              : 0.0;

              return Stack(
                children: [
                  // 阴影背景
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

                  // 主聊天页面（被推开）
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
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return Container(
      color: const Color(0xFFFff5f7),
      child: Stack(
        children: [
          // 装饰色块
          Positioned(
            top: -80,
            left: -60,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFB5C5).withValues(alpha: 0.2),
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            right: -40,
            child: Container(
              width: 200,
              height: 200,
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

  Widget _buildChatContent() {
    return Scaffold(
      backgroundColor: Colors.white.withValues(alpha: 0.55),
      body: Column(
        children: [
          // 顶部栏
          ChatTopBar(
            currentLead: _currentLead,
            currentPersona: _currentPersona,
            onAvatarTap: () {
              // TODO: 点头像 → 男主小世界
            },
            onMenuTap: () {},
          ),

          // 消息区域
          Expanded(
            child: ChatMessageArea(
              currentPersona: _currentPersona,
            ),
          ),

          // 底部输入
          ChatInputBar(
            onCameraTap: () {},
            onVoiceTap: () {},
            onPlusTap: () {},
            onSendTap: (text) {},
          ),
        ],
      ),
    );
  }
}

