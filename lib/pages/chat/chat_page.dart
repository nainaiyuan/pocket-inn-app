import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../ai_provider/ai_provider_manager.dart';
import '../../ai_provider/models.dart';
import '../../butler/tools/tool_intent_parser.dart';
import '../../models/male_lead.dart';
import '../../services/chat_database_service.dart';
import '../../services/chat_memory_service.dart';
import '../../models/chat_memory.dart';
import '../../services/chat_service.dart';
import '../../services/butler_command.dart';
import '../../butler/context/context_tracker.dart';
import '../../butler/storage/storage_registry.dart';
import 'services/context_manager.dart';
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
import 'services/chat_storage_service.dart';
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

  /// 8-05 14:32：当前聊天用的 AI 是不是内置模拟 AI（测试对话判定）
  bool _isCurrentMockChat() {
    final pid = _state.personaId;
    if (pid == null || pid.isEmpty) return false;
    return AIProviderManager.isMockId(
        AIProviderManager.instance.lastProviderFor(pid) ?? '');
  }

  Future<void> _sendMsg(String t) async {
    // 8-03 18:2x（用户反馈"男主说完话再说话他不理人"）：生成锁——
    // 男主生成中（含工具轮）新消息直接忽略并提示，防并发上下文混乱
    if (_generating) {
      DebugLogger.log('管家流程', '⏳ 男主正在忙（生成中），忽略新消息: $t');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('男主正在忙，等他回完再说…'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }
    _generating = true;
    final userMsgId = DateTime.now().millisecondsSinceEpoch.toString();
    // 本轮男主第一句话气泡 id 重置（工具气泡只挂本轮第一句话头上）
    _firstAiMsgId = null;
    _msgKey.currentState?.appendMessage(ChatMessage(id: userMsgId, text: t, isMe: true));
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    // 8-05 14:36 用户修正：测试对话 ≠ 关功能，而是独立"测试空间"——
    // 模拟 AI 聊天时所有数据（会话/消息/记忆/情绪/上下文总结）落到
    // ${真实persona}__mock__test 这个测试 key，功能照常跑、数据不混；
    // 聊天页 UI 仍显示真实 persona（头像/名字/人设不变）
    final isMockChat = AIProviderManager.isMockId(
        AIProviderManager.instance.lastProviderFor(personaId) ?? '');
    final chatPid = isMockChat ? '${personaId}${AIProviderManager.mockTestSuffix}' : personaId;
    // 会话空间切换（真实 ↔ 测试）：旧会话作废，重新建对应空间的
    if (_chatSessionId != null && _chatSessionIsMock != isMockChat) {
      DebugLogger.log('管家流程', '🧪 会话空间切换（测试↔真实），旧会话作废');
      _chatSessionId = null;
      _chatLeafId = null;
    }
    _chatSessionIsMock = isMockChat;
    // 男主正在被调用（同一男主连续对话 → 上下文延续）
    if (personaId.isNotEmpty) {
      ContextTracker.instance.touch(chatPid);
    }
    // 拟人化：用户消息未读 → 男主开始"正在输入"
    ChatPresence.instance.markUnread(userMsgId);
    ChatPresence.instance.setTyping(true);
    // 管家对话记录：隐式会话 + 消息落库（记忆提取的数据源）
    // 测试对话建测试会话（_chatSessionId = 测试会话 id →
    // 消息/记忆全部落在测试空间）
    await _ensureChatSession(chatPid, personaName);
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
      // 测试对话也跑（链路完整可测），但 characterId 用测试 key →
      // 技能执行/情绪记录全部落在测试空间
      String sendText = t;
      String? skillInjection;
      String? keywordAsk;
      try {
        final pipeline = await ChatService.instance.runButlerPipeline(
          userText: t,
          characterId: chatPid,
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
      // 用户 8-03 01:52：用户指名道姓让男主调用某工具（如"调用recall_memory"）
      // 但 DeepSeek 可能不响应 → 检测到工具名时注入强制提示，确保男主真的调用
      final toolHint = _buildExplicitToolHint(t);
      // 用户 8-03 05:31：用户直接发 JSON 工具指令（兼容不同 AI 的指令格式）→
      // 不走男主主调用（男主收到 JSON 会空回复），直接进工具轮执行，
      // 用户 8-03 06:01：撤销用户消息直连工具——调工具是男主的技能，
      // 用户消息一律走男主，由男主决定是否调用（男主回复由管家解析执行）
      // 8-03 18:2x（用户要求）：男主已读 = 管家已联系男主开始走流程。
      // 生成请求发出（男主开始处理）→ 用户消息立即变"已读"；
      // 不再等回复完成才 markAllRead
      ChatPresence.instance.markRead(userMsgId);
      // 8-03 18:27（用户语义）：生成中 = "正在输出"（男主打字阶段）
      ChatPresence.instance.beginTyping();
      var result = await _aiSvc.generateReply(
        sendText,
        personaId,
        personaName: personaName,
        personaPrompt: _currentPersonaPrompt(),
        sessionId: _chatSessionId,
        // 8-05 14:36：测试对话的上下文管理（摘要/压缩/恢复包）落到测试 key
        storagePersonaId: chatPid,
        // 用户 8-03 02:41 模块化重构：技能注入 + 温控询问 + 获准记忆 → USER_PROFILE
        //（用户状态）；审批反馈 + 工具强制提示 → TASK_STATE（任务状态）
        userProfile: [
          if (skillInjection != null) skillInjection,
          if (keywordAsk != null) keywordAsk,
          ...recallInjection,
        ].join('\n'),
        taskState: [
          if (_pendingFeedback != null) _pendingFeedback!,
          if (toolHint != null) toolHint,
          // 8-04 18:34：疑似工具调用格式不对 → 提示男主正确格式（下轮注入）
          if (_formatHint != null) _formatHint!,
        ].join('\n'),
      );
      // 用完即清（反馈/记忆/格式提示只注入一次）
      _pendingFeedback = null;
      _formatHint = null;
      _pendingRecall = null;
      _pendingRecallCategory = null;
      _pendingRecallLimit = null;
      // 收集男主各轮文本（第一轮 + 工具轮）——文本与工具可共存：
      // 模型第一轮既说话又调工具时，文本不丢，工具执行后合并显示
      final replyTexts = <String>[];
      if (result.text.trim().isNotEmpty) {
        replyTexts.add(result.text.trim());
      }
      // 8-03 05:31：男主回复文本里含工具指令（⟨工具:⟩块 / JSON，
      // 兼容不同 AI 的输出格式）→ 管家解析识别 → 转 toolCalls 走工具轮。
      // 8-04 18:2x（用户明确要求）：**中文意图词表已移除**——
      // 管家只认明确指令格式（⟨工具:…⟩块 / JSON），自然语言永不触发，
      // 男主正常说话（"翻翻以前写的日记"）不会再被误判成工具调用。
      // 纯聊天文本（无明确指令格式）→ 返回 null → 零副作用照常显示
      if ((result.toolCalls == null || result.toolCalls!.isEmpty) &&
          result.text.trim().isNotEmpty) {
        final intent = ToolIntentParser.extract(result.text);
        if (intent != null && intent.isNotEmpty) {
          DebugLogger.log('AI路由',
              '🔧 管家解析到男主工具指令: ${intent.map((c) => c['name']).join('、')}');
          result = AIProviderResult(
            // 剥离 ⟨工具:…⟩ 块，用户只看到男主自然的话
            text: ToolIntentParser.stripToolBlocks(result.text),
            toolCalls: intent,
            usage: result.usage,
            providerName: result.providerName,
            reasoningContent: result.reasoningContent,
          );
        } else {
          // 8-04 18:34（用户设计）：疑似工具调用但格式不对 →
          // 管家不执行，提示男主正确格式（注入下轮 taskState，用完即清）
          final hint = ToolIntentParser.detectSuspicious(result.text);
          if (hint != null) {
            _formatHint = hint;
            DebugLogger.log('AI路由', '📐 男主工具格式不对，下轮提示正确格式');
          }
        }
      }
      // 8-03 18:2x（用户反馈"不连贯，管家不实时显示流程"）：
      // 第一轮文本立即显示（不等工具轮跑完），
      // 用户先看到男主说话 → 再看工具气泡 → 再看男主基于结果继续说话
      if (result.text.trim().isNotEmpty) {
        final firstText = await _displayableText(result.text);
        if (firstText.isNotEmpty) {
          final firstMsgId =
              '${DateTime.now().microsecondsSinceEpoch}_ai0';
          _firstAiMsgId = firstMsgId;
          _msgKey.currentState?.appendMessage(ChatMessage(
            id: firstMsgId,
            text: firstText,
            isMe: false,
            thinkingChain: result.reasoningContent,
          ));
          // 文字进入打字机播放 → "正在输出"由打字机播完时 endTyping 关闭
        } else {
          // 文本被剥离成空（纯指令/工具块）→ 本轮没有打字 → 关"正在输出"
          ChatPresence.instance.endTyping();
        }
      } else {
        // 第一轮没说话（直接调工具）→ 工具阶段不显示"正在输出"
        ChatPresence.instance.endTyping();
      }
      // function calling 循环：模型请求工具 → 执行 → 回传 → 再生成（最多3轮防死循环）
      // 用户 8-03 00:55：日志里看不见工具调用 → 每个工具调用都记日志
      // 用户 8-03 01:57：工具轮不限定轮数（原来最多 3 轮，复杂任务可能不够）；
      // 但防死循环：同一工具连续调用 ≥3 次 → 强制停止
      // 用户 8-03 02:26：记录"是否有工具执行"——工具已执行时空文本合法（气泡已反馈），
      // 只有"主调用直接空 + 无工具"才需要轻提示用户
      var toolExecuted = false;
      var toolLoop = 0;
      final consecutiveToolCounts = <String, int>{};
      while (result.toolCalls != null && result.toolCalls!.isNotEmpty) {
        toolLoop++;
        toolExecuted = true;
        DebugLogger.log('AI路由', '🔧 第 $toolLoop 轮：男主请求 ${result.toolCalls!.length} 个工具');
        // 8-03 17:24（用户指示：AI 需要什么给什么，研究 DeepSeek 原生调用）：
        // 工具轮双通道——
        // ① 原生 tool_calls（模型 API 返回，带 id）：原样回传 assistant
        //   （content + reasoning_content + tool_calls 含 id），tool 消息
        //   用模型给的 id 配对（官方文档：append response.choices[0].message，
        //   思考模式 tool_calls 必须配 id 回传，否则 400）
        // ② 文本块工具（⟨工具:⟩ 解析，无 id）：不发伪造原生 tool_calls，
        //   工具结果合并注入 user 消息（文本协议兜底，本地/不支持原生工具的模型用）
        final nativeCalls = result.toolCalls!
            .where((c) => (c['id']?.toString() ?? '').isNotEmpty)
            .toList();
        final textToolResults = <String>[];
        final toolMessages = <AIChatMessage>[
          if (nativeCalls.isNotEmpty)
            AIChatMessage(
              role: 'assistant',
              // 官方示例：整个 message 原样回传（含 content 原文）
              content: result.text,
              toolCalls: nativeCalls,
              // 思考模式必须原样回传 reasoning_content（toApiJson 原样输出）
              reasoningContent: result.reasoningContent,
            ),
        ];
        var loopExceeded = false;
        for (final call in result.toolCalls!) {
          final name = call['name']?.toString() ?? '';
          final args = (call['arguments'] as Map<String, dynamic>?) ?? {};
          _ToolResult toolResult;
          DebugLogger.log('AI路由', '🔧 工具 $name 参数：${args.isEmpty ? '（空）' : args}');
          if (name == 'record_memory') {
            final content = args['content']?.toString() ?? '';
            var category = args['category']?.toString() ?? '';
            // 8-03 06:29：男主不知道类别规范，常写"其他" → 管家兜底：
            // 空类别，或"其他"但内容明显可归类（喜欢/约定/日常/事实）→ 自动纠正
            if (category.isEmpty || category == ButlerCommandParser.catOther) {
              final auto = ButlerCommandParser.autoCategory(content);
              if (auto != ButlerCommandParser.catOther || category.isEmpty) {
                category = auto;
              }
            }
            // 8-03 06:34：男主提取的关键词（妈妈→亲戚、喜欢→喜好）→
            // 并入规律引擎关键词池，找规律时总能找到
            final kw = args['keywords'];
            final words = <String>[];
            if (kw != null) {
              if (kw is List) {
                for (final w in kw) {
                  final s = w.toString().trim();
                  if (s.isNotEmpty) words.add(s);
                }
              } else if (kw is String) {
                words.addAll(kw
                    .split(RegExp(r'[,，、\s]+'))
                    .where((w) => w.isNotEmpty));
              }
              if (words.isNotEmpty) {
                ButlerPipelineResult.pendingKeywords.addAll(words);
                DebugLogger.log('管家流程',
                    '🎯 record_memory 关键词并入规律引擎: ${words.join('、')}');
              }
            }
            // 8-03 06:37：男主写的完整句（content）原样保存 + 关键词落库
            _appendToolBubble('正在记录：「$content」（$category）…');
            // 8-03 19:1x（用户要求：调工具要确认）：写记忆前让用户点头
            // 8-03 23:0x（用户要求）：一次弹窗展示全——
            // 男主想记录的原话 + 类别 + 男主提取的关键词（a+b 找规律用）
            final ok = await _approveToolCall(
              '记录',
              '「$content」\n\n类别：$category\n'
              '关键词：${words.isEmpty ? '（无）' : words.join('、')}\n\n'
              '要让他记住吗？',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了记录「$content」');
              toolResult = _ToolResult(false, '用户拒绝：暂不记录「$content」');
            } else {
              toolResult = await _executeRecordTool(
                category,
                content,
                keywords: words,
              );
            }
          } else if (name == 'recall_memory') {
            final query = args['query']?.toString() ?? '';
            final category = args['category']?.toString() ?? '';
            _appendToolBubble('正在查记忆：$query…');
            // 8-03 19:1x（用户要求：调工具要确认）：查记忆是读用户隐私，
            // 必须先问用户（和文本协议 #查记忆# 的 _approveRecall 一致）
            final ok = await _approveToolCall('查记忆', '他想查关于「$query」的记忆，允许吗？');
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了查「$query」');
              toolResult = _ToolResult(false, '用户拒绝：暂不查「$query」');
            } else {
              toolResult = await _executeRecallTool(query, category);
            }
          } else if (name == 'save_identity_memory') {
            // 37批：男主用原生工具写代号记忆（替代 #A# 文本协议，DeepSeek 更可靠）
            final code = args['code']?.toString() ?? '';
            final content = args['content']?.toString() ?? '';
            _appendToolBubble('男主想记住关于「$code」的事…');
            // 8-03 19:1x：写代号记忆也确认
            final ok = await _approveToolCall('记住代号', '「$code」：$content\n\n要让他记住吗？');
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了记住「$code」');
              toolResult = _ToolResult(false, '用户拒绝：暂不记住「$code」');
            } else {
              toolResult = await _executeSaveIdentityMemoryTool(code, content);
            }
          } else if (name == 'list_tools') {
            // 8-03 19:1x：list_tools 也出"正在…"气泡（之前只有结果气泡，
            // 用户反馈"根本没看见工具气泡"）——工具调用必须有可见反馈
            _appendToolBubble('男主想查看工具清单…');
            // 8-03 19:35（用户实测反馈）：list_tools 也要确认——
            // 用户要求所有工具调用都先问他允不允许
            final ok = await _approveToolCall(
                '查看工具清单', '他想看看自己现在有哪些能力可用，允许吗？');
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了查看工具清单');
              toolResult = _ToolResult(false, '用户拒绝：暂不查看工具清单');
            } else {
              toolResult = _executeListToolsTool();
            }
          } else if (name == 'write_diary') {
            final content = args['content']?.toString() ?? '';
            _appendToolBubble('男主在写日记…');
            final ok = await _approveToolCall('写日记', '「$content」\n\n要让他记下来吗？');
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了写日记');
              toolResult = _ToolResult(false, '用户拒绝：暂不写日记');
            } else {
              toolResult = await _executeWriteDiaryTool(content);
            }
          } else if (name == 'query_diary') {
            final keyword = args['keyword']?.toString() ?? '';
            _appendToolBubble('男主在翻日记：$keyword…');
            final ok = await _approveToolCall('翻日记', '他想查日记里关于「$keyword」的内容，允许吗？');
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了翻日记');
              toolResult = _ToolResult(false, '用户拒绝：暂不翻日记');
            } else {
              toolResult = await _executeQueryDiaryTool(keyword);
            }
          } else {
            toolResult = _ToolResult(false, '未知工具：$name');
          }
          // 完成/失败气泡（用户 8-03 01:57）：执行完必须给用户明确反馈
          _appendToolResultBubble(name, toolResult);
          DebugLogger.log('AI路由', '🔧 工具 $name 结果：${toolResult.text.length > 80 ? toolResult.text.substring(0, 80) + '…' : toolResult.text}');
          // 8-04 17:0x（用户：上下文要留地方放工具，男主才知道做过什么；
          // 带时间戳+成败+原因，失败后才能继续调工具解决）：
          // 工具调用记录进上下文（stateless 全量带 → 男主看得到）
          ContextManager.instance
              .feedToolCall(personaId, name, toolResult.ok, toolResult.text);
          if (nativeCalls.contains(call)) {
            // 原生：tool 消息必须用模型给的 id 配对（不能自己编 id）
            // 8-04 17:0x（用户：📄 里工具轮要简化成"成功/失败+一句话"）：
            // content 统一带【工具 名】+ ✅成功/❌失败 标记 —— 模型看得更清楚，
            // 📄 展示层也能解析出工具名和结果好坏
            toolMessages.add(AIChatMessage(
              role: 'tool',
              content: '【工具 $name】${toolResult.ok ? '✅成功' : '❌失败'}：${toolResult.text}',
              toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
            ));
          } else {
            // 文本块：结果收集，最后合并注入 user 消息
            textToolResults.add('【工具 $name】${toolResult.ok ? '✅成功' : '❌失败'}：${toolResult.text}');
          }
          // 防死循环：同一工具连续调用 ≥3 次 → 停止本轮
          final n = (consecutiveToolCounts[name] ?? 0) + 1;
          consecutiveToolCounts[name] = n;
          if (n >= 3) {
            loopExceeded = true;
            DebugLogger.log('AI路由', '⚠️ 工具 $name 连续调用 $n 次，强制停止（防死循环）');
          }
        }
        if (loopExceeded) break;
        // 文本块工具结果：合并注入 user 消息（不走原生 tool_calls，兜底通道）
        // 8-04 18:1x（用户：男主分不清用户话和工具结果）：明确标注
        // "这是工具返回结果，不是用户说的"——防止模型把结果当用户指令
        if (textToolResults.isNotEmpty) {
          toolMessages.add(AIChatMessage(
            role: 'user',
            content: '【工具执行结果】（以下是工具返回的数据，'
                '不是用户说的话，用户消息在上面）\n'
                '${textToolResults.join('\n')}\n\n'
                '基于结果自然地回复用户，不要再调用工具。',
          ));
        }
        // 8-03 18:27：工具轮生成也是男主打字阶段 → 显示"正在输出"
        ChatPresence.instance.beginTyping();
        result = await _aiSvc.generateReply(
          '',
          personaId,
          personaName: personaName,
          personaPrompt: _currentPersonaPrompt(),
          toolRound: true,
          toolMessages: toolMessages,
          sessionId: _chatSessionId,
          storagePersonaId: chatPid,
        );
        if (result.text.trim().isNotEmpty) {
          replyTexts.add(result.text.trim());
          // 8-03 18:2x：工具轮男主回复也立即追加显示（渐进，不等循环结束）
          final roundText = await _displayableText(result.text);
          if (roundText.isNotEmpty) {
            _msgKey.currentState?.appendMessage(ChatMessage(
              id: '${DateTime.now().microsecondsSinceEpoch}_ai$toolLoop',
              text: roundText,
              isMe: false,
              thinkingChain: result.reasoningContent,
            ));
            // 打字机接管，"正在输出"由播完时 endTyping 关闭
          } else {
            ChatPresence.instance.endTyping();
          }
        } else {
          // 工具轮没说话（可能又调工具）→ 工具阶段不显示
          ChatPresence.instance.endTyping();
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
      // 注：渐进显示已把各轮文本实时插入 UI（第一轮 _ai0、工具轮 _aiN），
      // 这里只落库不重复显示
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
      // 渐进显示已实时插入各轮气泡（第一轮 _ai0、工具轮 _aiN），
      // 此处不再重复 append（8-03 18:2x 渐进显示改造）
      // 男主回复完成：全部已读 + 停止输入
      ChatPresence.instance.markAllRead();
      // 用户 8-03 02:26：男主空回复（无工具、无文本）不该弹红色报错。
      // 轻提示即可（重试 2 次都空 → AI 服务端偶发，不是功能坏了）
      if (displayText.trim().isEmpty && !toolExecuted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('男主这次没有回复，再发一条试试'),
          duration: Duration(seconds: 2),
        ));
      }
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
      // 生成锁释放（无论如何）
      _generating = false;
      // 无论如何：清零"正在输出"（打字机播完已 endTyping，这里兜底；
      // 失败则保持未读，男主没读到）
      ChatPresence.instance.resetTyping();
      // 作息规律：当天首次聊天 → 记开始时间（用户一般几点来找男主）
      // 8-05 14:36：测试对话不算用户行为（作息统计是用户维度，跳过）
      if (personaId.isNotEmpty && !isMockChat) {
        unawaited(_recordChatStart());
      }
      // 用户 21:10：日记 = 男主每天结束（用户睡觉后）写的当天总结。
      // 用户消息含结束信号（睡了/晚安/睡觉/拜拜…）→ 男主写完回复后，
      // 管家把当天对话原文交给男主写当天日记（异步，不打断用户）。
      // 21:13：同时记录"平均结束聊时间"（用户一般聊到几点睡）。
      // 8-05 14:36：测试对话写测试空间的日记（chatPid），不碰真实日记
      if (personaId.isNotEmpty && _isEndOfDaySignal(t)) {
        if (!isMockChat) unawaited(_recordChatEnd());
        unawaited(_writeDailyDiary(chatPid, personaName));
      }
    }
  }

  /// 记录当天首次聊天时间（作息规律：平均开始聊）
  Future<void> _recordChatStart() async {
    try {
      final store = StorageRegistry.instance.schedule;
      final now = DateTime.now();
      final minute = now.hour * 60 + now.minute;
      await store.recordStart(minute);
    } catch (e) {
      DebugLogger.log('指令模块', '⚠️ 记录开始聊失败（静默）: $e');
    }
  }

  /// 记录当天结束聊时间（作息规律：平均结束聊）
  Future<void> _recordChatEnd() async {
    try {
      final store = StorageRegistry.instance.schedule;
      final now = DateTime.now();
      final minute = now.hour * 60 + now.minute;
      await store.recordEnd(minute);
    } catch (e) {
      DebugLogger.log('指令模块', '⚠️ 记录结束聊失败（静默）: $e');
    }
  }

  /// 结束信号检测：用户说"睡了/晚安/睡觉/拜拜/下线…" → 该写当天日记了
  bool _isEndOfDaySignal(String text) {
    return RegExp(
      r'睡了|晚安|睡觉|拜拜|下线|去睡|要睡了|碎觉|不聊了|先这样',
    ).hasMatch(text);
  }

  /// 写当天日记（男主视角的一天总结）：
  /// - 同一天只写一次（防重复触发）
  /// - 取当前上下文原文（peek，不清空——用户可能还在聊）
  /// - 男主把当天发生的事总结成日记 → 存 butler_diary
  /// - 失败静默（不打扰用户）
  Future<void> _writeDailyDiary(String personaId, String personaName) async {
    final today = DateTime.now();
    final dateKey =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    if (_dailyDiaryWrittenDate == dateKey) return;
    try {
      final raw = ContextManager.instance.peekRaw(personaId);
      if (raw.trim().isEmpty) {
        DebugLogger.log('指令模块', '📔 当天没有对话原文，跳过写日记');
        return;
      }
      _dailyDiaryWrittenDate = dateKey;
      DebugLogger.log('指令模块', '📔 检测到结束信号，男主写当天日记…');
      final diary = await _aiSvc.generateDailyDiary(personaId, personaName, raw);
      if (diary.isNotEmpty) {
        await ChatDatabaseService.instance.saveDiaryEntry(personaId, diary);
        DebugLogger.log('指令模块', '✅ 当天日记已写（${diary.length} 字）');
      }
    } on Object catch (e) {
      DebugLogger.log('指令模块', '⚠️ 写日记失败（静默）: $e');
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
      onAcceptance: _runAcceptance,
      onForceSummarize: _forceSummarizeNow,
    );
  }

  /// 8-05 21:36 用户：假窗口满·手动触发总结（验证后拆）——
  /// 对当前对话直接跑一遍总结流程，假装上下文满了。
  /// 对话显示在聊天框（走真实 generateReply 路径，可看 📄 结构）。
  /// 8-05 22:07 用户：要拿真实 AI 测总结 → 按钮两种模式都显示，
  /// 这里用确认框把关：真实模式会真动当前对话（原文→摘要）。
  Future<void> _forceSummarizeNow() async {
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    if (lid == null) return;
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    final isMock = _isCurrentMockChat();
    final chatPid = isMock
        ? '${personaId}${AIProviderManager.mockTestSuffix}'
        : personaId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('假窗口满·手动总结'),
        content: Text(isMock
            ? '将对【测试 AI】的当前对话执行总结：\n原文压缩成摘要、摘要区新增条目、管家历史清空。\n继续？'
            : '将对【真实 AI】的当前对话执行总结：\n原文压缩成摘要、摘要区新增条目、管家历史清空。\n这是真实数据，总结后原文不可恢复。\n继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('执行总结'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (mounted) {
      setState(() => _acceptanceNote = '🧪 假窗口满·手动总结进行中…');
    }
    // 总结是管家主动行为：C（带人设）+ 原文 + 【当前管家】指令。
    // userProfile/taskState 是"当前用户消息"的注入，总结不需要。
    await _aiSvc.forceSummarizeNow(
      chatPid,
      personaName,
      personaPrompt: _currentPersonaPrompt(),
    );
    if (mounted) {
      setState(() => _acceptanceNote = '✅ 手动总结完成（摘要区+原文已更新）');
    }
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
                  // 一键验收横幅（8-04 21:1x：自动切 AI 跑对话时显示进度/结论）
                  if (_acceptanceNote != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      color: const Color(0xFF7B6A8F).withValues(alpha: 0.12),
                      child: Row(
                        children: [
                          if (_accepting)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF7B6A8F),
                              ),
                            )
                          else
                            const Icon(Icons.rocket_launch,
                                size: 14, color: Color(0xFF7B6A8F)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _acceptanceNote!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF5A4A6A),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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
                        // 8-05 14:36：测试对话落测试空间的库（storagePersonaId），
                        // 历史加载也读测试空间（测试对话退出再进还在）
                        ChatMessageArea(key: _msgKey, currentPersona: _state.persona,
                          characterAvatarPath: _state.effectiveAvatarPath,
                          onAvatarTap: _openWorld,
                          storagePersonaId: _isCurrentMockChat()
                              ? '${_state.personaId}${AIProviderManager.mockTestSuffix}'
                              : null,
                          ),
                      ],
                    ),
                  ),
                  // 8-03 20:3x（用户要求）：话术栏——预设用户话术一键发送 +
                  // 🤖/☁️ 模拟AI切换（找bug工具：不连真实API也能走完整链路）
                  // 8-05 15:0x（用户：测试的东西要全部收进测试箱）：
                  // 话术栏是模拟AI测试工具 → 测试模式关时不显示
                  if (AIProviderManager.testModeEnabled) _buildScriptBar(),
                  // 8-05 16:36 用户：测试模式开着必须一眼看出 + 一键退出
                  if (AIProviderManager.testModeEnabled)
                    _buildTestModeBanner(),
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

        // ===== 🔁 让男主重新认识按钮（8-04 23:4x 用户）=====
        // 只带【已总结摘要+恢复包+当次未总结原文】（总结过的旧原文不重复扔），
        // 全量发给男主重新熟悉——不赌 AI 记没记住，错了手动救
        if (AIProviderManager.testModeEnabled)
          Positioned(
            right: 106, top: MediaQuery.of(context).padding.top + 4,
            child: GestureDetector(
              onTap: _resyncContext,
              child: Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: Colors.black26, shape: BoxShape.circle,
            ),
              child: const Icon(Icons.sync, size: 15, color: Colors.white70),
            ),
          ),
        ),

        // ===== 🧪 模拟测试按钮（找bug工具，8-03 20:1x 用户要求）=====
        // 预设对话 + 手动写男主回复，走真实 feed/build/解析流程，
        // 看"发给模型的历史"里男主消息到底在不在
        if (AIProviderManager.testModeEnabled)
          Positioned(
            right: 72, top: MediaQuery.of(context).padding.top + 4,
            child: GestureDetector(
              onTap: _showSimulation,
              child: Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: Colors.black26, shape: BoxShape.circle,
            ),
              child: const Icon(Icons.science_outlined, size: 15, color: Colors.white70),
            ),
          ),
        ),

        // ===== 📄 prompt 查看按钮（透明化：男主"知道什么"一目了然）=====
        if (AIProviderManager.testModeEnabled)
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
        if (AIProviderManager.testModeEnabled)
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

  // ===== 话术栏（找bug工具，8-03 20:3x 用户要求）=====
  // 预设用户话术一键发送（走完整真实链路）。
  // 测试 AI 不用手动开关：右上角 AI 选择里选"🧪 测试AI（内置）"即可
  // ——模拟器扮演 DeepSeek（思考/调工具/校验工具轮回传格式），
  // 不联网不花 token，用户不用配置 API。
  static const _scriptPhrases = [
    '你好呀',
    '记住我喜欢喝美式咖啡',
    '我之前说过喜欢什么吗',
    '你有什么工具',
    '帮我写日记',
  ];

  /// 测试模式横幅：明确提示"真实 AI 已隔离、对话走模拟 AI"+ 一键退出
  /// （8-05 16:36 用户：UI 看不出测试起效、退出要一键恢复）
  Widget _buildTestModeBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF7B6A8F).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF7B6A8F).withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, size: 15, color: Color(0xFF7B6A8F)),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '🧪 测试模式：真实 AI 已隔离，对话走模拟 AI',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF6A4A5A)),
            ),
          ),
          GestureDetector(
            onTap: () {
              final pid = _state.personaId ?? '${_state.leadId}_default';
              AIProviderManager.exitTestMode(pid);
              setState(() {});
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF7B6A8F),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                '退出测试',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScriptBar() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // 预设话术
          for (final p in _scriptPhrases)
            GestureDetector(
              onTap: () {
                if (_generating) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('男主正在回复，稍等一下'),
                    duration: Duration(seconds: 1),
                  ));
                  return;
                }
                _sendMsg(p);
              },
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3E8EE),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFD9C3CE), width: 0.5),
                ),
                child: Center(
                  child: Text(
                    p,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6A4A5A)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 🔁 让男主重新认识我们（8-04 23:4x 用户）：
  /// 只带【已总结摘要+恢复包+当次未总结原文】，全量发给男主重新熟悉。
  /// 男主回复走工具气泡（_appendToolBubble：显示+落库，不 feed）——
  /// 不污染原文（重新认识的指令不是"聊天内容"），也不刷新最后聊天时间。
  Future<void> _resyncContext() async {
    final pid = _state.personaId;
    if (pid == null) return;
    final contextText = ContextManager.instance.buildResyncContext(pid);
    if (contextText.trim().isEmpty) {
      _appendToolBubble('🔁 没有可同步的内容（没有摘要/恢复包/新聊天记录）');
      return;
    }
    _appendToolBubble('🔁 正在把上下文重新发给男主…');
    try {
      final reply = await _aiSvc.resyncContext(
        pid,
        _state.persona?.name ?? '角色',
        contextText,
      );
      if (reply.isNotEmpty) {
        _appendToolBubble('🔁 男主已重新熟悉 ✅ $reply');
      } else {
        _appendToolBubble('🔁 男主没读出内容（回复为空），可再点一次');
      }
    } on Object catch (e) {
      _appendToolBubble('🔁 同步失败：$e');
    }
  }

  /// 🧪 找bug工具（用户 8-03 20:0x 要求）：预设对话 + 手动写男主回复，
  /// 走真实 ContextManager.feed → buildHistoryMessages → ToolIntentParser 流程，
  /// 每步显示结果 → 验证"男主消息到底有没有进发给模型的历史"。
  /// 用独立 pid（sim_xxx）空间，不污染真实对话上下文。
  Future<void> _showSimulation() async {
    final pid = 'sim_${DateTime.now().millisecondsSinceEpoch}';
    final sb = StringBuffer();
    sb.writeln('🧪 模拟对话测试（男主话=手动预设，独立上下文空间）');
    sb.writeln('══════════════════════════════════════');

    Future<void> round(int n, String userText, String aiText,
        {String note = ''}) async {
      sb.writeln('\n──── 轮$n　用户：「$userText」────');
      if (note.isNotEmpty) sb.writeln('　⚙️ $note');
      // 1) generateReply 真实顺序：先组装历史（此刻不含本条用户消息）
      final hist = ContextManager.instance.buildHistoryMessages(pid);
      sb.writeln('▶ 发给模型的历史 ${hist.length} 条：');
      if (hist.isEmpty) sb.writeln('　（空）');
      for (final h in hist) {
        sb.writeln('　[${h.role}] ${h.content.replaceAll(RegExp(r'\\s+'), ' ')}');
      }
      // 2) feed 用户消息（真实）
      ContextManager.instance.feedUserMessage(pid, userText);
      sb.writeln('▶ feed 用户 ✅');
      // 3) feed 男主回复（手动写，走真实 feedAssistantMessage）
      ContextManager.instance.feedAssistantMessage(pid, aiText);
      sb.writeln('▶ feed 男主：「$aiText」✅');
      // 4) 工具指令解析（真实 ToolIntentParser）
      final intent = ToolIntentParser.extract(aiText);
      if (intent != null && intent.isNotEmpty) {
        sb.writeln('▶ 男主话解析出工具：${intent.map((c) => c['name']).join('、')}');
      } else {
        sb.writeln('▶ 男主话无工具指令（纯文本）');
      }
    }

    await round(1, '你好呀', '你好，今天过得怎么样？');
    await round(2, '记住我喜欢喝美式咖啡', '好的，我记住了，你爱喝美式咖啡。',
        note: '场景A：男主正常文本回复');
    await round(3, '我之前说过喜欢什么吗', '我查查看。',
        note: '场景B：男主只调工具没说话（真实=原生tool_calls无文本）→ 这轮男主话不进上下文');
    await round(4, '那你查到了吗', '查到了，你说过喜欢猫。',
        note: '场景C：关键验证——上一轮男主"我查查看"还在历史里吗？');
    await round(5, '你都记得我什么呀', '记得你爱喝美式咖啡、喜欢猫。',
        note: '场景D：男主话含中文意图词，验证解析');

    sb.writeln('\n════════ 当前上下文全貌（peekRaw）════════');
    final rawAll = ContextManager.instance.peekRaw(pid);
    sb.writeln(rawAll.isEmpty ? '（空）' : rawAll);
    sb.writeln('\n════════ 结论判断 ════════');
    final raw = rawAll;
    final userCount = '用户：'.allMatches(raw).length;
    final aiCount = '男主：'.allMatches(raw).length;
    sb.writeln('上下文里 用户 $userCount 条 / 男主 $aiCount 条');
    sb.writeln(aiCount >= userCount - 1
        ? '✅ 男主消息正常进上下文（说明链路OK，问题在AI侧/工具轮）'
        : '❌ 男主消息丢失（$aiCount 少于 ${userCount - 1}）→ 查 feedAssistantMessage 调用链');

    DebugLogger.log('模拟测试', sb.toString());
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '🧪 模拟对话测试',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 460,
          child: SingleChildScrollView(
            child: SelectableText(
              sb.toString(),
              style: const TextStyle(color: Color(0xFF6A4A5A), fontSize: 12, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ===== 管家对话记录（隐式会话 + 记忆提取）=====

  String? _chatSessionId;
  String? _chatLeafId;

  /// 8-05 14:36：当前 _chatSessionId 属于哪个空间（true=测试会话）。
  /// 真实 ↔ 测试切换时旧会话作废重建，防真实聊天落进测试会话
  bool _chatSessionIsMock = false;

  /// 待反馈给男主的审批结果（下轮注入 prompt：确认/拒绝/帮助文本）
  String? _pendingFeedback;
  // 8-04 18:34：疑似工具调用格式不对 → 下轮注入男主正确格式提示（用完即清）
  String? _formatHint;

  /// 男主获准调取的记忆查询词（下轮注入检索到的记忆）
  String? _pendingRecall;

  /// 获准查询的类别（null = 关键词查询）
  String? _pendingRecallCategory;

  /// 获准查看的条数上限（null = 不限，取最近6条）
  int? _pendingRecallLimit;

  /// 当天日记已写日期（yyyy-MM-dd，同一天只写一次）
  String? _dailyDiaryWrittenDate;

  /// 待定查询（命中太多 → 等男主说想看几条）
  ({String query, String category, int total})? _pendingQuery;

  /// 插入管家工具气泡（🔧 正在…，男主头像下小气泡）
  /// 用 [tool] 前缀标记（freezed ChatMessage 不加字段，bubble 检测前缀渲染）
  /// 用户 8-03 03:09：男主只要做了什么，气泡就必须有——不管用户看不看。
  /// 所以气泡先落库（ChatStorageService，不依赖聊天页挂载），
  /// 聊天页挂载时再实时插入 UI；没挂载时用户回来从 DB 加载也能看到。
  /// 注意：ChatMessageAreaState.appendMessage 内部自己会落库，
  /// 所以挂载时直接调它（避免双写）；没挂载时才手动落库。
  void _appendToolBubble(String text) {
    final personaId = _state.personaId;
    if (personaId == null) return;
    final msg = ChatMessage(
      // 微秒时间戳 + 自增序号：同一毫秒多个气泡也不撞 id（撞了落库会丢）
      id: '${DateTime.now().microsecondsSinceEpoch}_tool${_toolBubbleSeq++}',
      text: '[tool] $text',
      isMe: false,
    );
    final area = _msgKey.currentState;
    if (area != null) {
      // 8-03 19:35（用户实测反馈）：insertBefore 是"插到该消息前面"——
      // 之前挂 _lastUserMsgId 把工具气泡插到了用户气泡上面。改回挂男主
      // 第一句话头上：男主第一句话已 append（工具轮在第一句话之后跑），
      // 插到它前面 = 用户消息和男主回复之间 ✅
      // 男主第一轮无文本（直接调工具）→ _firstAiMsgId 为 null → append
      // 尾部 = 用户消息之后，顺序同样正确 ✅
      area.appendMessage(msg, insertBeforeId: _firstAiMsgId);
    } else {
      // 聊天页没挂载（切走/后台）→ 只落库，回来从 DB 加载能看到
      // 8-05 14:36：测试对话落测试空间的库（${personaId}__mock__test）
      final isMock = AIProviderManager.isMockId(
          AIProviderManager.instance.lastProviderFor(personaId) ?? '');
      ChatStorageService()
          .appendMessage(isMock ? '${personaId}${AIProviderManager.mockTestSuffix}' : personaId, msg);
    }
  }

  /// 工具气泡自增序号（防同一微秒撞 id）
  int _toolBubbleSeq = 0;

  /// 8-03 18:2x：男主生成锁（防并发——男主生成中再发消息会上下文混乱）
  bool _generating = false;

  /// 8-04 21:1x：一键验收进行中（自动切 AI 跑真实对话）
  bool _accepting = false;

  /// 验收顶部横幅当前提示
  String? _acceptanceNote;

  /// 8-04 21:1x 用户："一键跑对话，自动切换 AI，对话体现在聊天框，
  /// 我只需要点允许写/允许查，写成一个验收流程看逻辑对不对"
  /// 真实对话全链路验收：自动切 5 个模拟 AI 形态 + 自动发消息，
  /// 工具授权弹窗正常弹（用户点）；每步结论以 📋 消息注入聊天框。
  Future<void> _runAcceptance() async {
    if (_accepting) return;
    if (_generating) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('男主正在忙，等他回完再验收…'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    final lid = _state.leadId;
    if (lid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('先选一个男主再验收'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    final pid = _state.personaId ?? '${lid}_default';
    // 8-05 15:5x（验收 2/7 根因）：14:52 起测试对话的数据全落测试空间
    // （${pid}__mock__test），但验收的检查还在读真实 pid → 读不到。
    // 验收的决策/上下文检查全部改用测试空间 key；provider 绑定仍用真实 pid
    final testPid = '${pid}${AIProviderManager.mockTestSuffix}';
    final manager = AIProviderManager.instance;
    final ctx = ContextManager.instance;
    final svc = AiChatService();
    // 记录原绑定 + 原窗口 + 主实例形态（测完还原）
    final before = manager.bindingFor(pid);
    final beforeWindow = ContextTracker.instance.windowOf(pid);
    final savedMockMode = manager.builtinMockConfig.memoryMode;
    // 8-05 19:56（用户第二次跑 5/7 根因）：测试空间状态残留——
    // 上次验收 ⑦⑧ 写的【恢复包】→ ⑥ buildHistoryMessages 直接 return
    // 恢复包、看不到【男主摘要】；lastChatAt 被设成 2h 前 → ④ 误判
    // idleExpired → 连续使用也全量带。验收前重置测试空间内存状态，
    // 保证每次从零开始、结果可复现（测试空间是隔离的，不影响真实数据）。
    manager.resetLastProvider(pid);
    await ctx.clearProviderUsed(testPid);
    ctx.debugSetLastChatAt(testPid, DateTime.now());
    await ctx.clearRecovery(testPid);
    await ctx.clearSummaries(testPid);
    svc.resetForceRecover(testPid);
    // 8-05 21:30（④ 根因）：上次验收 ⑤ 的 setWindow(800) 持久残留 →
    // 下次验收 ①-③ 提前触发总结 → forceRecover → ④ 误判全量带。
    // 验收开头清窗口回"未确认"（①-④ 用默认大窗口，⑤ 再自己调小）
    ContextTracker.instance.clearWindow(testPid);
    setState(() {
      _accepting = true;
      _acceptanceNote = '🚀 一键验收开始…';
    });
    // 验收结果收集：label / 是否通过 / 失败原因（结束弹窗用）
    final results = <({String label, bool ok, String? reason})>[];
    void record(String label, bool ok, String? reason) =>
        results.add((label: label, ok: ok, reason: reason));

    /// 注入一条 📋 验收消息到聊天框（精简一行）
    void note(String text) {
      _msgKey.currentState?.appendMessage(ChatMessage(
        id: 'accept_${DateTime.now().millisecondsSinceEpoch}',
        text: text,
        isMe: false,
      ));
    }

    /// 发消息并等男主回完（含工具授权弹窗等待）
    Future<void> say(String t) async {
      await _sendMsg(t);
      var waited = 0;
      while (_generating && waited < 240) {
        await Future.delayed(const Duration(milliseconds: 500));
        waited++;
      }
    }

    /// 切 AI + 更新横幅
    Future<void> sw(String id, String hint) async {
      final before = manager.lastProviderFor(pid);
      await manager.setPersonaBinding(pid, [id]);
      // 8-04 22:3x（验收⑤⑦⑧修复）：决策的 stateful 读 lastProviderFor
      // （上次用的）——切换绑定后必须重置，否则上次是 stateful（模拟C）
      // 时决策误走 stateful 分支 → 总结/沉淀永不触发
      manager.resetLastProvider(pid);
      final after = manager.lastProviderFor(pid);
      // 8-05 17:2x（验收④根因）：同一 AI 连续使用不算切换——
      // 无条件 clearProviderUsed 会让 ④ 误判 switched=true → needRecover=true
      // → 连续对话也全量带（浪费 token）。只有真正切换了才清。
      if (before != after) {
        ctx.clearProviderUsed(testPid);
      }
      if (mounted) setState(() => _acceptanceNote = hint);
    }

    try {
      // ── ① AI A（无记忆）：建立话题（短消息，不灌长文本）──
      // 8-05 20:00（用户：编号 8 个检查只有 7 个，① 没检查点）：
      // ① 补成检查点——话题建立 = 消息进了上下文原文
      await sw('builtin-mock', '①/⑧ AI A 无记忆·思考开 — 建立话题');
      note('📋 ① AI A：建立话题');
      await say('你好呀，我来验收啦。先记住：我喜欢蓝色，爱喝美式咖啡。');
      final rawA = ctx.peekRaw(testPid);
      final aOk = rawA.trim().isNotEmpty;
      record('① AI A建立话题', aOk,
          aOk ? null : '原文为空——用户消息没进上下文，后面全白搭');
      note('📋 ① ${aOk ? '✓' : '✗'} 原文 ${rawA.length} 字');

      // ── ② 切 AI B（无记忆·思考关）：验证切换后上下文不丢 ──
      await sw('builtin-mock-b', '②/⑧ AI B 无记忆·思考关 — 验证切换不失忆');
      note('📋 ② 切 AI B：验证切换后不失忆');
      await say('我刚才说我喜欢的颜色是什么？');
      final histB = ctx.buildHistoryMessages(testPid, modelHint: 'mock-1');
      final bOk = histB.isNotEmpty;
      record('② 切换AI B后全量带历史', bOk,
          bOk ? null : '历史为空——stateless 切换后没带上下文，男主会失忆');
      note('📋 ② ${bOk ? '✓' : '✗'} 切B后带${histB.length}条历史');

      // ── ③ 切 AI C（有记忆1h）：验证 stateful 切换全量带 ──
      await sw('builtin-mock-c', '③/⑧ AI C 有记忆1h — 验证 stateful 切换');
      note('📋 ③ 切 AI C：验证 stateful 切换全量带');
      await say('我们刚才聊了哪两件事？');
      var d = svc.assembleDecision(testPid, toolRound: false);
      // 8-04 22:5x（③ 判定修复）：say 后重算 decision 时 switched 已被
      // ③ 自己的 noteProviderUsed 消耗（永远 false）——判定改看组装结果：
      // stateful 判定看决策（C 是 stateful ✓），全量带看组装历史非空
      final histC = ctx.buildHistoryMessages(testPid, modelHint: 'mock-1');
      final cOk = d.stateful && histC.isNotEmpty;
      record('③ stateful切换全量带', cOk,
          cOk ? null : 'stateful=${d.stateful} 组装历史=${histC.length}条——'
              '切到有记忆AI没全量带，男主失忆');
      note('📋 ③ ${cOk ? '✓' : '✗'} stateful=${d.stateful} 组装${histC.length}条');

      // ── ④ AI C 连续使用：验证轻量 ──
      await sw('builtin-mock-c', '④/⑧ AI C 连续使用 — 验证轻量');
      note('📋 ④ AI C 连续使用：验证轻量');
      await say('那你觉得蓝色和美式咖啡配吗？');
      d = svc.assembleDecision(testPid, toolRound: false);
      final dOk = d.stateful && !d.needRecover;
      // 8-05 20:0x（④ 反复失败）：失败原因带完整决策值——
      // switched/idleExpired/forceRecover 哪个 true 一目了然，直接定位
      record('④ stateful连续轻量', dOk,
          dOk ? null : '连续使用还全量带——浪费 token'
              '(stateful=${d.stateful} switched=${d.switched} '
              'idleExpired=${d.idleExpired} forceRecover=${d.forceRecover})');
      note('📋 ④ ${dOk ? '✓' : '✗'} 连续轻量=${!d.needRecover}');

      // ── ⑤ 切回 AI A（stateless）+ 调小窗口：token 满 → 男主总结 ──
      // 8-04 21:2x 用户："别塞那么多上下文，token 调小就好了"
      // 8-04 21:5x 修：窗口 2000→800（预算≈85 字，①-④ 原文 ~130 字已超）
      // 8-04 21:5x 二修：① 强制主实例 stateless（防配置页/自检页残留
      //   stateful 导致 ⑤ 走 stateful 分支不总结）② 消息去掉"记得"等
      //   关键词（避免 recall_memory 工具轮干扰时序）③ 失败自诊断：
      //   预算/原文长度/决策 直接显示在弹窗原因里
      await sw('builtin-mock', '⑤/⑧ 调小token窗口 → 男主主动总结');
      note('📋 ⑤ 切回 AI A：调小窗口，少量消息触发总结');
      manager.updateBuiltinMock(memoryMode: 'stateless'); // 防残留 stateful
      ContextTracker.instance.setWindow(testPid, 800); // 预算≈85字，短消息即触发
      await say('我们今天还聊了散步、读书、做饭、旅行、听音乐，'
          '这些话题我慢慢说给你听。');
      await say('对了，我最近在学做菜，喜欢研究新菜谱，'
          '周末还想去爬山，你觉得怎么样？');
      final summaries = ctx.summariesFor(testPid);
      // 8-05 19:40（用户：本地AI测试走通，真实男主才稳）：
      // v2 总结必须走 save_summary 工具路径——摘要条目带（#1-#N）范围标记；
      // 只有内容没编号 = 走了文本兜底（男主没调工具），真实场景会不稳
      final sumHasRange = summaries.any((x) =>
          x.contains('（#') && x.contains('-#'));
      final sumOk = summaries.isNotEmpty && sumHasRange;
      if (!sumOk) {
        // 自诊断：失败原因直接带数据，弹窗复制发龙虾即可定位
        final budget = ctx.topicBudgetChars(testPid, modelHint: 'mock-1');
        final rawLen = ctx.debugRawLength(testPid);
        final st = svc.assembleDecision(testPid, toolRound: false).stateful;
        DebugLogger.log('AI验收', '⑤自诊断: 预算=$budget 原文=$rawLen stateful=$st'
            ' 摘要=${summaries.length}条 带编号=$sumHasRange');
      }
      record('⑤ token满男主调save_summary总结', sumOk,
          sumOk
              ? null
              : '摘要${summaries.length}条，带编号=$sumHasRange'
                  '（诊断:预算=${ctx.topicBudgetChars(testPid, modelHint: 'mock-1')}'
                  '字 原文=${ctx.debugRawLength(testPid)}字 '
                  'stateful=${svc.assembleDecision(testPid, toolRound: false).stateful}'
                  '——摘要没编号=走了文本兜底，男主没调 save_summary；'
                  '日志看「上下文管理」有无"✂️ 原文攒够了"');
      note('📋 ⑤ ${sumOk ? '✓' : '✗'} 摘要 ${summaries.length} 条'
          ' 带编号=$sumHasRange');

      // ── ⑥ 切 AI E（无记忆·工具关）：验证总结后上下文不丢 ──
      await sw('builtin-mock-e', '⑥/⑧ AI E 无记忆·工具关 — 验证总结后不失忆');
      note('📋 ⑥ 切 AI E：验证总结后上下文不丢');
      await say('刚才我们聊了好多，你能总结一下都聊了什么吗？');
      final histE = ctx.buildHistoryMessages(testPid, modelHint: 'mock-1');
      final hasSummary = histE.any((m) =>
          m.role == 'system' && m.content.contains('男主摘要'));
      final eOk = hasSummary;
      record('⑥ 总结后切换带摘要', eOk,
          eOk ? null : '切 E 后历史里没有【男主摘要】——总结丢了，男主失忆');
      note('📋 ⑥ ${eOk ? '✓' : '✗'} 含摘要=${hasSummary}');

      // ── ⑦ 切回 AI C（有记忆1h）：1h 快到之前 → 男主写三类存档 ──
      // 8-04 21:3x 用户："超过1小时没聊，1小时快到之前就要让AI做总结，
      // 下次聊把上下文/总结/恢复包扔给他，不然全都没了"
      // 模拟：距上次聊天 40 分钟（> 超时一半 30min）→ 下次聊天时补沉淀
      await sw('builtin-mock-c', '⑦/⑧ AI C 有记忆1h — 模拟空闲40分钟→沉淀');
      note('📋 ⑦ 切 AI C：模拟 40 分钟没聊 → 男主应写三类存档（摘要+恢复包）');
      await say('我们约好了周末去爬山，别忘啦。');
      ctx.debugSetLastChatAt(testPid, DateTime.now().subtract(const Duration(minutes: 40)));
      await say('在吗？刚想到爬山的事，周末天气怎么样都去对吧？');
      final recovery7 = ctx.recoveryFor(testPid);
      final sum7 = ctx.summariesFor(testPid);
      final gOk = recovery7 != null && recovery7.isNotEmpty && sum7.isNotEmpty;
      record('⑦ 空闲过半触发沉淀（恢复包+摘要）', gOk,
          gOk ? null : '恢复包=${recovery7 == null ? '无' : '有'} 摘要=${sum7.length}条——'
              '没触发沉淀。日志看「上下文管理」有没有"📝 空闲超时…趁 AI 还记得"');
      note('📋 ⑦ ${gOk ? '✓' : '✗'} 恢复包=${recovery7 == null ? '无' : '有'} 摘要=${sum7.length}条');

      // ── ⑧ 模拟超过 1h：下次聊 → 带恢复包+摘要接上 ──
      // 8-04 21:5x 修：assembleDecision 要在 say 前读（say 里 feed 会把
      // lastChat 刷新成 now，say 后读永远判不出超时）——决策输入验证
      // 看 say 前，组装结果看 say 后（恢复包在内存，与 lastChat 无关）
      await sw('builtin-mock-c', '⑧/⑧ 模拟超时1h → 带恢复包接上');
      note('📋 ⑧ 模拟超过 1 小时没聊 → 应判空闲超时，全量带恢复包');
      ctx.debugSetLastChatAt(testPid, DateTime.now().subtract(const Duration(hours: 2)));
      final dPre = svc.assembleDecision(testPid, toolRound: false);
      await say('我回来了，我们继续聊吧。');
      final histRec = ctx.buildHistoryMessages(testPid, modelHint: 'mock-1');
      final hasRec = histRec.any((m) =>
          m.role == 'system' && m.content.contains('恢复包'));
      final hOk = dPre.idleExpired && dPre.needRecover && hasRec;
      record('⑧ 超时后带恢复包接上', hOk,
          hOk ? null : '决策(idleExpired=${dPre.idleExpired} '
              'needRecover=${dPre.needRecover}) 含恢复包=$hasRec——'
              '超时后没带恢复包，男主失忆');
      note('📋 ⑧ ${hOk ? '✓' : '✗'} idleExpired=${dPre.idleExpired} 含恢复包=$hasRec');

      final pass = results.where((r) => r.ok).length;
      final total = results.length;
      if (mounted) {
        setState(() => _acceptanceNote = '✅ 验收完成：$pass/$total 通过');
      }
      DebugLogger.log('AI验收',
          '■ 验收完成 $pass/$total：${results.map((r) => '${r.label}=${r.ok ? "✓" : "✗"}').join('；')}');
      // 结束弹窗：哪里错了一目了然，可一键复制发给龙虾（8-04 21:2x 用户）
      if (mounted) {
        await _showAcceptanceResult(results);
      }
    } finally {
      // 还原 AI 绑定 + 窗口 + 主实例形态（⑤ 强制过 stateless）
      if (before == null) {
        await manager.clearPersonaBinding(pid);
      } else {
        await manager.setPersonaBinding(pid, before);
      }
      ContextTracker.instance.setWindow(pid, beforeWindow);
      try {
        if (savedMockMode != 'stateless') {
          manager.updateBuiltinMock(memoryMode: savedMockMode);
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _accepting = false;
          _acceptanceNote = null;
        });
      }
    }
  }

  /// 验收结果弹窗：每步 ✓/✗ + 失败原因 + 一键复制（发给龙虾排查）
  Future<void> _showAcceptanceResult(
      List<({String label, bool ok, String? reason})> results) async {
    final pass = results.where((r) => r.ok).length;
    final total = results.length;
    final sb = StringBuffer('🚀 一键验收：$pass/$total 通过\n\n');
    for (final r in results) {
      sb.write('${r.ok ? '✅' : '❌'} ${r.label}\n');
      if (!r.ok && r.reason != null) sb.write('   原因：${r.reason}\n');
    }
    sb.write('\n（失败步骤的日志关键词：AI路由 / 上下文管理 / AI验收）');
    final text = sb.toString();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(pass == total ? '✅ 验收全部通过' : '❌ 验收有失败项'),
        content: SingleChildScrollView(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.6)),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('已复制，粘贴发给龙虾即可'),
                duration: Duration(seconds: 2),
              ));
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制结果'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFC896B4)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 8-03 18:2x：本轮男主第一句话气泡 id——工具气泡都挂在它头上
  /// （用户要求：调工具显示在第一句话的上方，后续句子在下方）
  String? _firstAiMsgId;

  /// 男主回复 → 用户可见文本（剥离工具块 + #指令 + 还原代号）。
  /// 8-03 18:2x：渐进显示用——每轮文本单独显示，不等全部跑完
  Future<String> _displayableText(String raw) async {
    var t = ToolIntentParser.stripToolBlocks(raw);
    t = ButlerCommandParser.instance.strip(t);
    try {
      final butler = ChatService.instance.butler;
      if (butler != null) {
        t = await butler.processIncoming(
          text: t,
          sessionId: _chatSessionId ?? 'chat_page',
        );
      }
    } catch (e) {
      DebugLogger.log('管家流程', '✖ 代号还原失败（渐进显示）: $e');
    }
    return t.trim();
  }

  /// 工具执行完成/失败气泡（用户 8-03 01:57）：执行完必须给用户明确反馈。
  void _appendToolResultBubble(String toolName, _ToolResult r) {
    _appendToolBubble('${r.ok ? '✅' : '❌'} $toolName ${r.ok ? '完成' : '失败'}：${r.text}');
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
  /// 8-03 19:1x（用户要求：调工具要确认）：原生工具轮通用确认弹窗。
  /// 有副作用/涉及用户隐私的工具执行前让用户点头（list_tools 无副作用不弹）。
  /// 用户拒绝 → 返回 false → 工具结果里带"用户拒绝"，男主自然应对，不卡流程。
  Future<bool> _approveToolCall(String toolName, String description) async {
    if (!mounted) return true; // 页面已关闭不阻塞工具
    // 8-04 15:0x（用户报：点确认后"立刻唤醒下面的输入框"）：
    // 弹窗前先收焦点收键盘，弹窗关闭后输入框不会自动弹键盘
    FocusManager.instance.primaryFocus?.unfocus();
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('🔧 男主想$toolName'),
        content: Text(
          description,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不允许', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFC896B4)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    // 弹窗关闭后再收一次，防止焦点残留弹键盘
    FocusManager.instance.primaryFocus?.unfocus();
    return approved == true;
  }

  Future<void> _approveRecord(String content) async {
    if (content.isEmpty) return;
    if (!mounted) return;
    // 8-04 15:0x：弹窗前收焦点收键盘（同 _approveToolCall）
    FocusManager.instance.primaryFocus?.unfocus();
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
    FocusManager.instance.primaryFocus?.unfocus();
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
  Future<_ToolResult> _executeRecordTool(
    String category,
    String content, {
    List<String> keywords = const [],
  }) async {
    if (content.isEmpty) return const _ToolResult(false, '内容为空，无法记录');
    if (!mounted) return const _ToolResult(false, '用户不在，记录未确认');
    // 8-03 22:0x（用户实测：点"让他记住"弹两个确认窗）：
    // 工具轮 485 行 _approveToolCall 已确认过 → 这里 #记# 时代遗留的
    // 老弹窗（💌 男主想记住这个）造成双重确认 → 移除，直接执行
    // 8-05 14:36：测试对话建的是测试会话 → 记忆写入测试空间，功能照常
    if (_chatSessionId == null) {
      await _ensureChatSession(_state.personaId ?? '', '');
    }
    if (_chatSessionId != null) {
      // 8-03 06:41：男主写的完整句 + 关键词都落库
      final parts = <String>['[${category.isEmpty ? '其他' : category}] $content'];
      if (keywords.isNotEmpty) parts.add('关键词：${keywords.join('、')}');
      await ChatDatabaseService.instance.insertMemoriesInTx([
        MemoryNode(
          id: 'mem_${DateTime.now().millisecondsSinceEpoch}',
          sessionId: _chatSessionId!,
          branchLeafId: _chatLeafId ?? '',
          content: parts.join('\n'),
          sourceMessageIds: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ]);
      DebugLogger.log('指令模块', '✅ 工具记录确认: [${category.isEmpty ? '其他' : category}] $content');
      return _ToolResult(true, '已记录：[$category] $content');
    }
    DebugLogger.log('指令模块', '⛔ 工具记录失败: 会话未创建');
    return const _ToolResult(false, '记忆库不可用（会话未创建），请稍后再试');
  }

  /// 工具执行：recall_memory（检索 → 弹窗授权 → 返回记忆给模型）
  Future<_ToolResult> _executeRecallTool(String query, String category) async {
    try {
      // 用户 8-03 05:53：会话未建时直接说"暂无记忆"容易误判 → 先补建会话再查
      // 8-05 14:36：测试对话查的是测试会话的记忆（测试空间，功能照常）
      if (_chatSessionId == null) {
        await _ensureChatSession(_state.personaId ?? '', '');
      }
      final sessionId = _chatSessionId;
      if (sessionId == null) return const _ToolResult(false, '暂无记忆可查');
      final isCategory = category.isNotEmpty &&
          ButlerCommandParser.allCategories.contains(category);
      final memories = await ChatMemoryService.instance.searchMemories(
        sessionId,
        category: isCategory ? category : null,
        keyword: isCategory ? null : (query.isEmpty ? category : query),
      );
      if (memories.isEmpty) {
        return _ToolResult(false, '没有找到关于「${query.isEmpty ? category : query}」的记忆');
      }
      if (!mounted) return const _ToolResult(false, '用户不在，查询未授权');
      // 8-03 22:0x（与记录双弹窗同批）：工具轮 502 行 _approveToolCall
      // 已确认过 → 这里 #查# 时代遗留的老弹窗（🔍 男主想翻你的记忆）
      // 造成双重确认 → 移除，直接返回结果
      // 21:02：记忆库存的是用户原文（可能含真实称呼）→ 返回给模型前替换成代号
      final butler = ChatService.instance.butler;
      final maskEnabled = butler != null && butler.config.maskLayerEnabled;
      final lines = memories
          .take(5)
          .map((m) => m.content
              .replaceFirst(RegExp(r'^\[(喜好|约定|日常|事实|其他)\]'), ''))
          .map((c) => maskEnabled
              ? butler.maskEngine.maskRealNames(c, sessionId)
              : c)
          .toList();
      return _ToolResult(true, '查到的记忆：\n- ${lines.join('\n- ')}');
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 工具查记忆失败: $e');
      return _ToolResult(false, '查记忆出错了');
    }
  }

  /// 工具执行：save_identity_memory（男主写代号人物记忆 → 待确认区，用户确认才生效）
  /// 37批：原生 function calling 替代 #A# 文本协议（DeepSeek 对文本协议不可靠）
  Future<_ToolResult> _executeSaveIdentityMemoryTool(String code, String content) async {
    if (code.trim().isEmpty || content.trim().isEmpty) {
      return const _ToolResult(false, '参数不完整：需要代号（code）和内容（content）');
    }
    final butler = ChatService.instance.butler;
    if (butler == null || !butler.config.maskLayerEnabled) {
      return const _ToolResult(false, '假面层未开启，无法保存代号记忆');
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
      return _ToolResult(false, '无法识别代号「$code」——它不是当前对话里的代号。'
          '不要追问它代表谁，当作没记住继续聊天即可。');
    }
    final String targetId = identityId!;
    await butler.maskEngine.identityStore?.addIdentityMemory(
      identityId: targetId,
      content: content.trim(),
    );
    DebugLogger.log('假面层', '✅ 工具保存代号记忆: $code → $content');
    return _ToolResult(true, '已把「$code」的事记下，等用户确认后生效。'
        '确认前不要当作已记住的信息使用。');
  }

  /// 工具执行：list_tools（男主查询自己有哪些工具可用）
  _ToolResult _executeListToolsTool() {
    return const _ToolResult(true, '你现在可以使用的工具：\n'
        '- record_memory：记录用户的事（类别：喜好/约定/日常/事实/其他）\n'
        '- recall_memory：查看以前记住的关于用户的事\n'
        '- save_identity_memory：保存关于某位代号人物（如 家人A）的事\n'
        '- write_diary：写日记（把值得记住的细节存档）\n'
        '- query_diary：查日记（按关键词回忆以前的细节）\n'
        '- list_tools：查看工具清单（就是现在这个）\n'
        '调用完成后自然地继续和用户说话。');
  }

  /// 工具执行：write_diary（男主写日记 → 存档，无需用户审批）
  Future<_ToolResult> _executeWriteDiaryTool(String content) async {
    if (content.trim().isEmpty) return const _ToolResult(false, '内容为空，无法写日记');
    final personaId = _state.personaId ?? '';
    if (personaId.isEmpty) return const _ToolResult(false, '日记保存失败（缺少角色）');
    try {
      await ChatDatabaseService.instance.saveDiaryEntry(personaId, content.trim());
      DebugLogger.log('指令模块', '✅ 男主写日记（${content.length} 字）');
      return const _ToolResult(true, '已写进日记。以后想回忆这段，可以查日记。');
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 写日记失败: $e');
      return const _ToolResult(false, '日记保存失败，稍后再试');
    }
  }

  /// 工具执行：query_diary（男主查日记 → 按关键词返回最近条目）
  Future<_ToolResult> _executeQueryDiaryTool(String keyword) async {
    final personaId = _state.personaId ?? '';
    if (personaId.isEmpty) return const _ToolResult(false, '查日记失败（缺少角色）');
    try {
      final entries = await ChatDatabaseService.instance.searchDiary(
        personaId,
        keyword: keyword.trim().isEmpty ? null : keyword.trim(),
        limit: 8,
      );
      if (entries.isEmpty) {
        return _ToolResult(false, '日记里没有找到关于「${keyword.isEmpty ? '最近' : keyword}」的记录。'
            '不用勉强，自然继续聊天。');
      }
      return _ToolResult(true, '日记里找到 ${entries.length} 条相关记录：\n- ${entries.join('\n- ')}');
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 查日记失败: $e');
      return const _ToolResult(false, '查日记出错了');
    }
  }

  /// 男主获准调取记忆 → 异步检索记忆库生成注入文本（按类别/条数）
  /// 21:02：记忆库存的是用户原文（可能含真实称呼）→ 注入前过假面层替换成代号
  /// 用户 8-03 01:52：用户指名道姓让男主调用工具（"调用recall_memory"等），
  /// 但模型可能忽略 → 检测工具名并注入强制提示，确保男主真的调用。
  /// 返回 null = 用户没提工具名，不注入。
  String? _buildExplicitToolHint(String userText) {
    const known = <String, String>{
      'record_memory': '记住',
      'recall_memory': '查看记忆',
      'save_identity_memory': '保存身份记忆',
      'list_tools': '查看工具',
      'write_diary': '写日记',
      'query_diary': '查日记',
    };
    final matched = known.keys.where(userText.contains).toList();
    if (matched.isEmpty) return null;
    final names = matched.join('、');
    return '【用户指令】用户明确要求你调用工具 $names。'
        '请立即调用该工具（function calling），不要只说不做。'
        '调用完成后用自然的话告诉用户结果。';
  }

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
      final butler = ChatService.instance.butler;
      final maskEnabled = butler != null && butler.config.maskLayerEnabled;
      final lines = memories
          .map((m) => m.content
              .replaceFirst(RegExp(r'^\[(喜好|约定|日常|事实|其他)\]'), ''))
          .map((c) => maskEnabled
              ? butler.maskEngine.maskRealNames(c, sessionId)
              : c)
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
  /// 8-04 16:4x：完整内容已落库 prompt_logs —— 重启后内存为空时
  /// 从 DB 读最近一条，弹窗不再是"还没有记录"。
  Future<void> _showPromptDialog() async {
    var promptText = _aiSvc.lastPromptText;
    if (promptText == null || promptText.isEmpty) {
      final personaId = _state.personaId ?? '';
      if (personaId.isNotEmpty) {
        promptText = await ChatStorageService().loadLatestPromptLog(personaId);
      }
    }
    if (!mounted) return;
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

/// 工具执行结果（用户 8-03 01:58）：结构化状态，不靠语义猜。
/// ok=true 成功 / ok=false 失败；text 是回传给男主（AI）的文本。
class _ToolResult {
  final bool ok;
  final String text;
  const _ToolResult(this.ok, this.text);
}
