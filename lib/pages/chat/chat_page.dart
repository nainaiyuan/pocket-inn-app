import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
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

/// 聊天主页面 —— 三页连续空间手势（v8 状态机版）
///
/// 手势系统：
/// - 全屏 Listener（只读，不消费事件）
/// - 方向锁定后分水平（切页）/ 垂直（滚 ListView）
/// - 触摸坐标实时推算滚动归属
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

enum Panel { left, center, right }

class _ChatPageState extends State<ChatPage> with SingleTickerProviderStateMixin {
  static const double _sideFrac = 0.65;
  static const double _snapThr = 0.30;
  static const double _lockThr = 8.0;
  static const double _closeFactor = 2.5;

  // ---- 唯一状态 ----
  double _offset = 0;
  Panel _currentPanel = Panel.center;

  // ---- 角色 ----
  final _charSvc = CharacterService();
  final _aiSvc = AiChatService();
  MaleLead? _lead;
  Persona? _persona;
  bool _showPlus = false;
  final GlobalKey<ChatMessageAreaState> _msgKey = GlobalKey();
  File? _bgImage; // 背景图（可选，按 persona id 存储）

  // 获取当前背景图
  File? get _currentBg {
    final pid = _persona?.id;
    if (pid == null) return _bgImage;
    return _bgImages[pid] ?? _bgImage;
  }

