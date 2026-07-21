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

/// 聊天主页面 —— 二维手势空间
///
/// 一个连续空间：左页 | 中页 | 右页
/// 手指拖到哪，页面跟到哪，松手吸附展开/收回。
///
/// 手势系统：
/// - Listener 全屏只读监听（不消费事件，不影响 ListView 滚动）
/// - PointerDown 记录 startX/startY
/// - PointerMove 判定方向后锁定：
///   水平锁 → 更新 _offset，页面跟随手指
///   垂直锁 → 不做任何事，事件自然透给 ListView
/// - PointerUp 判断吸附（超过 40% 展开，不足弹回）
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  // ---- 偏移状态（ValueNotifier 避免全局 rebuild）----
  final ValueNotifier<double> _offsetNotifier = ValueNotifier(0);
  int _snapTarget = 0; // 吸附目标：0=中间，1=左，-1=右
  late AnimationController _animCtrl;

  // ---- 手势 ----
  double _startX = 0, _startY = 0;
  bool _locked = false;
  bool _horiz = false; // true=横向锁定，false=纵向
  bool _active = false;
  bool _wasLockedHoriz = false; // 记录本次手势是否锁定了横向（用于 PointerUp）

  // ---- 角色 ----
  final _charSvc = CharacterService();
  final _aiSvc = AiChatService();
  MaleLead? _lead;
  Persona? _persona;
  bool _showPlus = false;
  final GlobalKey<ChatMessageAreaState> _msgKey = GlobalKey();

  static const double _sideFrac = 0.65;
  static const double _snapThr = 0.40;
  static const double _lockThr = 8.0;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() { if (mounted) setState(() {}); });
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

  double get _sideW => MediaQuery.of(context).size.width * _sideFrac;

  double _getOff() {
    if (_active) return _offsetNotifier.value;
    return _snapTarget * _sideW * _animCtrl.value;
  }

  void _snapTo(int t) { _snapTarget = t; _animCtrl.forward(from: 0); }
  void _snapBack() { _animCtrl.reverse().then((_) { if (mounted) setState(() { _snapTarget = 0; _offsetNotifier.value = 0; }); }); }

  void _togglePlus() { if (_snapTarget != 0) { _snapBack(); return; } setState(() => _showPlus = !_showPlus); }
  void _selectPersona(MaleLead l, Persona p) { setState(() { _lead = l; _persona = p; }); _snapBack(); HapticFeedback.lightImpact(); }

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

  // ---- Listener 手势（只读，不消费事件）----

  void _onDown(PointerDownEvent e) {
    if (_showPlus) return;
    _startX = e.position.dx;
    _startY = e.position.dy;
    _locked = false;
    _horiz = false;
    _active = false;
    _wasLockedHoriz = false;
    _animCtrl.stop();
  }

  void _onMove(PointerMoveEvent e) {
    if (_showPlus) return;
    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_locked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _locked = true;
      _horiz = dx.abs() > dy.abs();
      if (_horiz) {
        _active = true;
        _wasLockedHoriz = true;
        // 水平锁定：取当前 offset 作为起始
        _offsetNotifier.value = _snapTarget * _sideW;
      }
      return;
    }

    if (!_horiz) return; // 垂直锁定，透给 ListView

    // 水平锁定：更新偏移，跟随手指
    // 直接用当前 position 计算偏移（不用增量，更精确）
    final totalDx = e.position.dx - _startX;
    final base = _snapTarget * _sideW;
    _offsetNotifier.value = (base + totalDx).clamp(-_sideW, _sideW);
  }

  void _onUp(PointerUpEvent e) {
    if (!_wasLockedHoriz) {
      // 垂直手势或未锁定 → 恢复状态
      _active = false;
      _locked = false;
      _wasLockedHoriz = false;
      return;
    }

    final sideW = _sideW;
    final off = _offsetNotifier.value;
    final absOff = off.abs();
    final isLeft = off > 0;

    if (_snapTarget == 0) {
      // 中间 → 展开
      if (absOff > sideW * _snapThr) {
        _snapTo(isLeft ? 1 : -1);
      } else {
        _snapBack();
      }
    } else {
      // 已展开 → 反方向收回
      if ((_snapTarget == 1 && off < sideW * (1 - _snapThr)) ||
          (_snapTarget == -1 && off > -sideW * (1 - _snapThr))) {
        _snapBack();
      } else {
        _snapTo(_snapTarget);
      }
    }

    _active = false;
    _locked = false;
    _wasLockedHoriz = false;
  }

  @override
  void dispose() { _animCtrl.dispose(); _offsetNotifier.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sideFrac;
    final showingLeft = _snapTarget == 1;
    final showingRight = _snapTarget == -1;

    return Stack(
      children: [
        // ===== 左页 =====
        Positioned(left: 0, top: 0, width: sideW, height: double.infinity,
          child: Container(color: const Color(0xFFEED9DC),
            child: IgnorePointer(ignoring: !showingLeft || _animCtrl.value < 0.95,
              child: ChatSidebarLeft(
                currentLead: _lead, currentPersona: _persona,
                onSelectPersona: (entry) => _selectPersona(entry.key, entry.value),
              ),
            ),
          ),
        ),

        // ===== 中间页（ValueNotifier 监听，只 rebuild Positioned）=====
        ListenableBuilder(
          listenable: _offsetNotifier,
          builder: (ctx, _) {
            final off = _getOff();
            return Positioned(
              left: off, top: 0, right: -off, bottom: 0,
              child: Material(
                color: const Color(0xFFF5EEF0),
                child: SafeArea(
                  child: Column(children: [
                    ChatTopBar(currentLead: _lead, currentPersona: _persona,
                      onAvatarTap: _openWorld, onMenuTap: () { _snapTo(1); }),
                    Expanded(child: ChatMessageArea(key: _msgKey, currentPersona: _persona)),
                    ChatInputBar(onCameraTap: () {}, onVoiceTap: () {},
                      onPlusTap: _togglePlus, onSendTap: _sendMsg),
                  ]),
                ),
              ),
            );
          },
        ),

        // ===== 右页 =====
        Positioned(right: 0, top: 0, width: sideW, height: double.infinity,
          child: Container(color: const Color(0xFFDCE4EE),
            child: IgnorePointer(ignoring: !showingRight || _animCtrl.value < 0.95,
              child: const ChatSidebarRight(),
            ),
          ),
        ),

        // ===== 全屏手势监听（Listener，不消费事件）=====
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
}
