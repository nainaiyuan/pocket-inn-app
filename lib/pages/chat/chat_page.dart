import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../ai_provider/models.dart';
import '../../models/male_lead.dart';
import '../../services/character_service.dart';
import '../../services/chat_service.dart';
import '../../services/local_storage_service.dart';
import '../../models/chat_message.dart';
import '../../utils/debug_logger.dart';
import '../ai_config_page.dart';
import 'services/ai_chat_service.dart';
import 'state/chat_presence.dart';
import 'state/current_character_state.dart';
import 'widgets/ai_provider_sheet.dart';
import 'widgets/chat_sidebar_left.dart';
import 'widgets/chat_sidebar_right.dart';
import 'widgets/chat_top_bar.dart';
import 'widgets/chat_message_area.dart';
import 'widgets/character_world_page.dart';
import 'widgets/chat_input_bar.dart';
import 'widgets/debug_log_sheet.dart';
import 'widgets/plus_menu.dart';

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
    _state.addListener(_onStateChanged);
    _load();
  }

  void _onStateChanged() {
    if (!mounted) return;
    if (_state.needsGestureReset) {
      DebugLogger.log('GESTURE', 'reset from state');
      _resetGestureState();
      _state.consumeGestureReset();
    }
    DebugLogger.log('CHAT', 'rebuild from state notify');
    setState(() {});
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
    // 安全兜底：如果 _pointerId 已经被释放但状态残留，直接重置
    if (_pointerId >= 0 && _pointerId != e.pointer) {
      _pointerId = -1;
      _dragging = false;
      _horizLocked = false;
    }
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
    final userMsgId = DateTime.now().millisecondsSinceEpoch.toString();
    _msgKey.currentState?.appendMessage(ChatMessage(id: userMsgId, text: t, isMe: true));
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    // 拟人化：用户消息未读 → 男主开始"正在输入"
    ChatPresence.instance.markUnread(userMsgId);
    ChatPresence.instance.setTyping(true);
    try {
      // ===== 管家管线：技能触发 → 假面替换 → 情绪记录（流程树可见）=====
      String sendText = t;
      String? skillInjection;
      try {
        final pipeline = await ChatService.instance.runButlerPipeline(
          userText: t,
          characterId: personaId,
          characterName: personaName,
        );
        sendText = pipeline.maskedText;
        skillInjection = pipeline.skillInjection;
      } catch (e) {
        // 管家失败不阻断聊天，只记日志
        DebugLogger.log('管家流程', '✖ 管家管线异常（不阻断聊天）: $e');
      }
      final result = await _aiSvc.generateReply(
        sendText,
        personaId,
        personaName: personaName,
        skillContext: skillInjection,
      );
      _msgKey.currentState?.appendMessage(ChatMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}_ai',
        text: result.text.trim(),
        isMe: false,
      ));
      // 男主回复完成：全部已读 + 停止输入
      ChatPresence.instance.markAllRead();
      if (result.failedProviders.isNotEmpty) {
        // 自动切换发生了，告诉用户一声（不打断）
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${result.failedProviders.join('、')} 不可用，已自动切换到 ${result.providerName ?? '下一个'}'),
          duration: const Duration(seconds: 3),
        ));
      }
    } on AIProviderUnavailableException catch (e) {
      // 用户关了自动切换 → 弹窗，不偷偷换人
      DebugLogger.log('AI路由', '❌ ${e.providerName} 不可用（自动切换已关闭）: ${e.cause}');
      await _showAiUnavailableDialog(e);
    } on AIAllProvidersFailedException catch (e) {
      DebugLogger.log('AI路由', '❌ 所有候选都失败: ${e.tried.join('、')}');
      await _showAllAiFailedDialog(e);
    } on Object catch (e) {
      DebugLogger.log('AI路由', '❌ 聊天请求失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('发送失败：$e'),
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      // 无论如何：停止"正在输入"（失败则保持未读，男主没读到）
      ChatPresence.instance.setTyping(false);
    }
  }

  /// 自动切换关闭时的弹窗：告诉用户当前 AI 不可用，让 ta 检查。
  Future<void> _showAiUnavailableDialog(AIProviderUnavailableException e) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('当前 AI 不可用'),
        content: Text(
          '「${e.providerName}」连不上或出错了：\n\n${e.cause}\n\n'
          '你可以去「管家 → AI 配置」检查 Key / 地址，或在这里开启自动切换。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('再试一次'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openAiConfig();
            },
            child: const Text('去检查配置'),
          ),
        ],
      ),
    );
  }

  /// 全部候选都失败时的弹窗。
  Future<void> _showAllAiFailedDialog(AIAllProvidersFailedException e) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('所有 AI 都不可用'),
        content: Text(
          e.tried.isEmpty
              ? '当前没有可用的 AI Provider。\n请去「管家 → AI 配置」检查或配置。'
              : '试了这些都不行：${e.tried.join('、')}\n\n'
                  '请去「管家 → AI 配置」检查 Key / 地址。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openAiConfig();
            },
            child: const Text('去检查配置'),
          ),
        ],
      ),
    );
  }

  void _openAiConfig() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AiConfigPage()),
    );
  }

  /// 打开 AI 设置弹层（当前 AI / 自动切换 / 候选勾选）。
  Future<void> _openAiSheet() async {
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    await showAiProviderSheet(
      context: context,
      personaId: personaId,
      personaName: personaName,
    );
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

  // 从加号菜单设置全局聊天背景（影响立绘下所有未单独设背景的 Persona）
  Future<void> _pickBgImage() async {
    await DebugLogger.log('BG', 'pickBgImage start');
    // 先关 plus 菜单（防止卡死）
    _showPlus = false;
    _resetGestureState();
    setState(() {});
    // 给一帧让 UI 刷新，确保 plus 菜单完全消失
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      // FilePicker 返回后强制复位手势状态（防止 pointerId 残留）
      _resetGestureState();
      if (result == null || result.files.single.path == null) return;
      final file = result.files.single;
      if (!_state.hasLead) return;

      // 保存为立绘级别的背景文件
      String saved;
      if (file.bytes != null) {
        saved = await _localStore.saveLeadBackgroundFromBytes(_state.leadId!, file.bytes!);
      } else {
        saved = await _localStore.saveLeadBackground(_state.leadId!, File(file.path!));
      }
      // 清 Flutter 图片缓存，强制背景重新解码
      imageCache.clear();
      imageCache.clearLiveImages();
      await _state.updateLeadBackground(saved);
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
                    onAiTap: _openAiSheet,
                    onNameChanged: () { if (mounted) setState(() {}); }),
                  // 聊天消息区域（背景图放在这里，精确对齐内容区）
                  Expanded(
                    child: Stack(
                      children: [
                        // 聊天背景图（放在消息区域底层）
                        if (_currentBg != null)
                          Positioned.fill(
                            child: ClipRRect(
                              child: Stack(
                                children: [
                                  Image.file(_currentBg!, fit: BoxFit.cover,
                                    width: screenW,
                                    height: MediaQuery.of(context).size.height,
                                    key: ValueKey('bg_${_currentBg!.path}_${_currentBg!.lastModifiedSync().millisecondsSinceEpoch}'),
                                  ),
                                  Positioned.fill(
                                    child: BackdropFilter(
                                      filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                                      child: Container(color: Colors.black.withValues(alpha: 0.08)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        // 消息列表在背景之上
                        ChatMessageArea(key: _msgKey, currentPersona: _state.persona,
                          characterAvatarPath: _state.effectiveAvatarPath,
                          onAvatarTap: _openWorld,
                          ),
                      ],
                    ),
                  ),
                  ChatInputBar(onCameraTap: () {}, onVoiceTap: () {},
                    onPlusTap: _togglePlus, onSendTap: _sendMsg),
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
            onClosePanel: () {
              _currentPanel = Panel.center;
              _animateTo(0);
              // 删除 Persona 后强制重建（左页/右页/中间页状态一致）
              WidgetsBinding.instance.addPostFrameCallback((_) => setState(() {}));
            },
            onClearChat: () => _msgKey.currentState?.reloadMessages(),
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

        // ===== 📄 prompt 查看按钮（透明化：男主"知道什么"一目了然）=====
        Positioned(
          right: 38, top: MediaQuery.of(context).padding.top + 4,
          child: GestureDetector(
            onTap: _showPromptDialog,
            child: Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: Colors.black26, shape: BoxShape.circle,
              ),
              child: const Icon(Icons.description_outlined, size: 15, color: Colors.white70),
            ),
          ),
        ),

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
    showDebugLogSheet(context);
  }

  /// 查看最近一次发给男主的完整 prompt（透明化：男主"知道什么"一目了然）
  void _showPromptDialog() {
    final promptText = _aiSvc.lastPromptText;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '发给男主的完整内容',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: promptText == null || promptText.isEmpty
              ? const Center(
                  child: Text(
                    '还没有记录。\n先和男主聊一句，这里就能看到\n他收到的完整信息。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black45,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    promptText,
                    style: const TextStyle(
                      color: Color(0xFF6A4A5A),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭', style: TextStyle(color: Color(0xFFC896B4))),
          ),
        ],
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
    // 中间页(index=1)：当 _offset 偏移超过侧栏30%时禁用交互
    final isCenter = index == 1;
    final panelOpen = _offset.abs() > _sideW * _snapThr;
    return Positioned(
      left: left, top: 0,
      width: width, bottom: 0,
      child: Container(
        color: color,
        child: (isCenter && panelOpen) ? IgnorePointer(child: child) : child,
      ),
    );
  }
}
