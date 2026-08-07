import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../services/global_banner_service.dart';
import '../../services/tool_approval_store.dart';
import '../../services/global_timer_card_service.dart';
import '../../services/card_task_store.dart';
import '../../services/setting_version_store.dart';
import '../../services/record_tree_store.dart';
import '../../services/working_pad_store.dart';
import '../../services/flow_store.dart';
import '../../services/timer_plan_store.dart';
import '../../services/pending_queue_store.dart';
import '../../butler/memory/relation_record.dart';
import '../../butler/storage/storage_registry.dart';
import '../../services/relation_change_notifier.dart';
import '../../services/tool_catalog.dart';
import 'widgets/task_list_page.dart';
import '../../data/bug_knowledge_base.dart';
import 'companion_page.dart';
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
import '../../butler/system_template.dart' show SystemTemplate;
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

class _ChatPageState extends State<ChatPage>
    with SingleTickerProviderStateMixin {
  static const double _sideFrac =
      0.85; // 8-06 00:24 用户：80% 还少点 → 85%（唯一比例来源，手势逻辑全走 _sideW getter 联动）
  static const double _snapThr = 0.30;
  static const double _lockThr = 8.0;
  static const double _closeFactor = 2.5;

  // ---- 状态 ----
  double _offset = 0;
  Panel _currentPanel = Panel.center;
  Timer? _notifyWakeTimer; // 8-06 notify_user 超时唤醒

  /// 用户是否在聊天页（全局标志：HomePage 切 tab 同步）——超时唤醒判断用
  bool get _isChatPageActive => GlobalBannerService.instance.userOnChat;

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
    final goingBack =
        (_startPanel == Panel.left && dx < 0) ||
        (_startPanel == Panel.right && dx > 0);
    if (_startPanel != Panel.center && goingBack) {
      factor = _closeFactor;
    }

    double lo, hi;
    switch (_startPanel) {
      case Panel.left:
        lo = 0;
        hi = _sideW;
        break;
      case Panel.right:
        lo = -_sideW;
        hi = 0;
        break;
      case Panel.center:
        lo = -_sideW;
        hi = _sideW;
        break;
    }

    setState(() {
      _offset = (_dragBase + dx * factor).clamp(lo, hi);
    });
  }

  void _onUp(PointerUpEvent e) {
    if (_showPlus) return;
    if (_pointerId != e.pointer) return;
    _pointerId = -1;

    if (!_dragging) {
      _horizLocked = false;
      setState(() {});
      return;
    }

    _dragging = false;
    _horizLocked = false;

    double target;
    Panel nextPanel;

    switch (_startPanel) {
      case Panel.center:
        if (_offset.abs() < _sideW * _snapThr) {
          target = 0;
          nextPanel = Panel.center;
        } else if (_offset > 0) {
          target = _sideW;
          nextPanel = Panel.left;
        } else {
          target = -_sideW;
          nextPanel = Panel.right;
        }
        break;
      case Panel.left:
        if (_offset < _sideW * (1 - _snapThr)) {
          target = 0;
          nextPanel = Panel.center;
        } else {
          target = _sideW;
          nextPanel = Panel.left;
        }
        break;
      case Panel.right:
        if (_offset > -_sideW * (1 - _snapThr)) {
          target = 0;
          nextPanel = Panel.center;
        } else {
          target = -_sideW;
          nextPanel = Panel.right;
        }
        break;
    }

    _currentPanel = nextPanel;
    _animateTo(target);
  }

  // ---- 功能 ----

  void _togglePlus() {
    if (_currentPanel != Panel.center) {
      setState(() {
        _currentPanel = Panel.center;
      });
      _animateTo(0);
      return;
    }
    setState(() => _showPlus = !_showPlus);
  }

  void _selectPersona(MaleLead l, Persona p) {
    _state.setCurrent(l, p);
    _currentPanel = Panel.center;
    _animateTo(0);
    HapticFeedback.lightImpact();
  }

  /// 8-05 14:32：当前聊天用的 AI 是不是内置模拟 AI（测试对话判定）
  /// 8-07 14:03 用户：测试模式开 → 真实 AI 也走测试空间
  /// （通道真实、数据隔离）。测试空间 key = ${personaId}__test，
  /// 退出测试模式按标签一键删；真实数据零接触。
  bool _useTestSpace([String? pid]) {
    final p = pid ?? _state.personaId ?? '';
    return AIProviderManager.testModeEnabled ||
        AIProviderManager.isMockId(
          AIProviderManager.instance.lastProviderFor(p) ?? '',
        );
  }

  /// 设定存储的 persona key：测试模式下走测试空间（${pid}__test），
  /// 男主在测试里改的设定是副本，退出测试模式即删，真实设定零接触。
  String _settingPid() {
    final pid = _state.personaId ?? '';
    return _useTestSpace(pid) ? '$pid${AIProviderManager.mockTestSuffix}' : pid;
  }

  bool _isCurrentMockChat() {
    final pid = _state.personaId;
    if (pid == null || pid.isEmpty) return false;
    return AIProviderManager.isMockId(
      AIProviderManager.instance.lastProviderFor(pid) ?? '',
    );
  }

  /// 8-06 23:55 用户：流程停止条——长任务时强行让男主停止
  Widget _buildFlowStopBar() {
    final pid =
        _state.personaId ??
        (_state.leadId == null ? '' : '${_state.leadId}_default');
    final summary = FlowStore.summary(pid) ?? '流程执行中';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: const Color(0xFF7B6A8F).withValues(alpha: 0.12),
      child: Row(
        children: [
          const Icon(Icons.playlist_play, size: 14, color: Color(0xFF5A4A6A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '男主正在执行流程：$summary',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF5A4A6A),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: _stopFlow,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFB04A5A),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('⏹ 停止', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 8-06 23:55 用户：停止按钮——流程 running → stopped，
  /// 把"停在哪 + 用户说了什么"作为【系统事件】给男主，它决定继续还是先回复
  Future<void> _stopFlow() async {
    final pid =
        _state.personaId ??
        (_state.leadId == null ? '' : '${_state.leadId}_default');
    final flow = await FlowStore.get(pid);
    if (flow == null || !mounted) return;
    final pendingMsgs = PendingQueueStore.list(pid);
    final userText = pendingMsgs
        .map((e) => '[待#${e['id']}] ${e['text']}')
        .join('；');
    final steps =
        (flow['steps'] as List?)?.map((e) => e.toString()).toList() ??
        <String>[];
    final cur = (flow['currentStep'] as num?)?.toInt() ?? 0;
    await FlowStore.stop(pid, userMessages: userText);
    if (mounted) setState(() {});
    final curStep = cur < steps.length ? steps[cur] : '';
    final event =
        '你正在执行的流程被用户打断：目标「${flow['goal']}」，'
        '停在 ${cur + 1}/${steps.length} 步（$curStep）。'
        '她刚才发来的消息（管家收集的）：'
        '${userText.isEmpty ? '（没有新消息，她只是按了停止）' : userText}。'
        '请决定：① 调 manage_flow resume 继续执行流程；'
        '② 先回复她（流程保持暂停，回完再 resume，或 finish/cancel 结束）。';
    if (_generating) {
      // 男主正在跑这轮（工具轮循环中）→ 排队，等它结束自动触发
      _pendingStopEvent = event;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已停止流程，等男主这轮结束就回应你'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    await _sendMsg('', systemEvent: event);
  }

  Future<void> _sendMsg(String t, {String? systemEvent}) async {
    // 8-07 14:03：测试空间设定初始化（首次进测试空间，复制真实设定副本）
    final _tPid =
        _state.personaId ??
        (_state.leadId == null ? '' : '${_state.leadId}_default');
    if (_tPid.isNotEmpty && _useTestSpace(_tPid)) {
      await SettingVersionStore.ensureTestCopy(_tPid);
    }
    // 8-06 23:55 用户：流程执行中用户消息只收集不传（不打扰男主执行）。
    // 放 _generating 前：男主工具轮循环（_generating=true）时消息也不丢。
    // 停止触发的生成（systemEvent 非空）不走收集。
    if (systemEvent == null) {
      final flowPid =
          _state.personaId ??
          (_state.leadId == null ? '' : '${_state.leadId}_default');
      FlowStore.warm(flowPid);
      if (FlowStore.isRunning(flowPid)) {
        PendingQueueStore.enqueue(flowPid, t);
        if (mounted) {
          _msgKey.currentState?.appendMessage(
            ChatMessage(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              text: t,
              isMe: true,
            ),
          );
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('男主正在执行流程，消息已收集（没打扰它）。想打断点 ⏹ 停止'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
    }
    // 8-03 18:2x（用户反馈"男主说完话再说话他不理人"）：生成锁——
    // 男主生成中（含工具轮）新消息直接忽略并提示，防并发上下文混乱
    if (_generating) {
      DebugLogger.log('管家流程', '⏳ 男主正在忙（生成中），忽略新消息: $t');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('男主正在忙，等他回完再说…'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _generating = true;
    final userMsgId = DateTime.now().millisecondsSinceEpoch.toString();
    // 本轮男主第一句话气泡 id 重置（工具气泡只挂本轮第一句话头上）
    _firstAiMsgId = null;
    // 8-06 23:55：停止触发的生成没有用户消息 → 显示系统提示气泡
    _msgKey.currentState?.appendMessage(
      ChatMessage(
        id: userMsgId,
        text: systemEvent == null ? t : '⏸ 你按了停止，男主正在处理…',
        isMe: true,
      ),
    );
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    // 8-06 21:00：工具结果记忆预热（prompt 注入同步读，这里先刷新缓存）
    // 8-06 21:12：便签（当前任务模块）预热
    WorkingPadStore.warm(personaId);
    // 8-06 21:26：定时任务计划预热
    TimerPlanStore.warm(personaId);
    // 8-06 21:36：待回复队列预热
    PendingQueueStore.warm(personaId);
    FlowStore.warm(personaId);
    // 8-06 21:54：常用工具表预热
    FrequentToolsStore.warm(personaId);
    // 8-05 14:36 用户修正：测试对话 ≠ 关功能，而是独立"测试空间"——
    // 模拟 AI 聊天时所有数据（会话/消息/记忆/情绪/上下文总结）落到
    // ${真实persona}__mock__test 这个测试 key，功能照常跑、数据不混；
    // 聊天页 UI 仍显示真实 persona（头像/名字/人设不变）
    // 8-07 14:03：测试模式开 → 无论 mock 还是真实 AI，数据都落测试空间
    final useTestSpace = _useTestSpace(personaId);
    final chatPid = useTestSpace
        ? '${personaId}${AIProviderManager.mockTestSuffix}'
        : personaId;
    // 会话空间切换（真实 ↔ 测试）：旧会话作废，重新建对应空间的
    if (_chatSessionId != null && _chatSessionIsMock != useTestSpace) {
      DebugLogger.log('管家流程', '🧪 会话空间切换（测试↔真实），旧会话作废');
      _chatSessionId = null;
      _chatLeafId = null;
    }
    _chatSessionIsMock = useTestSpace;
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
        // 8-06 23:55：系统事件触发的生成没有用户消息，不落库
        if (systemEvent == null) {
          final userNode = await ChatDatabaseService.instance.appendUserMessage(
            sessionId: _chatSessionId!,
            parentMessageId: _chatLeafId,
            text: t,
          );
          _chatLeafId = userNode.id;
        }
      } catch (e) {
        DebugLogger.log('管家流程', '✖ 对话落库失败（用户消息）: $e');
      }
    }
    try {
      // ===== 管家管线：技能触发 → 假面替换 → 情绪记录（流程树可见）=====
      // 测试对话也跑（链路完整可测），但 characterId 用测试 key →
      // 技能执行/情绪记录全部落在测试空间
      String sendText = systemEvent == null ? t : '';
      String? skillInjection;
      String? keywordAsk;
      try {
        // 8-06 23:55：系统事件不跑管家管线（没有用户文本可分析）
        if (systemEvent == null) {
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
        }
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
        systemEvent: systemEvent,
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
          DebugLogger.log(
            'AI路由',
            '🔧 管家解析到男主工具指令: ${intent.map((c) => c['name']).join('、')}',
          );
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
          final firstMsgId = '${DateTime.now().microsecondsSinceEpoch}_ai0';
          _firstAiMsgId = firstMsgId;
          _msgKey.currentState?.appendMessage(
            ChatMessage(
              id: firstMsgId,
              text: firstText,
              isMe: false,
              thinkingChain: result.reasoningContent,
            ),
          );
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
      // 8-06 21:36：continue 累计计数（交错调用也能防无限"继续说"）
      var continueCount = 0;
      // 8-07 00:1x：用户连续拒绝计数（≥3 强制男主停止尝试）
      var rejectedCount = 0;
      while (result.toolCalls != null && result.toolCalls!.isNotEmpty) {
        toolLoop++;
        toolExecuted = true;
        DebugLogger.log(
          'AI路由',
          '🔧 第 $toolLoop 轮：男主请求 ${result.toolCalls!.length} 个工具',
        );
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
        // 8-07 00:1x：用户拒绝收集——拒绝不走普通工具结果（男主会无视），
        // 这轮工具执行完走【系统事件】通道强制男主决策
        final rejectedTools = <String>[];
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
          DebugLogger.log(
            'AI路由',
            '🔧 工具 $name 参数：${args.isEmpty ? '（空）' : args}',
          );
          if (name == 'record_relation') {
            toolResult = await _executeRelationTool(args);
          } else if (name == 'record_memory') {
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
                words.addAll(
                  kw.split(RegExp(r'[,，、\s]+')).where((w) => w.isNotEmpty),
                );
              }
              if (words.isNotEmpty) {
                ButlerPipelineResult.pendingKeywords.addAll(words);
                DebugLogger.log(
                  '管家流程',
                  '🎯 record_memory 关键词并入规律引擎: ${words.join('、')}',
                );
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
              personaId: personaId,
              toolKey: 'record_memory',
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
            final ok = await _approveToolCall(
              '查记忆',
              '他想查关于「$query」的记忆，允许吗？',
              personaId: personaId,
              toolKey: 'recall_memory',
            );
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
            final ok = await _approveToolCall(
              '记住代号',
              '「$code」：$content\n\n要让他记住吗？',
              personaId: personaId,
              toolKey: 'save_identity_memory',
            );
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
              '查看工具清单',
              '他想看看自己现在有哪些能力可用，允许吗？',
              personaId: personaId,
              toolKey: 'list_tools',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了查看工具清单');
              toolResult = _ToolResult(false, '用户拒绝：暂不查看工具清单');
            } else {
              toolResult = await _executeListToolsTool(args);
            }
          } else if (name == 'write_diary') {
            final content = args['content']?.toString() ?? '';
            _appendToolBubble('男主在写日记…');
            final ok = await _approveToolCall(
              '写日记',
              '「$content」\n\n要让他记下来吗？',
              personaId: personaId,
              toolKey: 'write_diary',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了写日记');
              toolResult = _ToolResult(false, '用户拒绝：暂不写日记');
            } else {
              toolResult = await _executeWriteDiaryTool(content);
            }
          } else if (name == 'query_diary') {
            final keyword = args['keyword']?.toString() ?? '';
            _appendToolBubble('男主在翻日记：$keyword…');
            final ok = await _approveToolCall(
              '翻日记',
              '他想查日记里关于「$keyword」的内容，允许吗？',
              personaId: personaId,
              toolKey: 'query_diary',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了翻日记');
              toolResult = _ToolResult(false, '用户拒绝：暂不翻日记');
            } else {
              toolResult = await _executeQueryDiaryTool(keyword);
            }
          } else if (name == 'notify_user') {
            // 8-06 00:31 用户：男主弹窗（APP内顶部横幅轰炸，APP外之后再做）。
            // 8-06 00:58 修正：弹窗打扰用户 → 默认要审批；
            // 用户批准免审批后（request_permission 申请）男主可直接弹
            final msgCount = (args['messages'] is List)
                ? (args['messages'] as List).length
                : 1;
            final ok = await _approveToolCall(
              '弹消息提醒',
              '他想给你弹 $msgCount 条消息（APP内顶部横幅，像发消息一样）。\n'
                  '允许吗？（批准后他可以在对话里申请这个能力免审批）',
              personaId: personaId,
              toolKey: 'notify_user',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了弹消息提醒');
              toolResult = _ToolResult(false, '用户拒绝：暂不弹消息');
            } else {
              toolResult = await _executeNotifyTool(args);
            }
          } else if (name == 'request_permission') {
            // 8-06 00:58 用户：男主申请某能力免审批 → 弹窗（同意/拒绝 + 可选原因）
            // 免审批工具本身，不需要再审批
            toolResult = await _executeRequestPermission(args);
          } else if (name == 'query_logs') {
            // 8-06 01:03 用户：男主查日志排错（只读，不需要审批）
            toolResult = await _executeQueryLogs(args);
          } else if (name == 'report_bug') {
            // 8-06 01:06 用户：bug 报告弹窗（定位信息+解法+一键复制，只读不需要审批）
            toolResult = await _executeReportBug(args);
          } else if (name == 'countdown_card') {
            // 8-06 13:38 用户：计时卡片（悬浮倒计时卡片，可拖动/收起/选项/逾期提醒）
            // 默认要审批（和 notify_user 一致，可申请免审批）
            final ok = await _approveToolCall(
              '设计时卡片',
              '他想给你设一个倒计时卡片（比如"去洗澡，40分钟后回来"）。\n'
                  '允许吗？（批准后他可以在对话里申请这个能力免审批）',
              personaId: personaId,
              toolKey: 'countdown_card',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了计时卡片');
              toolResult = _ToolResult(false, '用户拒绝：暂不设计时卡片');
            } else {
              toolResult = await _executeCountdownCard(args);
            }
          } else if (name == 'manage_task') {
            // 8-06 13:53 用户：男主管理任务（撤销/调整/回应申请）——默认要审批
            final ok = await _approveToolCall(
              '管理任务',
              '他想${args['action'] == 'cancel'
                  ? '撤销'
                  : args['action'] == 'reject'
                  ? '回应'
                  : '调整'}一个任务卡片，允许吗？',
              personaId: personaId,
              toolKey: 'manage_task',
            );
            if (!ok) {
              toolResult = _ToolResult(false, '用户拒绝：暂不管理任务');
            } else {
              toolResult = await _executeManageTask(args);
            }
          } else if (name == 'update_setting') {
            // 8-06 17:46-18:24 用户：男主主动优化设定 → 弹窗审批（可手动修改）
            // 弹窗本身就是审批动作，不再套确认框
            toolResult = await _executeUpdateSetting(args);
          } else if (name == 'query_setting_history') {
            // 8-06 18:08 用户：男主查设定变更历史（只读，不需要审批）
            toolResult = await _executeQuerySettingHistory(args);
          } else if (name == 'query_record') {
            // 8-06 18:41-19:21 用户：男主查分类记录（只读，不需要审批）
            toolResult = await _executeQueryRecord(args);
          } else if (name == 'add_record') {
            // 男主自己记（他整理的，不打扰她）
            toolResult = await _executeAddRecord(args);
          } else if (name == 'manage_record_tree') {
            // 改分类影响她 → 弹窗审批
            toolResult = await _executeManageRecordTree(args);
          } else if (name == 'manage_pad') {
            // 8-06 21:12 用户：男主自己的便签（当前任务模块），自己维护，免审批
            _appendToolBubble('📋 男主在整理自己的便签…');
            toolResult = await _executeManagePad(args);
          } else if (name == 'manage_flow') {
            // 8-06 23:55 用户：流程层——男主自管（免审批）
            // 长任务先立流程（goal+steps），一条条执行，做完 finish
            _appendToolBubble('📋 男主在整理流程…');
            final action = args['action']?.toString() ?? '';
            if (action == 'create') {
              final goal = args['goal']?.toString() ?? '';
              final stepsRaw = args['steps'];
              final steps = <String>[];
              if (stepsRaw is List) {
                for (final st in stepsRaw) {
                  final t = st.toString().trim();
                  if (t.isNotEmpty) steps.add(t);
                }
              } else if (stepsRaw is String) {
                steps.addAll(
                  stepsRaw
                      .split(RegExp(r'\n+'))
                      .where((st) => st.trim().isNotEmpty),
                );
              }
              toolResult = _ToolResult(
                true,
                await FlowStore.create(personaId, goal, steps),
              );
            } else if (action == 'next') {
              toolResult = _ToolResult(true, await FlowStore.next(personaId));
            } else if (action == 'finish') {
              toolResult = _ToolResult(true, await FlowStore.finish(personaId));
            } else if (action == 'cancel') {
              toolResult = _ToolResult(true, await FlowStore.cancel(personaId));
            } else if (action == 'resume') {
              toolResult = _ToolResult(true, await FlowStore.resume(personaId));
            } else if (action == 'status') {
              toolResult = _ToolResult(
                true,
                FlowStore.text(personaId) ?? '没有流程（create 先立）',
              );
            } else if (action == 'update') {
              // 8-07 00:1x 用户：用户提了新要求 → 更新流程目标/步骤，从头执行
              final goal = args['goal']?.toString();
              final stepsRaw = args['steps'];
              List<String>? steps;
              if (stepsRaw is List) {
                steps = <String>[];
                for (final st in stepsRaw) {
                  final t = st.toString().trim();
                  if (t.isNotEmpty) steps.add(t);
                }
              } else if (stepsRaw is String) {
                steps = stepsRaw
                    .split(RegExp(r'\n+'))
                    .where((st) => st.trim().isNotEmpty)
                    .toList();
              }
              toolResult = _ToolResult(
                true,
                await FlowStore.update(personaId, goal: goal, steps: steps),
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_flow 参数：action=create/next/finish/cancel/resume/status/update，'
                'create/update 要 goal+steps',
              );
            }
            // 流程状态变化 → 刷新停止条
            if (mounted) setState(() {});
          } else if (name == 'manage_frequent_tools') {
            // 8-06 21:54 用户：常用工具表维护（男主自己的，免审批）
            final action = args['action']?.toString() ?? '';
            final name = args['name']?.toString() ?? '';
            if (action == 'add') {
              if (!ToolCatalog.allNames.contains(name)) {
                toolResult = _ToolResult(false, '没有「$name」这个工具');
              } else {
                await FrequentToolsStore.add(personaId, name);
                toolResult = _ToolResult(true, '已加入常用表：$name（每轮都会出现在【你常用的工具】）');
              }
            } else if (action == 'remove') {
              final ok = await FrequentToolsStore.remove(personaId, name);
              toolResult = ok
                  ? _ToolResult(true, '已从常用表移除：$name')
                  : _ToolResult(false, '常用表里没有「$name」');
            } else if (action == 'list') {
              final list = FrequentToolsStore.list(personaId);
              toolResult = _ToolResult(
                true,
                list.isEmpty ? '常用表是空的（add 添加）' : '常用表：${list.join('、')}',
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_frequent_tools 参数：action=add/remove/list，name=工具名',
              );
            }
          } else if (name == 'resolve_pending') {
            // 8-06 21:41 用户：回复标记也走工具（原生就是调工具的）
            // 8-06 21:43：没有"不回"选项——没回的留在待回复区挂着
            // 免审批、不弹气泡（男主的话本身就是回复）
            final rIds = <int>[];
            final rRaw = args['replied_ids'];
            if (rRaw is List) {
              for (final v in rRaw) {
                final n = (v as num?)?.toInt();
                if (n != null && n >= 1) rIds.add(n);
              }
            }
            if (rIds.isEmpty) {
              toolResult = const _ToolResult(
                false,
                'resolve_pending 参数不对：replied_ids 至少要有一个编号',
              );
            } else {
              await PendingQueueStore.removeByIds(personaId, rIds);
              toolResult = _ToolResult(true, '已标记回复：待#${rIds.join('、')}');
            }
          } else if (name == 'continue_speaking') {
            // 8-06 21:36 用户：男主不等她继续说话——调"继续"工具，
            // 系统自动再生成一轮（不带她消息）；免审批、不弹气泡
            toolResult = _ToolResult(true, '继续');
          } else {
            toolResult = _ToolResult(false, '未知工具：$name');
          }
          // 完成/失败气泡（用户 8-03 01:57）：执行完必须给用户明确反馈
          // 8-06 21:36：continue/resolve_pending 不弹气泡（男主的话本身就是反馈）
          if (name != 'continue_speaking' && name != 'resolve_pending') {
            _appendToolResultBubble(name, toolResult);
          }
          DebugLogger.log(
            'AI路由',
            '🔧 工具 $name 结果：${toolResult.text.length > 80 ? toolResult.text.substring(0, 80) + '…' : toolResult.text}',
          );
          // 8-04 17:0x（用户：上下文要留地方放工具，男主才知道做过什么；
          // 带时间戳+成败+原因，失败后才能继续调工具解决）：
          // 工具调用记录进上下文（stateless 全量带 → 男主看得到）
          ContextManager.instance.feedToolCall(
            personaId,
            name,
            toolResult.ok,
            toolResult.text,
          );
          // 8-07 00:1x：审批拒绝系统事件化——拒绝结果同时收集，
          // 这轮工具执行完统一走【系统事件】通道（不是普通工具结果）
          if (!toolResult.ok && toolResult.text.startsWith('用户拒绝')) {
            rejectedTools.add(
              '「$name」${toolResult.text.replaceFirst('用户拒绝：', '：')}',
            );
          }
          // 8-06 21:36：continue/resolve_pending 结果不回填工具消息
          final isContinue =
              name == 'continue_speaking' || name == 'resolve_pending';
          if (!isContinue && nativeCalls.contains(call)) {
            // 原生：tool 消息必须用模型给的 id 配对（不能自己编 id）
            // 8-04 17:0x（用户：📄 里工具轮要简化成"成功/失败+一句话"）：
            // content 统一带【工具 名】+ ✅成功/❌失败 标记 —— 模型看得更清楚，
            // 📄 展示层也能解析出工具名和结果好坏
            toolMessages.add(
              AIChatMessage(
                role: 'tool',
                // 8-06 00:51 用户：调用工具=需要审批；成功调用=审批通过。
                // 工具消息在系统分区，天然不是用户说的话——不用额外解释
                content:
                    '【工具 $name】${toolResult.ok ? '✅成功（审批通过）' : '❌失败（审批未过）'}：${toolResult.text}',
                toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
              ),
            );
          } else if (isContinue) {
            // continue（文本块格式）：不收集结果
          } else {
            // 文本块：结果收集，最后合并注入 user 消息
            textToolResults.add(
              '【工具 $name】${toolResult.ok ? '✅成功' : '❌失败'}：${toolResult.text}',
            );
          }
          // 防死循环：同一工具连续调用 ≥3 次 → 停止本轮
          final n = (consecutiveToolCounts[name] ?? 0) + 1;
          consecutiveToolCounts[name] = n;
          // 8-06 21:36：continue 本轮累计 ≥3 次也停（交错调用防不住"连续"计数）
          if (name == 'continue_speaking') continueCount++;
          if (n >= 3 || (name == 'continue_speaking' && continueCount >= 3)) {
            loopExceeded = true;
            DebugLogger.log(
              'AI路由',
              '⚠️ 工具 $name 调用 $n 次（continue 累计 $continueCount），强制停止（防死循环）',
            );
          }
        }
        if (loopExceeded) break;
        // 文本块工具结果：合并注入 user 消息（不走原生 tool_calls，兜底通道）
        // 8-04 18:1x（用户：男主分不清用户话和工具结果）：明确标注
        // "这是工具返回结果，不是用户说的"——防止模型把结果当用户指令
        if (textToolResults.isNotEmpty) {
          toolMessages.add(
            AIChatMessage(
              role: 'user',
              content:
                  '【系统·工具执行结果】\n'
                  '${textToolResults.join('\n')}\n\n'
                  '基于结果自然地回复用户，不要再调用工具。',
            ),
          );
        }
        // 8-03 18:27：工具轮生成也是男主打字阶段 → 显示"正在输出"
        ChatPresence.instance.beginTyping();
        result = await _aiSvc.generateReply(
          '',
          personaId,
          personaName: personaName,
          personaPrompt: _currentPersonaPrompt(),
          toolRound: true,
          // 8-06 21:12 用户 bug：第一轮男主已回过话 → 工具轮别再带旧话（防回复两句）
          userAlreadyReplied: result.text.trim().isNotEmpty,
          toolMessages: toolMessages,
          sessionId: _chatSessionId,
          storagePersonaId: chatPid,
        );
        if (result.text.trim().isNotEmpty) {
          replyTexts.add(result.text.trim());
          // 8-03 18:2x：工具轮男主回复也立即追加显示（渐进，不等循环结束）
          final roundText = await _displayableText(result.text);
          if (roundText.isNotEmpty) {
            _msgKey.currentState?.appendMessage(
              ChatMessage(
                id: '${DateTime.now().microsecondsSinceEpoch}_ai$toolLoop',
                text: roundText,
                isMe: false,
                thinkingChain: result.reasoningContent,
              ),
            );
            // 打字机接管，"正在输出"由播完时 endTyping 关闭
          } else {
            ChatPresence.instance.endTyping();
          }
        } else {
          // 工具轮没说话（可能又调工具）→ 工具阶段不显示
          ChatPresence.instance.endTyping();
        }
        // 8-07 00:1x 用户：审批拒绝系统事件化（GPT 方案④：task_rejected
        // 不是普通 user/tool 消息）——男主收到明确事件，必须决策：
        // 换方案 / 跳过这步 / 取消流程 / 先回复她。不能当没看见继续傻走。
        if (rejectedTools.isNotEmpty) {
          rejectedCount++;
          String flowInfo = '';
          final flowText = FlowStore.text(personaId);
          if (flowText != null && flowText.isNotEmpty) {
            flowInfo = '你正在执行流程：\n$flowText\n';
          }
          final event =
              '你调用的工具被她拒绝了：${rejectedTools.join('；')}。\n'
              '$flowInfo'
              '${rejectedCount >= 3 ? '她已经连续拒绝 3 次了，别再尝试这个方向，直接回复她。' : '请决定下一步：换方案 / 跳过这步 / 取消流程 / 先回复她。'}';
          rejectedTools.clear();
          ChatPresence.instance.beginTyping();
          result = await _aiSvc.generateReply(
            '',
            personaId,
            personaName: personaName,
            personaPrompt: _currentPersonaPrompt(),
            userAlreadyReplied: true,
            sessionId: _chatSessionId,
            storagePersonaId: chatPid,
            systemEvent: event,
          );
          if (result.text.trim().isNotEmpty) {
            replyTexts.add(result.text.trim());
            final eventText = await _displayableText(result.text);
            if (eventText.isNotEmpty) {
              _msgKey.currentState?.appendMessage(
                ChatMessage(
                  id: '${DateTime.now().microsecondsSinceEpoch}_aiRej$rejectedCount',
                  text: eventText,
                  isMe: false,
                  thinkingChain: result.reasoningContent,
                ),
              );
            } else {
              ChatPresence.instance.endTyping();
            }
          } else {
            ChatPresence.instance.endTyping();
          }
        }
      }

      // 剥离 #keywords（仅管家可见）→ 显示/落库用干净文本
      var displayText = ButlerPipelineResult.extractKeywordsFromReply(
        replyTexts.join('\n'),
      );
      // 8-06 21:36 用户：男主回复带编号 → 管家按标注消除待回复
      // （"回待#1、待#2"消除对应；"不回待#3"也消除=放下；没标注兜底消最老一条）
      if (result.text.trim().isNotEmpty) {
        final removed = await PendingQueueStore.resolve(personaId, result.text);
        if (removed.isNotEmpty) {
          DebugLogger.log('指令模块', '📥 待回复已消除 待#${removed.join('、')}（男主回复带编号）');
        }
      }
      // 指令模块：解析男主输出（#记录/#查记忆/#定时/#帮助/#model）→ 审批弹窗
      final commands = ButlerCommandParser.instance.parse(result.text.trim());
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
          final aiNode = await ChatDatabaseService.instance
              .appendAssistantMessage(
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('男主这次没有回复，再发一条试试'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      if (result.failedProviders.isNotEmpty) {
        // 自动切换发生了，告诉用户一声（不打断）
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.failedProviders.join('、')} 不可用，已自动切换到 ${result.providerName ?? '下一个'}',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送失败：$e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      // 生成锁释放（无论如何）
      _generating = false;
      // 无论如何：清零"正在输出"（打字机播完已 endTyping，这里兜底；
      // 失败则保持未读，男主没读到）
      ChatPresence.instance.resetTyping();
      // 作息规律：当天首次聊天 → 记开始时间（用户一般几点来找男主）
      // 8-05 14:36：测试对话不算用户行为（作息统计是用户维度，跳过）
      if (personaId.isNotEmpty && !_chatSessionIsMock) {
        unawaited(_recordChatStart());
      }
      // 用户 21:10：日记 = 男主每天结束（用户睡觉后）写的当天总结。
      // 用户消息含结束信号（睡了/晚安/睡觉/拜拜…）→ 男主写完回复后，
      // 管家把当天对话原文交给男主写当天日记（异步，不打断用户）。
      // 21:13：同时记录"平均结束聊时间"（用户一般聊到几点睡）。
      // 8-05 14:36：测试对话写测试空间的日记（chatPid），不碰真实日记
      if (personaId.isNotEmpty && _isEndOfDaySignal(t)) {
        if (!_chatSessionIsMock) unawaited(_recordChatEnd());
        unawaited(_writeDailyDiary(chatPid, personaName));
      }
    }
    // 8-06 23:55：停止事件排队——这轮结束（无论成败）自动触发，不丢
    final pendingStop = _pendingStopEvent;
    if (pendingStop != null) {
      _pendingStopEvent = null;
      if (mounted) unawaited(_sendMsg('', systemEvent: pendingStop));
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
    return RegExp(r'睡了|晚安|睡觉|拜拜|下线|去睡|要睡了|碎觉|不聊了|先这样').hasMatch(text);
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
      final diary = await _aiSvc.generateDailyDiary(
        personaId,
        personaName,
        raw,
      );
      if (diary.isNotEmpty) {
        await ChatDatabaseService.instance.saveDiaryEntry(personaId, diary);
        DebugLogger.log('指令模块', '✅ 当天日记已写（${diary.length} 字）');
      }
    } on Object catch (e) {
      DebugLogger.log('指令模块', '⚠️ 写日记失败（静默）: $e');
    }
  }

  /// 自动切换关闭时的弹窗：告诉用户当前 AI 不可用，让 ta 检查。
  Future<void> _showAiUnavailableDialog(
    AIProviderUnavailableException e,
  ) async {
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
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AiConfigPage()));
  }

  /// 打开 AI 设置弹层（当前 AI / 自动切换 / 候选勾选）。
  Future<void> _openAiSheet() async {
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    // 8-06 21:00：工具结果记忆预热（prompt 注入同步读，这里先刷新缓存）
    // 8-06 21:12：便签（当前任务模块）预热
    WorkingPadStore.warm(personaId);
    // 8-06 21:26：定时任务计划预热
    TimerPlanStore.warm(personaId);
    // 8-06 21:36：待回复队列预热
    PendingQueueStore.warm(personaId);
    FlowStore.warm(personaId);
    // 8-06 21:54：常用工具表预热
    FrequentToolsStore.warm(personaId);
    await showAiProviderSheet(
      context: context,
      personaId: personaId,
      personaName: personaName,
      onAcceptance: _runAcceptance,
      onForceSummarize: _forceSummarizeNow,
      onTestSetting: _runTestSetting,
    );
  }

  /// 8-07 14:03 用户：🚀 一键测设定——真实 AI 通道自动发测试指令，
  /// 测「设定段落化」（update_setting 的 tag 定位 + 多轮审批弹窗）。
  /// 数据落测试空间（${pid}__test），退出测试模式自动清空。
  Future<void> _runTestSetting() async {
    final pid = _state.personaId ?? '';
    if (pid.isEmpty) return;
    await SettingVersionStore.ensureTestCopy(pid);
    if (mounted) {
      _appendToolBubble('🧪 一键测设定：真实 AI 通道测试开始（数据落测试空间，退出测试模式自动清空）');
    }
    await _sendMsg(
      '【测试指令】现在测一下「设定修改」功能，请按步骤做：\n'
      '1. 用 update_setting 工具，给男主设定新增一段【测试标记】标签，'
      '内容写"测试通过"（只加这一段，不要整体重写、不要动其他段落）；\n'
      '2. 再用 query_setting_history 查一下，确认这次变更已记录；\n'
      '3. 最后告诉我：你加了哪段、用的什么 action。\n'
      '（审批弹窗正常发起即可，这是测试）',
    );
  }

  /// 8-05 22:40 用户：转正为日常功能「手动精简上下文·省 token」——
  /// 随时把当前角色对话压缩成摘要（原文→【男主摘要】带 #编号），
  /// 不用等窗口满。走真实 generateReply 路径（C 自动拼 + 本次对话 +
  /// 【当前管家】指令 + save_summary）。
  /// 确认框把关：真实模式会真动当前对话（原文→摘要，不可恢复）。
  Future<void> _forceSummarizeNow() async {
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    if (lid == null) return;
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    final isMock = _useTestSpace();
    final chatPid = isMock
        ? '${personaId}${AIProviderManager.mockTestSuffix}'
        : personaId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('精简上下文·省 token'),
        content: Text(
          isMock
              ? '将当前对话压缩成摘要（原文→摘要区，带 #编号）。\n继续？'
              : '将当前对话压缩成摘要（原文→摘要区，带 #编号）。\n'
                    '这是真实数据，压缩后原文不可恢复。\n继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('精简'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (mounted) {
      setState(() => _acceptanceNote = '🗜️ 精简上下文进行中…');
    }
    // 总结是管家主动行为：C（带人设）+ 原文 + 【当前管家】指令。
    // userProfile/taskState 是"当前用户消息"的注入，总结不需要。
    await _aiSvc.forceSummarizeNow(
      chatPid,
      personaName,
      personaPrompt: _currentPersonaPrompt(),
    );
    if (mounted) {
      setState(() => _acceptanceNote = '✅ 精简完成（摘要区+原文已更新）');
    }
  }

  void _openWorld() {
    if (!_state.hasLead) return;
    final lid = _state.lead!.id;
    final pid = _state.persona?.id ?? '${lid}_default';
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => CharacterWorldPage(
          lead: _state.lead!,
          persona:
              _state.persona ?? Persona(id: pid, maleLeadId: lid, name: '默认'),
        ),
        transitionsBuilder: (_, a, __, c) =>
            FadeTransition(opacity: a, child: c),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
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
        saved = await _localStore.saveLeadBackgroundFromBytes(
          _state.leadId!,
          file.bytes!,
        );
      } else {
        saved = await _localStore.saveLeadBackground(
          _state.leadId!,
          File(file.path!),
        );
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
          SnackBar(
            content: Text('背景设置失败：$e'),
            duration: const Duration(seconds: 2),
          ),
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
        savedPath = await _localStore.savePersonaAvatarFromBytes(
          _state.leadId!,
          _state.personaId!,
          file.bytes!,
        );
      } else {
        savedPath = await _localStore.savePersonaAvatar(
          _state.leadId!,
          _state.personaId!,
          File(file.path!),
        );
      }
      await _state.updateAvatar(savedPath);
    } catch (e) {
      _resetGestureState();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('头像设置失败：$e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _anim.removeListener(_onAnimTick);
    _anim.dispose();
    _notifyWakeTimer?.cancel(); // 8-06 notify_user 超时唤醒
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
            onOpenSettings: () {
              _currentPanel = Panel.right;
              _animateTo(-sideW);
            },
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
                  ChatTopBar(
                    currentLead: _state.lead,
                    currentPersona: _state.persona,
                    onTapAvatar: _openWorld,
                    // 8-05 23:45：右上角设计感按钮 → 陪伴三页；
                    // 设定右页入口移到陪伴页的小齿轮（onOpenSettings）
                    onCompanionTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CompanionPage()),
                    ),
                    onAiTap: _openAiSheet,
                    onNameChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                  // 一键验收横幅（8-04 21:1x：自动切 AI 跑对话时显示进度/结论）
                  if (_acceptanceNote != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
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
                            const Icon(
                              Icons.rocket_launch,
                              size: 14,
                              color: Color(0xFF7B6A8F),
                            ),
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
                                  Image.file(
                                    _currentBg!,
                                    fit: BoxFit.cover,
                                    width: screenW,
                                    height: MediaQuery.of(context).size.height,
                                    key: ValueKey(
                                      'bg_${_currentBg!.path}_${_currentBg!.lastModifiedSync().millisecondsSinceEpoch}',
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: BackdropFilter(
                                      filter: ui.ImageFilter.blur(
                                        sigmaX: 6,
                                        sigmaY: 6,
                                      ),
                                      child: Container(
                                        color: Colors.black.withValues(
                                          alpha: 0.08,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        // 消息列表在背景之上
                        // 8-05 14:36：测试对话落测试空间的库（storagePersonaId），
                        // 历史加载也读测试空间（测试对话退出再进还在）
                        ChatMessageArea(
                          key: _msgKey,
                          currentPersona: _state.persona,
                          characterAvatarPath: _state.effectiveAvatarPath,
                          onAvatarTap: _openWorld,
                          storagePersonaId: _useTestSpace()
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
                  if (AIProviderManager.testModeEnabled) _buildTestModeBanner(),
                  // 8-06 23:55 用户：流程执行中显示"⏹ 停止"条——
                  // 长任务时用户可强行让男主停止，返回结果给它判断
                  if (FlowStore.isRunning(
                    _state.personaId ??
                        (_state.leadId == null
                            ? ''
                            : '${_state.leadId}_default'),
                  ))
                    _buildFlowStopBar(),
                  ChatInputBar(
                    onCameraTap: () {},
                    onVoiceTap: () {},
                    onPlusTap: _togglePlus,
                    onSendTap: _sendMsg,
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
            onClosePanel: () {
              _currentPanel = Panel.center;
              _animateTo(0);
              // 删除 Persona 后强制重建（左页/右页/中间页状态一致）
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => setState(() {}),
              );
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
          Positioned.fill(
            child: PlusMenu(
              onDismiss: () => setState(() => _showPlus = false),
              onPickAvatar: _pickAvatarFromPlus,
              onPickBg: _pickBgImage,
            ),
          ),

        // ===== 🔁 让男主重新认识按钮（8-04 23:4x 用户）=====
        // 只带【已总结摘要+恢复包+当次未总结原文】（总结过的旧原文不重复扔），
        // 全量发给男主重新熟悉——不赌 AI 记没记住，错了手动救
        if (AIProviderManager.testModeEnabled)
          Positioned(
            right: 106,
            top: MediaQuery.of(context).padding.top + 4,
            child: GestureDetector(
              onTap: _resyncContext,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  shape: BoxShape.circle,
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
            right: 72,
            top: MediaQuery.of(context).padding.top + 4,
            child: GestureDetector(
              onTap: _showSimulation,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.science_outlined,
                  size: 15,
                  color: Colors.white70,
                ),
              ),
            ),
          ),

        // ===== 📄 prompt 查看按钮（透明化：男主"知道什么"一目了然）=====
        if (AIProviderManager.testModeEnabled)
          Positioned(
            right: 38,
            top: MediaQuery.of(context).padding.top + 4,
            child: GestureDetector(
              onTap: _showPromptDialog,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.description_outlined,
                  size: 15,
                  color: Colors.white70,
                ),
              ),
            ),
          ),

        // ===== 调试日志按钮（右上角） =====
        if (AIProviderManager.testModeEnabled)
          Positioned(
            right: 4,
            top: MediaQuery.of(context).padding.top + 4,
            child: GestureDetector(
              onTap: _showDebugLog,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.bug_report,
                  size: 16,
                  color: Colors.white70,
                ),
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
          const Icon(
            Icons.science_outlined,
            size: 15,
            color: Color(0xFF7B6A8F),
          ),
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('男主正在回复，稍等一下'),
                      duration: Duration(seconds: 1),
                    ),
                  );
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
                  border: Border.all(
                    color: const Color(0xFFD9C3CE),
                    width: 0.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    p,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6A4A5A),
                    ),
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

    Future<void> round(
      int n,
      String userText,
      String aiText, {
      String note = '',
    }) async {
      sb.writeln('\n──── 轮$n　用户：「$userText」────');
      if (note.isNotEmpty) sb.writeln('　⚙️ $note');
      // 1) generateReply 真实顺序：先组装历史（此刻不含本条用户消息）
      final hist = ContextManager.instance.buildHistoryMessages(pid);
      sb.writeln('▶ 发给模型的历史 ${hist.length} 条：');
      if (hist.isEmpty) sb.writeln('　（空）');
      for (final h in hist) {
        sb.writeln(
          '　[${h.role}] ${h.content.replaceAll(RegExp(r'\\s+'), ' ')}',
        );
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
    await round(2, '记住我喜欢喝美式咖啡', '好的，我记住了，你爱喝美式咖啡。', note: '场景A：男主正常文本回复');
    await round(
      3,
      '我之前说过喜欢什么吗',
      '我查查看。',
      note: '场景B：男主只调工具没说话（真实=原生tool_calls无文本）→ 这轮男主话不进上下文',
    );
    await round(
      4,
      '那你查到了吗',
      '查到了，你说过喜欢猫。',
      note: '场景C：关键验证——上一轮男主"我查查看"还在历史里吗？',
    );
    await round(5, '你都记得我什么呀', '记得你爱喝美式咖啡、喜欢猫。', note: '场景D：男主话含中文意图词，验证解析');

    sb.writeln('\n════════ 当前上下文全貌（peekRaw）════════');
    final rawAll = ContextManager.instance.peekRaw(pid);
    sb.writeln(rawAll.isEmpty ? '（空）' : rawAll);
    sb.writeln('\n════════ 结论判断 ════════');
    final raw = rawAll;
    final userCount = '用户：'.allMatches(raw).length;
    final aiCount = '男主：'.allMatches(raw).length;
    sb.writeln('上下文里 用户 $userCount 条 / 男主 $aiCount 条');
    sb.writeln(
      aiCount >= userCount - 1
          ? '✅ 男主消息正常进上下文（说明链路OK，问题在AI侧/工具轮）'
          : '❌ 男主消息丢失（$aiCount 少于 ${userCount - 1}）→ 查 feedAssistantMessage 调用链',
    );

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
      final isMock = _useTestSpace(personaId);
      ChatStorageService().appendMessage(
        isMock ? '${personaId}${AIProviderManager.mockTestSuffix}' : personaId,
        msg,
      );
    }
  }

  /// 工具气泡自增序号（防同一微秒撞 id）
  int _toolBubbleSeq = 0;

  /// 8-03 18:2x：男主生成锁（防并发——男主生成中再发消息会上下文混乱）
  bool _generating = false;
  // 8-06 23:55：停止事件排队——男主生成中按停止，等这轮结束自动触发
  String? _pendingStopEvent;

  /// 8-04 21:1x：一键验收进行中（自动切 AI 跑真实对话）
  bool _accepting = false;

  /// 验收顶部横幅当前提示
  String? _acceptanceNote;

  /// 8-07 15:0x 用户：验收弹窗分不清是哪一步——当前验收步骤标签
  /// （如 '⑨/12 设定·只改喜好段'），弹窗标题里显示，非验收时 null
  String? _acceptingStep;

  /// 8-04 21:1x 用户："一键跑对话，自动切换 AI，对话体现在聊天框，
  /// 我只需要点允许写/允许查，写成一个验收流程看逻辑对不对"
  /// 真实对话全链路验收：自动切 5 个模拟 AI 形态 + 自动发消息，
  /// 工具授权弹窗正常弹（用户点）；每步结论以 📋 消息注入聊天框。
  Future<void> _runAcceptance() async {
    if (_accepting) return;
    if (_generating) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('男主正在忙，等他回完再验收…'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final lid = _state.leadId;
    if (lid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('先选一个男主再验收'),
          duration: Duration(seconds: 2),
        ),
      );
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
      _msgKey.currentState?.appendMessage(
        ChatMessage(
          id: 'accept_${DateTime.now().millisecondsSinceEpoch}',
          text: text,
          isMe: false,
        ),
      );
    }

    /// 发消息并等男主回完（含工具授权弹窗等待）
    /// [waitLong]：多轮会话弹窗步骤用（用户要在弹窗里跟男主来回，给 8 分钟）
    Future<void> say(String t, {bool waitLong = false}) async {
      await _sendMsg(t);
      var waited = 0;
      final maxWait = waitLong ? 960 : 240;
      while (_generating && waited < maxWait) {
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
      record('① AI A建立话题', aOk, aOk ? null : '原文为空——用户消息没进上下文，后面全白搭');
      note('📋 ① ${aOk ? '✓' : '✗'} 原文 ${rawA.length} 字');

      // ── ② 切 AI B（无记忆·思考关）：验证切换后上下文不丢 ──
      await sw('builtin-mock-b', '②/⑧ AI B 无记忆·思考关 — 验证切换不失忆');
      note('📋 ② 切 AI B：验证切换后不失忆');
      await say('我刚才说我喜欢的颜色是什么？');
      final histB = ctx.buildHistoryMessages(testPid, modelHint: 'mock-1');
      final bOk = histB.isNotEmpty;
      record(
        '② 切换AI B后全量带历史',
        bOk,
        bOk ? null : '历史为空——stateless 切换后没带上下文，男主会失忆',
      );
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
      record(
        '③ stateful切换全量带',
        cOk,
        cOk
            ? null
            : 'stateful=${d.stateful} 组装历史=${histC.length}条——'
                  '切到有记忆AI没全量带，男主失忆',
      );
      note('📋 ③ ${cOk ? '✓' : '✗'} stateful=${d.stateful} 组装${histC.length}条');

      // ── ④ AI C 连续使用：验证轻量 ──
      await sw('builtin-mock-c', '④/⑧ AI C 连续使用 — 验证轻量');
      note('📋 ④ AI C 连续使用：验证轻量');
      await say('那你觉得蓝色和美式咖啡配吗？');
      d = svc.assembleDecision(testPid, toolRound: false);
      final dOk = d.stateful && !d.needRecover;
      // 8-05 20:0x（④ 反复失败）：失败原因带完整决策值——
      // switched/idleExpired/forceRecover 哪个 true 一目了然，直接定位
      record(
        '④ stateful连续轻量',
        dOk,
        dOk
            ? null
            : '连续使用还全量带——浪费 token'
                  '(stateful=${d.stateful} switched=${d.switched} '
                  'idleExpired=${d.idleExpired} forceRecover=${d.forceRecover})',
      );
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
      await say(
        '我们今天还聊了散步、读书、做饭、旅行、听音乐，'
        '这些话题我慢慢说给你听。',
      );
      await say(
        '对了，我最近在学做菜，喜欢研究新菜谱，'
        '周末还想去爬山，你觉得怎么样？',
      );
      final summaries = ctx.summariesFor(testPid);
      // 8-05 19:40（用户：本地AI测试走通，真实男主才稳）：
      // v2 总结必须走 save_summary 工具路径——摘要条目带（#1-#N）范围标记；
      // 只有内容没编号 = 走了文本兜底（男主没调工具），真实场景会不稳
      final sumHasRange = summaries.any(
        (x) => x.contains('（#') && x.contains('-#'),
      );
      final sumOk = summaries.isNotEmpty && sumHasRange;
      if (!sumOk) {
        // 自诊断：失败原因直接带数据，弹窗复制发龙虾即可定位
        final budget = ctx.topicBudgetChars(testPid, modelHint: 'mock-1');
        final rawLen = ctx.debugRawLength(testPid);
        final st = svc.assembleDecision(testPid, toolRound: false).stateful;
        DebugLogger.log(
          'AI验收',
          '⑤自诊断: 预算=$budget 原文=$rawLen stateful=$st'
              ' 摘要=${summaries.length}条 带编号=$sumHasRange',
        );
      }
      record(
        '⑤ token满男主调save_summary总结',
        sumOk,
        sumOk
            ? null
            : '摘要${summaries.length}条，带编号=$sumHasRange'
                  '（诊断:预算=${ctx.topicBudgetChars(testPid, modelHint: 'mock-1')}'
                  '字 原文=${ctx.debugRawLength(testPid)}字 '
                  'stateful=${svc.assembleDecision(testPid, toolRound: false).stateful}'
                  '——摘要没编号=走了文本兜底，男主没调 save_summary；'
                  '日志看「上下文管理」有无"✂️ 原文攒够了"',
      );
      note(
        '📋 ⑤ ${sumOk ? '✓' : '✗'} 摘要 ${summaries.length} 条'
        ' 带编号=$sumHasRange',
      );

      // ── ⑥ 切 AI E（无记忆·工具关）：验证总结后上下文不丢 ──
      await sw('builtin-mock-e', '⑥/⑧ AI E 无记忆·工具关 — 验证总结后不失忆');
      note('📋 ⑥ 切 AI E：验证总结后上下文不丢');
      await say('刚才我们聊了好多，你能总结一下都聊了什么吗？');
      final histE = ctx.buildHistoryMessages(testPid, modelHint: 'mock-1');
      final hasSummary = histE.any(
        (m) => m.role == 'system' && m.content.contains('男主摘要'),
      );
      final eOk = hasSummary;
      record('⑥ 总结后切换带摘要', eOk, eOk ? null : '切 E 后历史里没有【男主摘要】——总结丢了，男主失忆');
      note('📋 ⑥ ${eOk ? '✓' : '✗'} 含摘要=${hasSummary}');

      // ── ⑦ 切回 AI C（有记忆1h）：1h 快到之前 → 男主写三类存档 ──
      // 8-04 21:3x 用户："超过1小时没聊，1小时快到之前就要让AI做总结，
      // 下次聊把上下文/总结/恢复包扔给他，不然全都没了"
      // 模拟：距上次聊天 40 分钟（> 超时一半 30min）→ 下次聊天时补沉淀
      await sw('builtin-mock-c', '⑦/⑧ AI C 有记忆1h — 模拟空闲40分钟→沉淀');
      note('📋 ⑦ 切 AI C：模拟 40 分钟没聊 → 男主应写三类存档（摘要+恢复包）');
      await say('我们约好了周末去爬山，别忘啦。');
      ctx.debugSetLastChatAt(
        testPid,
        DateTime.now().subtract(const Duration(minutes: 40)),
      );
      await say('在吗？刚想到爬山的事，周末天气怎么样都去对吧？');
      final recovery7 = ctx.recoveryFor(testPid);
      final sum7 = ctx.summariesFor(testPid);
      final gOk = recovery7 != null && recovery7.isNotEmpty && sum7.isNotEmpty;
      record(
        '⑦ 空闲过半触发沉淀（恢复包+摘要）',
        gOk,
        gOk
            ? null
            : '恢复包=${recovery7 == null ? '无' : '有'} 摘要=${sum7.length}条——'
                  '没触发沉淀。日志看「上下文管理」有没有"📝 空闲超时…趁 AI 还记得"',
      );
      note(
        '📋 ⑦ ${gOk ? '✓' : '✗'} 恢复包=${recovery7 == null ? '无' : '有'} 摘要=${sum7.length}条',
      );

      // ── ⑧ 模拟超过 1h：下次聊 → 带恢复包+摘要接上 ──
      // 8-04 21:5x 修：assembleDecision 要在 say 前读（say 里 feed 会把
      // lastChat 刷新成 now，say 后读永远判不出超时）——决策输入验证
      // 看 say 前，组装结果看 say 后（恢复包在内存，与 lastChat 无关）
      await sw('builtin-mock-c', '⑧/⑧ 模拟超时1h → 带恢复包接上');
      note('📋 ⑧ 模拟超过 1 小时没聊 → 应判空闲超时，全量带恢复包');
      ctx.debugSetLastChatAt(
        testPid,
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      final dPre = svc.assembleDecision(testPid, toolRound: false);
      await say('我回来了，我们继续聊吧。');
      final histRec = ctx.buildHistoryMessages(testPid, modelHint: 'mock-1');
      final hasRec = histRec.any(
        (m) => m.role == 'system' && m.content.contains('恢复包'),
      );
      final hOk = dPre.idleExpired && dPre.needRecover && hasRec;
      record(
        '⑧ 超时后带恢复包接上',
        hOk,
        hOk
            ? null
            : '决策(idleExpired=${dPre.idleExpired} '
                  'needRecover=${dPre.needRecover}) 含恢复包=$hasRec——'
                  '超时后没带恢复包，男主失忆',
      );
      note(
        '📋 ⑧ ${hOk ? '✓' : '✗'} idleExpired=${dPre.idleExpired} 含恢复包=$hasRec',
      );

      // ── ⑨-⑫ 设定功能（8-07 14:12 用户：剧本覆盖设定段落化+多轮弹窗）──
      // 验收前：给测试空间写固定测试设定（段落化，断言用）
      await SettingVersionStore.saveNewVersion(
        testPid,
        'male',
        '【身份】测试角色\n【喜好】测试喜好A',
        note: '验收剧本初始化',
      );
      // ⑨ 段落化 update：只改【喜好】段，其他段落不动（弹窗用户点同意）
      await sw('builtin-mock', '⑨/⑫ 设定·改一段（tag 定位）');
      _acceptingStep = '⑨/12 设定·只改【喜好】段（其他段不能动）';
      note('📋 ⑨ 让男主用 update_setting 只改【喜好】段——弹窗点「就用这版」');
      await say(
        '用 update_setting 工具，把男主设定里的【喜好】段改成"测试喜好B"，'
        '只改这一段，别动其他段落。',
      );
      final book9 = await SettingVersionStore.load(testPid);
      final male9 = book9.currentMale;
      final i9 =
          male9.contains('测试喜好B') &&
          male9.contains('【身份】测试角色') &&
          !male9.contains('测试喜好A');
      record(
        '⑨ 设定update只改目标段',
        i9,
        i9 ? null : '当前男主设定：$male9——段落没精准替换或误动了其他段',
      );
      note(
        '📋 ⑨ ${i9 ? '✓' : '✗'} 喜好段已替换=${male9.contains('测试喜好B')}'
        ' 身份段未动=${male9.contains('【身份】测试角色')}',
      );

      // ⑩ 段落化 add：新增一段
      await sw('builtin-mock', '⑩/⑫ 设定·新增一段');
      _acceptingStep = '⑩/12 设定·新增【测试段】';
      note('📋 ⑩ 让男主用 update_setting 新增【测试段】——弹窗点「就用这版」');
      await say('再用 update_setting 新增一段【测试段】，内容写"验收新增"，别动其他段落。');
      final book10 = await SettingVersionStore.load(testPid);
      final i10 = book10.currentMale.contains('【测试段】验收新增');
      record(
        '⑩ 设定add新增段',
        i10,
        i10 ? null : '当前男主设定：${book10.currentMale}——新增段没成功',
      );
      note('📋 ⑩ ${i10 ? '✓' : '✗'} 新增段=${i10}');

      // ⑪ 段落化 delete：删掉新增段
      await sw('builtin-mock', '⑪/⑫ 设定·删一段');
      _acceptingStep = '⑪/12 设定·删除【测试段】';
      note('📋 ⑪ 让男主用 update_setting 删掉【测试段】——弹窗点「就用这版」');
      await say('再用 update_setting 把【测试段】删掉。');
      final book11 = await SettingVersionStore.load(testPid);
      final deleted = !book11.currentMale.contains('【测试段】');
      // ⑪ 依赖⑩：⑩ 没加成（add 失败）时"删不掉"不算 ⑪ 的锅，标记依赖
      final i11 = i10 ? deleted : true;
      record(
        '⑪ 设定delete删段',
        i11,
        i11
            ? (i10 ? null : '⑩ add 失败，⑪ 无段可删（依赖⑩，跳过判定）')
            : '当前男主设定：${book11.currentMale}——删除段没成功',
      );
      note(
        '📋 ⑪ ${i11 ? '✓' : '✗'} 测试段已删=${deleted}'
        '${i10 ? '' : '（⑩失败，跳过判定）'}',
      );

      // ⑫ 多轮会话弹窗：弹窗里跟男主商量一轮再同意（用户手动：
      // 点「💬 发给他」写"改成测试喜好C" → 看男主回复自动填方案 → 同意）
      await sw('builtin-mock', '⑫/⑫ 设定·多轮会话弹窗');
      _acceptingStep = '⑫/12 设定·商量后改【喜好】为测试喜好C';
      note(
        '📋 ⑫ 改【喜好】——弹窗里男主会给选项：直接点选项 A（他会'
        '出正式版本 v2），再点「就用这版」；也可以先「发给他」商量',
      );
      await say(
        '用 update_setting 把【喜好】改成"测试喜好C"。'
        '弹窗里我会先跟你商量，你正常回应我就行。',
        waitLong: true,
      );
      final book12 = await SettingVersionStore.load(testPid);
      final i12 = book12.currentMale.contains('测试喜好C');
      record(
        '⑫ 多轮会话后生效',
        i12,
        i12 ? null : '当前男主设定：${book12.currentMale}——多轮商量后没生效',
      );
      note('📋 ⑫ ${i12 ? '✓' : '✗'} 商量后生效=${i12}');

      final pass = results.where((r) => r.ok).length;
      final total = results.length;
      if (mounted) {
        setState(() => _acceptanceNote = '✅ 验收完成：$pass/$total 通过');
      }
      DebugLogger.log(
        'AI验收',
        '■ 验收完成 $pass/$total：${results.map((r) => '${r.label}=${r.ok ? "✓" : "✗"}').join('；')}',
      );
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
          _acceptingStep = null;
        });
      }
    }
  }

  /// 验收结果弹窗：每步 ✓/✗ + 失败原因 + 一键复制（发给龙虾排查）
  Future<void> _showAcceptanceResult(
    List<({String label, bool ok, String? reason})> results,
  ) async {
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制，粘贴发给龙虾即可'),
                  duration: Duration(seconds: 2),
                ),
              );
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制结果'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
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
    _appendToolBubble(
      '${r.ok ? '✅' : '❌'} $toolName ${r.ok ? '完成' : '失败'}：${r.text}',
    );
  }

  /// 处理男主指令（#记录/#查记忆/#定时/#帮助/#model）→ 审批弹窗 → 反馈
  Future<void> _handleButlerCommand(ParsedCommand cmd) async {
    try {
      switch (cmd.type) {
        case ButlerCommandParser.cmdTimer:
          _pendingFeedback = '（用户说定时功能还在路上，先记下这个需求：${cmd.arg}）';
        case ButlerCommandParser.cmdHelp:
          _pendingFeedback = ButlerCommandParser.helpText;
        case ButlerCommandParser.cmdModel:
          final m = RegExp(r'(\S+)\s+(\d+)').firstMatch(cmd.arg);
          if (m != null) {
            final w = int.tryParse(m.group(2)!);
            if (w != null && w > 0) {
              ContextTracker.instance.setWindow(_state.personaId ?? '', w);
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
  Future<bool> _approveToolCall(
    String toolName,
    String description, {
    String? personaId,
    String? toolKey,
  }) async {
    if (!mounted) return true; // 页面已关闭不阻塞工具
    // 8-06 00:58 用户：工具免审批——用户批准过的工具直接执行（男主申请→用户同意）
    // toolKey = 工具英文名（与 schema/配置 key 对齐）；toolName = 弹窗显示名
    final key = toolKey ?? toolName;
    if (personaId != null && personaId.isNotEmpty) {
      if (await ToolApprovalStore.isExempt(personaId, key)) {
        DebugLogger.log('指令模块', '🔓 $toolName（$key）已免审批，直接执行');
        return true;
      }
    }
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
            child: const Text(
              '不允许',
              style: TextStyle(color: Color(0xFF8A7A80)),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
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
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
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
      _pendingFeedback = '（用户确认了你的记录请求：「$body」（$category），已经记下了）';
    } else {
      DebugLogger.log('指令模块', '⛔ 用户拒绝记录: $body');
      _pendingFeedback = '（用户拒绝了你的记录请求：「$body」，你可以自然地问问为什么）';
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
        _pendingQuery = (
          query: query,
          category: isCategory ? query : '',
          total: total,
        );
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
    await _approveRecall(
      '${pq.query}（${pq.total}条，${want == -1 ? '全部' : '看$limit条'}）',
    );
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
          query.isEmpty ? '他想看看你们之间的记忆，允许吗？' : '他想查关于「$query」的记忆，允许吗？',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              '不允许',
              style: TextStyle(color: Color(0xFF8A7A80)),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
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

  /// 工具执行：record_relation（8-07 01:13 用户：统一关系记录格式
  /// 谁→谁→什么＋原话＋时间＋归属，情绪/记忆/规律都这么记，织成关系网）
  Future<_ToolResult> _executeRelationTool(Map<String, dynamic> args) async {
    final subject = args['subject']?.toString().trim() ?? '';
    final predicate = args['predicate']?.toString().trim() ?? '';
    final object = args['object']?.toString().trim() ?? '';
    final quote = args['quote']?.toString().trim() ?? '';
    final time = args['time']?.toString().trim();
    var category = args['category']?.toString().trim() ?? '';
    if (subject.isEmpty || predicate.isEmpty || object.isEmpty) {
      return const _ToolResult(false, '关系不完整（需要 谁→谁→什么），请补齐再记');
    }
    if (quote.isEmpty) {
      return const _ToolResult(false, '缺少原话（quote），记录要带上她的原话');
    }
    if (category.isEmpty ||
        !const ['记忆', '情绪', '规律', '行为'].contains(category)) {
      category = '记忆';
    }
    try {
      await StorageRegistry.instance.relations.save(
        RelationRecord(
          id: 'rel_${DateTime.now().millisecondsSinceEpoch}',
          subject: subject,
          predicate: predicate,
          object: object,
          quote: quote,
          time: (time == null || time.isEmpty) ? null : time,
          characterId: _state.personaId, // 归属当前男主；null=共同
          category: category,
        ),
      );
      // 通知关系图刷新（但ler_page 挂的是自己页面实例，需要全局通道）
      RelationChangeNotifier.instance.notify();
      DebugLogger.log('指令模块', '✅ 关系记录: $subject→$predicate→$object（$category）');
      return _ToolResult(
        true,
        '已记关系：$subject → $predicate → $object'
        '${time == null || time.isEmpty ? '' : '（$time）'}［$category］',
      );
    } catch (e) {
      DebugLogger.log('指令模块', '⛔ 关系记录失败: $e');
      return _ToolResult(false, '关系记录失败：$e');
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
      final parts = <String>[
        '[${category.isEmpty ? '其他' : category}] $content',
      ];
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
      DebugLogger.log(
        '指令模块',
        '✅ 工具记录确认: [${category.isEmpty ? '其他' : category}] $content',
      );
      return _ToolResult(true, '已记录：[$category] $content');
    }
    DebugLogger.log('指令模块', '⛔ 工具记录失败: 会话未创建');
    return const _ToolResult(false, '记忆库不可用（会话未创建），请稍后再试');
  }

  /// 工具执行：notify_user（男主弹窗——全局顶部横幅轰炸 + 超时唤醒）
  ///
  /// 8-06 00:31 用户需求：
  /// - APP 内弹（顶部，小情侣消息轰炸样式），APP 外系统通知之后再做
  /// - 男主可选弹几条（messages 长度）、可选间隔（interval_seconds）、
  ///   逐条指定内容（第一条/第二条…）
  /// - wait_minutes 内用户没返回聊天页 → 管家唤醒男主 → 男主再主动找用户
  Future<_ToolResult> _executeNotifyTool(Map<String, dynamic> args) async {
    final raw = args['messages'];
    final messages = <String>[];
    if (raw is List) {
      for (final m in raw) {
        final s = m.toString().trim();
        if (s.isNotEmpty) messages.add(s);
      }
    } else if (raw is String) {
      final s = raw.trim();
      if (s.isNotEmpty) messages.add(s);
    }
    if (messages.isEmpty) {
      return const _ToolResult(false, '没有可弹的消息（messages 为空）');
    }
    final rawInterval = args['interval_seconds'];
    final intervalSec = (rawInterval as num?)?.toInt();
    final waitMin = (args['wait_minutes'] as num?)?.toInt() ?? 5;
    // 男主没填间隔 → null → 服务端自适应（默认 4s，条数多自动加速）
    final interval = intervalSec == null
        ? null
        : Duration(seconds: intervalSec.clamp(1, 300));
    final personaName = _state.personaName ?? '他';
    _appendToolBubble(
      '📬 男主弹了 ${messages.length} 条消息'
      '${intervalSec == null ? '（自动间隔）' : '（间隔 ${intervalSec}s）'}',
    );
    GlobalBannerService.instance.showBurst(
      title: personaName,
      messages: messages,
      interval: interval,
    );
    // 8-06 00:44 用户：弹窗消息也要注入上下文 + 落库——
    // 男主记得自己弹过什么（用户回来质问"你不是发消息叫我了吗"能答上），
    // 用户回来在聊天页也能看到这些消息（像男主发的消息一样）。
    // 和 butlerWakeUp 的落库机制一致：feed 进上下文 + 存为男主消息。
    final pid = _state.personaId;
    if (pid != null && pid.isNotEmpty) {
      for (final m in messages) {
        ContextManager.instance.feedAssistantMessage(pid, m);
        await ChatStorageService().appendMessage(
          pid,
          ChatMessage(
            id: '${DateTime.now().microsecondsSinceEpoch}_notify',
            text: m,
            isMe: false,
          ),
        );
      }
      DebugLogger.log(
        '指令模块',
        '📬 notify_user：${messages.length} 条已注入上下文+落库（男主记得自己弹过什么）',
      );
    }
    DebugLogger.log(
      '指令模块',
      '📬 notify_user：${messages.length} 条，间隔 ${intervalSec}s，${waitMin} 分钟后没回来就唤醒',
    );
    // 8-06 21:26 用户：定时计划记进【定时任务】区（独立于便签，持久化）
    if (pid != null && pid.isNotEmpty) {
      TimerPlanStore.add(
        pid,
        '唤醒男主找她（${messages.length} 条消息，${waitMin} 分钟内没回来）',
      );
    }
    // 超时唤醒：wait_minutes 内用户没回聊天页 → 管家唤醒男主再找用户
    _scheduleNotifyWakeUp(waitMin);
    return _ToolResult(true, '已弹出 ${messages.length} 条消息（她点一下就能回到聊天页）');
  }

  /// notify_user 超时唤醒：wait_minutes 后检查用户是否还在聊天页，
  /// 没在 → 管家唤醒男主（butlerWakeUp），男主再主动找用户。
  void _scheduleNotifyWakeUp(int waitMinutes) {
    _scheduleWakeUp(
      waitMinutes,
      '她离开 $waitMinutes 分钟还没回来，'
      '你再用 notify_user 弹消息叫她回来（或说一句想她的话）。'
      '消息要自然、不催。',
    );
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
      final isCategory =
          category.isNotEmpty &&
          ButlerCommandParser.allCategories.contains(category);
      final memories = await ChatMemoryService.instance.searchMemories(
        sessionId,
        category: isCategory ? category : null,
        keyword: isCategory ? null : (query.isEmpty ? category : query),
      );
      if (memories.isEmpty) {
        return _ToolResult(
          false,
          '没有找到关于「${query.isEmpty ? category : query}」的记忆',
        );
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
          .map(
            (m) => m.content.replaceFirst(RegExp(r'^\[(喜好|约定|日常|事实|其他)\]'), ''),
          )
          .map(
            (c) =>
                maskEnabled ? butler.maskEngine.maskRealNames(c, sessionId) : c,
          )
          .toList();
      return _ToolResult(true, '查到的记忆：\n- ${lines.join('\n- ')}');
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 工具查记忆失败: $e');
      return _ToolResult(false, '查记忆出错了');
    }
  }

  /// 工具执行：save_identity_memory（男主写代号人物记忆 → 待确认区，用户确认才生效）
  /// 37批：原生 function calling 替代 #A# 文本协议（DeepSeek 对文本协议不可靠）
  Future<_ToolResult> _executeSaveIdentityMemoryTool(
    String code,
    String content,
  ) async {
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
      return _ToolResult(
        false,
        '无法识别代号「$code」——它不是当前对话里的代号。'
        '不要追问它代表谁，当作没记住继续聊天即可。',
      );
    }
    final String targetId = identityId!;
    await butler.maskEngine.identityStore?.addIdentityMemory(
      identityId: targetId,
      content: content.trim(),
    );
    DebugLogger.log('假面层', '✅ 工具保存代号记忆: $code → $content');
    return _ToolResult(
      true,
      '已把「$code」的事记下，等用户确认后生效。'
      '确认前不要当作已记住的信息使用。',
    );
  }

  /// 8-06 20:53 用户报 bug：男主反复 list_tools 没有工具记忆
  /// → 工具清单统一成一份：prompt 注入（男主天生知道）+ list_tools 返回同一份
  String _toolListText() {
    // 8-06 21:54 用户：不把全量工具写进 prompt——分类概览 + 常用表，
    // 细节男主自己调 list_tools {category} 查（查完进结果记忆，不用反复查）
    final pid = _state.personaId ?? '';
    final parts = <String>[
      '【你的工具·概览】\n${ToolCatalog.overview()}'
          '\n（想不起来某类有哪些/怎么用 → 调 list_tools {category} 查，'
          '查完结果会记住，不用反复查）',
    ];
    final freq = FrequentToolsStore.text(pid);
    if (freq != null) parts.add(freq);
    return parts.join('\n\n');
  }

  /// 工具执行：list_tools（男主查工具：{category} 分类详情 / {name} 单个 /
  /// 无参数 → 概览；{action: add_frequent/remove_frequent, name} 维护常用表）
  Future<_ToolResult> _executeListToolsTool(Map<String, dynamic> args) async {
    final action = args['action']?.toString();
    final name = args['name']?.toString() ?? '';
    final category = args['category']?.toString() ?? '';
    final pid = _state.personaId ?? '';
    if (action == 'add_frequent' || action == 'remove_frequent') {
      if (name.isEmpty) {
        return const _ToolResult(false, '维护常用表要带 name（工具名）');
      }
      if (action == 'add_frequent') {
        if (!ToolCatalog.allNames.contains(name)) {
          return _ToolResult(false, '没有「$name」这个工具');
        }
        await FrequentToolsStore.add(pid, name);
        return _ToolResult(true, '已加入常用表：$name（之后每轮都会出现在【你常用的工具】）');
      }
      final ok = await FrequentToolsStore.remove(pid, name);
      return ok
          ? _ToolResult(true, '已从常用表移除：$name')
          : _ToolResult(false, '常用表里没有「$name」');
    }
    if (category.isNotEmpty) {
      final detail = ToolCatalog.categoryDetail(category);
      if (detail == null) {
        return _ToolResult(
          false,
          '没有「$category」这个分类（分类：${ToolCatalog.categories.keys.join('、')}）',
        );
      }
      return _ToolResult(true, detail);
    }
    if (name.isNotEmpty) {
      final detail = ToolCatalog.toolDetail(name);
      return detail == null
          ? _ToolResult(false, '没有「$name」这个工具')
          : _ToolResult(true, detail);
    }
    return _ToolResult(true, _toolListText());
  }

  /// 工具执行：write_diary（男主写日记 → 存档，无需用户审批）
  Future<_ToolResult> _executeWriteDiaryTool(String content) async {
    if (content.trim().isEmpty) return const _ToolResult(false, '内容为空，无法写日记');
    final personaId = _state.personaId ?? '';
    if (personaId.isEmpty) return const _ToolResult(false, '日记保存失败（缺少角色）');
    try {
      await ChatDatabaseService.instance.saveDiaryEntry(
        personaId,
        content.trim(),
      );
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
        return _ToolResult(
          false,
          '日记里没有找到关于「${keyword.isEmpty ? '最近' : keyword}」的记录。'
          '不用勉强，自然继续聊天。',
        );
      }
      return _ToolResult(
        true,
        '日记里找到 ${entries.length} 条相关记录：\n- ${entries.join('\n- ')}',
      );
    } catch (e) {
      DebugLogger.log('指令模块', '✖ 查日记失败: $e');
      return const _ToolResult(false, '查日记出错了');
    }
  }

  /// 工具执行：request_permission（男主申请某能力免审批）
  ///
  /// 8-06 00:58-01:00 用户：男主调申请工具 → 弹窗给用户「某某能力不需要审批」
  /// + 申请理由 → 用户同意/拒绝；男主可要求用户写原因 → 原因回复给男主。
  Future<_ToolResult> _executeRequestPermission(
    Map<String, dynamic> args,
  ) async {
    final personaId = _state.personaId ?? '';
    final toolName = args['tool_name']?.toString().trim() ?? '';
    if (toolName.isEmpty) {
      return const _ToolResult(false, '申请失败：没说要申请哪个工具');
    }
    final reason = args['reason']?.toString().trim() ?? '';
    final askReason = args['ask_reason'] == true;
    final result = await _showPermissionRequestDialog(
      toolName: toolName,
      reason: reason,
      askReason: askReason,
    );
    if (result == null) {
      return _ToolResult(false, '她没回应申请「$toolName」免审批。你可以稍后再自然地问一次，或换种方式。');
    }
    if (result.approved) {
      await ToolApprovalStore.setExempt(personaId, toolName, true);
      final reasonTxt = result.reason.trim();
      return _ToolResult(
        true,
        '她批准了「$toolName」免审批！以后调它不用再问她。'
        '${reasonTxt.isNotEmpty ? '她还写了原因：$reasonTxt' : ''}',
      );
    }
    final reasonTxt = result.reason.trim();
    return _ToolResult(
      false,
      '她拒绝了「$toolName」免审批。'
      '${reasonTxt.isNotEmpty ? '她写的原因：$reasonTxt' : '她没说原因'}'
      '——你自己判断：是接受、还是换个方式再沟通。',
    );
  }

  /// 申请免审批弹窗：同意/拒绝 + 可选原因输入（男主 ask_reason 时提示填写）
  Future<({bool approved, String reason})?> _showPermissionRequestDialog({
    required String toolName,
    required String reason,
    required bool askReason,
  }) async {
    if (!mounted) return null;
    FocusManager.instance.primaryFocus?.unfocus();
    final reasonCtrl = TextEditingController();
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('🙋 男主申请免审批'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '他想让「$toolName」以后不用每次问你。',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            if (reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7EAF1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '💬 他的理由：$reason',
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: askReason
                    ? '他想听你的原因，写两句吧…（同意或拒绝都可以写）'
                    : '想跟他说两句？可不填…',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒绝', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('同意'),
          ),
        ],
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    if (approved == null) return null;
    return (approved: approved, reason: reasonCtrl.text.trim());
  }

  /// 工具执行：query_logs（男主查运行日志排错，只读免审批）
  ///
  /// 8-06 01:03 用户：不能整串日志扔给男主——按关键词/级别/条数/日期
  /// 筛选，只返回匹配的几条 + 统计。
  Future<_ToolResult> _executeQueryLogs(Map<String, dynamic> args) async {
    final keyword = args['keyword']?.toString().trim();
    final level = args['level']?.toString().trim();
    final limit = (args['limit'] as num?)?.toInt() ?? 15;
    final date = args['date']?.toString().trim();
    final result = DebugLogger.query(
      keyword: (keyword == null || keyword.isEmpty) ? null : keyword,
      level: (level == null || level.isEmpty) ? null : level,
      limit: limit.clamp(1, 50),
      date: (date == null || date.isEmpty) ? null : date,
    );
    if (result.lines.isEmpty) {
      return _ToolResult(
        true,
        '日志里没找到匹配的记录'
        '${keyword != null ? '（关键词：$keyword' : ''}'
        '${level != null ? '，级别：$level' : ''}'
        '${date != null ? '，日期：$date' : ''}'
        '${keyword != null || level != null || date != null ? '）' : ''}。一切正常。',
      );
    }
    return _ToolResult(
      true,
      '日志匹配 ${result.total} 条，给你最近 ${result.lines.length} 条：\n'
      '${result.lines.join('\n')}',
    );
  }

  /// 工具执行：report_bug（bug 报告弹窗：定位信息 + 知识库解法 + 一键复制）
  ///
  /// 8-06 01:06 用户：有 bug 男主创立弹窗，上面可直接复制，
  /// 处理办法是定位各种东西，用户直接复制给开发者（龙虾）修。
  Future<_ToolResult> _executeReportBug(Map<String, dynamic> args) async {
    final desc = args['description']?.toString().trim() ?? '（男主发现的问题）';
    final logKw = args['log_keyword']?.toString().trim();
    // 相关日志片段（最近 10 条匹配）
    final logs = DebugLogger.query(
      keyword: (logKw == null || logKw.isEmpty) ? null : logKw,
      limit: 10,
    );
    // 知识库匹配：描述 + 日志一起喂
    final solution = BugKnowledgeBase.match('$desc ${logs.lines.join(' ')}');
    final now = DateTime.now();
    final report = StringBuffer()
      ..writeln('🐛 Bug 报告')
      ..writeln(
        '时间：${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      )
      ..writeln('问题：$desc');
    if (logs.lines.isNotEmpty) {
      report
        ..writeln()
        ..writeln('相关日志（${logs.total} 条匹配，显示 ${logs.lines.length} 条）：');
      for (final l in logs.lines) {
        report.writeln(l);
      }
    } else {
      report.writeln('相关日志：（无匹配）');
    }
    if (solution != null) {
      report
        ..writeln()
        ..writeln('知识库解法：$solution');
    } else {
      report
        ..writeln()
        ..writeln('知识库解法：（未匹配到，等开发者看日志定位）');
    }
    await _showBugReportDialog(report.toString(), solution);
    return _ToolResult(true, '已生成 bug 报告弹窗（她可以一键复制发给开发者）');
  }

  /// bug 报告弹窗：可选中文本 + 一键复制按钮
  Future<void> _showBugReportDialog(String report, String? solution) async {
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Text('🐛 '),
            Text('男主发现了一个问题', style: TextStyle(fontSize: 17)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (solution != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7EAF1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '💡 $solution',
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              // 报告全文（可选中复制）
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFC896B4).withValues(alpha: 0.2),
                  ),
                ),
                child: SelectableText(
                  report,
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '👆 报告可长按选中复制；也可以直接点下面按钮一键复制，'
                '粘贴发给开发者（龙虾）修。',
                style: TextStyle(fontSize: 11, color: const Color(0xFF8A7A80)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              '知道了',
              style: TextStyle(color: Color(0xFF8A7A80)),
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text('✅ 报告已复制，粘贴发给龙虾就能修'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制报告'),
          ),
        ],
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 工具执行：countdown_card（男主设计时卡片）
  ///
  /// 8-06 13:38 用户：屏幕固定悬浮卡片，可挪动可收起，卡面倒计时+自由编辑内容；
  /// 男主填选项（延长/结束/纯消息）；逾期后男主可选要不要弹窗问/多久弹窗/多久唤醒。
  Future<_ToolResult> _executeCountdownCard(Map<String, dynamic> args) async {
    final minutes = (args['minutes'] as num?)?.toInt(); // null = 纯选择卡片
    final title = args['title']?.toString().trim() ?? '记得回来哦';
    final category = args['category']?.toString().trim() ?? '';
    final allowRequest = args['allow_request'] == true;
    final remindOnExpire = args['remind_on_expire'] != false;
    final remindDelay = (args['remind_delay_minutes'] as num?)?.toInt() ?? 0;
    final wakeMin = (args['wake_minutes'] as num?)?.toInt() ?? 5;
    // 选项解析
    final options = <CardOption>[];
    final rawOptions = args['options'];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        if (o is Map) {
          options.add(CardOption.fromJson(Map<String, dynamic>.from(o)));
        }
      }
    }
    final pid = _state.personaId ?? '';
    final personaName = _state.personaName ?? '他';
    _appendToolBubble(
      '⏱ 男主发来互动卡片：$title${minutes != null ? '（$minutes 分钟）' : ''}',
    );
    GlobalTimerCardService.instance.showCard(
      title: title,
      minutes: minutes,
      initiator: personaName,
      category: category,
      allowRequest: allowRequest,
      options: options,
      onOption: (label, action, extendMinutes) async {
        // 用户点了选项 → 结果进上下文+落库（男主记得她选了啥）
        final actionTxt = switch (action) {
          'extend' => '她点了「$label」，自动延长了 $extendMinutes 分钟',
          'finish' => '她点了「$label」，卡片任务完成了',
          _ => '她点了「$label」',
        };
        if (pid.isNotEmpty) {
          ContextManager.instance.feedAssistantMessage(pid, actionTxt);
          await ChatStorageService().appendMessage(
            pid,
            ChatMessage(
              id: '${DateTime.now().microsecondsSinceEpoch}_card',
              text: actionTxt,
              isMe: false,
            ),
          );
        }
        DebugLogger.log('指令模块', '⏱ 卡片选项：$actionTxt');
      },
      onExpire: () {
        DebugLogger.log('指令模块', '⏱ 卡片到期（$remindDelay 分钟后弹窗，$wakeMin 分钟后唤醒）');
        // 到期 → 可选弹窗问她（横幅）
        if (remindOnExpire) {
          Timer(Duration(minutes: remindDelay), () {
            if (!mounted) return;
            GlobalBannerService.instance.showBurst(
              title: personaName,
              messages: ['时间到了哦，在干嘛呀？', '别忘了我们约好的事～'],
              interval: const Duration(seconds: 4),
            );
          });
        }
        // 到期 → 系统给男主发判断指令（8-06 13:59 用户）：
        // 男主自己判断延期 / 撤销换一个，用 manage_task 操作
        final expireTxt =
            '【系统】卡片「$title」时间到了，她还没回应/没完成。'
            '你来判断：要不要延期（manage_task extend）、'
            '还是撤销换一个方式（manage_task cancel）？'
            '决定好了用 manage_task 处理，卡片和任务列表会同步。';
        if (pid.isNotEmpty) {
          ContextManager.instance.feedAssistantMessage(pid, expireTxt);
          ChatStorageService().appendMessage(
            pid,
            ChatMessage(
              id: '${DateTime.now().microsecondsSinceEpoch}_exp',
              text: '⏰ 卡片「$title」时间到了',
              isMe: false,
            ),
          );
        }
        // 逾期还没处理 → 唤醒男主主动判断（判断指令同上）
        _scheduleWakeUp(wakeMin, expireTxt);
      },
      onRequest: (reason) async {
        // 她提交了申请调整 → 进上下文+落库，男主自己判断（manage_task 回应）
        final requestTxt =
            '她申请调整任务「$title」：$reason'
            '——你判断：撤销（manage_task cancel）/ 调整（extend 或 edit_title）/ '
            '拒绝（manage_task reject 并给她回复）。';
        DebugLogger.log('指令模块', '💬 任务申请：$requestTxt');
        if (pid.isNotEmpty) {
          ContextManager.instance.feedAssistantMessage(pid, requestTxt);
          await ChatStorageService().appendMessage(
            pid,
            ChatMessage(
              id: '${DateTime.now().microsecondsSinceEpoch}_req',
              text: '💬 她申请调整任务：「$title」\n理由：$reason',
              isMe: false,
            ),
          );
        }
      },
      onDone: () {
        // 她点了完成 → 结果告诉男主
        final doneTxt = '她把任务「$title」标记为完成了';
        DebugLogger.log('指令模块', '✅ 任务完成：$doneTxt');
        if (pid.isNotEmpty) {
          ContextManager.instance.feedAssistantMessage(pid, doneTxt);
        }
      },
      onOpenList: () {
        if (!mounted) return;
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const TaskListPage()));
      },
    );
    return _ToolResult(
      true,
      '已发出互动卡片：$title'
      '${minutes != null ? '（$minutes 分钟）' : '（无倒计时）'}'
      '${category.isEmpty ? '' : '【分类：$category】'}'
      '${allowRequest ? '（开放了申请调整入口）' : ''}'
      '${options.isEmpty ? '（没填选项）' : '（含 ${options.length} 个选项）'}',
    );
  }

  /// 工具执行：manage_task（男主撤销/调整/回应申请）
  ///
  /// 8-06 13:53 用户：男主判断后操作卡片任务，同步任务列表
  Future<_ToolResult> _executeManageTask(Map<String, dynamic> args) async {
    final taskId = args['task_id']?.toString().trim() ?? '';
    final action = args['action']?.toString().trim() ?? '';
    if (taskId.isEmpty) {
      return const _ToolResult(false, '管理失败：缺任务 ID');
    }
    final svc = GlobalTimerCardService.instance;
    final isCurrent = svc.isActive && svc.taskId == taskId;
    final task = await CardTaskStore.instance.byId(taskId);
    if (task == null) {
      return _ToolResult(false, '没找到这个任务（可能已删除）');
    }
    switch (action) {
      case 'cancel':
        // 撤销：卡片销毁 + 任务标撤销
        if (isCurrent) {
          svc.cancelByButler();
        } else {
          await CardTaskStore.instance.update(taskId, (t) {
            t.status = 'cancelled';
            t.result = '男主撤销了任务';
          });
        }
        _appendToolBubble('🗑️ 男主撤销了任务：「${task.title}」');
        return _ToolResult(true, '已撤销任务「${task.title}」，卡片已销毁，任务列表已同步');
      case 'extend':
        final minutes = (args['minutes'] as num?)?.toInt() ?? 5;
        if (isCurrent) {
          svc.extend(minutes);
        } else {
          await CardTaskStore.instance.update(taskId, (t) {
            t.endAt = DateTime.now().add(Duration(minutes: minutes));
          });
        }
        _appendToolBubble('⏱ 男主延长了任务「${task.title}」$minutes 分钟');
        return _ToolResult(true, '已延长任务「${task.title}」$minutes 分钟');
      case 'edit_title':
        final newTitle = args['title']?.toString().trim() ?? '';
        if (newTitle.isEmpty) {
          return const _ToolResult(false, '改卡面失败：没写新内容');
        }
        if (isCurrent) {
          svc.setTitle(newTitle);
        } else {
          await CardTaskStore.instance.update(taskId, (t) {
            t.title = newTitle;
          });
        }
        _appendToolBubble('📝 男主改了卡面：「$newTitle」');
        return _ToolResult(true, '已把卡面改为「$newTitle」');
      case 'reject':
        final reply = args['reply']?.toString().trim() ?? '这次先按说好的来，好不好？';
        if (isCurrent) {
          svc.clearRequest();
        } else {
          await CardTaskStore.instance.update(taskId, (t) {
            t.requestReason = null;
          });
        }
        // 回复落库 + 进上下文（她能看到男主的话）
        final pid = _state.personaId ?? '';
        if (pid.isNotEmpty) {
          final replyTxt = '男主拒绝了她的任务申请调整，回复：「$reply」';
          ContextManager.instance.feedAssistantMessage(pid, replyTxt);
          await ChatStorageService().appendMessage(
            pid,
            ChatMessage(
              id: '${DateTime.now().microsecondsSinceEpoch}_rej',
              text: '「$reply」',
              isMe: false,
            ),
          );
        }
        _appendToolBubble('💬 男主回复了她的申请：「$reply」');
        return _ToolResult(true, '已拒绝申请并回复：「$reply」');
      default:
        return _ToolResult(false, '未知操作：$action');
    }
  }

  /// 工具执行：update_setting（男主主动优化设定，弹窗审批+可手动修改）
  ///
  /// 8-06 17:46-18:24 用户：弹窗显示新设定+理由 → 用户可编辑 → 确认 →
  /// 覆盖当前版（旧版进历史）+ 变更日志 + 摘要注入 prompt。
  Future<_ToolResult> _executeUpdateSetting(Map<String, dynamic> args) async {
    final pid = _state.personaId ?? '';
    if (pid.isEmpty) return const _ToolResult(false, '更新设定失败（缺少角色）');
    final type = args['setting_type']?.toString() == 'user' ? 'user' : 'male';
    final actionRaw = args['action']?.toString().trim() ?? '';
    final action = ['update', 'delete', 'add', 'replace'].contains(actionRaw)
        ? actionRaw
        : 'update';
    final tag = (args['tag']?.toString().trim() ?? '').replaceAll(
      RegExp(r'[【】]'),
      '',
    );
    final content = args['content']?.toString().trim() ?? '';
    final reason = args['reason']?.toString().trim() ?? '';
    final typeName = type == 'user' ? '用户设定' : '男主设定';

    if (action != 'delete' && content.isEmpty) {
      return _ToolResult(
        false,
        '更新设定失败：没写新内容'
        '${action == 'replace' ? '（replace 要写完整全文）' : '（update/add 要写这一段的新内容）'}',
      );
    }

    // 读当前设定 → 段落操作（8-07：测试模式下读测试空间副本）
    final settingPid = _settingPid();
    final book = await SettingVersionStore.load(settingPid);
    final current = type == 'user' ? book.currentUser : book.currentMale;
    String newText;
    String opDesc;
    if (action == 'replace') {
      newText = content;
      opDesc = '整体重写$typeName${reason.isEmpty ? '' : '：$reason'}';
    } else {
      final sections = _parseSettingSections(current);
      final idx = tag.isEmpty
          ? -1
          : sections.indexWhere((sec) => sec.tag == tag);
      if (action == 'add') {
        if (tag.isEmpty) {
          return const _ToolResult(false, '新增段落要写 tag（如 喜好）');
        }
        if (idx >= 0) {
          return _ToolResult(false, '【$tag】已经存在了，要改它用 action=update');
        }
        sections.add((tag: tag, body: content));
        newText = _sectionsToText(sections);
        opDesc = '新增段落【$tag】${reason.isEmpty ? '' : '：$reason'}';
      } else if (action == 'delete') {
        if (idx < 0) {
          return _ToolResult(
            false,
            '没找到【$tag】段落。当前段落：\n${_sectionsOutline(sections)}',
          );
        }
        final removed = sections.removeAt(idx);
        newText = _sectionsToText(sections);
        opDesc = '删除段落【${removed.tag}】${reason.isEmpty ? '' : '：$reason'}';
      } else {
        // update
        if (idx < 0) {
          return _ToolResult(
            false,
            '没找到【$tag】段落。当前段落：\n${_sectionsOutline(sections)}'
            '（想整体整理用 action=replace；想加新段用 action=add）',
          );
        }
        final old = sections[idx].body;
        sections[idx] = (tag: tag, body: content);
        newText = _sectionsToText(sections);
        final brief = (String t) =>
            t.length > 30 ? '${t.substring(0, 30)}…' : t;
        opDesc =
            '修改【$tag】：${brief(old)} → ${brief(content)}'
            '${reason.isEmpty ? '' : '（$reason）'}';
      }
    }

    // 弹窗审批（多轮会话；编辑框显示全文，她可整体改）
    final result = await _showSettingApprovalDialog(
      typeName: typeName,
      content: newText,
      reason: opDesc,
      testStep: _acceptingStep,
    );
    if (result == null) {
      return _ToolResult(false, '她没回应设定更新（先别催，她可能在忙）');
    }
    if (!result.approved) {
      final fb = result.feedback.trim();
      return _ToolResult(
        false,
        '她拒绝了「$typeName」更新。'
        '${fb.isNotEmpty ? '她的反馈：$fb——按她的意见改完再提交。' : '她没说原因，你可以问问她哪里不满意。'}',
      );
    }

    // 批准 → 存为新版本 + 变更日志
    final finalContent = result.content.trim();
    await SettingVersionStore.saveNewVersion(
      settingPid,
      type,
      finalContent,
      note: reason.isEmpty ? null : reason,
    );
    await SettingVersionStore.addChangelog(settingPid, type, opDesc);
    DebugLogger.log('指令模块', '📚 $typeName 已更新（$opDesc）');
    _appendToolBubble('📚 男主更新了$typeName：$opDesc（旧版已存进右页历史，可一键恢复）');
    return _ToolResult(
      true,
      '$typeName 已更新生效（$opDesc）。新版本已存好，旧版在右页历史里'
      '（她可一键恢复）。当前段落结构：\n'
      '${_sectionsOutline(_parseSettingSections(finalContent))}',
    );
  }

  // ── 设定段落工具（8-07 用户：段落化+标签，男主精准修改省 token）──

  /// 解析男主回复里的【问题N】+【选项】组（8-07 15:5x 用户：选项要能连续点，
  /// 男主一次可以问多个问题，每个问题一组 A/B/C）：
  /// 格式：
  ///   【问题1】身份部分想怎么定？
  ///   【选项】
  ///   A. 内容
  ///   B）内容
  ///   C: 内容
  ///   【问题2】喜好部分呢？
  ///   【选项】
  ///   A. ...
  /// 也兼容旧格式：单独的【选项】块（无【问题N】）→ 一组 question=''
  static List<({String question, List<({String key, String text})> options})>
  _parseOptionGroups(String reply) {
    final groups =
        <({String question, List<({String key, String text})> options})>[];
    final blockReg = RegExp(
      r'【问题\d*】([\s\S]*?)【选项】([\s\S]*?)(?=【问题\d*】|$)',
    );
    for (final m in blockReg.allMatches(reply)) {
      final question = m.group(1)!.trim();
      final opts = <({String key, String text})>[];
      for (final line in m.group(2)!.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final om = RegExp(r'^([A-Za-z0-9])[.、:：)）]\s*(.+)$').firstMatch(t);
        if (om != null) {
          opts.add((key: om.group(1)!, text: om.group(2)!.trim()));
        }
      }
      if (opts.isNotEmpty) {
        groups.add((question: question, options: opts));
      }
    }
    // 兼容旧格式：单独【选项】块
    if (groups.isEmpty) {
      final idx = reply.indexOf('【选项】');
      if (idx >= 0) {
        final rest = reply.substring(idx + '【选项】'.length).trim();
        final opts = <({String key, String text})>[];
        for (final line in rest.split('\n')) {
          final t = line.trim();
          if (t.isEmpty) continue;
          final m = RegExp(r'^([A-Za-z0-9])[.、:：)）]\s*(.+)$').firstMatch(t);
          if (m != null) {
            opts.add((key: m.group(1)!, text: m.group(2)!.trim()));
          }
        }
        if (opts.isNotEmpty) {
          groups.add((question: '', options: opts));
        }
      }
    }
    return groups;
  }

  /// 设定文本按【标签】切段；没有标签 → 整段一个（tag 空）
  static List<({String tag, String body})> _parseSettingSections(String text) {
    final reg = RegExp(r'【([^】]+)】([\s\S]*?)(?=【[^】]+】|$)');
    final result = <({String tag, String body})>[];
    for (final m in reg.allMatches(text)) {
      final t = m.group(1)!.trim();
      final b = m.group(2)!.trim();
      if (t.isNotEmpty) result.add((tag: t, body: b));
    }
    if (result.isEmpty && text.trim().isNotEmpty) {
      result.add((tag: '', body: text.trim()));
    }
    return result;
  }

  /// 段落列表 → 原文（无编号，用户可编辑的形式）
  static String _sectionsToText(List<({String tag, String body})> sections) {
    final buf = StringBuffer();
    for (final sec in sections) {
      if (sec.tag.isNotEmpty) {
        buf.writeln('【${sec.tag}】${sec.body}');
      } else {
        buf.writeln(sec.body);
      }
    }
    return buf.toString().trim();
  }

  /// 段落列表 → 编号大纲（提示男主当前有哪些段，定位用）
  static String _sectionsOutline(List<({String tag, String body})> sections) {
    if (sections.isEmpty) return '（空）';
    final buf = StringBuffer();
    for (var i = 0; i < sections.length; i++) {
      final sec = sections[i];
      final preview = sec.body.length > 20
          ? '${sec.body.substring(0, 20)}…'
          : sec.body;
      buf.writeln(
        '${i + 1}.${sec.tag.isEmpty ? '【未分段】' : '【${sec.tag}】'}$preview',
      );
    }
    return buf.toString().trim();
  }

  /// 设定文本 → 编号显示（prompt 注入用）；没分段就原样
  static String _formatSectionsNumbered(String text) {
    final sections = _parseSettingSections(text);
    if (sections.length == 1 && sections.first.tag.isEmpty) return text;
    return _sectionsOutline(sections);
  }

  /// 设定更新审批弹窗（8-06 18:12 用户：弹窗内迭代，不进聊天框）
  Future<({bool approved, String content, String feedback})?>
  _showSettingApprovalDialog({
    required String typeName,
    required String content,
    required String reason,
    String? testStep,
  }) async {
    if (!mounted) return null;
    FocusManager.instance.primaryFocus?.unfocus();
    final ctrl = TextEditingController(text: content);
    final fbCtrl = TextEditingController();
    var maleText = reason.isEmpty ? '我想更新$typeName，你看看这样行不行。' : reason;
    var round = 1;
    var busy = false;
    // 8-07 15:2x 用户：男主方案要打版本号，看得出改了几版、每版长啥样
    // v1 = 男主最初方案；每次男主带【新方案】回复 → 追加新版本
    final versions = <({int v, String text})>[(v: 1, text: content)];
    var currentV = 1;
    // 8-07 15:5x 用户：男主了解阶段可以连续问多个问题，每个问题一组
    // 选项（A/B/C），用户连着点/反驳，直到点「就用这版」才定案——
    // 男主回复带【问题N】+【选项】块 → 渲染成可点按钮组
    var questionGroups =
        <({String question, List<({String key, String text})> options})>[];
    // 会话记录（每轮：她说/男主说，给男主当上下文）
    final history = <String>[];
    final pid = _state.personaId ?? '';
    final pName = _state.personaName ?? _state.lead?.name ?? '角色';

    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          // 发给男主一轮（"发给他"按钮和"点选项"共用）：男主回复
          // 带【新方案】→ 自动更新设定框并记新版本；带【选项】→ 显示可点选项
          Future<void> sendToMale(String userMsg) async {
            fbCtrl.clear();
            setState(() => busy = true);
            history.add('她说：$userMsg');
            final reply = await _askMaleInSession(
              personaId: pid,
              settingPid: _settingPid(),
              personaName: pName,
              typeName: typeName,
              draft: ctrl.text,
              maleLast: maleText,
              userMsg: userMsg,
              history: history,
            );
            history.add('男主说：$reply');
            final idx = reply.indexOf('【新方案】');
            if (idx >= 0) {
              final rest = reply.substring(idx + '【新方案】'.length).trim();
              if (rest.startsWith('【')) {
                final secs = _parseSettingSections(ctrl.text);
                final m = RegExp(r'^【([^】]+)】([\s\S]*)').firstMatch(rest);
                if (m != null) {
                  final t = m.group(1)!.trim();
                  final b = m.group(2)!.trim();
                  final i = secs.indexWhere((x) => x.tag == t);
                  if (i >= 0) {
                    secs[i] = (tag: t, body: b);
                  } else {
                    secs.add((tag: t, body: b));
                  }
                  ctrl.text = _sectionsToText(secs);
                }
              } else if (rest.isNotEmpty) {
                ctrl.text = rest;
              }
              ctrl.selection = TextSelection.collapsed(
                offset: ctrl.text.length,
              );
            }
            setState(() {
              maleText = reply;
              round++;
              busy = false;
              final hasNew = versions.any((x) => x.text == ctrl.text);
              if (!hasNew && idx >= 0) {
                // 8-07 15:5x 用户：从旧版继续改 → 该版之后的版本自动作废
                // （截断），新方案接在后面重新编号
                if (currentV < versions.length) {
                  versions.removeRange(currentV, versions.length);
                }
                versions.add((v: versions.length + 1, text: ctrl.text));
                currentV = versions.length;
              }
              // 男主回复带【问题N】+【选项】→ 渲染可点选项组；没有就清空
              questionGroups = _parseOptionGroups(reply);
            });
          }

          // 弃用某一版（✕）：删除后重编号，至少保留一版；
          // 若编辑框内容是被删的版 → 载入最后一版
          void discardVersion(int v) {
            if (versions.length <= 1) return;
            setState(() {
              versions.removeWhere((x) => x.v == v);
              for (var i = 0; i < versions.length; i++) {
                versions[i] = (v: i + 1, text: versions[i].text);
              }
              if (currentV > versions.length) {
                currentV = versions.length;
              }
              if (!versions.any((x) => x.text == ctrl.text)) {
                ctrl.text = versions.last.text;
                ctrl.selection = TextSelection.collapsed(
                  offset: ctrl.text.length,
                );
                currentV = versions.length;
              }
            });
          }

          return AlertDialog(
            backgroundColor: const Color(0xFFFDF7F9),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              '📚 男主想更新$typeName'
              '${testStep != null ? ' · 验收 $testStep' : ''}'
              ' · 方案 v$currentV/${versions.length}'
              '${round > 1 ? '（第 $round 轮）' : ''}',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7EAF1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '💬 男主${round > 1 ? '（第 $round 轮）' : ''}：$maleText',
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 选项区：男主问的问题（一组问题+一组选项），点一个回复他；
                  // 可以连着点多个，也可以下面反驳；他出【新方案】才算定版
                  if (questionGroups.isNotEmpty) ...[
                    const Text(
                      '🎯 男主在问你（点选项直接回复他，可以连着点；也可以自己在下面改/反驳）：',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8A7A80)),
                    ),
                    const SizedBox(height: 6),
                    for (final group in questionGroups) ...[
                      if (group.question.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '❓ ${group.question}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF6B5560),
                            ),
                          ),
                        ),
                      ],
                      for (final opt in group.options)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: GestureDetector(
                            onTap: busy
                                ? null
                                : () {
                                    // 告诉男主选了哪个 → 他继续问/出正式版
                                    sendToMale(
                                      '${group.question.isEmpty ? '' : '【${group.question}】'}'
                                      '我选 ${opt.key}：${opt.text}',
                                    );
                                  },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF7EAF1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFE8C9D8),
                                ),
                              ),
                              child: Text(
                                '${opt.key}. ${opt.text}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ],
                  // 方案版本区：男主出过几版一目了然，点编号回看/从这版继续，
                  // ✕ 弃用改错的版（8-07 15:5x 用户：版本多了要能弃用/回退）
                  if (versions.length > 1) ...[
                    const Text(
                      '📚 男主方案版本：点编号=回看/从这版继续（后面版本自动作废），✕=弃用这版',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8A7A80)),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final ver in versions)
                          Container(
                            padding: const EdgeInsets.only(left: 8),
                            decoration: BoxDecoration(
                              color: currentV == ver.v
                                  ? const Color(0xFFC896B4)
                                  : const Color(0xFFF7EAF1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    ctrl.text = ver.text;
                                    ctrl.selection = TextSelection.collapsed(
                                      offset: ctrl.text.length,
                                    );
                                    setState(() => currentV = ver.v);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 3,
                                    ),
                                    child: Text(
                                      'v${ver.v}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: currentV == ver.v
                                            ? Colors.white
                                            : const Color(0xFF8A7A80),
                                        fontWeight: currentV == ver.v
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ),
                                if (versions.length > 1)
                                  GestureDetector(
                                    onTap: () => discardVersion(ver.v),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 3,
                                      ),
                                      child: Text(
                                        '✕',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: currentV == ver.v
                                              ? Colors.white70
                                              : const Color(0xFFB08A9C),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  const Text(
                    '📄 设定全文（可以直接改；点「就用这版」= 按这个定案）：',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8A7A80)),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: ctrl,
                    maxLines: 8,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: fbCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      hintText: '跟男主说：哪里不对、想要什么…他出下一版（说需求=还没定案）',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (busy) ...[
                    const SizedBox(height: 10),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text(
                          '男主正在回复…',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8A7A80),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx, false),
                child: const Text(
                  '放弃',
                  style: TextStyle(color: Color(0xFF8A7A80)),
                ),
              ),
              if (!busy)
                TextButton(
                  onPressed: () async {
                    final msg = fbCtrl.text.trim();
                    if (msg.isEmpty) return;
                    await sendToMale(msg);
                  },
                  child: const Text(
                    '💬 发给他·出下一版',
                    style: TextStyle(color: Color(0xFFC896B4)),
                  ),
                ),
              if (!busy)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC896B4),
                  ),
                  onPressed: () {
                    // 8-07 15:0x：防连点——先置 busy 再 pop，双击不会 pop 两次
                    setState(() => busy = true);
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('✅ 就用这版'),
                ),
            ],
          );
        },
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    // 8-07 15:5x 用户：缓存及时删——弹窗关闭后释放控制器，避免泄漏
    final outContent = ctrl.text;
    final outFeedback = fbCtrl.text;
    ctrl.dispose();
    fbCtrl.dispose();
    if (approved == null) return null;
    return (approved: approved, content: outContent, feedback: outFeedback);
  }

  /// 设定会话内：男主回复（一次 AI 回合，可查只读信息；查了=流程没走完，继续）
  Future<String> _askMaleInSession({
    required String personaId,
    String? settingPid,
    required String personaName,
    required String typeName,
    required String draft,
    required String maleLast,
    required String userMsg,
    required List<String> history,
  }) async {
    try {
      final personaPrompt = _state.persona?.prompt ?? '';
      final book = SettingVersionStore.cached(settingPid ?? personaId);
      final currentInfo = StringBuffer('当前男主设定：');
      currentInfo.writeln(
        (book == null || book.currentMale.trim().isEmpty)
            ? '（空）'
            : book.currentMale,
      );
      currentInfo.write('当前用户设定：');
      currentInfo.write(
        (book == null || book.currentUser.trim().isEmpty)
            ? '（空）'
            : book.currentUser,
      );
      final system = SystemTemplate.build(
        personaName: personaName,
        personaPrompt: personaPrompt,
        needsWindow: false,
        taskState:
            '【设定修改会话】你在和她讨论「$typeName」的修改，还没定案。\n'
            '$currentInfo\n'
            '你刚才的方案：\n$draft\n'
            '你上一轮说：$maleLast\n'
            '她本轮回复你：$userMsg\n'
            '回应她（像平时聊天一样自然）：可以解释、追问细节、或查资料'
            '（recall_memory/query_diary/query_setting_history/query_record/'
            'list_tools 可直接查，不用她审批）。'
            '【连续问答】你可以一次问多个问题，每个问题带一组选项，格式：\n'
            '【问题1】问题内容\n【选项】\nA. 选项内容\nB. 选项内容\nC. 其他/我自己说\n'
            '【问题2】问题内容\n【选项】\nA. ...\n（要几个问题写几组，选项一般 2-3 个）\n'
            '她点选项或反驳后，你可以继续追问下一个问题，也可以给出修改后的方案'
            '（最后单独一行写【新方案】然后写完整新内容）。'
            '【别中途断流程】她没点「就用这版」之前，讨论都没结束——'
            '她还在提需求/点选项，你就继续问或改，别急着定案收尾。',
      );
      final msgs = <AIChatMessage>[
        AIChatMessage(role: 'system', content: system),
        for (final h in history) AIChatMessage(role: 'user', content: h),
        AIChatMessage(role: 'user', content: '【她本轮的话】$userMsg'),
      ];
      // 只读工具白名单（男主在会话里查资料，不用她审批）
      final readOnly = AiChatService.butlerTools
          .where(
            (t) => _sessionReadOnlyTools.contains(
              ((t['function'] as Map<String, dynamic>)['name'] as String?),
            ),
          )
          .toList();
      for (var i = 0; i < 3; i++) {
        final res = await AIProviderManager.instance.chat(
          personaId,
          msgs,
          tools: readOnly,
        );
        final calls = res.toolCalls;
        if (calls != null && calls.isNotEmpty) {
          for (final call in calls) {
            final name = call['name']?.toString() ?? '';
            final args = (call['arguments'] as Map<String, dynamic>?) ?? {};
            final r = await _executeReadOnlySessionTool(name, args);
            msgs.add(AIChatMessage(role: 'user', content: '【工具结果】$r'));
          }
          continue;
        }
        return res.text.trim().isEmpty ? '（我还在想，你继续说？）' : res.text.trim();
      }
      return '（我查了不少，先说到这——你继续说，我再改。）';
    } catch (e) {
      DebugLogger.log('设定会话', '❌ 男主回复失败：$e');
      return '（我这边卡了一下…你再说一遍？）';
    }
  }

  /// 设定会话内只读工具白名单
  static const _sessionReadOnlyTools = {
    'recall_memory',
    'query_diary',
    'query_setting_history',
    'query_record',
    'list_tools',
  };

  /// 设定会话内执行只读工具（免审批，用户在弹窗里全程可见）
  Future<String> _executeReadOnlySessionTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    _ToolResult r;
    switch (name) {
      case 'recall_memory':
        r = await _executeRecallTool(
          args['query']?.toString() ?? '',
          args['category']?.toString() ?? '',
        );
        break;
      case 'query_diary':
        r = await _executeQueryDiaryTool(args['keyword']?.toString() ?? '');
        break;
      case 'query_setting_history':
        r = await _executeQuerySettingHistory(args);
        break;
      case 'query_record':
        r = await _executeQueryRecord(args);
        break;
      case 'list_tools':
        r = await _executeListToolsTool(args);
        break;
      default:
        r = const _ToolResult(false, '这个工具在设定会话里不能用');
    }
    return '${r.ok ? '✅' : '❌'} ${r.text}';
  }

  /// 工具执行：query_setting_history（男主查设定变更历史）
  Future<_ToolResult> _executeQuerySettingHistory(
    Map<String, dynamic> args,
  ) async {
    final pid = _state.personaId ?? '';
    if (pid.isEmpty) return const _ToolResult(false, '查历史失败（缺少角色）');
    final limit = (args['limit'] as num?)?.toInt() ?? 10;
    // 8-07：测试模式下查测试空间的设定历史
    final book = await SettingVersionStore.load(_settingPid());
    final log = book.changelog.take(limit).toList();
    if (log.isEmpty) {
      return const _ToolResult(true, '还没有设定变更记录——你还没主动优化过设定。');
    }
    final buf = StringBuffer('设定变更历史（共 ${book.changelog.length} 条）：\n');
    for (final e in log) {
      final t = e.time;
      final ts =
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')} '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
      buf.writeln('- [$ts] ${e.type == 'user' ? '用户设定' : '男主设定'}：${e.summary}');
    }
    // 附带当前版本信息
    buf.writeln();
    buf.writeln(
      '当前男主设定：${book.currentMale.isEmpty ? '（空）' : book.currentMale}',
    );
    buf.writeln(
      '当前用户设定：${book.currentUser.isEmpty ? '（空）' : book.currentUser}',
    );
    return _ToolResult(true, buf.toString());
  }

  /// 工具执行：query_record（男主查分类记录 / 候选分类路径）
  Future<_ToolResult> _executeQueryRecord(Map<String, dynamic> args) async {
    final tree = await RecordTreeStore.load();
    final keywords =
        (args['keywords'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final object = args['object']?.toString().trim() ?? '';

    final buf = StringBuffer();
    var any = false;

    if (object.isNotEmpty) {
      final paths = RecordTreeStore.candidatePaths(tree, object);
      if (paths.isNotEmpty) {
        any = true;
        buf.writeln('查「$object」的候选分类路径：');
        for (final pt in paths) {
          buf.writeln('- $pt');
        }
        buf.writeln('（看哪个对；不对就用 manage_record_tree 调整，会影响她所以要弹窗确认）');
      }
    }

    if (keywords.isNotEmpty) {
      final hits = RecordTreeStore.matchEntries(tree, keywords);
      if (hits.isNotEmpty) {
        any = true;
        buf.writeln('关键词 ${keywords.join('+')} 命中的记录：');
        for (final e in hits) {
          final path = RecordTreeStore.pathText(tree, e.nodeId);
          buf.writeln(
            '📂 $path'
            '${e.summary != null && e.summary!.isNotEmpty ? '（${e.summary}）' : ''}',
          );
          for (final n in e.notes) {
            final t = n.time;
            final ts =
                '${t.month.toString().padLeft(2, '0')}-'
                '${t.day.toString().padLeft(2, '0')} '
                '${t.hour.toString().padLeft(2, '0')}:'
                '${t.minute.toString().padLeft(2, '0')}';
            buf.writeln(
              '  · $ts ${n.text}'
              '${n.source != null && n.source!.isNotEmpty ? '（${n.source}）' : ''}',
            );
          }
          if (e.keywordGroups.isNotEmpty) {
            buf.writeln(
              '  关键词组：${e.keywordGroups.map((g) => g.join('+')).join(' / ')}',
            );
          }
        }
        buf.writeln('（同一分类下的记录是一家人，一起出来了）');
      }
    }

    if (!any) {
      // 给出现有分类概览，帮男主决定挂哪
      final paths = <String>[];
      for (final n in tree.nodes) {
        if (n.parentId != null) paths.add(RecordTreeStore.pathText(tree, n.id));
      }
      if (paths.isEmpty) {
        return const _ToolResult(
          true,
          '没查到。现有分类也还没有——你可以 add_record 新建'
          '（按 归属→关系→对象→类别 格式，如 ["用户","宠物"]）。',
        );
      }
      buf.writeln('没查到匹配。现有分类：');
      for (final pt in paths.take(40)) {
        buf.writeln('- $pt');
      }
      if (paths.length > 40) buf.writeln('…还有 ${paths.length - 40} 个');
      buf.writeln('（优先挂进现有分类；都不合适就 add_record 新建）');
    }
    return _ToolResult(true, buf.toString().trim());
  }

  /// 工具执行：add_record（男主自己记，挂分类下，免审批）
  Future<_ToolResult> _executeAddRecord(Map<String, dynamic> args) async {
    final path =
        (args['path'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        [];
    if (path.isEmpty) return const _ToolResult(false, '记录失败：没给分类路径');
    final text = args['text']?.toString().trim() ?? '';
    if (text.isEmpty) return const _ToolResult(false, '记录失败：没写原话');
    final groups =
        (args['keyword_groups'] as List?)
            ?.map(
              (g) => (g as List)
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty)
                  .toList(),
            )
            .where((g) => g.isNotEmpty)
            .toList() ??
        [];
    final summary = args['summary']?.toString().trim() ?? '';

    final tree = await RecordTreeStore.load();
    // 归属根校验：路径第一层必须是 用户/男主/其他
    if (path.first != '用户' && path.first != '男主' && path.first != '其他') {
      return const _ToolResult(
        false,
        '记录失败：路径第一层必须是 用户/男主/其他 之一'
        '（分清楚是谁的）',
      );
    }
    final nodeName = path.last;
    final parentPath = path.sublist(0, path.length - 1);
    final node = tree.ensureNode(parentPath, nodeName);

    // 每分类一条记录容器：存在则合并（原话/关键词组追加），不存在则新建
    var entry = tree.entries.where((e) => e.nodeId == node.id).firstOrNull;
    if (entry == null) {
      entry = RecordEntry(
        id: RecordTreeStore.newId('re'),
        nodeId: node.id,
        keywordGroups: groups,
        notes: [RecordNote(text: text, time: DateTime.now(), source: '男主记录')],
        summary: summary.isEmpty ? null : summary,
      );
      tree.entries.add(entry);
    } else {
      for (final g in groups) {
        if (!entry.keywordGroups.any((eg) => eg.join('|') == g.join('|'))) {
          entry.keywordGroups.add(g);
        }
      }
      entry.notes.add(
        RecordNote(text: text, time: DateTime.now(), source: '男主记录'),
      );
      if (summary.isNotEmpty) entry.summary = summary;
    }
    await RecordTreeStore.save(tree);
    final pathText = RecordTreeStore.pathText(tree, node.id);
    DebugLogger.log('指令模块', '🌳 男主记了一条：$pathText');
    return _ToolResult(
      true,
      '已记到「$pathText」'
      '${entry.keywordGroups.isNotEmpty ? '，关键词组：${entry.keywordGroups.map((g) => g.join('+')).join(' / ')}' : ''}'
      '。原话和以后同分类的句子都会合并在这里。',
    );
  }

  /// 工具执行：manage_record_tree（改分类影响她 → 弹窗审批）
  Future<_ToolResult> _executeManageRecordTree(
    Map<String, dynamic> args,
  ) async {
    final action = args['action']?.toString() ?? '';
    final nodeId = args['node_id']?.toString() ?? '';
    final name = args['name']?.toString().trim() ?? '';
    final newParentPath =
        (args['new_parent_path'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        [];

    final tree = await RecordTreeStore.load();
    final node = tree.nodeById(nodeId);
    if (node == null) return const _ToolResult(false, '调整失败：找不到这个分类节点');

    // 构造变更描述
    String desc;
    switch (action) {
      case 'rename':
        if (name.isEmpty) return const _ToolResult(false, '调整失败：没给新名字');
        desc = '把「${RecordTreeStore.pathText(tree, node.id)}」改名为「$name」';
        break;
      case 'move':
        if (newParentPath.isEmpty)
          return const _ToolResult(false, '调整失败：没给新位置');
        desc =
            '把「${RecordTreeStore.pathText(tree, node.id)}」挪到「${newParentPath.join('·')}」下面';
        break;
      case 'add_node':
        if (name.isEmpty) return const _ToolResult(false, '调整失败：没给新分类名');
        desc = '在「${RecordTreeStore.pathText(tree, node.id)}」下面加分类「$name」';
        break;
      case 'delete_node':
        desc =
            '删除「${RecordTreeStore.pathText(tree, node.id)}」'
            '（它下面的子分类和记录一起删）';
        break;
      default:
        return _ToolResult(false, '调整失败：未知动作 $action');
    }

    // 弹窗审批（复用设定审批弹窗模式：显示变更 + 确认/拒绝 + 反馈）
    final result = await _showRecordTreeConfirmDialog(desc);
    if (result == null) {
      return _ToolResult(false, '她没回应分类调整（先别催，她可能在忙）');
    }
    if (!result.approved) {
      final fb = result.feedback.trim();
      return _ToolResult(
        false,
        '她拒绝了分类调整。'
        '${fb.isNotEmpty ? '她的反馈：$fb——按她的意见改完再提交。' : '她没说原因，你可以问问她。'}',
      );
    }

    // 执行
    bool ok = false;
    switch (action) {
      case 'rename':
        ok = tree.renameNode(nodeId, name);
        break;
      case 'move':
        final parent = tree.ensureNode(
          newParentPath.sublist(0, newParentPath.length - 1),
          newParentPath.last,
        );
        ok = tree.moveNode(nodeId, parent.id);
        if (!ok) {
          return const _ToolResult(false, '移动失败：不能挪到它自己的子树里');
        }
        break;
      case 'add_node':
        tree.ensureNode(
          [
            ...RecordTreeStore.pathText(tree, node.id).split('·'),
            name,
          ].toList(),
          name,
        );
        ok = true;
        break;
      case 'delete_node':
        ok = tree.deleteNode(nodeId);
        if (!ok) {
          return const _ToolResult(false, '删除失败：归属根（用户/男主/其他）不能删');
        }
        break;
    }
    if (!ok) return _ToolResult(false, '调整失败，请重试');
    await RecordTreeStore.save(tree);
    DebugLogger.log('指令模块', '🌳 分类已调整（她确认过）：$desc');
    _appendToolBubble('🌳 分类已调整：$desc');
    return _ToolResult(true, '已调整：$desc。她确认过了。');
  }

  /// 分类调整审批弹窗（8-06 19:19 用户：弹窗内对话迭代，改对才确认）
  Future<({bool approved, String feedback})?> _showRecordTreeConfirmDialog(
    String description,
  ) async {
    if (!mounted) return null;
    FocusManager.instance.primaryFocus?.unfocus();
    final fbCtrl = TextEditingController();
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('🌳 男主想调整分类'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7EAF1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '他想：$description',
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: fbCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: '不同意的话，写给他让他再改…（可不填）',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒绝', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('同意'),
          ),
        ],
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    if (approved == null) return null;
    return (approved: approved, feedback: fbCtrl.text);
  }

  /// 工具执行：manage_pad（男主自己的便签/当前任务模块，免审批）
  Future<_ToolResult> _executeManagePad(Map<String, dynamic> args) async {
    final personaId = _state.personaId ?? '';
    final action = args['action']?.toString() ?? '';
    switch (action) {
      case 'set':
        final content = args['content']?.toString() ?? '';
        final lines = content
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        await WorkingPadStore.setAll(personaId, lines);
        DebugLogger.log('指令模块', '📋 便签整体更新（${lines.length} 行）');
        return _ToolResult(
          true,
          '便签已更新（${lines.length} 行）。'
          '${lines.isEmpty ? '已清空。' : '下一句对话你会带着它。'}',
        );
      case 'append':
        final content = args['content']?.toString().trim() ?? '';
        if (content.isEmpty) return const _ToolResult(false, '便签没写内容');
        await WorkingPadStore.append(personaId, content);
        DebugLogger.log('指令模块', '📋 便签追加一行');
        return _ToolResult(true, '已记到便签：$content');
      case 'remove':
        final from = (args['from'] as num?)?.toInt() ?? 0;
        final to = (args['to'] as num?)?.toInt();
        final n = await WorkingPadStore.remove(personaId, from, to);
        if (n == 0) {
          return _ToolResult(
            false,
            '删除失败：便签没有第 $from 行'
            '（先查一下现在有哪几行）',
          );
        }
        DebugLogger.log('指令模块', '📋 便签删了 $n 行');
        return _ToolResult(true, '便签删了 $n 行（第 $from 行起）。');
      default:
        return _ToolResult(
          false,
          '便签操作失败：未知动作 $action'
          '（set/append/remove）',
        );
    }
  }

  /// 通用超时唤醒：waitMinutes 后用户没回聊天页 → butlerWakeUp 唤醒男主
  /// （8-06 13:38 从 _scheduleNotifyWakeUp 泛化，notify_user / countdown_card 共用）
  void _scheduleWakeUp(int waitMinutes, String instruction) {
    _notifyWakeTimer?.cancel();
    _notifyWakeTimer = Timer(Duration(minutes: waitMinutes), () async {
      if (!mounted) return;
      if (_isChatPageActive) {
        DebugLogger.log('指令模块', '📬 超时检查：用户已回到聊天页，不唤醒');
        // 8-06 21:26：计划完成（她回来了，不用唤）→ 定时任务区移除
        TimerPlanStore.markDone(_state.personaId ?? '', '唤醒');
        return;
      }
      final pid = _state.personaId;
      final pname = _state.personaName;
      final pprompt = _currentPersonaPrompt();
      if (pid == null || pid.isEmpty) return;
      // 8-06 21:26：唤醒已执行 → 定时任务区移除
      TimerPlanStore.markDone(pid, '唤醒');
      DebugLogger.log('指令模块', '📬 超时唤醒：$waitMinutes 分钟没回来，唤醒男主再找她');
      final text = await AiChatService().butlerWakeUp(
        pid,
        (pname == null || pname.isEmpty) ? '男主' : pname,
        pprompt.isEmpty ? '你是她的恋人' : pprompt,
        instruction,
      );
      if (text.isNotEmpty) {
        _appendToolBubble('💌 男主又来找你了：$text');
      }
    });
  }

  /// 男主获准调取记忆 → 异步检索记忆库生成注入文本（按类别/条数）
  /// 21:02：记忆库存的是用户原文（可能含真实称呼）→ 注入前过假面层替换成代号
  /// 用户 8-03 01:52：用户指名道姓让男主调用工具（"调用recall_memory"等），
  /// 但模型可能忽略 → 检测工具名并注入强制提示，确保男主真的调用。
  /// 返回 null = 用户没提工具名，不注入。
  String? _buildExplicitToolHint(String userText) {
    const known = <String, String>{
      'record_memory': '记住',
      'record_relation': '记关系',
      'recall_memory': '查看记忆',
      'save_identity_memory': '保存身份记忆',
      'list_tools': '查看工具',
      'write_diary': '写日记',
      'query_diary': '查日记',
      'notify_user': '弹消息',
      'request_permission': '申请免审批',
      'query_logs': '查日志',
      'report_bug': '报bug',
      'countdown_card': '计时',
      'manage_task': '管理任务',
      'update_setting': '更新设定',
      'query_setting_history': '查设定历史',
      'query_record': '查记录',
      'add_record': '记记录',
      'manage_record_tree': '调分类',
      'manage_pad': '整理便签',
      'manage_flow': '流程',
      'continue_speaking': '继续说',
      'resolve_pending': '标记回复',
      'manage_frequent_tools': '维护常用工具',
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
          .map(
            (m) => m.content.replaceFirst(RegExp(r'^\[(喜好|约定|日常|事实|其他)\]'), ''),
          )
          .map(
            (c) =>
                maskEnabled ? butler.maskEngine.maskRealNames(c, sessionId) : c,
          )
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
      left: left,
      top: 0,
      width: width,
      bottom: 0,
      child: Container(
        color: color,
        child: (isCenter && panelOpen) ? IgnorePointer(child: child) : child,
      ),
    );
  }

  /// 当前 persona 的初始设定（用户写的人设），随每轮请求进 system
  String _currentPersonaPrompt() {
    try {
      var prompt = _state.persona?.prompt ?? '';
      // 8-06 18:24 用户：设定版本管理 —— prompt 附加男主设定/用户设定/变更摘要
      // （男主知道自己的演变史，不会"性情大变"却不知所以然）
      final pid = _state.personaId;
      if (pid != null && pid.isNotEmpty) {
        final book = SettingVersionStore.cached(_settingPid());
        if (book != null) {
          final male = book.currentMale.trim();
          final user = book.currentUser.trim();
          if (male.isNotEmpty) {
            prompt +=
                '\n\n【男主设定·当前版】（分段，改哪段用 update_setting 的 tag 定位）\n'
                '${_formatSectionsNumbered(male)}';
          }
          if (user.isNotEmpty) {
            prompt +=
                '\n\n【用户设定·当前版】（分段，改哪段用 update_setting 的 tag 定位）\n'
                '${_formatSectionsNumbered(user)}';
          }
          final summary = SettingVersionStore.summaryTextSync(_settingPid());
          if (summary.isNotEmpty) {
            prompt +=
                '\n\n【设定变更摘要·你的演变史】\n$summary'
                '（这些都是你经历过/主动做出的设定调整，顺着时间线你就能明白'
                '自己为什么是现在这个样子。需要细节可以调 query_setting_history。）';
          }
          // 8-06 20:53 用户报 bug：男主反复 list_tools → 工具概览注入（男主天生知道）
          // 8-06 21:54 用户：不写全量清单——分类概览 + 常用表，细节自查
          prompt +=
              '\n\n${_toolListText()}'
              '\n（连续测试/做事时：先把步骤立到便签（1. 2. 3.），'
              '再一条条执行过去；查到的结果自己决定留不留，重要的存便签，'
              '别重复查同一件事。）';
          // 8-06 21:12 用户：男主便签/当前任务模块——他自己维护，每轮注入
          final padText = WorkingPadStore.text(pid);
          if (padText != null) {
            prompt +=
                '\n\n【当前任务模块·你的便签】\n$padText'
                '\n（这是你自己维护的：查到的、干到一半的、还要用的都写在这。'
                '自己判断留删——干完活的删、正文里已经有的删（上下文已有的优先），'
                '不设限额，删的时候自己说行号范围。'
                '写摘要时自己清理。下一句对话你还知道有什么没干。）';
          }
          // 8-06 21:26 用户：定时任务独立区（跟便签分开——计划等触发，便签是正在干的活）
          final timerText = TimerPlanStore.waitingText(pid);
          if (timerText != null) {
            prompt +=
                '\n\n【定时任务】（你设的计划，到点会触发；'
                '触发完/她明确不要了就从这里移除）\n$timerText';
          }
          // 8-06 18:41-19:21 用户：分类记录体系 —— 记录职责 + 现有分类概览
          final recordDuty =
              '\n\n【你的记录职责】'
              '观察她的喜好/习惯/家人/宠物/说过的话，发现值得记的：'
              '先调 query_record（给关键词组或对象名）查有没有，已有就不动；'
              '没有就调 add_record 记下来——按「归属→关系→对象→类别」格式选分类路径'
              '（归属必须是 用户/男主/其他 之一，分清楚是谁的；'
              '如她妈妈的事 = ["用户","家人","妈妈","喜好"]）。'
              '凑不成关键词组合的一句话也记，会合并进该分类。'
              '记录里多挂几组关键词（a+b、a+b+c、b+d…），以后任意一组命中都能翻出原话和时间。'
              '想改分类（改名/挪动/加大类/删除）会影响她 → 调 manage_record_tree，'
              '会弹窗给她确认，她拒绝就给反馈，按反馈改完再提交。';
          prompt += recordDuty;
          // 现有分类概览（男主知道有什么，避免重复建；同步缓存读）
          try {
            final tree = RecordTreeStore.cached();
            if (tree != null) {
              final paths = <String>[];
              for (final n in tree.nodes) {
                if (n.parentId != null) {
                  paths.add(RecordTreeStore.pathText(tree, n.id));
                }
              }
              if (paths.isNotEmpty) {
                prompt += '\n\n【现有分类】\n';
                prompt += paths.take(50).join('\n');
                if (paths.length > 50) prompt += '\n…共 ${paths.length} 个分类';
                prompt += '\n（记东西优先挂进这些分类；都不合适再新建）';
              }
            }
          } catch (_) {}
        }
      }
      return prompt;
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