  final Map<String, File> _bgImages = {}; // personaId → 背景图

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onAnimTick);
    _load();
  }

  Future<void> _load() async {
    try { await _charSvc.load(); } catch (_) {}
    if (!mounted) return;
    final ls = _charSvc.leads;
    if (ls.isNotEmpty) {
      setState(() { _lead = ls.first; _persona = ls.first.personas.isNotEmpty ? ls.first.personas.first : null; });
    } else {
      await _charSvc.addMaleLead(MaleLead(id: 'd', name: '沈星回'));
      if (!mounted) return;
      await _charSvc.load();
      if (_charSvc.leads.isNotEmpty && mounted)
        setState(() { _lead = _charSvc.leads.first; _persona = _charSvc.leads.first.personas.isNotEmpty ? _charSvc.leads.first.personas.first : null; });
    }
  }

  // ---- 手势 ----
  bool _dragging = false;
  double _dragBase = 0;
  Panel _startPanel = Panel.center;
  double _startX = 0, _startY = 0;
  bool _horizLocked = false;
  int _pointerId = -1;

  // ---- 动画 ----
  late AnimationController _anim;
  double _animStart = 0, _animEnd = 0;

  double get _sideW => MediaQuery.of(context).size.width * _sideFrac;

  void _onAnimTick() {
    if (_dragging) return;
    setState(() {
      _offset = _animStart + (_animEnd - _animStart) * _anim.value;
    });
  }

  void _animateTo(double target) {
    _animStart = _offset;
    _animEnd = target;
    _anim
      ..value = 0
      ..forward();
  }

  void _onDown(PointerDownEvent e) {
    if (_showPlus) return;
    if (_pointerId >= 0) return;
    _pointerId = e.pointer;
    _startX = e.position.dx;
    _startY = e.position.dy;

    _anim.stop();
    if (_anim.value > 0 && _anim.value < 1) {
      _offset = _animStart + (_animEnd - _animStart) * _anim.value;
    }

    _dragBase = _offset;
    _startPanel = _currentPanel;
    _dragging = false;
    _horizLocked = false;
    setState(() {});
  }

  void _onMove(PointerMoveEvent e) {
    if (_showPlus) return;
    if (e.pointer != _pointerId) return;

    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_horizLocked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _horizLocked = dx.abs() > dy.abs() * 1.3;
      if (!_horizLocked) {
        setState(() {});
        return;
      }
      _dragging = true;
    }

    if (!_dragging) return;

    double factor = 1.0;
    final goingBack = (_startPanel == Panel.left && dx < 0) ||
                      (_startPanel == Panel.right && dx > 0);
    if (_startPanel != Panel.center && goingBack) {
      factor = _closeFactor;
    }

    double lo, hi;
    switch (_startPanel) {
      case Panel.left:   lo = 0; hi = _sideW; break;
      case Panel.right:  lo = -_sideW; hi = 0; break;
      case Panel.center: lo = -_sideW; hi = _sideW; break;
    }

    setState(() {
      _offset = (_dragBase + dx * factor).clamp(lo, hi);
    });
  }

  void _onUp(PointerUpEvent e) {
    if (_showPlus) return;
    if (_pointerId != e.pointer) return;
    _pointerId = -1;

    if (!_dragging) { _horizLocked = false; setState(() {}); return; }

    _dragging = false;
    _horizLocked = false;

    double target;
    Panel nextPanel;

    switch (_startPanel) {
      case Panel.center:
        if (_offset.abs() < _sideW * _snapThr) {
          target = 0; nextPanel = Panel.center;
        } else if (_offset > 0) {
          target = _sideW; nextPanel = Panel.left;
        } else {
          target = -_sideW; nextPanel = Panel.right;
        }
        break;
      case Panel.left:
        if (_offset < _sideW * (1 - _snapThr)) {
          target = 0; nextPanel = Panel.center;
        } else {
          target = _sideW; nextPanel = Panel.left;
        }
        break;
      case Panel.right:
        if (_offset > -_sideW * (1 - _snapThr)) {
          target = 0; nextPanel = Panel.center;
        } else {
          target = -_sideW; nextPanel = Panel.right;
        }
        break;
    }

    _currentPanel = nextPanel;
    _animateTo(target);
  }

  // ---- 功能 ----

  void _togglePlus() {
    if (_currentPanel != Panel.center) { setState(() { _currentPanel = Panel.center; }); _animateTo(0); return; }
    setState(() => _showPlus = !_showPlus);
  }

  void _selectPersona(MaleLead l, Persona p) {
    setState(() { _lead = l; _persona = p; });
    _currentPanel = Panel.center;
    _animateTo(0);
    HapticFeedback.lightImpact();
  }

  Future<void> _sendMsg(String t) async {
    _msgKey.currentState?.appendMessage(ChatMessage(id: DateTime.now().millisecondsSinceEpoch.toString(), text: t, isMe: true));
    final r = await _aiSvc.generateReply(t, _persona?.id ?? 'd');
    _msgKey.currentState?.appendMessage(ChatMessage(id: '${DateTime.now().millisecondsSinceEpoch}_ai', text: r, isMe: false));
  }

  void _openWorld() {
    if (_lead == null || _persona == null) return;
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => CharacterWorldPage(lead: _lead!, persona: _persona!),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      transitionDuration: const Duration(milliseconds: 300),
    ));
  }

  // 选择聊天背景图
  Future<void> _pickBgImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result != null && result.files.single.path != null) {
      final img = File(result.files.single.path!);
      setState(() {
        final pid = _persona?.id;
        if (pid != null) {
          _bgImages[pid] = img;
        } else {
          _bgImage = img;
        }
      });
    }
  }

  // ---- 实时推算滚动归属 ----
  int _calcScrollPage() {
    if (_pointerId < 0) {
      switch (_currentPanel) {
        case Panel.left:   return 0;
        case Panel.right:  return 2;
        case Panel.center: return 1;
      }
    }
    if (_offset > 0 && _startX < _offset) return 0;
    if (_offset < 0 && _startX > MediaQuery.of(context).size.width + _offset) return 2;
    return 1;
  }

  @override
  void dispose() {
    _anim.removeListener(_onAnimTick);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sideFrac;

    return Stack(
      children: [
        // ===== 左页 =====
        _pageWidget(
          index: 0,
          left: _offset - sideW,
          width: sideW,
          color: const Color(0xFFEED9DC),
          child: ChatSidebarLeft(
            currentLead: _lead,
            currentPersona: _persona,
            onSelectPersona: (entry) => _selectPersona(entry.key, entry.value),
            onOpenSettings: () { _currentPanel = Panel.right; _animateTo(-sideW); },
            onSetBg: _pickBgImage,
          ),
        ),

        // ===== 中间页（聊天）=====
        _pageWidget(
          index: 1,
          left: _offset,
          width: screenW,
          color: const Color(0xFFF5EEF0),
          child: Material(
            color: Colors.transparent,
            child: SafeArea(
              child: Stack(
                children: [
                  // 背景图（毛玻璃遮罩）
                  Positioned.fill(
                    child: _currentBg != null
                        ? ClipRRect(
                            child: Stack(
                              children: [
                                Image.file(_currentBg!, fit: BoxFit.cover, width: screenW, height: double.infinity),
                                Positioned.fill(
                                  child: BackdropFilter(
                                    filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                                    child: Container(color: const Color(0xFFF5EEF0).withValues(alpha: 0.4)),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  // 聊天内容
                  Column(children: [
                    ChatTopBar(currentLead: _lead, currentPersona: _persona,
                      onAvatarTap: _openWorld, onMenuTap: () { _currentPanel = Panel.right; _animateTo(-sideW); }),
                    Expanded(child: ChatMessageArea(key: _msgKey, currentPersona: _persona)),
                    ChatInputBar(onCameraTap: () {}, onVoiceTap: () {},
                      onPlusTap: _togglePlus, onSendTap: _sendMsg),
                  ]),
                ],
              ),
            ),
          ),
        ),

        // ===== 右页 =====
        _pageWidget(
          index: 2,
          left: screenW + _offset,
          width: sideW,
          color: const Color(0xFFDCE4EE),
          child: ChatSidebarRight(
            currentLead: _lead,
            currentPersona: _persona,
            onDelete: () {
              // 删完后切到第一个可用角色
              final ls = _charSvc.leads;
              if (ls.isNotEmpty) {
                final firstLead = ls.first;
                final firstPersona = firstLead.personas.isNotEmpty
                    ? firstLead.personas.first
                    : Persona(id: '${firstLead.id}_default', maleLeadId: firstLead.id, name: '默认');
                setState(() {
                  _lead = firstLead;
                  _persona = firstPersona;
                });
              }
              _currentPanel = Panel.center;
              _animateTo(0);
            },
          ),
        ),

        // ===== 全屏手势监听 =====
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
          ),
        ),

        // ===== [+] 菜单 =====
        if (_showPlus)
          Positioned.fill(child: PlusMenu(onDismiss: () => setState(() => _showPlus = false))),
      ],
    );
  }

  Widget _pageWidget({
    required int index,
    required double left,
    required double width,
    required Color color,
    required Widget child,
  }) {
    final isActive = _calcScrollPage() == index;
    return Positioned(
      left: left, top: 0,
      width: width, bottom: 0,
      child: Container(
        color: color,
        child: AbsorbPointer(
          absorbing: !isActive,
          child: child,
        ),
      ),
    );
  }
}
