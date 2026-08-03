import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../services/local_storage_service.dart';
import '../../models/chat_message.dart';
import '../../utils/debug_logger.dart';
import '../ai_config_page.dart';
import 'services/ai_chat_service.dart';
import 'services/context_manager.dart';
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
      // 用户 8-03 05:31：男主回复文本里含工具指令（JSON / 中文文本，
      // 兼容不同 AI 的输出格式）→ 管家解析识别 → 转 toolCalls 走工具轮。
      // 纯聊天文本（无指令）→ 返回 null → 零副作用照常显示
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
            toolResult = await _executeRecordTool(
              category,
              content,
              keywords: words,
            );
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
          } else if (name == 'write_diary') {
            final content = args['content']?.toString() ?? '';
            _appendToolBubble('男主在写日记…');
            toolResult = await _executeWriteDiaryTool(content);
          } else if (name == 'query_diary') {
            final keyword = args['keyword']?.toString() ?? '';
            _appendToolBubble('男主在翻日记：$keyword…');
            toolResult = await _executeQueryDiaryTool(keyword);
          } else {
            toolResult = _ToolResult(false, '未知工具：$name');
          }
          // 完成/失败气泡（用户 8-03 01:57）：执行完必须给用户明确反馈
          _appendToolResultBubble(name, toolResult);
          DebugLogger.log('AI路由', '🔧 工具 $name 结果：${toolResult.text.length > 80 ? toolResult.text.substring(0, 80) + '…' : toolResult.text}');
          if (nativeCalls.contains(call)) {
            // 原生：tool 消息必须用模型给的 id 配对（不能自己编 id）
            toolMessages.add(AIChatMessage(
              role: 'tool',
              content: toolResult.text,
              toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
            ));
          } else {
            // 文本块：结果收集，最后合并注入 user 消息
            textToolResults.add('【工具 $name】${toolResult.text}');
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
        if (textToolResults.isNotEmpty) {
          toolMessages.add(AIChatMessage(
            role: 'user',
            content: '【工具执行结果】\n${textToolResults.join('\n')}\n\n'
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
      if (personaId.isNotEmpty) {
        unawaited(_recordChatStart());
      }
      // 用户 21:10：日记 = 男主每天结束（用户睡觉后）写的当天总结。
      // 用户消息含结束信号（睡了/晚安/睡觉/拜拜…）→ 男主写完回复后，
      // 管家把当天对话原文交给男主写当天日记（异步，不打断用户）。
      // 21:13：同时记录"平均结束聊时间"（用户一般聊到几点睡）。
      if (personaId.isNotEmpty && _isEndOfDaySignal(t)) {
        unawaited(_recordChatEnd());
        unawaited(_writeDailyDiary(personaId, personaName));
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
      // 8-03 18:2x：工具气泡挂男主第一句话头上（第一句话上方）。
      // 用户要求：调工具显示在第一句话的顶部，第二句话在第一句话下面，
      // 工具始终跟第一句话绑定。没有第一句话（男主直接调工具）→ 正常追加。
      area.appendMessage(msg, insertBeforeId: _firstAiMsgId);
    } else {
      // 聊天页没挂载（切走/后台）→ 只落库，回来从 DB 加载能看到
      ChatStorageService().appendMessage(personaId, msg);
    }
  }

  /// 工具气泡自增序号（防同一微秒撞 id）
  int _toolBubbleSeq = 0;

  /// 8-03 18:2x：男主生成锁（防并发——男主生成中再发消息会上下文混乱）
  bool _generating = false;

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
  Future<_ToolResult> _executeRecordTool(
    String category,
    String content, {
    List<String> keywords = const [],
  }) async {
    if (content.isEmpty) return const _ToolResult(false, '内容为空，无法记录');
    if (!mounted) return const _ToolResult(false, '用户不在，记录未确认');
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('💌 男主想记住这个'),
        content: Text(
          [
            '「$content」',
            '类别：${category.isEmpty ? '其他' : category}',
            if (keywords.isNotEmpty) '关键词：${keywords.join('、')}',
            '',
            '要让他记住吗？',
          ].join('\n'),
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
      // 用户 8-03 05:53：会话未创建时静默跳过 = 假成功（用户以为记住了实际没写库）
      // → 先补建会话再插入；补建失败明确报错，绝不假成功
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
    DebugLogger.log('指令模块', '⛔ 工具记录被拒: $content');
    return _ToolResult(false, '用户拒绝了记录：「$content」。如果想知道原因，可以自然地问她。');
  }

  /// 工具执行：recall_memory（检索 → 弹窗授权 → 返回记忆给模型）
  Future<_ToolResult> _executeRecallTool(String query, String category) async {
    try {
      // 用户 8-03 05:53：会话未建时直接说"暂无记忆"容易误判 → 先补建会话再查
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
        return const _ToolResult(false, '用户拒绝了查看记忆的请求，不要追问');
      }
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

/// 工具执行结果（用户 8-03 01:58）：结构化状态，不靠语义猜。
/// ok=true 成功 / ok=false 失败；text 是回传给男主（AI）的文本。
class _ToolResult {
  final bool ok;
  final String text;
  const _ToolResult(this.ok, this.text);
}
