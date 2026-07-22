import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/male_lead.dart';
import '../../services/character_service.dart';
import '../../services/local_storage_service.dart';
import '../../models/chat_message.dart';
import '../../utils/debug_logger.dart';
import 'services/ai_chat_service.dart';
import 'state/current_character_state.dart';
import 'widgets/chat_sidebar_left.dart';
import 'widgets/chat_sidebar_right.dart';
import 'widgets/chat_top_bar.dart';
import 'widgets/chat_message_area.dart';
import 'widgets/chat_input_bar.dart';
import 'widgets/plus_menu.dart';
import 'widgets/character_world_page.dart';

/// 聊天主页面 —— 三页连续空间手势（v8 状态机版）
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

  // ---- 状态 ----
  double _offset = 0;
  Panel _currentPanel = Panel.center;

  // ---- 角色 —— 全部从 _state 读取 ----
  final _state = CurrentCharacterState();
  final _aiSvc = AiChatService();
  bool _showPlus = false;
  final GlobalKey<ChatMessageAreaState> _msgKey = GlobalKey();
  final _localStore = LocalStorageService();

  /// 当前聊天背景 — 从 _state 实时读
  File? get _currentBg {
    return _state.bgFile;
  }

  @override
  void initState() {
    super.initState();
    _localStore.init();
    DebugLogger.init();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onAnimTick);
    _state.addListener(() { if (mounted) setState(() {}); });
    _load();
  }

  Future<void> _load() async {
    await _state.init();
    if (!mounted) return;
    if (_state.characterService.leads.isEmpty) {
      await _state.createLeadWithDefaultPersona('沈星回');
    }
    await _state.tryAutoSelect();
    await DebugLogger.log('CHAT', '_load done, hasLead=${_state.hasLead}');
    if (mounted) setState(() {});
  }

  // ---- 手势 ----
  bool _dragging = false;
  double _dragBase = 0;
  Panel _startPanel = Panel.center;
  double _startX = 0, _startY = 0;
  bool _horizLocked = false;
  int _pointerId = -1;

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

  /// 强制复位手势状态（在 FilePicker 返回后调用，防止 pointerId 残留导致手势卡死）
  void _resetGestureState() {
    _pointerId = -1;
    _dragging = false;
    _horizLocked = false;
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
    _state.setCurrent(l, p);
    _currentPanel = Panel.center;
    _animateTo(0);
    HapticFeedback.lightImpact();
  }

  Future<void> _sendMsg(String t) async {
    _msgKey.currentState?.appendMessage(ChatMessage(id: DateTime.now().millisecondsSinceEpoch.toString(), text: t, isMe: true));
    final r = await _aiSvc.generateReply(t, _state.personaId ?? 'd');
    _msgKey.currentState?.appendMessage(ChatMessage(id: '${DateTime.now().millisecondsSinceEpoch}_ai', text: r, isMe: false));
  }

  void _openWorld() {
    if (!_state.hasLead) return;
    final lid = _state.lead!.id;
    final pid = _state.persona?.id ?? '${lid}_default';
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => CharacterWorldPage(
        lead: _state.lead!,
        persona: _state.persona ?? Persona(id: pid, maleLeadId: lid, name: '默认'),
      ),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      transitionDuration: const Duration(milliseconds: 300),
    ));
  }

  Future<void> _pickBgImage() async {
    await DebugLogger.log('BG', 'pickBgImage start');
    // 先关 plus 菜单（防止卡死）
    _showPlus = false;
    setState(() {});
    // 给一帧让 UI 刷新，确保 plus 菜单完全消失
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      // FilePicker 返回后强制复位手势状态（防止 pointerId 残留）
      _resetGestureState();
      if (result == null || result.files.single.path == null) return;
      final file = result.files.single;
      if (!_state.hasLead || !_state.hasPersona) return;

      String saved;
      if (file.bytes != null) {
        saved = await _localStore.saveBackgroundFromBytes(_state.leadId!, _state.personaId!, file.bytes!);
      } else {
        saved = await _localStore.saveBackground(_state.leadId!, _state.personaId!, File(file.path!));
      }
      await _state.updateBackground(saved);
      await DebugLogger.log('BG', 'pickBgImage done path=$saved');
    } catch (e) {
      _resetGestureState();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('背景设置失败：$e'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  // 从加号菜单更换头像
  Future<void> _pickAvatarFromPlus() async {
    // 先关 plus 菜单（防止卡死）+ 复位手势
    _showPlus = false;
    _resetGestureState();
    setState(() {});
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      // FilePicker 返回后强制复位手势状态
      _resetGestureState();
      if (result == null || result.files.single.path == null) return;
      final file = result.files.single;
      if (!_state.hasLead || !_state.hasPersona) return;

      String savedPath;
      if (file.bytes != null) {
        savedPath = await _localStore.savePersonaAvatarFromBytes(_state.leadId!, _state.personaId!, file.bytes!);
      } else {
        savedPath = await _localStore.savePersonaAvatar(_state.leadId!, _state.personaId!, File(file.path!));
      }
      await _state.updateAvatar(savedPath);
    } catch (e) {
      _resetGestureState();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('头像设置失败：$e'), duration: const Duration(seconds: 2)),
        );
      }
    }
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
            currentLead: _state.lead,
            currentPersona: _state.persona,
            onSelectPersona: (entry) => _selectPersona(entry.key, entry.value),
            onOpenSettings: () { _currentPanel = Panel.right; _animateTo(-sideW); },
            onSetBg: _pickBgImage,
            characterState: _state,
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
              child: Column(
                children: [
                  ChatTopBar(currentLead: _state.lead, currentPersona: _state.persona,
                    onTapAvatar: _openWorld, onMenuTap: () { _currentPanel = Panel.right; _animateTo(-sideW); },
                    onNameChanged: () { if (mounted) setState(() {}); }),
                  Expanded(child: ChatMessageArea(key: _msgKey, currentPersona: _state.persona,
                    characterAvatarPath: _state.effectiveAvatarPath,
                    onAvatarTap: _openWorld)),
                  ChatInputBar(onCameraTap: () {}, onVoiceTap: () {},
                    onPlusTap: _togglePlus, onSendTap: _sendMsg),
                ],
              ),
            ),
          ),
        ),

        // ===== 聊天背景图（毛玻璃，在中间页顶层） =====
        if (_currentBg != null)
          Positioned.fill(
            left: _offset,
            child: IgnorePointer(
              child: ClipRRect(
                child: Stack(
                  children: [
                    // 背景原图
                    Image.file(_currentBg!, fit: BoxFit.cover,
                      width: screenW,
                      height: MediaQuery.of(context).size.height,
                    ),
                    // 毛玻璃遮罩（更透的粉色）
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                        child: Container(color: const Color(0xFFF5EEF0).withValues(alpha: 0.15)),
                      ),
                    ),
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
            currentLead: _state.lead,
            currentPersona: _state.persona,
            onDelete: () {
              _state.deleteCurrent();
              if (_state.characterService.leads.isEmpty) {
                _state.createLeadWithDefaultPersona('沈星回');
              } else {
                _state.tryAutoSelect();
              }
              _currentPanel = Panel.center;
              _animateTo(0);
            },
            characterState: _state,
          ),
        ),

        // ===== 全屏手势监听 =====
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onDown,
            onPointerMove: (e) {
              if (_pointerId >= 0) _onMove(e);
            },
            onPointerUp: _onUp,
          ),
        ),

        // ===== [+] 菜单 =====
        if (_showPlus)
          Positioned.fill(child: PlusMenu(
            onDismiss: () => setState(() => _showPlus = false),
            onPickAvatar: _pickAvatarFromPlus,
            onPickBg: _pickBgImage,
          )),

        // ===== 调试日志按钮（右上角） =====
        Positioned(
          right: 4, top: MediaQuery.of(context).padding.top + 4,
          child: GestureDetector(
            onTap: _showDebugLog,
            child: Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: Colors.black26, shape: BoxShape.circle,
              ),
              child: const Icon(Icons.bug_report, size: 16, color: Colors.white70),
            ),
          ),
        ),
      ],
    );
  }

  void _showDebugLog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (ctx, scrollCtrl) => Container(
          color: const Color(0xFF1A1A2E),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('🪲 调试日志', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭', style: TextStyle(color: Colors.white70))),
                ],
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollCtrl,
                  child: SelectableText(
                    DebugLogger.recentLogsText.isEmpty ? '暂无日志' : DebugLogger.recentLogsText,
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageWidget({
    required int index,
    required double left,
    required double width,
    required Color color,
    required Widget child,
  }) {
    return Positioned(
      left: left, top: 0,
      width: width, bottom: 0,
      child: Container(
        color: color,
        child: child,
      ),
    );
  }
}
