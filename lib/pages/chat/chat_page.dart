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

/// 聊天主页面 —— 三页一体（一张纸）
///
/// 左中右三页是连在一起的**一整张纸**，屏幕是窗口。
/// - 中间页全屏 = 屏幕在纸的中间
/// - 全屏左滑 = 屏幕往左移 → 看到纸的右边（右页展开）
/// - 全屏右滑 = 屏幕往右移 → 看到纸的左边（左页展开）
/// - 右页展开后再左滑 = 纸往右拉 → 屏幕回到中间
/// - 左页展开后再右滑 = 纸往左拉 → 屏幕回到中间
///
/// 手势：三页区域全部用 Listener 自己算角度，
/// 任何含水平分量的滑动都会触发纸的平移，只有纯垂直才透给 ListView。
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

  // "纸张"偏移状态：0=中间，正数=纸右移（左页露出），负数=纸左移（右页露出）
  double _paperOffset = 0;
  bool _isOpen = false; // true=左页或右页完全展开

  late AnimationController _paperCtrl;

  static const double _sidebarFraction = 0.65;

  // Listener 手势判定
  bool _isDragging = false;
  double _startX = 0, _startY = 0;
  bool _claimed = false;

  @override
  void initState() {
    super.initState();
    _paperCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() {
      if (mounted) setState(() {});
    });
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
    _snapToCenter();
    HapticFeedback.lightImpact();
  }

  void _snapToCenter() {
    if (_paperCtrl.isAnimating) _paperCtrl.stop();
    _paperCtrl.reverse().then((_) {
      if (mounted) setState(() { _isOpen = false; _paperOffset = 0; });
    });
  }

  void _togglePlus() {
    if (_isOpen) {
      _snapToCenter();
      return;
    }
    setState(() => _showPlusMenu = !_showPlusMenu);
  }

  // ========== 整张纸的偏移量 ==========

  double _paperOffsetValue() {
    final w = MediaQuery.of(context).size.width * _sidebarFraction;
    if (_isDragging) return _paperOffset;
    if (_isOpen) return _paperOffset > 0 ? w * _paperCtrl.value : -w * _paperCtrl.value;
    return 0;
  }

  // ========== 全局触摸角度判定 ==========

  void _onPointerDown(PointerDownEvent e) {
    _isDragging = false;
    _claimed = false;
    _startX = e.position.dx;
    _startY = e.position.dy;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_showPlusMenu) return;
    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_claimed) {
      if (dx.abs() < 4 && dy.abs() < 4) return;
      // 只要包含水平分量（不是纯垂直）→ 纸张滑动
      if (dy.abs() > dx.abs() * 3) {
        // 纯垂直 → 不拦截
        return;
      }
      _claimed = true;
      _isDragging = true;
    }

    if (!_isDragging) return;

    // 只在中间页区域拖纸张（侧栏区域不拦截）
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sidebarFraction;
    if (_paperOffset > 0 || (_isOpen && _paperCtrl.value > 0.5)) {
      // 左页展开中，中间页被推到右边
      if (e.position.dx < sideW) return; // 手指在左侧页区域，不拦截
    } else if (_paperOffset < 0 || (_isOpen && _paperCtrl.value > 0.5)) {
      // 右页展开中
      if (e.position.dx > screenW - sideW) return; // 手指在右侧页区域，不拦截
    }

    setState(() {
      _paperOffset += e.position.dx - _startX;
      final maxW = screenW * _sidebarFraction;
      _paperOffset = _paperOffset.clamp(-maxW, maxW);
    });
    _startX = e.position.dx;
    _startY = e.position.dy;
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!_claimed || !_isDragging) {
      _isDragging = false;
      _claimed = false;
      _paperOffset = 0;
      return;
    }

    final screenW = MediaQuery.of(context).size.width;
    final maxW = screenW * _sidebarFraction;
    final threshold = maxW * 0.30;

    if (!_isOpen) {
      // 中间页 → 滑动到哪边展开哪边
      if (_paperOffset > threshold) {
        _isOpen = true;
        _paperCtrl.forward(from: (_paperOffset / maxW).clamp(0.0, 1.0));
      } else if (_paperOffset < -threshold) {
        _isOpen = true;
        _paperCtrl.forward(from: (-_paperOffset / maxW).clamp(0.0, 1.0));
      }
    } else {
      // 已展开 → 反方向收回
      if ((_paperOffset > 0 && _paperOffset < -threshold) ||
          (_paperOffset < 0 && _paperOffset > threshold)) {
        _snapToCenter();
        setState(() { _paperOffset = 0; _isDragging = false; _claimed = false; });
        return;
      }
      // 弹回完全展开
      _paperCtrl.forward();
    }

    setState(() {
      _paperOffset = 0;
      _isDragging = false;
      _claimed = false;
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
    _paperCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sidebarFraction;
    final off = _paperOffsetValue();

    // 三页构成的纸张宽度 = 屏幕宽 + 2 * 侧栏宽
    final windowLeft = sideW + off;

    return Stack(
      children: [
        // ===== 一张纸（左中右连在一起） =====
        // 整张纸的宽度 = 侧栏宽 + 屏幕宽 + 侧栏宽
        // 通过窗口偏移来展示不同部分
        ClipRect(
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: Stack(
              children: [
                // 左页
                Positioned(
                  left: windowLeft - sideW, // 相对窗口的左页位置
                  top: 0,
                  width: sideW,
                  height: double.infinity,
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

                // 中间页
                Positioned(
                  left: windowLeft, // 相对窗口的中间页位置
                  top: 0,
                  width: screenW,
                  height: double.infinity,
                  child: Scaffold(
                    backgroundColor: const Color(0xFFF5EEF0),
                    body: SafeArea(
                      child: Column(
                        children: [
                          ChatTopBar(
                            currentLead: _currentLead,
                            currentPersona: _currentPersona,
                            onAvatarTap: _openCharacterWorld,
                            onMenuTap: () {
                              if (!_isOpen) {
                                _isOpen = true;
                                _paperCtrl.forward();
                              }
                            },
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
                ),

                // 右页
                Positioned(
                  left: windowLeft + screenW, // 相对窗口的右页位置
                  top: 0,
                  width: sideW,
                  height: double.infinity,
                  child: Container(
                    color: const Color(0xFFDCE4EE),
                    child: const ChatSidebarRight(),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ===== 全局触摸监听器 =====
        Positioned.fill(
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
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
}
