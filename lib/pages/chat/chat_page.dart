import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../ai_provider/models.dart';
import '../../models/male_lead.dart';
import '../../services/character_service.dart';
import '../../services/chat_database_service.dart';
import '../../services/chat_memory_service.dart';
import '../../models/chat_memory.dart';
import '../../services/chat_service.dart';
import '../../services/butler_command.dart';
import '../../butler/context/context_tracker.dart';
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
    // 男主正在被调用（同一男主连续对话 → 上下文延续）
    if (personaId.isNotEmpty) {
      ContextTracker.instance.touch(personaId);
    }
    // 拟人化：用户消息未读 → 男主开始"正在输入"
    ChatPresence.instance.markUnread(userMsgId);
    ChatPresence.instance.setTyping(true);
    // 管家对话记录：隐式会话 + 消息落库（记忆提取的数据源）
    await _ensureChatSession(personaId, personaName);
    if (_chatSessionId != null) {
      try {
        final userNode = await ChatDatabaseService.instance.appendUserMessage(
          sessionId: _chatSessionId!,
          parentMessageId: _chatLeafId,
          text: t,
        );
        _chatLeafId = userNode.id;
      } catch (e) {
        DebugLogger.log('管家流程', '✖ 对话落库失败（用户消息）: $e');
      }
    }
    try {
      // ===== 管家管线：技能触发 → 假面替换 → 情绪记录（流程树可见）=====
      String sendText = t;
      String? skillInjection;
      String? keywordAsk;
      try {
        final pipeline = await ChatService.instance.runButlerPipeline(
          userText: t,
          characterId: personaId,
          characterName: personaName,
          // 37批：传真实会话 id → 每次新对话重新轮换代号（男主无法把代号绑定到人）
          sessionId: _chatSessionId ?? 'chat_page',
        );
        sendText = pipeline.maskedText;
        skillInjection = pipeline.skillInjection;
        keywordAsk = pipeline.keywordAsk;
      } catch (e) {
        // 管家失败不阻断聊天，只记日志
        DebugLogger.log('管家流程', '✖ 管家管线异常（不阻断聊天）: $e');
      }
      // 获准记忆注入（异步检索记忆库，按类别/条数）
      final recallInjection = _pendingRecall != null
          ? await _buildRecallInjectionAsync(_pendingRecall!)
          : const <String>[];
      // 工具调用轮（function calling）：模型请求工具 → 执行（弹窗审批）→ 回传 → 再生成
      var result = await _aiSvc.generateReply(
        sendText,
        personaId,
        personaName: personaName,
        personaPrompt: _currentPersonaPrompt(),
        sessionId: _chatSessionId,
        // 技能注入 + 温控询问 + 审批反馈 + 获准记忆 都拼进 system
        skillContext: [
          if (skillInjection != null) skillInjection,
          if (keywordAsk != null) keywordAsk,
          if (_pendingFeedback != null) _pendingFeedback!,
          ...recallInjection,
        ].join('\n'),
      );
      // 用完即清（反馈/记忆只注入一次）
      _pendingFeedback = null;
      _pendingRecall = null;
      _pendingRecallCategory = null;
      _pendingRecallLimit = null;
      // 收集男主各轮文本（第一轮 + 工具轮）——文本与工具可共存：
      // 模型第一轮既说话又调工具时，文本不丢，工具执行后合并显示
      final replyTexts = <String>[];
      if (result.text.trim().isNotEmpty) {
        replyTexts.add(result.text.trim());
      }
      // function calling 循环：模型请求工具 → 执行 → 回传 → 再生成（最多3轮防死循环）
      var toolLoop = 0;
      while (toolLoop < 3 &&
          result.toolCalls != null &&
          result.toolCalls!.isNotEmpty) {
        toolLoop++;
        final toolMessages = <AIChatMessage>[
          AIChatMessage(role: 'assistant', content: '', toolCalls: result.toolCalls),
        ];
        for (final call in result.toolCalls!) {
          final name = call['name']?.toString() ?? '';
          final args = (call['arguments'] as Map<String, dynamic>?) ?? {};
          String toolResult;
          if (name == 'record_memory') {
            final content = args['content']?.toString() ?? '';
            final category = args['category']?.toString() ?? '';
            _appendToolBubble('正在记录：「$content」（$category）…');
            toolResult = await _executeRecordTool(category, content);
          } else if (name == 'recall_memory') {
            final query = args['query']?.toString() ?? '';
            final category = args['category']?.toString() ?? '';
            _appendToolBubble('正在查记忆：$query…');
            toolResult = await _executeRecallTool(query, category);
          } else if (name == 'save_identity_memory') {
            // 37批：男主用原生工具写代号记忆（替代 #A# 文本协议，DeepSeek 更可靠）
            final code = args['code']?.toString() ?? '';
            final content = args['content']?.toString() ?? '';
            _appendToolBubble('男主想记住关于「$code」的事…');
            toolResult = await _executeSaveIdentityMemoryTool(code, content);
          } else if (name == 'list_tools') {
            toolResult = _executeListToolsTool();
          } else {
            toolResult = '未知工具：$name';
          }
          toolMessages.add(AIChatMessage(
            role: 'tool',
            content: toolResult,
            toolCallId: 'call_${toolLoop}_$name',
          ));
        }
        result = await _aiSvc.generateReply(
          '',
          personaId,
          personaName: personaName,
          personaPrompt: _currentPersonaPrompt(),
          toolRound: true,
          toolMessages: toolMessages,
          sessionId: _chatSessionId,
        );
        if (result.text.trim().isNotEmpty) {
          replyTexts.add(result.text.trim());
        }
      }

  // 剥离 #keywords（仅管家可见）→ 显示/落库用干净文本
      var displayText = ButlerPipelineResult.extractKeywordsFromReply(
        replyTexts.join('\n'),
      );
      // 指令模块：解析男主输出（#记录/#查记忆/#定时/#帮助/#model）→ 审批弹窗
      final commands =
          ButlerCommandParser.instance.parse(result.text.trim());
      // 静默执行：男主输出指令 → 先出工具气泡（🔧 正在…）→ 审批 → 男主干完活才说话
      for (final cmd in commands) {
        if (cmd.type == ButlerCommandParser.cmdRecord) {
          _appendToolBubble('正在记录：「${cmd.arg}」，等用户确认…');
          await _approveRecord(cmd.arg);
        } else if (cmd.type == ButlerCommandParser.cmdRecall) {
          _appendToolBubble('正在查记忆：${cmd.arg.isEmpty ? '全部' : cmd.arg}…');
          await _startRecallFlow(cmd.arg);
        } else {
          await _handleButlerCommand(cmd);
        }
      }
      // 剥离所有指令（#…#）→ 用户只看到男主自然的回复
      displayText = ButlerCommandParser.instance.strip(displayText);
      // 待定查询：男主回复"看5条/全部" → 继续审批流程
      if (_pendingQuery != null) {
        await _resolvePendingQuery(displayText);
      }
      // 假面层反向还原：男主回复里的代号 → 真名（"妈妈"不再显示为 [家人1]）
      try {
        final butler = ChatService.instance.butler;
        if (butler != null) {
          displayText = await butler.processIncoming(
            text: displayText,
            // 37批：与发送侧一致 → 同一会话内还原正确，新会话重新轮换代号
            sessionId: _chatSessionId ?? 'chat_page',
          );
        }
      } catch (e) {
        DebugLogger.log('管家流程', '✖ 代号还原失败: $e');
      }
      // 男主回复落库（静默执行时 displayText 为空 → 只记工具气泡，不记男主空回复）
      if (_chatSessionId != null && displayText.trim().isNotEmpty) {
        try {
          final aiNode = await ChatDatabaseService.instance.appendAssistantMessage(
            sessionId: _chatSessionId!,
            parentMessageId: _chatLeafId,
            text: displayText,
          );
          _chatLeafId = aiNode.id;
        } catch (e) {
          DebugLogger.log('管家流程', '✖ 对话落库失败（男主回复）: $e');
        }
      }
      if (displayText.trim().isNotEmpty) {
        _msgKey.currentState?.appendMessage(ChatMessage(
          id: '${DateTime.now().millisecondsSinceEpoch}_ai',
          text: displayText,
          isMe: false,
        ));
      }
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

  // ===== 管家对话记录（隐式会话 + 记忆提取）=====

  String? _chatSessionId;
  String? _chatLeafId;

  /// 待反馈给男主的审批结果（下轮注入 prompt：确认/拒绝/帮助文本）
  String? _pendingFeedback;

  /// 男主获准调取的记忆查询词（下轮注入检索到的记忆）
  String? _pendingRecall;

  /// 获准查询的类别（null = 关键词查询）
  String? _pendingRecallCategory;

  /// 获准查看的条数上限（null = 不限，取最近6条）
  int? _pendingRecallLimit;

  /// 待定查询（命中太多 → 等男主说想看几条）
  ({String query, String category, int total})? _pendingQuery;

  /// 插入管家工具气泡（🔧 正在…，男主头像下小气泡）
  /// 用 [tool] 前缀标记（freezed ChatMessage 不加字段，bubble 检测前缀渲染）
  void _appendToolBubble(String text) {
    _msgKey.currentState?.appendMessage(ChatMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}_tool',
      text: '[tool] $text',
      isMe: false,
    ));
  }

  /// 处理男主指令（#记录/#查记忆/#定时/#帮助/#model）→ 审批弹窗 → 反馈
  Future<void> _handleButlerCommand(ParsedCommand cmd) async {
    try {
      switch (cmd.type) {
        case ButlerCommandParser.cmdTimer:
          _pendingFeedback =
              '（用户说定时功能还在路上，先记下这个需求：${cmd.arg}）';
        case ButlerCommandParser.cmdHelp:
          _pendingFeedback = ButlerCommandParser.helpText;
        case ButlerCommandParser.cmdModel:
          final m = RegExp(r'(\S+)\s+(\d+)').firstMatch(cmd.arg);
          if (m != null) {
            final w = int.tryParse(m.group(2)!);
            if (w != null && w > 0) {
              ContextTracker.instance
                  .setWindow(_state.personaId ?? '', w);
            }
          }
      }
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 指令处理失败: $e');
    }
  }

  /// 记录审批：男主想记用户喜好 → 用户确认/拒绝 → 反馈男主
  Future<void> _approveRecord(String content) async {
    if (content.isEmpty) return;
    if (!mounted) return;
    // 类别解析：男主带"类别：内容" → 用男主的；否则管家自动归类
    final split = ButlerCommandParser.instance.splitCategory(content);
    final category = split.category;
    final body = split.content;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('💌 男主想记住这个'),
        content: Text(
          '「$body」\n\n类别：$category\n\n要让他记住吗？',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不记', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC896B4)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('让他记住'),
          ),
        ],
      ),
    );
    if (approved == true) {
      // 写入记忆库（[类别] 前缀存储，男主 #查记忆 可按类别筛）
      if (_chatSessionId != null) {
        await ChatDatabaseService.instance.insertMemoriesInTx([
          MemoryNode(
            id: 'mem_${DateTime.now().millisecondsSinceEpoch}',
            sessionId: _chatSessionId!,
            branchLeafId: _chatLeafId ?? '',
            content: '[$category] $body',
            sourceMessageIds: const [],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ]);
      }
      DebugLogger.log('指令模块', '✅ 用户确认记录: [$category] $body');
      _pendingFeedback =
          '（用户确认了你的记录请求：「$body」（$category），已经记下了）';
    } else {
      DebugLogger.log('指令模块', '⛔ 用户拒绝记录: $body');
      _pendingFeedback =
          '（用户拒绝了你的记录请求：「$body」，你可以自然地问问为什么）';
    }
  }

  /// 查记忆主流程：检索 → 命中数分级 → 少直接审批 / 多等男主选条数
  Future<void> _startRecallFlow(String arg) async {
    if (_chatSessionId == null) return;
    try {
      // 解析「类别：内容」/ 纯类别 / 纯关键词
      final split = ButlerCommandParser.instance.splitCategory(arg);
      final query = split.content.isEmpty ? split.category : arg;
      final isCategory = ButlerCommandParser.allCategories.contains(query);
      final memories = await ChatMemoryService.instance.searchMemories(
        _chatSessionId!,
        category: isCategory ? query : null,
        keyword: isCategory ? null : query,
      );
      final total = memories.length;
      if (total == 0) {
        _appendToolBubble('没有找到相关记忆');
        _pendingFeedback = '（没有找到关于「$query」的记忆）';
        return;
      }
      if (total <= 5) {
        // 少：直接审批
        _pendingRecall = query;
        _pendingRecallCategory = isCategory ? query : null;
        await _approveRecall('$query（$total条）');
      } else {
        // 多：等男主说想看几条
        _pendingQuery = (query: query, category: isCategory ? query : '', total: total);
        _pendingFeedback =
            '（查到了 $total 条关于「$query」的记忆。请告诉管家你想看几条，比如"看前5条"或"最近3条"；说"全部"就是都看）';
        _appendToolBubble('查到了 $total 条，你想看几条？');
      }
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 查记忆失败: $e');
      _appendToolBubble('查记忆出错了');
    }
  }

  /// 男主回复里指定条数 → 从待定查询继续
  Future<void> _resolvePendingQuery(String replyText) async {
    final pq = _pendingQuery;
    if (pq == null) return;
    final want = ButlerCommandParser.parseWantedCount(replyText);
    if (want == null) return; // 男主没指定，继续等
    _pendingQuery = null;
    final limit = want == -1 ? pq.total : (want < pq.total ? want : pq.total);
    _pendingRecall = pq.query;
    _pendingRecallCategory = pq.category.isEmpty ? null : pq.category;
    _pendingRecallLimit = limit;
    await _approveRecall('${pq.query}（${pq.total}条，${want == -1 ? '全部' : '看$limit条'}）');
  }

  /// 查记忆授权：男主申请调记忆 → 用户允许/拒绝 → 反馈
  Future<void> _approveRecall(String query) async {
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('🔍 男主想翻你的记忆'),
        content: Text(
          query.isEmpty
              ? '他想看看你们之间的记忆，允许吗？'
              : '他想查关于「$query」的记忆，允许吗？',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不允许', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC896B4)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    if (approved == true) {
      _pendingRecall = query;
      _pendingFeedback = query.isEmpty
          ? '（用户允许你查看你们的记忆了）'
          : '（用户允许你查看关于「$query」的记忆了）';
      DebugLogger.log('指令模块', '✅ 用户授权查记忆: $query');
    } else {
      _pendingFeedback = query.isEmpty
          ? '（用户暂时不想让你看记忆，别追问）'
          : '（用户拒绝了查「$query」记忆的请求，别追问）';
      DebugLogger.log('指令模块', '⛔ 用户拒绝查记忆: $query');
    }
  }

  /// 工具执行：record_memory（弹窗确认 → 写记忆 → 返回结果给模型）
  Future<String> _executeRecordTool(String category, String content) async {
    if (content.isEmpty) return '内容为空，无法记录';
    if (!mounted) return '用户不在，记录未确认';
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('💌 男主想记住这个'),
        content: Text(
          '「$content」\n\n类别：${category.isEmpty ? '其他' : category}\n\n要让他记住吗？',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不记', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC896B4)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('让他记住'),
          ),
        ],
      ),
    );
    if (approved == true) {
      if (_chatSessionId != null) {
        await ChatDatabaseService.instance.insertMemoriesInTx([
          MemoryNode(
            id: 'mem_${DateTime.now().millisecondsSinceEpoch}',
            sessionId: _chatSessionId!,
            branchLeafId: _chatLeafId ?? '',
            content: '[${category.isEmpty ? '其他' : category}] $content',
            sourceMessageIds: const [],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ]);
      }
      DebugLogger.log('指令模块', '✅ 工具记录确认: [$category] $content');
      return '已记录：[$category] $content';
    }
    DebugLogger.log('指令模块', '⛔ 工具记录被拒: $content');
    return '用户拒绝了记录：「$content」。如果想知道原因，可以自然地问她。';
  }

  /// 工具执行：recall_memory（检索 → 弹窗授权 → 返回记忆给模型）
  Future<String> _executeRecallTool(String query, String category) async {
    try {
      final sessionId = _chatSessionId;
      if (sessionId == null) return '暂无记忆可查';
      final isCategory = category.isNotEmpty &&
          ButlerCommandParser.allCategories.contains(category);
      final memories = await ChatMemoryService.instance.searchMemories(
        sessionId,
        category: isCategory ? category : null,
        keyword: isCategory ? null : (query.isEmpty ? category : query),
      );
      if (memories.isEmpty) {
        return '没有找到关于「${query.isEmpty ? category : query}」的记忆';
      }
      if (!mounted) return '用户不在，查询未授权';
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFFFDF7F9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('🔍 男主想翻你的记忆'),
          content: Text(
            '查到了 ${memories.length} 条关于「${query.isEmpty ? category : query}」的记忆，'
            '允许他看吗？（最多显示 5 条）',
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不允许', style: TextStyle(color: Color(0xFF8A7A80))),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC896B4)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('允许'),
            ),
          ],
        ),
      );
      if (approved != true) {
        return '用户拒绝了查看记忆的请求，不要追问';
      }
      final lines = memories
          .take(5)
          .map((m) => m.content
              .replaceFirst(RegExp(r'^\[(喜好|约定|日常|事实|其他)\]'), ''))
          .toList();
      return '查到的记忆：\n- ${lines.join('\n- ')}';
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 工具查记忆失败: $e');
      return '查记忆出错了';
    }
  }

  /// 工具执行：save_identity_memory（男主写代号人物记忆 → 待确认区，用户确认才生效）
  /// 37批：原生 function calling 替代 #A# 文本协议（DeepSeek 对文本协议不可靠）
  Future<String> _executeSaveIdentityMemoryTool(String code, String content) async {
    if (code.trim().isEmpty || content.trim().isEmpty) {
      return '参数不完整：需要代号（code）和内容（content）';
    }
    final butler = ChatService.instance.butler;
    if (butler == null || !butler.config.maskLayerEnabled) {
      return '假面层未开启，无法保存代号记忆';
    }
    final sessionId = _chatSessionId ?? 'chat_page';
    // 会话映射：代号 → 身份 id
    String? identityId;
    final mapping = butler.maskEngine.getSessionMapping(sessionId);
    mapping.forEach((id, c) {
      if (c == code.trim()) identityId = id;
    });
    if (identityId == null) {
      // 会话映射没有 → 尝试注册时的默认代号（管理页展示用）
      for (final entry in butler.maskEngine.allIdentities) {
        if (butler.maskEngine.codeFor(entry.id) == code.trim()) {
          identityId = entry.id;
          break;
        }
      }
    }
    if (identityId == null) {
      return '无法识别代号「$code」——它不是当前对话里的代号。'
          '不要追问它代表谁，当作没记住继续聊天即可。';
    }
    final String targetId = identityId!;
    await butler.maskEngine.identityStore?.addIdentityMemory(
      identityId: targetId,
      content: content.trim(),
    );
    DebugLogger.log('假面层', '✅ 工具保存代号记忆: $code → $content');
    return '已把「$code」的事记下，等用户确认后生效。'
        '确认前不要当作已记住的信息使用。';
  }

  /// 工具执行：list_tools（男主查询自己有哪些工具可用）
  String _executeListToolsTool() {
    return '你现在可以使用的工具：\n'
        '- record_memory：记录用户的事（类别：喜好/约定/日常/事实/其他）\n'
        '- recall_memory：查看以前记住的关于用户的事\n'
        '- save_identity_memory：保存关于某位代号人物（如 家人A）的事\n'
        '- list_tools：查看工具清单（就是现在这个）\n'
        '调用完成后自然地继续和用户说话。';
  }

  /// 男主获准调取记忆 → 异步检索记忆库生成注入文本（按类别/条数）
  Future<List<String>> _buildRecallInjectionAsync(String query) async {
    try {
      final sessionId = _chatSessionId;
      if (sessionId == null) return const [];
      final isCategory =
          _pendingRecallCategory != null && _pendingRecallCategory!.isNotEmpty;
      var memories = await ChatMemoryService.instance.searchMemories(
        sessionId,
        category: isCategory ? _pendingRecallCategory : null,
        keyword: isCategory ? null : query,
      );
      if (memories.isEmpty) return const [];
      final limit = _pendingRecallLimit ?? 6;
      if (memories.length > limit) {
        memories = memories.sublist(0, limit);
      }
      final lines = memories
          .map((m) => m.content
              .replaceFirst(RegExp(r'^\[(喜好|约定|日常|事实|其他)\]'), ''))
          .toList();
      return [
        '（用户允许你查看记忆。以下是关于「$query」的记忆，自然接住：\n'
        '- ${lines.join('\n- ')}）',
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 懒创建隐式会话（每个男主一个，跨页面进入复用）
  Future<void> _ensureChatSession(String personaId, String personaName) async {
    if (_chatSessionId != null || personaId.isEmpty) return;
    try {
      final s = await ChatDatabaseService.instance.createSession(
        characterId: personaId,
        title: '与 $personaName 的聊天（自动记录）',
      );
      _chatSessionId = s.id;
      DebugLogger.log('管家流程', '📝 隐式会话已创建: ${s.id}');
    } catch (e) {
      DebugLogger.log('管家流程', '✖ 隐式会话创建失败: $e');
    }
  }

  /// 每 3 轮对话提取一次记忆（LLM 总结 → 用户记忆库 → 记忆检索技能可查）

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
  /// 当前 persona 的初始设定（用户写的人设），随每轮请求进 system
  String _currentPersonaPrompt() {
    try {
      return _state.persona?.prompt ?? '';
    } catch (_) {
      return '';
    }
  }
}
