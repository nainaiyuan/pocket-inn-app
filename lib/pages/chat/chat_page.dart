import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../butler/debug_lab/agent_run_trace.dart';
import '../../butler/debug_lab/trace_store.dart';
import '../../butler/debug_lab/trace_session.dart';
import '../../services/global_banner_service.dart';
import '../../services/tool_approval_store.dart';
import '../../services/global_timer_card_service.dart';
import '../../services/card_task_store.dart';
import '../../services/alarm_store.dart';
import '../../services/setting_version_store.dart';
import '../../services/record_tree_store.dart';
import '../../services/working_pad_store.dart';
import '../../services/flow_store.dart';
import '../../services/tool_cache_store.dart';
import '../../services/memory_block_store.dart';
import '../../services/tool_manual_store.dart';
import '../../services/tool_test_store.dart';
import 'services/chat_flow_store.dart';
import '../../services/timer_plan_store.dart';
import '../../services/pending_queue_store.dart';
import '../../butler/memory/relation_record.dart';
import '../../butler/storage/storage_registry.dart';
import '../../services/relation_change_notifier.dart';
import '../../services/tool_catalog.dart';
import '../../services/parse_utils.dart';
import 'widgets/task_list_page.dart';
import '../../data/bug_knowledge_base.dart';
import 'companion_page.dart';
import 'package:flutter/services.dart';
import '../../ai_provider/ai_provider_manager.dart';
import '../../ai_provider/models.dart';
import '../../ai_provider/tool_format_adapter.dart';
import '../../butler/tools/tool_intent_parser.dart';
import '../../models/male_lead.dart';
import '../../services/chat_database_service.dart';
import '../../services/chat_memory_service.dart';
import '../../models/chat_memory.dart';
import '../../services/chat_service.dart';
import '../../services/butler_command.dart';
import '../../butler/context/context_tracker.dart';
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
import 'widgets/pet_chat_overlay.dart';
import 'services/chat_storage_service.dart';
import 'services/multi_bubble_parser.dart';
import 'widgets/character_world_page.dart';
import '../../services/character_service.dart';
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
  // 8-14 14:5x：拖桌宠时锁定消息列表滚动
  bool _petDragging = false;
  Timer? _notifyWakeTimer; // 8-06 notify_user 超时唤醒
  Timer? _alarmTimer; // 8-10 定时任务检查器（闹钟到点 → 插流程步骤）
  /// 8-09 16:0x：FlowStore 变化通知回调引用（dispose 时注销用）
  VoidCallback? _flowOnChanged;
  Timer? _flowBarTimer; // 8-08 16:2x 流程条 2 秒轮询刷新（弹窗/底部进度同步）

  /// 设定审批弹窗内的版本快照（8-07 15:5x 用户：男主用 query_setting_version
  /// 按需查某版某段原文，不把全文塞给他）；弹窗关闭时置空
  List<({int v, String text, String diff})>? _dialogVersions;

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
    // 8-11 21:5x（用户：每轮 prompt 输入/输出要能回看）：
    // Agent 轨迹接 SharedPreferences 持久化（默认内存，重启就丢）
    TraceStore.configure(SharedPrefsTraceStorage());
    // 8-07 21:48 用户：日志增强——纯 Dart store 的日志钩子统一接 DebugLogger
    FlowStore.logSink = (t, m) => DebugLogger.log(t, m);
    // 8-09 16:0x（用户：流程卡片动态显示）：FlowStore 变化 → 立即刷新 UI
    //（步骤推进/状态变化/流程结束，卡片实时跟随，同一数据源）
    _flowOnChanged = () {
      if (mounted) setState(() {});
    };
    FlowStore.onChanged = _flowOnChanged;
    ToolCacheStore.logSink = (t, m) => DebugLogger.log(t, m);
    PendingQueueStore.logSink = (t, m) => DebugLogger.log(t, m);
    ChatFlowStore.logSink = (t, m) => DebugLogger.log(t, m);
    ToolIntentParser.logSink = (t, m) => DebugLogger.log(t, m);
    multiBubbleLogSink = (t, m) => DebugLogger.log(t, m);
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onAnimTick);
    _state.addListener(_onStateChanged);
    // 8-10：定时任务检查器（30 秒查一次，到点的闹钟 → 插当前流程步骤后面）
    _alarmTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final pid = _state.personaId;
      if (pid == null || pid.isEmpty) return;
      unawaited(_checkAlarms(pid));
    });
    // 8-09 16:0x：2 秒轮询已退役——FlowStore.onChanged（_write 后通知）实时刷新，
    // 卡片/状态条与 FlowStore 同一数据源，步骤推进立即更新
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
    // 8-08 15:2x（设计 7.5，GPT 10 问 6 定案：APP 重启 = 保存状态+恢复运行+
    // 用户进入 APP 时继续，不做后台常驻）：上次任务未完成 → 提示并自动续跑
    _checkRestartResume();
  }

  /// APP 重启恢复：FlowStore 持久化了 running 任务 → 用户进 APP 时
  /// 提示"上次任务未完成"并自动续跑（silent 默认，男主自己干完）
  Future<void> _checkRestartResume() async {
    try {
      final pid = _state.personaId ??
          (_state.leadId == null ? '' : '${_state.leadId}_default');
      if (pid.isEmpty) return;
      FlowStore.warm(pid);
      if (!FlowStore.isRunning(pid)) return;
      final flow = await FlowStore.get(pid);
      // 8-12 06:5x（用户：写完摘要+end_T0 还不停唤醒）：开机先清僵尸——
      // 工具测试建的旧任务没人收尾会无限唤醒；测试已不在跑 = 僵尸 →
      // 直接取消，连"上次任务未完成"的提示都不弹（那不是真任务）
      final goal = flow?['goal']?.toString() ?? '';
      if (goal == '测试所有工具' && !ToolTestStore.isRunning(pid)) {
        await FlowStore.cancel(pid);
        DebugLogger.log(
          '管家流程',
          '🧟 开机清理：工具测试僵尸任务已取消（测试早结束了，任务没人收尾）',
        );
        return;
      }
      final steps = (flow?['steps'] as List?)?.length ?? 0;
      final rawCur = (flow?['currentStep'] as num?)?.toInt() ?? 0;
      if (steps == 0) return;
      // 8-08 21:0x（用户：5/4）：currentStep 走完但 status 残留 running 的
      // 旧数据由 FlowStore 自愈；这里再兜一层显示保护（不显示越界进度）
      final cur = rawCur >= steps ? steps : rawCur + 1;
      DebugLogger.log(
        '管家流程',
        '🔔 APP 重启恢复：上次任务未完成（「${flow?['goal']}」第 $cur/$steps 步），'
        '自动续跑（用户进入 APP）',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '上次任务未完成（「${flow?['goal']}」第 $cur/$steps 步），男主继续干活…',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      // 自动续跑（等用户稍作停留，让 UI 先渲染完）
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (mounted) await _maybeAutoResume(pid);
    } catch (e) {
      DebugLogger.log('管家流程', '⚠️ APP 重启恢复检查失败: $e');
    }
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

  /// 8-13 02:2x 任意 persona 的测试空间映射（聚合设定历史用）
  String _settingPidFor(String pid) =>
      _useTestSpace(pid) ? '$pid${AIProviderManager.mockTestSuffix}' : pid;

  /// 8-13 02:2x 本体记忆共享开关（per persona，默认开）
  Future<bool> _memoryShareEnabled(String personaId) async {
    if (personaId.isEmpty) return false;
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool('memory_share_$personaId') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 8-06 23:55 用户：流程停止条——长任务时强行让男主停止
  /// 8-08 16:2x（用户定稿）：去掉 💬 插话按钮（直接发送=插话），只留 ⏹ 停止
  /// 8-09 16:0x（用户：卡片动态）：按钮随状态变——running → ⏹停止；
  /// stopped/paused → ⏹结束（取消流程，卡片消失）
  Widget _buildFlowStopBar() {
    final pid =
        _state.personaId ??
        (_state.leadId == null ? '' : '${_state.leadId}_default');
    final summary = FlowStore.summary(pid) ?? '流程执行中';
    final flowStatus = FlowStore.isRunning(pid) ? 'running' : 'paused';
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
            child: Text(
              flowStatus == 'running' ? '⏹ 停止' : '⏹ 结束',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 8-06 23:55 用户：停止按钮——流程 running → stopped，
  /// 把"停在哪 + 用户说了什么"作为【系统事件】给男主，它决定继续还是先回复
  /// 8-08 17:3x（用户反馈："我要让他停止，他又不会自动判断，每次唤醒都写气泡"）：
  /// 停止按钮语义扩展——不止停流程，还要停"男主自动续话"：
  /// - 有流程 → 停流程（原逻辑）
  /// - 没流程（男主在自动续话/自言自语）→ 停止续话 + 本轮结束后不再唤醒
  /// - 之前 bug：flow == null 直接 return → 无流程时按停止 = 无效，
  ///   男主继续续话写气泡直到 3 次上限
  Future<void> _stopFlow() async {
    final pid =
        _state.personaId ??
        (_state.leadId == null ? '' : '${_state.leadId}_default');
    final flow = await FlowStore.get(pid);
    // 8-08 17:3x：flow 可能为 null（没流程）——停止依然有效（停续话）。
    // 只有页面没了才 return
    if (!mounted) return;

    // 8-08 17:3x：用户按停止 → 本轮结束后的检查点⑤不再续话/唤醒
    //（男主回应"好的我安静"后不能被续话机制再拉起来 3 次）。
    // 用户下次发消息/插话时清除。
    _stopRequested = true;

    // 8-08 17:3x：无流程 → 只停续话：重置续话状态 + 正在生成的轮
    // 结束后注入"安静"指令，不再自动唤醒
    if (flow == null) {
      _autoContinuePid = null;
      _autoContinueCount = 0;
      _continueFrozen = false; // 8-08 18:1x：停止也解除续话冻结
      _interruptRoundActive = false;
      _interruptFollowUpDone = false;
      DebugLogger.log('管家流程', '⏸ 用户按停止（无流程）：停止男主自动续话，等他说话');
      if (_generating) {
        // 男主正在说 → 排队，这轮结束注入安静指令
        _pendingStopEvent =
            '用户按了停止：请立刻停止你现在正在说的话，'
            '安静等她下次发消息（不要自动续话、不要调工具）。';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已停止，男主这轮说完就安静'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已停止，男主不再自动说话'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
      if (mounted) setState(() {});
      return;
    }

    final pendingMsgs = PendingQueueStore.list(pid);
    final userText = pendingMsgs
        .map((e) => '[待#${e['id']}] ${e['text']}')
        .join('；');
    final steps =
        (flow['steps'] as List?)?.map((e) => e.toString()).toList() ??
        <String>[];
    final cur = (flow['currentStep'] as num?)?.toInt() ?? 0;
    // 8-09 16:0x（用户：卡片按钮随状态变）：流程已暂停（stopped/paused_by_user）
    // 时点按钮 = 结束（取消流程，卡片消失）；只有 running 才走 stop（可 resume）
    final flowStatus = flow['status']?.toString() ?? '';
    if (flowStatus != 'running') {
      await FlowStore.cancel(pid);
      _autoResumePid = null;
      _autoResumeRounds = 0;
      _lastAutoResumeStep = -1;
      _autoContinuePid = null;
      _autoContinueCount = 0;
      _continueFrozen = false;
      _interruptRoundActive = false;
      _interruptFollowUpDone = false;
      DebugLogger.log(
        '管家流程',
        '⏹ 用户结束已暂停的流程：目标「${flow['goal']}」（取消）',
      );
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('流程已结束'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    await FlowStore.stop(pid, userMessages: userText);
    // 8-08 13:0x 检查点⑤锚点：暂停 = 完全停止（用户拍板）——日志留痕，
    // resume 队列实现后这里要同时"移出队列 + 取消唤醒 Timer"
    // 8-08 14:0x：停止 → 取消自动续跑（否则刚停又被续跑拉起来）
    _autoResumePid = null;
    _autoResumeRounds = 0;
    _lastAutoResumeStep = -1;
    // 8-08 15:5x：停止 → 同时重置续话/插话状态
    _autoContinuePid = null;
    _autoContinueCount = 0;
    _continueFrozen = false; // 8-08 18:1x：停止也解除续话冻结
    _interruptRoundActive = false;
    _interruptFollowUpDone = false;
    DebugLogger.log(
      '管家流程',
      '⏸ 用户停止流程：目标「${flow['goal']}」，停在 ${cur + 1}/${steps.length} 步'
      '（暂停后不唤醒，等用户再发消息）',
    );
    if (mounted) setState(() {});
    final curStep = cur < steps.length ? steps[cur] : '';
    final event =
        '你正在执行的流程被用户打断：目标「${flow['goal']}」，'
        '停在 ${cur + 1}/${steps.length} 步（$curStep）。'
        '她刚才发来的消息（管家收集的）：'
        '${userText.isEmpty ? '（没有新消息，她只是按了停止）' : userText}。'
        '请决定：① 继续执行流程（旧长任务卡片，可直接说"继续"）；'
        '② 先回复她（流程保持暂停，回完再继续，或说结束）。';
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
    await _sendMsg('', systemEvent: event, bubbleText: '⏸ 你按了停止，男主正在处理…');
  }

  /// 8-08 15:1x：输入框 controller（外部传入 ChatInputBar）——
  /// 💬 插话要读输入框内容：打字 → 点插话 = 像发送一样直接发出去
  final _inputCtrl = TextEditingController();

  /// 8-08 16:2x（用户定稿："工作的时候直接发出去，不用单独插话按钮"）：
  /// 男主忙时用户直接发消息 = 插话：上屏 + 推给男主（先回用户再继续干活）。
  /// 与 ⏹ 停止（彻底停）区分：插话只是"优先回复"，任务不打断。
  /// 男主回复完 → 检查点⑤ → 自动续跑继续任务（断点 D 已修复，正好衔接）。
  Future<void> _interruptSend(String text, String pid) async {
    // 上屏：像发送一样，用户看到自己的话发出去了（输入框 ChatInputBar 已清）
    if (mounted) {
      _msgKey.currentState?.appendMessage(
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          text: text,
          isMe: true,
        ),
      );
    }
    // 用户说话了 → 重置男主续话计数
    _autoContinuePid = null;
    _autoContinueCount = 0;
    _continueFrozen = false; // 8-08 18:1x：用户说话 → 解除续话冻结
    _stopRequested = false; // 插话 = 用户主动说话，停止状态解除
    _maleChoseContinue = false; // 8-10 00:5x：用户说话 → 重置结尾命令标志
    // 8-09 18:2x（对话流程 v2）：插话也进对话流程（追加步骤）
    ChatFlowStore.warm(pid);
    unawaited(ChatFlowStore.feedUser(pid, text));
    // 8-11 04:3x（用户实测：插话没记入上下文）：插话走 systemEvent 路径
    // 发男主，generateReply 里 systemEvent != null 不 feed 用户消息 →
    // 插话原文不进【上下文参考】互动历史，男主回复后（步骤一消）上下文里
    // 就没了（用户看到：发给男主的内容有男主回复、没她的插话）。
    // 这里显式 feed（记入互动历史 + 原文落库；feedUserMessage 自带
    // appendContextRaw，男主后续轮次还能看到插话原文；非待回复，不双回）
    final _interruptChatPid =
        _useTestSpace(pid) ? '$pid${AIProviderManager.mockTestSuffix}' : pid;
    ContextManager.instance.feedUserMessage(_interruptChatPid, text);
    // 8-08 15:5x：存下插话内容（插话轮男主没回 → 兜底轮带给她看）
    _interruptUserText = text;
    // 队列里可能还有旧收集消息（旧版/管家入队）→ 一起带上
    var fullText = text;
    final pendingMsgs = PendingQueueStore.list(pid);
    if (pendingMsgs.isNotEmpty) {
      final extra = pendingMsgs
          .map((e) => '[待#${e['id']}] ${e['text']}')
          .join('；');
      fullText = '$text（另外还有：$extra）';
      await PendingQueueStore.removeByIds(
        pid,
        pendingMsgs.map((e) => e['id'].toString()).toList(),
      );
    }
    // 8-09 15:3x（用户设计定稿）：插话 = 流程里的正式步骤（不暂停流程）。
    // 流程执行中 → 当前步后插入"回复用户+判断"步骤，流程保持 running：
    // 当前步完成 → autoAdvance 自然推进到插话步骤 → 男主回复+调 manage_flow。
    // 用户的话像正常步骤一样记录（状态块可见、结束沉淀便签），
    // 检查点⑤ 看到流程 running 天然续跑——从根上杜绝"插话后断链"。
    final flowNow = await FlowStore.get(pid);
    final flowRunning = flowNow != null && flowNow['status'] == 'running';
    if (flowRunning) {
      final short =
          fullText.length > 40 ? '${fullText.substring(0, 40)}…' : fullText;
      await FlowStore.insertStep(pid,
          name: '回复用户：$short',
          note: fullText);
      DebugLogger.log('管家流程', '📌 用户插话 → 插入流程步骤（男主回完她后判断流程）: $short');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已把你的话排进流程，男主做完当前步就回你'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    // 8-09 20:5x（用户实测：对话流程里插话显示"流程已暂挂"误导）：
    // 没有长任务流程 → 检查对话流程（ChatFlowStore）。对话流程里
    // 插话 = feedUser 追加步骤（上面已做），流程**没有暂挂**，
    // 男主按步骤顺序回即可，不需要"resume/update/cancel"长任务指令。
    final chatFlowNow = ChatFlowStore.get(pid);
    final chatFlowRunning =
        chatFlowNow != null && chatFlowNow['status']?.toString() == 'running';
    if (chatFlowRunning) {
      final short =
          fullText.length > 40 ? '${fullText.substring(0, 40)}…' : fullText;
      DebugLogger.log(
          '管家流程', '💬 对话流程插话 → 已追加步骤，男主按序回: $short');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已追加到对话流程，男主按顺序回你'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      final chatEvent =
          '用户想跟你说话（已追加到当前对话流程，你按顺序回她，流程不用暂停）。'
          '她刚才发来的消息：$fullText。\n'
          '**这一轮先回复她**（插话轮管家会拦工具，回完她之后可以继续调工具处理流程步骤）。';
      await _sendMsg(
        '',
        systemEvent: chatEvent,
        // 8-10 01:2x（用户：插话气泡显示在我气泡那里，不要）：
        // 插话轮不显示用户侧气泡，男主直接说话
        silentBubble: true,
      );
      return;
    }
    final event =
        '用户想跟你说话（管家转达，你回完她之后判断）：'
        '她刚才发来的消息：$fullText。\n'
        '**这一轮先回复她，不要调任何工具**（插话轮管家会拦截工具调用）。\n'
        '回完她之后，根据她的话判断：\n'
        '· 她只是闲聊/没改需求 → 继续原流程（旧长任务卡片）；\n'
        '· 她提了新需求/要查东西 → 按她说的调整方向再继续；\n'
        '· 她明确说"不要了/取消" → 才结束流程；\n'
        '· 拿不准 → 默认继续原流程，**绝不因为她随便一句话就取消整个流程**。';
    if (_pendingInterruptEvent != null) {
      // 已有插话排队 → 合并（男主当前轮结束只推一次，内容带全）
      _pendingInterruptEvent = '$_pendingInterruptEvent\n她又发来：$text';
      DebugLogger.log('管家流程', '💬 插话排队中，合并新消息: $text');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('男主正在忙，已把你的话排上，他回完就说'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (_generating) {
      // 男主正在跑这轮（工具轮循环中）→ 排队，等它结束自动触发
      _pendingInterruptEvent = event;
      DebugLogger.log('管家流程', '💬 男主忙，插话排队（当前轮结束推）: $text');
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已把你的话排上，男主这轮忙完就回你'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    // 男主空闲但流程 running（等审批等）→ 直接触发插话轮
    DebugLogger.log('管家流程', '💬 男主空闲，直接推插话: $text');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已发给男主，他先回你'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    await _sendMsg(
      '',
      systemEvent: event,
      // 8-10 01:2x（用户：插话气泡显示在我气泡那里，不要）：
      // 插话轮不显示用户侧气泡，男主直接说话
      silentBubble: true,
    );
  }

  /// 8-08 14:0x（断点 D 修复）：任务 running → 自动续跑（APP 内第一版唤醒）。
  /// 男主回完用户消息任务没完成 → 自动继续执行，不用用户再发消息。
  /// 防死循环：currentStep 变了 → 重置计数（正常推进）；同一步连续 3 轮
  /// 无进展（currentStep 没变）→ 停止，注入系统事件让男主向用户交代。
  Future<void> _maybeAutoResume(String pid) async {
    if (_generating) return; // 已在生成（并发保护）
    final flow = await FlowStore.get(pid);
    if (flow == null || flow['status'] != 'running') return;
    // 8-12 06:5x（用户：男主写完摘要+发完 end_T0 还不停唤醒）：僵尸旧任务
    // 检测——manage_tool_test start 建的 FlowStore 任务（goal=测试所有工具）
    // 没人收尾（report/abort 只动 ToolTestStore 自己的状态），任务永远
    // running → 检查点⑤无限续跑唤醒男主，而男主工作区看不到旧任务、
    // 永远无法结束它。测试已不在跑（done/aborted）而任务还 running
    // = 僵尸 → 直接收掉，不唤醒男主。
    final goal = flow['goal']?.toString() ?? '';
    if (goal == '测试所有工具' && !ToolTestStore.isRunning(pid)) {
      await FlowStore.cancel(pid);
      DebugLogger.log(
        '管家流程',
        '🧟 僵尸旧任务检测：工具测试已结束但 FlowStore 任务没收尾'
        '（长任务系统 8-10 已停用）→ 自动取消，不再唤醒',
      );
      return;
    }
    final cur = (flow['currentStep'] as num?)?.toInt() ?? 0;
    if (_autoResumePid != pid) {
      // 换了任务 → 重置计数
      _autoResumePid = pid;
      _autoResumeRounds = 0;
      _lastAutoResumeStep = -1;
    }
    // 8-08 14:4x：上一轮请求了审批（弹窗等用户点）→ 是等待不是卡死 → 清零
    if (_lastRoundRequestedApproval) {
      _lastRoundRequestedApproval = false;
      _autoResumeRounds = 0;
      _lastAutoResumeStep = cur;
      DebugLogger.log('管家流程', '🔔 上一轮在等用户审批，不计入无进展');
    }
    if (cur != _lastAutoResumeStep) {
      // 推进了 → 重置无进展计数
      _lastAutoResumeStep = cur;
      _autoResumeRounds = 0;
    }
    if (_autoResumeRounds >= 3) {
      // 同一步连续 3 轮没推进 → 停止自动续跑，让男主交代
      DebugLogger.log('管家流程', '🔔 自动续跑 3 轮无进展，停止（等用户指示）');
      // 8-12 06:5x（用户：写完摘要+end_T0 还不停唤醒）：旧任务 3 轮无进展
      // = 僵尸（长任务系统 8-10 已停用，任务无法推进、男主工作区也看不到）
      // → 直接取消收掉；之前只发消息 + 重置计数，下一轮检查点⑤又无限续跑
      await FlowStore.cancel(pid);
      _autoResumePid = null;
      _autoResumeRounds = 0;
      _lastAutoResumeStep = -1;
      await _sendMsg(
        '',
        systemEvent: '你刚才自动续跑了几轮但流程没有推进（一直停在'
            '第 ${cur + 1} 步）。不要继续空转：告诉用户你卡在哪、缺什么，'
            '或决定 finish/cancel。',
        bubbleText: '🔔 男主自动续跑无进展，已停下等你处理…',
      );
      return;
    }
    _autoResumeRounds++;
    final steps = (flow['steps'] as List?)?.length ?? 0;
    // 8-09 15:3x（插话=流程步骤）：续跑前先查插话步骤兜底——
    // 男主卡在"回复用户"步骤只回话没调 manage_flow → 2 轮后强制 resume
    final fb = await FlowStore.interruptStepFallback(pid);
    if (fb == 'ok' || fb == 'ok_done') {
      DebugLogger.log('管家流程', '⏭ 插话步骤兜底触发（男主未调 manage_flow），流程继续');
      _autoResumeRounds = 0;
      _lastAutoResumeStep = -1; // 步骤已变，重置无进展计数
      if (fb == 'ok_done') return; // 全部完成，流程收尾，不再续跑
      // ok：已推进到下一步 → 继续本轮续跑（男主执行新步骤）
    } else if (fb == 'waiting') {
      DebugLogger.log('管家流程', '⏳ 插话步骤男主仍未调 manage_flow（兜底计数+1，继续提示）');
    }
    DebugLogger.log(
      '管家流程',
      '🔔 自动续跑 #$_autoResumeRounds（任务 running，男主继续执行第 ${cur + 1}/$steps 步）',
    );
    final rawStep = (flow['steps'] as List?) != null &&
            cur < (flow['steps'] as List).length
        ? (flow['steps'] as List)[cur]
        : null;
    // 8-08 15:2x：steps 对象化后取 name（旧字符串数组直接 toString）
    final stepText = rawStep is Map
        ? (rawStep['name']?.toString() ?? rawStep.toString())
        : (rawStep?.toString() ?? '');
    await _sendMsg(
      '',
      systemEvent: '任务还没完成，继续执行（用户没发新消息，这是自动续跑）：'
          '目标「${flow['goal']}」，当前第 ${cur + 1}/$steps 步（$stepText）。'
          '基于已有结果继续推进；做完直接回复她消掉（旧长任务卡片能收尾就收尾）。'
          '别重新规划、别重复查已查过的东西。',
      bubbleText: '🔔 男主继续执行流程…',
    );
  }

  /// 8-08 15:5x（用户需求：男主回复后自动唤醒，判断要不要继续说）：
  /// 非流程场景的男主主动续话机制——
  /// - 男主这轮说了话（spoke=true）→ 自动再唤醒一次，让他判断：
  ///   继续补充 / 做点事 / 结束这轮（结束=不唤醒，直到用户下次说话）
  /// - 男主这轮没说话 → 不唤醒（他不想说了）
  /// - 上限：用户消息之间最多 3 次（用户说话重置计数）
  /// - 最小间隔 25 秒（8-08 17:2x 日志复盘：男主 70 秒被唤醒 6 次，
  ///   每轮都去调工具/重写便签 → 用户看到"男主一直不停"）
  /// - 8-08 18:1x（GPT 意见）：续话 = "结束检查轮"——唤醒不是"必须继续说话"，
  ///   是给男主一次判断机会；他输出 need_continue:false / next_action:null
  ///   （_continueFrozen）→ 不再唤醒，直到用户说话
  /// - 用户消息排队（男主忙时收集的）→ 优先回用户（相当于自动插话）
  /// - 流程场景不经过这里（走 _maybeAutoResume，任务驱动）
  Future<void> _maybeAutoContinue(String pid, {required bool spoke}) async {
    if (_generating) return; // 并发保护
    if (pid.isEmpty) return;
    // 8-10 00:49（用户：去掉二次复核）——对话流程已结束（done）→
    // 不唤醒：男主先干活再回复，回复消掉大流程 = 流程结束，安静等用户。
    // 还有下一个大流程（running 有 pending）→ 检查轮带清单唤醒男主
    // 继续走（checkBrief 在下方注入"还有 N 条没回"）。
    // 普通聊天（statusOf == null）不受影响，检查轮照旧。
    // 8-10 00:5x（用户：结尾命令）——男主输出续命/合并命令 → done
    // 也放行（唤醒继续干活/处理后续大流程），用完即清。
    final chatFlowStatus = ChatFlowStore.statusOf(pid);
    final maleChoseContinue = _maleChoseContinue;
    _maleChoseContinue = false;
    // 8-10 21:5x（用户：manage_task 失败后男主消流程 → done 不唤醒 → 失败被遗忘）：
    // 本轮有工具失败（_lastRoundToolFailed）→ 即使 done 也唤醒男主处理，
    // 检查轮会带失败提醒。处理完（下轮无新失败）自然恢复"done 不唤醒"。
    // 8-12 04:1x（用户拍板：标了 end_TN+摘要=结束，不管中间有没有做完）：
    // done 一律不唤醒——男主写了摘要 = 他检查过了，失败结果也写在
    // 工具链（❌）/摘要里，不再因工具失败二次唤醒（那正是反复唤醒的
    // 另一个来源）。有排队新流程 → finish() 已提升为 running（statusOf
    // = 'running'），走下方检查轮唤醒处理下一个（T2）；没有 → 安静等用户。
    // 8-12 05:4x（用户：男主都做完了、工作区没有待办了，怎么还唤醒）：
    // "没有待办工作"就不唤醒，不只认 done——running 但全部步骤 ✅ 处理完
    // （只差 end_TN + 摘要归档）也一样不唤醒：唤醒他去补结束标记 = 男主
    // 看不懂、反复被叫（无限唤醒撞三次锁）。归档提醒本来就在工作区
    // （buildText"所有消息都处理完了"），下次她说话时男主自然看到补
    // end_TN + 摘要；有排队 T2 → finish() 已提升为 running 且带待办步骤
    // → hasPendingStep=true，走下方检查轮唤醒处理下一个。
    final toolFailed = _lastRoundToolFailed;
    _lastRoundToolFailed = false;
    final chatFlowNow = ChatFlowStore.get(pid);
    final hasPendingStep = chatFlowNow != null &&
        ((chatFlowNow['steps'] as List?) ?? const [])
            .any((s) => s['status']?.toString() != 'done');
    if ((chatFlowStatus == 'done' ||
            (chatFlowStatus == 'running' && !hasPendingStep)) &&
        !maleChoseContinue) {
      DebugLogger.log(
        '管家流程',
        chatFlowStatus == 'done'
            ? '🔕 对话流程已结束（done），不唤醒（用户 8-12：标了 end_TN+摘要=结束；'
                '有排队 T2 会由 finish 提升为 running 自动轮到）'
            : '🔕 对话流程全部处理完（无待办步骤，只差 end_TN+摘要归档），'
                '不唤醒（用户 8-12 05:4x：做完就不叫，下次她说话时工作区提醒补归档）',
      );
      return;
    }
    if (toolFailed) {
      DebugLogger.log(
        '管家流程',
        '🔔 本轮有工具失败（流程未结束 → 检查轮带失败提醒，男主判断重试还是结束）',
      );
    }
    if (maleChoseContinue) {
      DebugLogger.log(
        '管家流程',
        '🔔 男主结尾命令=继续/合并 → done 放行，检查轮唤醒',
      );
    }
    // ① 用户有消息排队（男主忙时收集的）→ 先回用户（优先级最高）
    final pending = PendingQueueStore.list(pid);
    if (pending.isNotEmpty) {
      _autoContinuePid = null;
      _autoContinueCount = 0; // 用户说话了，续话计数重置
      _continueFrozen = false; // 用户说话了，解除冻结
      final texts = pending
          .map((e) => '[待#${e['id']}] ${e['text']}')
          .join('；');
      await PendingQueueStore.removeByIds(
        pid,
        pending.map((e) => e['id'].toString()).toList(),
      );
      DebugLogger.log(
        '管家流程',
        '💬 男主忙时收集到用户消息 → 自动推给男主先回（$texts）',
      );
      if (mounted) {
        unawaited(
          _sendMsg(
            '',
            systemEvent: '用户刚才发来消息（你忙的时候管家收集的）：$texts。'
                '先回复她。',
            // 8-10 01:2x（用户：插话气泡显示在我气泡那里，不要）：
            // 不显示用户侧气泡，男主直接说话
            silentBubble: true,
          ),
        );
      }
      return;
    }
    // ② 男主这轮没说话 → 不唤醒（他不想说了，安静等用户）
    // 8-09 15:2x（用户日志：插话后男主断了——任务 paused_by_user 时男主
    // 回完插话/没回话都必须唤醒判断 resume/update/cancel，否则流程永远挂）
    // 8-10 00:4x（用户确认：空回复=二次唤醒复核正常流程，男主确认结束，
    // 别乱改）→ 不加"有思考无正文强制唤醒"的兜底
    if (!spoke) {
      final flowNow = await FlowStore.get(pid);
      final pausedByUser = flowNow != null &&
          (flowNow['status']?.toString() ?? '') == 'paused_by_user';
      if (!pausedByUser) {
        _autoContinuePid = null;
        _autoContinueCount = 0;
        _continueFrozen = false;
        return;
      }
      // paused_by_user：不 return——继续走检查轮（下方 pausedJudge 会带
      // resume/update/cancel 指令），男主必须交代流程怎么处理
      DebugLogger.log(
        '管家流程',
        '🔔 流程仍被插话暂挂（paused_by_user），男主没说话也唤醒判断流程',
      );
    }
    // ②' 男主已明确判定无需继续（need_continue:false）→ 不再唤醒
    //（8-08 18:1x GPT：next_action 为空 + 无 running 任务 → 停止 resume）
    // 8-12 05:2x（用户拍板：唤醒模型只有两种"不再唤醒"——消大流程归档、
    // 静默结束（need_continue:false，唤醒后直接结束不说话））：
    // 冻结**一律生效**（之前只拦非 running——男主静默结束后还会被检查轮
    // 再叫，不对）。有排队 T2 被 finish() 提升为 running 时，chat_page
    // 在 finish 后主动解除冻结（_continueFrozen=false）→ 检查轮立即唤醒
    // 处理下一个（不等用户说话）。
    if (_continueFrozen) {
      DebugLogger.log(
        '管家流程',
        '🔒 男主静默结束（need_continue:false）→ 不再唤醒，'
        '等用户说话（流程未归档的，下次她说话时工作区提醒补 end_TN + 摘要）',
      );
      return;
    }
    // ③ 上限 3 次（用户没说话）
    if (_autoContinuePid != pid) {
      _autoContinuePid = pid;
      _autoContinueCount = 0;
    }
    if (_autoContinueCount >= 3) {
      _autoContinuePid = null;
      _autoContinueCount = 0;
      _continueFrozen = false;
      DebugLogger.log('管家流程', '🔔 男主续话已达 3 次上限，停止（等用户说话）');
      return;
    }
    _autoContinueCount++;
    // 8-08 17:3x：续话计数变化 → 刷新停止条显示（男主续话中要能看到停止）
    if (mounted) setState(() {});
    DebugLogger.log(
      '管家流程',
      '🔔 男主续话 #$_autoContinueCount（结束检查轮：唤醒男主判断要不要继续说）',
    );
    // 8-08 16:2x（用户反馈：男主"为什么发空消息给我"）：
    // 续话提醒必须说清"这是系统自动提醒，不是用户消息"，男主才不会误解
    // 8-08 18:1x（GPT 意见）：改成"结束检查轮"——判断有没有必须继续的事，
    // 没有就输出退出标记 {"need_continue": false}（管家识别，不显示给她）
    // 8-08 19:0x：流程被她插话暂挂 → 检查轮带判断任务（resume/update/cancel）
    String pausedJudge = '';
    final flowNow = await FlowStore.get(pid);
    if (flowNow != null &&
        (flowNow['status']?.toString() ?? '') == 'paused_by_user') {
      pausedJudge = '当前流程被她插话暂挂了（她的话：'
          '${flowNow['stoppedNote'] ?? ''}）。你判断：\n'
          '· 她只是闲聊/没改需求 → 继续原流程（旧长任务卡片，能收尾就收尾）；\n'
          '· 她提了新需求/要查东西 → 按她说的调整方向再继续；\n'
          '· 她明确说"不要了/取消" → 才结束流程；\n'
          '· 拿不准 → 默认继续原流程，绝不乱取消。\n'
          '判断完直接回复她，不用问她。\n';
    }
    // 8-09 18:1x（对话流程）：检查轮带待回清单（还有几条没回）
    final chatFlowBrief = ChatFlowStore.checkBrief(pid);
    // 8-10 21:5x：工具失败提醒（本轮有失败才带，用完即清）
    // 8-12 04:1x：改用上方捕获的 toolFailed（原代码读 _lastRoundToolFailed
    // 已被顶部清零 → 永远为空，死代码）
    final toolFailedNote = toolFailed
        ? '⚠️ 刚才有工具调用失败了（看上面工具结果里的 ❌）：'
            '能补参数重试就补调工具重试；不需要处理就说明原因后正常结束。\n'
        : '';
    await _sendMsg(
      '',
      systemEvent: '【系统自动提醒——这不是用户消息，不用回复这条提醒本身】\n'
          '现在是"结束检查"：上一轮你已回复完，用户没有说话。\n'
          '$toolFailedNote'
          '$pausedJudge'
          '${chatFlowBrief != null ? '（对话流程：$chatFlowBrief）\n' : ''}'
          '请判断有没有必须继续的事：\n'
          '① 有未完成的话题，或刚才被打断没说完的回复？\n'
          '② 有正在运行的任务需要继续推进？\n'
          '③ 有明确的下一步动作（查资料/记记忆/推进流程）？\n'
          '有 → 继续做，或说一句进展；\n'
          '没有 → 说一句自然的结束语，并在这条回复的末尾加上退出标记：'
          '{"need_continue": false}（管家识别这个标记，不会显示给她；'
          '加了这个标记，系统就不会再自动唤醒你）。\n'
          '（8-12 05:2x 用户拍板：两种"不再唤醒"——① 工作区有【当前工作区】'
          '流程 → 最后一条 JSON 的 sys 写 end_TN（N=流程编号），信封里带 '
          'summary（这个大流程的简短摘要）归档；② 直接写 '
          '{"need_continue": false} = 静默结束'
          '（不再唤醒，流程保持不归档；下次她说话时工作区会提醒你补 '
          'end_TN + 摘要归档）。）\n'
          '注意：刚做完的事不用再调工具确认（流程已结束就别重复 finish），'
          '没有新事做就直接说结束语。'
          '（8-09 17:5x 补充）如果你刚回复她时漏记了新信息（她说过的'
          '喜好/习惯/约定）→ 现在补调 record_memory 记上，补完简单说'
          '一句或直接退出标记结束，不用长篇汇报。',
      silentBubble: true,
    );
  }

  Future<void> _sendMsg(
    String t, {
    String? systemEvent,
    String? bubbleText,
    bool silentBubble = false,
  }) async {
    // 8-07 14:03：测试空间设定初始化（首次进测试空间，复制真实设定副本）
    final _tPid =
        _state.personaId ??
        (_state.leadId == null ? '' : '${_state.leadId}_default');
    if (_tPid.isNotEmpty && _useTestSpace(_tPid)) {
      await SettingVersionStore.ensureTestCopy(_tPid);
    }
    // 8-08 16:2x（用户定稿："工作的时候直接发出去，不用单独插话按钮"）：
    // 男主忙（生成中/流程执行中）→ 用户直接发消息 = 插话：
    // 上屏 + 推给男主（先回用户再继续干活），不再默默收集。
    // 停止触发的生成（systemEvent 非空）不走插话。
    if (systemEvent == null && t.trim().isNotEmpty) {
      final flowPid =
          _state.personaId ??
          (_state.leadId == null ? '' : '${_state.leadId}_default');
      FlowStore.warm(flowPid);
      final busy = _generating || FlowStore.isRunning(flowPid);
      if (busy) {
        await _interruptSend(t, flowPid);
        return;
      }
    }
    // 8-03 18:2x（用户反馈"男主说完话再说话他不理人"）：生成锁——
    // 男主生成中（含工具轮）新消息直接忽略并提示，防并发上下文混乱
    // 8-08 16:2x：不再忽略也不再收集——上面已统一走 _interruptSend（直接发=插话）
    if (_generating) {
      return;
    }
    _generating = true;
    // 8-08 15:5x：用户正常发消息 → 重置男主续话计数（用户说话 = 新一轮对话）
    if (systemEvent == null && t.trim().isNotEmpty) {
      _autoContinuePid = null;
      _autoContinueCount = 0;
      _stopRequested = false; // 用户说话了 → 停止状态解除
    }
    // 8-08 15:5x：本轮男主输出信息（finally 用——判断"男主这轮说了话没"、
    // 续话/插话检查的数据源）。注意作用域：try 外声明，try/finally 都能读。
    var roundSpoke = false; // 男主本轮最终生成了非空文本
    final userMsgId = DateTime.now().millisecondsSinceEpoch.toString();
    // 本轮男主第一句话气泡 id 重置（工具气泡只挂本轮第一句话头上）
    _firstAiMsgId = null;
    // 8-06 23:55：停止触发的生成没有用户消息 → 显示系统提示气泡
    // 8-08 15:5x：silentBubble（男主自动续话轮）不显示系统气泡——男主直接说话
    if (!silentBubble) {
      _msgKey.currentState?.appendMessage(
        ChatMessage(
          id: userMsgId,
          text: systemEvent == null
              ? t
              : (bubbleText ?? '⏸ 你按了停止，男主正在处理…'),
          isMe: true,
        ),
      );
    }
    final lid = _state.leadId;
    final personaId = _state.personaId ?? (lid == null ? '' : '${lid}_default');
    final personaName = _state.personaName ?? _state.lead?.name ?? '角色';
    // 8-06 21:00：工具结果记忆预热（prompt 注入同步读，这里先刷新缓存）
    // 8-06 21:12：便签（当前任务模块）预热
    WorkingPadStore.warm(personaId);
    // 8-08 02:1x：工具工作缓存预热（男主干活中间数据，自管免审批）
    ToolCacheStore.warm(personaId);
    // 8-08 15:2x：工具手册 + 测试任务预热
    ToolManualStore.warm(personaId);
    // 8-12 18:0x：长期/短期记忆块预热（固定区记忆注入）
    // 8-13 02:2x 本体记忆共享：开关开 → 聚合 Lead 下所有角色的记忆块
    await _warmMemoryBlocks(personaId, lid);
    ToolTestStore.warm(personaId);
    // 8-06 21:26：定时任务计划预热
    TimerPlanStore.warm(personaId);
    // 8-06 21:36：待回复队列预热
    PendingQueueStore.warm(personaId);
    FlowStore.warm(personaId);
    // 8-06 21:54：常用工具表预热
    FrequentToolsStore.warm(personaId);
    // 8-09 18:2x（对话流程 v2）：用户消息 → 对话流程（立流程/追加步骤）。
    // 男主忙时的插话路径（_interruptSend）在上面已 return 分流，
    // 插话的 feed 在 _interruptSend 里做；这里只处理男主空闲时的正常消息。
    if (systemEvent == null && t.trim().isNotEmpty) {
      ChatFlowStore.warm(personaId);
      unawaited(ChatFlowStore.feedUser(personaId, t));
    }
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
      // 8-10 用户：管家分析出的信息（记忆/习惯/情感波动/技能触发/温控询问/
      // 获准记忆/工具提示）→ 插到触发它的那句话的流程步骤后面，合并做——
      // 不再塞进固定区（userProfile/taskState），男主处理那条时一起看一起做
      if (systemEvent == null) {
        for (final note in <String?>[
          skillInjection,
          keywordAsk,
          ...recallInjection,
          toolHint,
        ]) {
          if (note != null && note.trim().isNotEmpty) {
            unawaited(ChatFlowStore.feedButlerNote(chatPid, note));
          }
        }
      }
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
        // 8-10 v3：技能注入/温控询问/获准记忆已改挂流程步骤（上面
        // feedButlerNote），userProfile 只剩稳定用户设定
        userProfile: [
          _currentUserSetting(),
        ].join('\n'),
        taskState: [
          if (_pendingFeedback != null) _pendingFeedback!,
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
      // 8-07 19:15：多气泡逐条落库记录（链式 parent 还原顺序 + spans 样式）
      final dbRows = <_BubbleRow>[];
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
        replyTexts.add(result.text.trim());
        var textToShow = result.text;
        // 8-07 19:15（用户拍板）：男主回复不带任何标签（<reply>/<msg>/<act>）
        // → 整条打回重写：不显示、不执行、不落库；连续 3 次熔断放行防死循环
        // 8-07 23:5x（男主自诊断+用户建议）：**工具写岔 ≠ 纯聊天不按格式**——
        // 男主调工具格式没对上时，不当"格式违规"打回（会熔断放行漏裸 <
        // 且工具没执行 → 流程挂起）；而是豁免打回：提示正确格式注入下轮，
        // 疑似工具串剥掉后显示（空则不显示），流程不卡
        final suspHint = ToolIntentParser.detectSuspicious(textToShow);
        final isToolWriteOff = suspHint != null;
        if (!_hasAnyTag(textToShow) && !isToolWriteOff) {
          _formatFailCount++;
          if (_formatFailCount >= 3) {
            _formatFailCount = 0; // 熔断：第 3 次强制放行（按纯文本显示）
          } else {
            final rewriteEvent = '你的回复没有按格式输出（缺少 JSON 块），'
                '已被打回，用户没看到。请按格式重写（JSON 对象，每个占一行）：'
                '{"reply":"end_MN"}（标注回哪条，可省）'
                '+ {"act":"动作/神态"}（可选）+ {"msg":"你说的话"}。'
                '除 JSON 对象外不要输出任何其他文字；一次说多句 = 多个 {"msg":..} 对象。';
            DebugLogger.log('AI路由', '⛔ 男主无标签回复，打回重写（第 $_formatFailCount 次）');
            ChatPresence.instance.beginTyping();
            final rewritten = await _aiSvc.generateReply(
              '',
              personaId,
              personaName: personaName,
              personaPrompt: _currentPersonaPrompt(),
              userProfile: _currentUserSetting(),
              sessionId: _chatSessionId,
              storagePersonaId: chatPid,
              systemEvent: rewriteEvent,
            );
            if (rewritten.text.trim().isNotEmpty) {
              replyTexts.add(rewritten.text.trim());
              result = rewritten; // 整体替换 → 工具解析/工具轮用重写结果
              textToShow = rewritten.text;
            } else {
              ChatPresence.instance.endTyping();
              return; // 重写也空 → 结束本轮（别死循环）
            }
          }
        } else if (isToolWriteOff) {
          // 工具写岔豁免：不当格式违规打回；疑似工具串剥掉后显示剩余
          DebugLogger.log('AI路由', '📐 男主工具写岔（豁免打回），提示下轮修正格式');
          textToShow = ToolIntentParser.stripToolBlocks(textToShow);
          textToShow = stripAnthropicInvokeBlocks(textToShow);
        }
        final firstText = await _displayableText(textToShow);
        if (firstText.isNotEmpty) {
          // 8-10 00:0x（用户：哪个对话先出来，思考就放到谁那里；全都该有
          // 思考，不然像 bug——DS 客户端开思考就全有思考，不会时有时无）：
          // 男主说话的气泡 → 挂自己的思考（_takeFlowThinking 在 buffer 空
          // 时 = 本轮思考）。之前纯工具轮（男主没说话）攒的思考合并给
          // 这个气泡（不丢）。插话轮：插话思考独立挂自己的，不碰 buffer
          //（插话是独立轮，不能把流程攒的思考合并给它）。
          final interruptRound = _interruptRoundActive;
          final rows = await _appendMaleReply(
            textToShow,
            thinkingChain: interruptRound
                ? result.reasoningContent
                : _takeFlowThinking(result.reasoningContent),
            isFirst: true,
          );
          dbRows.addAll(rows);
          if (rows.isEmpty) {
            // 解析后为空（纯标签壳）→ 没有打字 → 关"正在输出"
            ChatPresence.instance.endTyping();
          }
          // 文字进入打字机播放 → "正在输出"由打字机播完时 endTyping 关闭
        } else {
          // 文本被剥离成空（纯指令/工具块）→ 本轮没有打字 → 关"正在输出"；
          // 8-10 00:0x：没说话但思考了 → 攒 buffer（下个说话气泡合并）
          _bufferFlowThinking(result.reasoningContent);
          ChatPresence.instance.endTyping();
        }
      } else {
        // 第一轮没说话（直接调工具）→ 工具阶段不显示"正在输出"；
        // 8-10 00:0x：思考攒 buffer（下个说话气泡合并，不丢）
        _bufferFlowThinking(result.reasoningContent);
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
      // 8-08 16:2x：中间文本攒起逻辑已删除（男主说了话立即显示，见工具轮分支）
      final consecutiveToolCounts = <String, int>{};
      // 8-06 21:36：continue 累计计数（交错调用也能防无限"继续说"）
      var continueCount = 0;
      // 8-07 00:1x：用户连续拒绝计数（≥3 强制男主停止尝试）
      var rejectedCount = 0;
      // 8-07 22:5x 用户：男主"一直查一直查工具"卡死——交错调用防不住
      // （consecutive 只数连续同工具）。加：
      // ① 本轮查询类工具累计 ≥3 强制停（不管交错）
      // ② 工具轮总轮数上限 6（防 query_logs→list_tools→query_logs 死循环）
      var queryToolCount = 0;
      // 8-12 20:3x（用户：不同工具翻找累计失败 8 次就提醒明确需求）
      var totalFailCount = 0;
      // 8-08 02:1x 用户：干太快被卡 → 总轮数 6 → 10（防死循环仍保留）
      // 8-12 20:2x（用户：兜底放宽，正常干活别卡）→ 10 → 12
      const maxToolRounds = 12;
      while (result.toolCalls != null && result.toolCalls!.isNotEmpty) {
        toolLoop++;
        toolExecuted = true;
        // 8-12 20:3x：stop 事件在 for 循环外生成，失败原因状态提到这里
        var lastFailName = '';
        var lastFailN = 0;
        var lastQueryStop = false;
        if (toolLoop > maxToolRounds) {
          // 防御兜底（正常路径由下方 stop 事件先拦，这里保证不无限循环）
          DebugLogger.log(
            'AI路由',
            '⚠️ 工具轮超过 $maxToolRounds 轮，强制跳出（防死循环）',
          );
          break;
        }
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
        // 8-08 22:5x（DeepSeek 400 根治，用户：老弹灰框一串错误）：
        // 思考模式要求带 tool_calls 的 assistant 消息必须原样回传
        // reasoning_content（8-03 06:54 已知）。响应里解析不出（或为空）
        // 时强行发原生 tool_calls 必 400 → 该轮不发原生，工具结果全走
        // 文本合并注入（translateToolRound 路径，天然免疫 400）。
        // 非思考模型（推理链本来就空）也走文本协议——功能完整只是不用
        // 原生 tool_calls，比 400 弹灰框强。
        final hasReasoning =
            (result.reasoningContent?.trim().isNotEmpty ?? false);
        // 8-09 17:0x（用户设计定稿：思考模式显式开关）：
        // 只有"开思考"的请求才需要 reasoning_content 回传保护（DeepSeek
        // 思考模式要求原样回传，否则 400）。没开思考的模型（非思考模型/
        // 思考关）工具轮本来就没有 reasoning_content，原生 tool_calls 完全
        // 正常 → 不再一刀切转文本（修正 8-08 22:5x 的过度防御：它把非思考
        // 模型的正常原生调用也砍了，这就是"动不动转文本协议"的直接原因）。
        final thinkingOn = AIProviderManager.instance.providers
                .where((c) =>
                    c.id ==
                    AIProviderManager.instance.lastProviderFor(personaId))
                .map((c) => c.thinkingEnabled == true)
                .firstOrNull ??
            false;
        // 8-09 22:3x（用户日志 HTTP 400：assistant tool_calls 必须跟 tool 消息）：
        // 修复"部分 call 缺 id"场景——原生路径要求**每个 call 都有 id 且全量配对**：
        // - 缺 id 的 call 被过滤 → nativeCalls 少一条 → 但循环仍执行它（走文本收集）
        //   → toolMessages 的 assistant(tool_calls) 带 N 个 call 却只有 N-1 条
        //   tool 消息 → DeepSeek 400 "must be followed by tool messages responding
        //   to each tool_call"。
        // - 修：只要原生路径有任何一个 call 缺 id → 整轮转文本协议（不混用），
        //   保证 assistant(tool_calls) 和 tool 消息严格一一配对。
        // 8-10 20:3x（用户日志复现：20:17:52 HTTP 400 仍发生）：
        // 上次修复只对 thinkingOn=true 检查 id——**thinkingOn=false 时
        // nativeCalls 直接收全部（不查 id）**，文本工具块（⟨工具:⟩ 解析，
        // 无 id，如 add_record）照样进原生路径 → 400。
        // 修：**有 id 才走原生，无 id 一律文本协议**（与 thinkingOn 无关）——
        // 原生 tool_calls 按规范必带 id，缺 id 的只可能是文本块解析来的。
        // 8-10 21:0x（用户：文本协议是兜底，不该当主路径——各家 AI 能原生
        // 就原生，DeepSeek 要传思考链也照传）：**补稳定 id 走原生，不降级**。
        // 补 id 含轮次+序号（同轮同名工具不冲突），与循环里 tool 消息的
        // toolCallId 一致 → assistant(tool_calls) 与 tool 消息严格一一配对。
        for (var i = 0; i < result.toolCalls!.length; i++) {
          final c = result.toolCalls![i];
          if ((c['id']?.toString() ?? '').isEmpty) {
            c['id'] = 'call_${toolLoop}_${i}_${c['name']?.toString() ?? ''}';
            DebugLogger.log(
              'AI路由',
              '🔗 文本块 call 补原生 id：${c['id']}（走原生配对，不降级）',
            );
          }
        }
        // 唯一降级场景：思考模式开启但没返回思考（异常状态）→ 保守文本协议
        final nativeCalls = (thinkingOn && !hasReasoning)
            ? <Map<String, dynamic>>[]
            : result.toolCalls!;
        if (result.toolCalls!.isNotEmpty && nativeCalls.isEmpty) {
          DebugLogger.log(
            'AI路由',
            '🛡 工具轮降级文本协议（思考模式异常：thinkingOn 但无 reasoning）→ '
            '原生 tool_calls 不发了',
          );
        }
        final textToolResults = <String>[];
        // 8-07 00:1x：用户拒绝收集——拒绝不走普通工具结果（男主会无视），
        // 这轮工具执行完走【系统事件】通道强制男主决策
        final rejectedTools = <String>[];
        // 8-08 21:5x（GPT10问第7条 state_hint 专区）：本轮软提示累积
        //（查询类≥3/连续拒绝≥2）→ 状态块【状态提示】注入，不混 toolMessages
        final toolRoundHints = <String>[];
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
        // 8-12 02:4x（用户：T1 工作区挂着 T0 的工具结果）：工具执行是
        // 异步的，结果回来时流程可能已切换（结束/拆插话）——执行前
        // snapshot 当前流程编号，挂步骤/存缓存时校验，不串流程
        final toolFlowNo =
            ChatFlowStore.get(personaId)?['flowNo']?.toString();
        for (final call in result.toolCalls!) {
          final name = call['name']?.toString() ?? '';
          // 8-08 19:0x（GPT 18:59 + 用户 19:04 定稿）：插话轮禁工具——
          // 机械拦截（原来只是提示，男主不听话会调）：不执行、直接回执给男主
          if (_interruptRoundActive) {
            DebugLogger.log(
              '管家流程',
              '🔒 插话轮禁工具：男主调 $name 被拦截（这轮只回用户）',
            );
            toolMessages.add(
              AIChatMessage(
                role: 'tool',
                content: '【工具 $name】❌被管家拦截：插话轮禁止调用工具，'
                    '这一轮只回复用户。她提的新需求先口头确认，'
                    '回完后判断流程怎么办（继续/调整/结束）。',
                toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
              ),
            );
            continue;
          }
          // 8-08 14:0x（断点 C 根治）：男主工具参数常写中文 key（{动作: next}）
          // 工具只认英文 key（{action: next}）→ next 失败 → 任务卡死。
          // 模型行为不可控，解析层兜底：按工具名做中文→英文参数名归一化。
          final rawArgs = (call['arguments'] as Map<String, dynamic>?) ?? {};
          final args = _normalizeToolArgs(name, rawArgs);
          _ToolResult toolResult;
          DebugLogger.log(
            'AI路由',
            '🔧 工具 $name 参数：${args.isEmpty ? '（空）' : args}'
            '${rawArgs != args && rawArgs.isNotEmpty ? '（原文：$rawArgs）' : ''}',
          );
          // 8-07 21:2x 用户：工具气泡没显示全/跳过——工具循环无异常保护，
          // 一个工具执行炸了后面全断。每个工具单独 try-catch：炸了显示 ❌
          // 气泡继续下一个，男主看得到哪个失败，下一轮能处理
          try {
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
          } else if (name == 'manage_schedule') {
            // 8-10 用户：定时任务（闹钟）——男主自管，本地保存到点提醒，
            // 不需要她审批（她让男主设的闹钟，男主自己写自己查）
            _appendToolBubble('⏰ 男主在整理定时任务…');
            toolResult = await _executeManageScheduleTool(args);
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
            _appendToolBubble('📋 男主在整理临时记忆…');
            toolResult = await _executeManagePad(args);
          } else if (name == 'manage_tool_cache') {
            // 8-08 02:1x 用户：工具工作缓存——男主干活中间数据（自管免审批）
            _appendToolBubble('🗃️ 男主在整理工具缓存…');
            toolResult = await _executeManageToolCache(args);
          } else if (name == 'manage_memory_block') {
            // 8-12 18:0x 用户：长期/短期记忆块（固定区记忆，压缩节点才更新）
            _appendToolBubble('🧠 男主在整理长期/短期记忆…');
            toolResult = await _executeManageMemoryBlock(args);
          } else if (name == 'save_summary') {
            // 8-11 20:2x（用户：男主说没有 save_summary）：正常轮执行分支——
            // 固定结束流程写摘要（大流程讲了什么）；range 可选
            final content = (args['content']?.toString() ?? '').trim();
            if (content.isEmpty) {
              toolResult = const _ToolResult(
                false,
                'save_summary 要带 content（摘要内容：这个大流程讲了什么）',
              );
            } else {
              final range =
                  (args['range']?.toString() ?? '').trim().isEmpty
                      ? '大流程摘要'
                      : args['range'].toString();
              await ContextManager.instance
                  .appendSummary(personaId, '（$range）$content');
              DebugLogger.log('上下文管理',
                  '✅ 男主调 save_summary 写摘要（$range，${content.length} 字）');
              toolResult = _ToolResult(true, '摘要已保存：$content');
            }
          } else if (name == 'manage_flow') {            // 8-06 23:55 用户：流程层——男主自管（免审批）
            // 8-10 03:0x 用户拍板：长任务=普通对话流程，manage_flow 停用。
            // 只放行收尾动作（finish/cancel/status 处理遗留卡片），创建/推进/续跑类一律拒绝。
            _appendToolBubble('📋 男主在整理流程…');
            final action = args['action']?.toString() ?? '';
            if (action != 'finish' && action != 'cancel' && action != 'status') {
              toolResult = const _ToolResult(
                false,
                'manage_flow 已停用（8-10 用户拍板：长任务直接做，不用立流程/定步骤）。'
                '直接干活，做完回复她消掉她的话；有遗留长任务卡片要收尾，用 finish/cancel/status。',
              );
            } else if (action == 'finish') {
              toolResult = _ToolResult(true, await FlowStore.finish(personaId));
            } else if (action == 'cancel') {
              toolResult = _ToolResult(true, await FlowStore.cancel(personaId));
            } else if (action == 'status') {
              final flowText = FlowStore.text(personaId);
              if (flowText != null) {
                toolResult = _ToolResult(true, flowText);
              } else {
                final chatText = ChatFlowStore.buildText(personaId);
                if (chatText != null) {
                  toolResult = _ToolResult(
                    true,
                    '没有长任务流程（已停用）。\n当前对话流程（用户消息自动立）:\n$chatText',
                  );
                } else {
                  toolResult = _ToolResult(false, '没有流程');
                }
              }
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_flow 已停用（8-10 用户拍板：长任务直接做，不用立流程/定步骤）。',
              );
            }
          } else if (name == 'manage_chat_flow') {
            // 8-09 19:3x（设计九.4/9.8）：对话流程调整——男主融合/删除步骤
            // action=merge（nos=[编号]+name=新内容）/ delete（nos=[编号]）/ status
            _appendToolBubble('📋 男主在调整对话流程…');
            final action = args['action']?.toString() ?? '';
            List<int>? nos;
            if (args['nos'] is List) {
              nos = (args['nos'] as List)
                  .map((e) => int.tryParse(e.toString()) ?? 0)
                  .where((e) => e > 0)
                  .toList();
            }
            if (action == 'merge') {
              final r = await ChatFlowStore.mergeSteps(
                personaId,
                nos: nos ?? const [],
                name: args['name']?.toString(),
              );
              toolResult = _ToolResult(r == 'ok', r == 'ok'
                  ? '已融合对话流程步骤 ✅（下次注入清单可见）'
                  : r);
            } else if (action == 'delete') {
              final r = await ChatFlowStore.deleteSteps(
                personaId,
                nos: nos ?? const [],
              );
              toolResult = _ToolResult(r == 'ok', r == 'ok'
                  ? '已删除对话流程步骤 ✅'
                  : r);
            } else if (action == 'status') {
              toolResult = _ToolResult(
                true,
                ChatFlowStore.buildText(personaId) ?? '没有对话流程',
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_chat_flow 参数：action=merge/delete/status。'
                'merge 带 nos=[步骤编号列表]+name=合并后的新内容；'
                'delete 带 nos=[步骤编号列表]。示例：'
                '{"action":"merge","nos":[1,2],"name":"记录用户喜欢猫也喜欢狗"}',
              );
            }
            if (mounted) setState(() {});
          } else if (name == 'manage_tool_manual') {
            // 8-08 15:2x（设计文档四，GPT 10 问 2）：工具使用手册——男主自管免审批
            // 格式/示例/坑记进手册，下次不重新试格式
            _appendToolBubble('📖 男主在整理工具手册…');
            final action = args['action']?.toString() ?? '';
            final tName = args['tool']?.toString() ?? '';
            if (action == 'add' || action == 'update') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.save(
                  personaId,
                  tName,
                  usage: args['usage']?.toString(),
                  format: args['format']?.toString(),
                  example: args['example']?.toString(),
                  note: args['note']?.toString(),
                ),
              );
            } else if (action == 'get') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.get(personaId, tName),
              );
            } else if (action == 'list') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.list(personaId),
              );
            } else if (action == 'remove') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.remove(personaId, tName),
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_tool_manual 参数：action=add/update/get/list/remove，'
                'tool=工具英文名；add 可带 usage/format/example/note。'
                '示例：{"action":"add","tool":"search_web","format":"{\\"query\\":\\"关键词\\"}"}',
              );
            }
          } else if (name == 'manage_tool_test') {
            // 8-08 15:2x（设计文档八，GPT 10 问 10）：工具测试任务管理器——男主自管免审批
            // 管家维护 checklist，男主每轮只面对"当前要测的工具"一个对象
            _appendToolBubble('🧪 男主在管理工具测试任务…');
            final action = args['action']?.toString() ?? '';
            if (action == 'start') {
              final toolsRaw = args['tools'];
              final tools = <String>[];
              if (toolsRaw is List) {
                for (final t in toolsRaw) {
                  final s = t.toString().trim();
                  if (s.isNotEmpty) tools.add(s);
                }
              } else if (toolsRaw is String) {
                tools.addAll(toolsRaw
                    .split(RegExp(r'[,，\n]+'))
                    .where((t) => t.trim().isNotEmpty));
              }
              // 自动立流程（goal=测试工具），checklist 由 ToolTestStore 维护
              if (!FlowStore.isRunning(personaId)) {
                await FlowStore.create(personaId, '测试所有工具',
                    ['逐个测试工具并记录结果', '汇总测试结果给用户']);
              }
              toolResult = _ToolResult(
                true,
                await ToolTestStore.start(personaId, tools),
              );
              if (mounted) setState(() {});
            } else if (action == 'report') {
              final tName = args['name']?.toString() ?? '';
              final ok = args['ok'] == true ||
                  args['ok']?.toString() == 'true' ||
                  args['ok']?.toString() == '成功';
              toolResult = _ToolResult(
                true,
                await ToolTestStore.report(
                  personaId,
                  tName,
                  ok: ok,
                  bug: args['bug']?.toString(),
                ),
              );
              // 8-12 06:5x（用户：男主写完摘要+end_T0 还不停唤醒）：测试
              // 全部测完（report 后 ToolTestStore 变 done）→ 收掉 start 建的
              // FlowStore 旧任务——之前没人收尾，僵尸 running → 检查点⑤
              // 无限续跑唤醒男主，而男主工作区看不到旧任务、永远无法结束
              if (!ToolTestStore.isRunning(personaId)) {
                await FlowStore.finish(personaId);
                DebugLogger.log(
                  '管家流程',
                  '🧪 工具测试已全部完成 → 收掉旧任务（防僵尸唤醒）',
                );
              }
            } else if (action == 'abort') {
              toolResult = _ToolResult(
                true,
                await ToolTestStore.abort(personaId),
              );
              // 8-12 06:5x：中止同样收掉旧任务（防僵尸）
              if (!ToolTestStore.isRunning(personaId)) {
                await FlowStore.cancel(personaId);
                DebugLogger.log(
                  '管家流程',
                  '🧪 工具测试已中止 → 取消旧任务（防僵尸唤醒）',
                );
              }
            } else if (action == 'status') {
              toolResult = _ToolResult(
                true,
                await ToolTestStore.status(personaId),
              );
            } else if (action == 'abort') {
              toolResult = _ToolResult(
                true,
                await ToolTestStore.abort(personaId),
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_tool_test 参数：action=start/report/status/abort。'
                'start 带 tools 列表；report 带 name+ok(+bug)。'
                '示例：{"action":"report","name":"search_web","ok":true}',
              );
            }
          } else if (name == 'manage_frequent_tools') {
            // 8-06 21:54 用户：常用工具表维护（男主自己的，免审批）
            final action = args['action']?.toString() ?? '';
            final name = args['name']?.toString() ?? '';
            if (action == 'add') {
              // 8-08 15:5x（用户反馈）：中文名/描述也能加（"记她的事"→record_memory），
              // 成功回显中文名确认，失败给可用示例
              final resolved = ToolCatalog.resolveName(name);
              if (resolved == null) {
                toolResult = _ToolResult(
                  false,
                  '没有「$name」这个工具。试试这些：'
                  '${ToolCatalog.allNames.take(8).join('、')}…'
                  '（也可以发中文描述，如"记她的事"）',
                );
              } else {
                await FrequentToolsStore.add(personaId, resolved);
                final desc = ToolCatalog.toolDetail(resolved) ?? resolved;
                toolResult = _ToolResult(
                  true,
                  '已加入常用表：$resolved（$desc）——'
                  '每轮都会出现在【你常用的工具】',
                );
              }
            } else if (action == 'remove') {
              // 8-08 15:5x：中文名/描述也能删
              final resolved = ToolCatalog.resolveName(name);
              final ok = resolved != null &&
                  await FrequentToolsStore.remove(personaId, resolved);
              toolResult = ok
                  ? _ToolResult(true, '已从常用表移除：$resolved')
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
            final rIds = <String>[];
            final rRaw = args['replied_ids'];
            if (rRaw is List) {
              for (final v in rRaw) {
                // 数字或字母（管家提醒 #A）都认
                final s = v.toString().trim();
                if (RegExp(r'^\d+$').hasMatch(s) ||
                    RegExp(r'^[A-Za-z]$').hasMatch(s)) {
                  rIds.add(s.toUpperCase());
                }
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
          } else if (name == 'query_tool_formats') {
            // 8-07 19:15 用户：管家识别不了男主的调用方式 → 查格式模板
            // 按文本块锁过滤：未解锁不返回文本块模板
            toolResult = _ToolResult(true, await _queryToolFormats(personaId));
          } else if (name == 'request_text_block') {
            // 8-07 19:15 用户：AI 主动申请文本块（原生+其他格式都试过）→ 用户批准
            final reason = args['reason']?.toString() ?? '';
            final approved =
                await _approveTextBlock(personaId, personaName, reason);
            toolResult = _ToolResult(
              approved,
              approved
                  ? '✅ 她已批准文本块！现在可以用：⟨工具:工具名⟩{"参数":"值"}⟨/工具⟩'
                  : '她暂时没批准文本块。继续用原生或其他家格式（查 query_tool_formats）',
            );
          } else {
            toolResult = _ToolResult(false, '未知工具：$name');
          }
          } catch (e) {
            DebugLogger.log('AI路由', '🔧 工具 $name 执行异常: $e');
            toolResult = _ToolResult(false, '工具执行异常：$e');
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
          // ── Agent Debug Lab 埋点（8-09）：工具执行 + 记忆写入 ──
          TraceSession.instance.recordToolExecution(TraceToolExecution(
            name: name,
            args: args,
            ok: toolResult.ok,
            resultText: toolResult.text,
            userApproved: !toolResult.text.startsWith('用户拒绝'),
          ));
          if (toolResult.ok &&
              (name == 'record_memory' || name == 'record_relation')) {
            TraceSession.instance.recordMemoryWritten('$name ✅');
          }
          // 8-08 15:2x（步骤状态机）：工具使用记录进 FlowStore 当前步
          // toolsUsed（完成条件判定 + 任务清单"本步已用工具"数据源）
          final briefForStep = toolResult.text.trim();
          await FlowStore.recordToolUse(
            personaId,
            name,
            ok: toolResult.ok,
            // 8-08 23:5x（GPT 参考 Tool Memory/Scratchpad）：结果摘要放宽
            // 到 120 字——男主从【当前流程】/【工具使用历史】直接看到
            // 结果，不用反复查（60 字经常截掉关键信息）
            brief: briefForStep.length > 120
                ? '${briefForStep.substring(0, 120)}…'
                : briefForStep,
          );
          // 8-09 18:2x（对话流程 v2）：工具挂到对话流程当前步
          // （决策点数据源：查了没找到 → 男主判断继续查还是回复结束）
          unawaited(ChatFlowStore.feedTool(
            personaId,
            name,
            ok: toolResult.ok,
            brief: briefForStep.length > 120
                ? '${briefForStep.substring(0, 120)}…'
                : briefForStep,
            flowNo: toolFlowNo,
          ));
          // 8-08 02:2x 用户：男主查完不记一直查 → 查询结果自动进工具缓存
          // 8-11 18:0x（用户 17:57 设计：缓存区 = 男主外置大脑）：
          // · 查询类工具结果 → 自动进缓存（男主下次直接查缓存，不重复查）
          // · **超长结果（>300 字，工具全查/大段数据）→ 完整存缓存**，
          //   上下文只留一行摘要 + "完整结果已存工具缓存"（不塞满每轮）
          final resultText = toolResult.text.trim();
          final isLong = resultText.length > 300;
          // 8-11 20:15（用户拍板）：工具编号 C1/C2…独立分配——
          // 结果行带编号，男主看到成功/失败可报编号查详细记录
          final toolNo = await ToolCacheStore.nextToolNo();
          if (toolResult.ok && (kQueryToolNames.contains(name) || isLong)) {
            if (resultText.isNotEmpty) {
              // 8-12 02:1x（用户：外置大脑的编号要对应 T1）——缓存条目
              // 带大流程编号 [T1]，男主/管家能按大流程查这轮的工具记录；
              // 用执行前 snapshot 的 flowNo（工具结果迟到时不串新流程）
              final flowTag =
                  (toolFlowNo != null && toolFlowNo.isNotEmpty)
                      ? ' [$toolFlowNo]'
                      : '';
              await ToolCacheStore.add(
                  personaId, '$toolNo$flowTag $name：$resultText');
            }
          }
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
          // 8-09 22:3x（400 修复）：配对条件从 nativeCalls.contains(call)
          // 改为 nativeCalls.isNotEmpty——原生路径现在是"全量配对"（要么
          // 全部 call 都进 nativeCalls，要么整轮转文本），不再有"部分 call
          // 被过滤"的中间态；contains 判断在 call 对象相等性上不可靠
          //（模型返回的 map 可能被包装/复制），isNotEmpty 直接表达意图：
          // 原生路径每个 call 都要有对应 tool 消息。
          if (!isContinue && nativeCalls.isNotEmpty) {
            // 原生：tool 消息必须用模型给的 id 配对（不能自己编 id）
            // 8-04 17:0x（用户：📄 里工具轮要简化成"成功/失败+一句话"）：
            // content 统一带【工具 名】+ ✅成功/❌失败 标记 —— 模型看得更清楚，
            // 📄 展示层也能解析出工具名和结果好坏
            toolMessages.add(
              AIChatMessage(
                role: 'tool',
                // 8-06 00:51 用户：调用工具=需要审批；成功调用=审批通过。
                // 工具消息在系统分区，天然不是用户说的话——不用额外解释
                // 8-11 18:0x（用户 17:57）：结果行 = 参数（名=值）+✅/❌+
                // 一句话+怎么办；超长 → 摘要+提示查缓存（外置大脑）
                content: _toolResultLine(toolNo, name, args, toolResult),
                toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
              ),
            );
          } else if (isContinue) {
            // continue（文本块格式）：不收集结果
            // 8-10 20:5x（用户 400 日志：call_2_add_record 无响应消息）：
            // **原生路径必须配对**——assistant(tool_calls) 里的每个 call
            // 都要有 tool 响应，continue_speaking/resolve_pending 被男主
            // 原生调用时（butlerTools 里有定义）走这里不 add → DeepSeek
            // 400 "did not have response messages"。补 tool 消息配对。
            if (nativeCalls.isNotEmpty) {
              toolMessages.add(AIChatMessage(
                role: 'tool',
                content: '【工具 $name】✅已执行（继续/标记回复，无需回传结果）',
                toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
              ));
            }
          } else {
            // 文本块：结果收集，最后合并注入 user 消息
            textToolResults.add(_toolResultLine(toolNo, name, args, toolResult));
          }
          // 8-10 21:5x（用户：manage_task 失败被遗忘）：工具失败（用户拒绝
          // 不算——那是正常交互）→ 标记本轮有失败 → done 也唤醒男主处理
          if (!toolResult.ok && !toolResult.text.startsWith('用户拒绝')) {
            _lastRoundToolFailed = true;
            totalFailCount++;
          }
          // 8-12 20:3x（用户：同一工具连续失败 5 次防死循环，成功清零；
          // 不同工具累计失败 8 次由下方 loopExceeded 条件拦——防到处翻找）
          if (!toolResult.ok && !toolResult.text.startsWith('用户拒绝')) {
            consecutiveToolCounts[name] =
                (consecutiveToolCounts[name] ?? 0) + 1;
          } else {
            consecutiveToolCounts[name] = 0;
          }
          final n = consecutiveToolCounts[name] ?? 0;
          // 8-06 21:36：continue 本轮累计 ≥3 次也停（交错调用防不住"连续"计数）
          if (name == 'continue_speaking') continueCount++;
          // 8-07 22:5x 用户：男主反复查工具卡死——只读查询类工具
          // 本轮累计 ≥3 强制停（不管交错：query_logs→list_tools→query_logs 也拦）
          const queryTools = kQueryToolNames;
          var queryStop = false;
          if (queryTools.contains(name)) {
            queryToolCount++;
            if (queryToolCount >= 10) {
              queryStop = true;
              DebugLogger.log(
                'AI路由',
                '⚠️ 本轮查询类工具累计 $queryToolCount 次（$name），强制停止（防反复查）',
              );
            } else if (queryToolCount >= 6) {
              // 8-08 02:1x 用户：干太快被卡 → 只软提示不强制停
              // 8-12 20:2x（用户：正常干活别卡）→ 软提示 3→6，强制 6→10
              DebugLogger.log(
                'AI路由',
                '💡 查询类工具已 $queryToolCount 次（$name），软提示（不强制停）',
              );
            }
          }
          if (n >= 5 ||
              totalFailCount >= 8 ||
              (name == 'continue_speaking' && continueCount >= 3) ||
              queryStop) {
            loopExceeded = true;
            lastFailName = name;
            lastFailN = n;
            lastQueryStop = queryStop;
            DebugLogger.log(
              'AI路由',
              '⚠️ 工具 $name 连续失败 $n 次 / 本轮累计失败 $totalFailCount 次'
              '（continue $continueCount，查询类 $queryToolCount），强制停止',
            );
          }
        }
        // 8-08 15:2x（GPT 10 问 5 定案：autoAdvance 默认开，严格判定）：
        // 每轮工具执行完，管家检查当前步完成条件（tool_result：有成功工具；
        // ai_output/user_confirm：有结构化 result），明确满足才自动推进。
        // 推进提示注入下一轮，男主不用手动 next（产出/确认类仍要手动带 result）
        if (!loopExceeded) {
          final advanceMsg = await FlowStore.autoAdvance(personaId);
          if (advanceMsg != null) {
            DebugLogger.log('管家流程', '▶ autoAdvance：$advanceMsg');
            if (advanceMsg == '__ALL_DONE__') {
              toolMessages.add(AIChatMessage(
                role: 'user',
                content: '【系统事件】所有步骤都已完成 ✅。'
                    '直接回复她汇总结果收尾。',
              ));
            } else {
              toolMessages.add(AIChatMessage(
                role: 'user',
                content: '【系统事件】$advanceMsg。继续执行新步骤，别回头重复。',
              ));
            }
          }
        }
        // 8-07 22:5x：不再这里提前 break——loopExceeded 时也要先注入
        // stop 事件（下方【系统事件】）让男主知道为什么停，再生成一轮
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
        // 8-08 02:1x 用户：查询类 ≥3 只软提示——男主还在找东西时别硬卡，
        // 提醒他直接说缺什么（≥6 才走 loopExceeded 强制停）
        // 8-08 21:5x（GPT10问第7条）：软提示走 state_hint 专区（状态块
        // 【状态提示】），不再混 role:'user' 事件消息
        if (!loopExceeded && queryToolCount >= 6 && queryToolCount < 10) {
          toolRoundHints.add('本轮已查了 $queryToolCount 次资料。'
              '如果还在找什么，直接告诉她你需要什么（她可以补），'
              '别一直反复查；查到就继续干活，不用停下来说话。');
        }
        // 8-07 22:5x 用户：男主反复查工具卡死——触发防循环后必须明确告知
        // 男主为什么停，否则他不知道为什么停、下轮又调
        // 8-12 20:3x（用户：提示语要像系统提示，简短命令式；不矛盾——
        // 流程保留、检查点⑤会自动唤醒继续，不是"等她下一句"）
        if (loopExceeded || toolLoop >= maxToolRounds) {
          final failReason = (lastFailN >= 5)
              ? '工具「$lastFailName」连续失败 $lastFailN 次'
              : (totalFailCount >= 8)
                  ? '本轮工具失败累计 $totalFailCount 次'
                  : (lastQueryStop)
                      ? '本轮查询类工具累计 $queryToolCount 次'
                      : '工具轮数已达上限';
          toolMessages.add(
            AIChatMessage(
              role: 'user',
              content:
                  '【系统】$failReason，本轮暂停工具调用。'
                  '先明确需求再查（查参数用 list_tools {name:工具名}），'
                  '别到处翻找；不要硬编答案。流程保留，继续或结束由你判断。',
            ),
          );
          // 注入后这轮生成完就停（不继续 while）
          loopExceeded = true;
        }
        // 8-03 18:27：工具轮生成也是男主打字阶段 → 显示"正在输出"
        ChatPresence.instance.beginTyping();
        result = await _aiSvc.generateReply(
          '',
          personaId,
          personaName: personaName,
          personaPrompt: _currentPersonaPrompt(),
          userProfile: _currentUserSetting(),
          toolRound: true,
          // 8-06 21:12 用户 bug：第一轮男主已回过话 → 工具轮别再带旧话（防回复两句）
          userAlreadyReplied: result.text.trim().isNotEmpty,
          toolMessages: toolMessages,
          // 8-09 14:5x：Debug Lab 记录本轮实际注入的结果块（t4 兜底，
          // 多轮工具时 secondMessages 只留最后一轮）
          stateHints: toolRoundHints,
          sessionId: _chatSessionId,
          storagePersonaId: chatPid,
        );
        // 8-09 14:5x：Debug Lab 记录本轮实际注入二次请求的结果块快照
        // （含原生 tool 消息/文本块结果/系统事件），t4 检查对照它兜底
        TraceSession.instance.recordInjectedToolResults(
          toolMessages.map((m) => m.content).toList(),
        );
        if (result.text.trim().isNotEmpty) {
          // 8-08 01:2x 用户（管家编排）：工具轮男主文本——
          // 8-08 16:2x 用户反馈："说了很多话还在回复模型，好奇怪"：
          // 中间文本攒起 → 用户只看到思考气泡，以为男主卡住。
          // 改成：男主说了话就立即显示（含工具轮中间文本）——
          // 正常情况下 system_template 要求男主"请求工具时不输出文本"，
          // 所以工具轮中间文本很少；万一模型不听话说了话，显示出来
          // 也比攒起来让用户以为卡住强。工具结果仍由管家批量回传。
          // 8-09 23:5x（用户：大流程中间思考多次、只结尾大回复）：
          // 思考链不再零碎挂中间气泡——还在调工具（toolCalls 非空）→
          // 思考攒 buffer；这轮是最终回复（无 toolCalls）→ buffer+本轮
          // 合并挂第一条气泡，一次展开全看到。
          // 8-10 00:0x（用户修正：哪个对话先出来思考放谁那里，全都该有
          // 思考，别时有时无）：说话的气泡一律挂思考——_takeFlowThinking
          // 在 buffer 空时 = 本轮自己的思考；buffer 非空（之前纯工具轮
          // 男主没说话攒的）→ 合并给这个气泡（不丢）。
          replyTexts.add(result.text.trim());
          final roundText = await _displayableText(result.text);
          if (roundText.isNotEmpty) {
            dbRows.addAll(await _appendMaleReply(
              result.text,
              thinkingChain: _takeFlowThinking(result.reasoningContent),
            ));
          } else {
            ChatPresence.instance.endTyping();
          }
        } else {
          // 工具轮没说话（可能又调工具）→ 工具阶段不显示；
          // 8-09 23:5x：没说话但思考了 → 攒 buffer（最终回复合并显示）
          _bufferFlowThinking(result.reasoningContent);
          ChatPresence.instance.endTyping();
        }
        // 8-08 01:2x 用户（管家编排）：审批拒绝【不打断流程】——拒绝结果
        // 已作为普通工具结果回传男主（"用户拒绝：X"），流程走完统一说；
        // 只保留连续拒绝计数（≥2 下一轮注入提示，男主别再试同一方向）
        // 8-08 21:5x（GPT10问第7条）：软提示走 state_hint 专区
        if (rejectedTools.isNotEmpty) {
          rejectedCount++;
          if (rejectedCount >= 2) {
            toolRoundHints.add('她已连续拒绝你 ${rejectedCount} 次'
                '（${rejectedTools.join('；')}），别再尝试这个方向——'
                '走完当前流程就直接回复她。');
            DebugLogger.log('AI路由', '⛔ 连续拒绝 ${rejectedCount} 次，注入 state_hint 提示');
          }
          rejectedTools.clear();
        }
      }

      // 8-09 23:5x（用户：大流程思考合并）兜底：循环退出后 buffer 还有
      // 残留 = 男主最后一轮没说话但思考了（text 空 + 无 toolCalls 时
      // 2280 else 分支只攒不取）→ 挂思考气泡（正文空 → "（他正在思考…）"
      // 占位 + 思考折叠区），思考不丢。
      if (_flowThinkingBuffer.isNotEmpty) {
        dbRows.addAll(await _appendMaleReply(
          '',
          thinkingChain: _takeFlowThinking(null),
        ));
      }

      // 剥离 #keywords（仅管家可见）→ 显示/落库用干净文本
      var displayText = ButlerPipelineResult.extractKeywordsFromReply(
        replyTexts.join('\n'),
      );
      // 8-07 19:15：剥 <msg>/<act>/<reply>/<sys> 标签 → 落库干净文本
      //（气泡显示用 spans 渲染，重载不显示标签壳；<sys> 是回管家静默块）
      // 8-07 23:3x JSON 化：JSON 块同样剥壳（取 msg/act 值重建纯文本）
      final parsedForDb = parseStructuredOutput(displayText);
      if (parsedForDb.hasFormat) {
        final bubbleTexts =
            parsedForDb.bubbles.map((b) => b.text).where((t) => t.isNotEmpty);
        displayText = bubbleTexts.join('\n').trim();
      } else {
        displayText = displayText
            .replaceAll(
              RegExp(r'</?msg>|</?act>|</?reply>|</?sys>',
                  caseSensitive: false),
              '',
            )
            .trim();
      }
      // 8-06 21:36 用户：男主回复带编号 → 管家按标注消除待回复
      // （"回待#1、待#2"消除对应；"不回待#3"也消除=放下；没标注兜底消最老一条）
      // 8-09 15:2x（用户日志：男主测工具时每轮都回#1 → 待回复永不消）：
      // 原用 result.text（最后一轮）——男主最后一轮纯调工具无文本时 resolve
      // 不执行，所有"回#N"标注作废 → 改用 replyTexts.join（全部轮次文本）
      final allRoundText = replyTexts.join('\n').trim();
      if (allRoundText.isNotEmpty) {
        final removed = await PendingQueueStore.resolve(personaId, allRoundText);
        if (removed.isNotEmpty) {
          DebugLogger.log('指令模块', '📥 待回复已消除 待#${removed.join('、')}（男主回复带编号）');
        }
      }
      // 8-09 18:2x（对话流程 v2）：男主回复 → 消对话流程条目
      //（标注 回#N、#M 精确消多条=合并消；无标注 FIFO 消最老一条；
      //  全部消完 → 流程 done）。与 PendingQueue 并存（队列为空时
      //  对话流程是唯一消条目通道）。
      if (allRoundText.isNotEmpty) {
        // 8-12 01:2x（用户历史：男主带 end_T0 + end_M1、end_M2 + save_summary
        // 成功，仍被反复唤醒补标）——根因：unawaited 竞态！feedReply 第一行
        // await warm 必然挂起，男主没输出 #指令时 commands 循环无 await，
        // 结束检查的 pendingNos 读到的是 feedReply 跑完前的旧状态（消息未标完）
        // → 打回补标 → 男主补标 → 又打回 → 死循环。必须等 feedReply 完成。
        await ChatFlowStore.feedReply(personaId, allRoundText);
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
      // 8-08 18:1x（GPT 意见：结束检查轮 + 明确退出状态）：
      // 男主输出 need_continue:false / next_action:null → 冻结自动唤醒
      //（这轮就是"结束检查轮"，男主明确说"没事情做了"）
      final exitSignal = parseExitSignal(replyTexts.join('\n'));
      // 8-10 00:5x（用户：男主消掉大流程自带结尾命令）——男主选
      // 续命（need_continue:true）或与后续大流程合二为一
      // （next_action:merge）→ 即使流程 done 也放行唤醒继续
      final nextAction = parseNextAction(replyTexts.join('\n'));
      if (exitSignal == false || nextAction == 'merge') {
        _maleChoseContinue = true;
        DebugLogger.log(
          '管家流程',
          nextAction == 'merge'
              ? '🔀 男主选择与后续大流程合二为一（next_action:merge）→ 唤醒继续'
              : '🔁 男主选择续命继续（need_continue:true）→ 唤醒继续',
        );
      }
      if (exitSignal == true) {
        _continueFrozen = true;
        // 8-12 05:1x（用户：工具轮男主没说结束也没唤醒男主——根因是
        // need_continue:false 把流程偷偷结束了）：结束流程**只认 end_TN**
        //（parseFlowEndSignal）；need_continue:false / next_action:null
        // 只冻结续话（不再自动唤醒），流程保持 running（✅ 全部处理完），
        // 等男主下次被唤醒时工作区提醒他写 end_TN + 摘要。没写 end_TN
        // = 没说结束 = 不归档（摘要都没写就归档 = 上下文丢失）。
        final flowEnd = parseFlowEndSignal(replyTexts.join('\n'));
        DebugLogger.log(
          '管家流程',
          flowEnd == true
              ? '🔚 男主写了结束标记（end_TN），结束对话流程'
              : '🔚 男主只说本轮无需继续（need_continue:false），'
                  '没写 end_TN → 流程不结束（保持 ✅ 全部处理完，'
                  '下次唤醒时提醒他写 end_TN + 摘要归档）',
        );
        if (flowEnd == true) {
          // 8-12 20:2x（用户：结束不用调 save_summary 工具——JSON 信封带
          // summary 字段即可，管家识别存档；适配不同 AI 的纯文本 JSON 输出）
          final summaryText = parsedForDb.summaryText.trim();
          if (summaryText.isNotEmpty) {
            await ContextManager.instance
                .appendSummary(personaId, '（大流程摘要）$summaryText');
            DebugLogger.log('上下文管理',
                '✅ 信封 summary 已存档（${summaryText.length} 字）');
          }
          // 8-09 18:4x（用户设计定稿）：退出标记 = 男主声明"回完了+干完了"
          // → 对话流程结束（回复只消条目，退出标记才结束流程）
          // 8-09 21:0x（用户：一个大流程结束男主至少要跟她说一句）：
          // 结束前校验——男主从没回过话（只调工具）→ 拒绝结束，
          // 引导先说话；说过话 → 正常 finish。
          final finishBlock = ChatFlowStore.finishCheck(personaId);
          if (finishBlock != null) {
            _pendingInterruptEvent = finishBlock;
            DebugLogger.log('管家流程', '🔚 男主想结束但没说过话 → 打回引导先说话');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('男主还没跟用户说话，已提醒他先回复再结束'),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          } else {
            // 8-12 04:1x（用户拍板）：只要男主标了 end_TN + save_summary
            // 就结束——不管中间有没有标完 end_MN（他写了摘要 = 他检查过了，
            // 只是忘记打结束标签）。不再打回补标（那正是反复唤醒死循环的
            // 根因：打回 → 男主补标 → 又打回）。有排队新流程（她插话）→
            // finish() 自动提升为当前，检查点⑤唤醒处理下一个（T2）；
            // 没有 → 安静等用户。
            await ChatFlowStore.finish(personaId);
            // 8-12 05:2x（用户：排队 T1 要等 25 秒才轮到 = 等好久）：
            // finish 提升排队流程为 running 后，解除冻结 → 检查轮立即
            // 唤醒处理下一个（不等用户说话、不等 25 秒）。
            if (ChatFlowStore.statusOf(personaId) == 'running') {
              _continueFrozen = false;
              DebugLogger.log(
                '管家流程',
                '🔜 排队流程已提升为当前（running），解除冻结，检查轮立即唤醒处理',
              );
            }
          }
        }
      } else if (exitSignal == false) {
        _continueFrozen = false;
        DebugLogger.log(
          '管家流程',
          '🔔 男主明确判定需要继续（need_continue:true），解除冻结',
        );
      }
      // 退出标记从显示文本剥离（防纯文本路径漏给用户看；JSON 路径已自动丢弃）
      displayText = stripExitSignal(displayText);
      // 8-08 15:5x：男主最终文本 → roundSpoke（finally 判断"这轮说了话没"）
      if (displayText.trim().isNotEmpty) roundSpoke = true;
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
      // 8-07 19:15 多气泡：逐条链式落库（每条气泡一条记录，parent 指向上一条
      // → 重载后气泡顺序 + 混合样式（spans）都保持）；旧版合并一条的兼容
      //（无 dbRows 时退回合并落库）
      if (_chatSessionId != null && displayText.trim().isNotEmpty) {
        try {
          if (dbRows.isNotEmpty) {
            var parentId = _chatLeafId;
            for (final row in dbRows) {
              final aiNode = await ChatDatabaseService.instance
                  .appendAssistantMessage(
                    sessionId: _chatSessionId!,
                    parentMessageId: parentId,
                    text: row.text,
                    spans: row.spansJson,
                  );
              parentId = aiNode.id;
            }
            _chatLeafId = parentId;
          } else {
            final aiNode = await ChatDatabaseService.instance
                .appendAssistantMessage(
                  sessionId: _chatSessionId!,
                  parentMessageId: _chatLeafId,
                  text: displayText,
                );
            _chatLeafId = aiNode.id;
          }
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
      // 8-10 00:4x（用户确认：空回复 = 二次唤醒复核正常流程，男主复核
      // 确认结束 → 输出退出标记无正文，别乱改）→ 不加任何兜底/提示
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
      // 8-08 15:2x（设计九）：不直接弹窗——注入系统事件走一轮，男主
      // 跟用户解释（上限 1 次；再次失败弹窗兜底）
      if (!_providerErrorInjected && mounted) {
        _providerErrorInjected = true;
        _pendingProviderErrorEvent =
            '你刚才这轮对话/工具调用失败了（原因：${e.tried.join('、')} 都不可用）。'
            '你可以：① 重试一次；② 直接告诉用户"现在做不到，原因…"，别假装成功。';
      } else {
        _providerErrorInjected = false;
        await _showAllAiFailedDialog(e);
      }
    } on Object catch (e, s) {
      // 8-08 02:1x：RangeError(start/end) 弹"发送失败"——堆栈落日志定位真凶
      // 8-08 18:4x（用户日志：RangeError 84..88:113 / 0..54:108，真凶被截断）：
      // 必须用 catch 的 s（抛出位置栈），StackTrace.current 是 catch 位置没用
      DebugLogger.log('AI路由', '❌ 聊天请求失败: $e\n$s');
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
      // 8-08 17:3x：生成结束 → 刷新停止条显示条件（_generating 变化）
      if (mounted) setState(() {});
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
      // 8-08 13:0x 检查点⑤锚点（纯日志埋点，暂不实现唤醒）：
      // 本轮结束（无论成败）后，任务是否还 running——这是"男主回复用户后
      // 任务睡着"的判定依据。日志对照 A/B/C/D 判定卡 D 项。
      // 注意：FlowStore 的 key 是 personaId（含测试空间也是同一 key），
      // 不能用 chatPid（带 mock 后缀）判断。
      if (personaId.isNotEmpty) {
        try {
          FlowStore.warm(personaId);
          if (FlowStore.isRunning(personaId)) {
            final f = await FlowStore.get(personaId);
            final steps = (f?['steps'] as List?)?.length ?? 0;
            final rawCur = (f?['currentStep'] as num?)?.toInt() ?? 0;
            // 8-08 21:0x：越界保护（自愈后的 running 不应出现 cur>=len，
            // 再兜一层防日志显示 5/4）
            final cur = rawCur >= steps ? steps : rawCur + 1;
            DebugLogger.log(
              '管家流程',
              '⏰ 检查点⑤：本轮结束，任务仍 running'
              '（目标「${f?['goal'] ?? '?'}」第 $cur/$steps 步）'
              '→ 自动续跑（断点 D 已修复）',
            );
            // 8-08 14:0x（断点 D 修复）：任务 running → 自动续跑，
            // 男主自己把活干完，不用用户再发消息。无进展 3 轮自动停。
            // 有插话排队 → 不续跑，让插话先（用户着急，先回用户再干活）
            // 8-08 15:5x：插话触发轮（_interruptRoundActive）→ 不续跑，
            // 先确认男主回了用户（方法末尾检查，没回就注入"只回用户"轮）
            if (_pendingInterruptEvent == null && !_interruptRoundActive) {
              unawaited(_maybeAutoResume(personaId));
            } else {
              DebugLogger.log(
                '管家流程',
                '💬 插话排队或插话轮进行中，跳过自动续跑（先回用户）',
              );
            }
          } else {
            DebugLogger.log('管家流程', '⏰ 检查点⑤：本轮结束，任务非 running（无需唤醒）');
            // 8-08 15:5x（用户需求：男主回复后自动唤醒判断要不要继续说）：
            // 非流程场景——男主这轮说了话 → 自动再唤醒一次让他判断
            // 还要不要继续说（上限 3 次；用户说话重置；有用户消息排队先回用户）。
            // 有排队事件（停止/插话/错误）→ 不续话，先处理排队事件
            // 8-08 17:3x：用户按过停止（_stopRequested）→ 不续话
            if (!_interruptRoundActive &&
                _pendingStopEvent == null &&
                _pendingInterruptEvent == null &&
                _pendingProviderErrorEvent == null &&
                !_stopRequested) {
              unawaited(
                _maybeAutoContinue(personaId, spoke: roundSpoke),
              );
            } else if (_stopRequested) {
              DebugLogger.log(
                '管家流程',
                '⏸ 用户按过停止，检查点⑤不再续话/唤醒',
              );
            }
          }
        } catch (e) {
          DebugLogger.log('管家流程', '⏰ 检查点⑤检查失败: $e');
        }
      }
    }
    // 8-06 23:55：停止事件排队——这轮结束（无论成败）自动触发，不丢
    final pendingStop = _pendingStopEvent;
    if (pendingStop != null) {
      _pendingStopEvent = null;
      if (mounted) {
        unawaited(
          _sendMsg(
            '',
            systemEvent: pendingStop,
            bubbleText: '⏸ 你按了停止，男主正在处理…',
          ),
        );
      }
      return;
    }
    // 8-08 14:1x：插话事件排队——这轮结束自动触发（先于续跑，见上）
    final pendingInterrupt = _pendingInterruptEvent;
    if (pendingInterrupt != null) {
      _pendingInterruptEvent = null;
      // 8-10 01:2x（用户：男主把所有的都回完了才说"你插话了"，显示在
      // 我的气泡那里，又唤醒男主一轮）——插话排队的消息可能已被男主在
      // 流程里回了（feedUser 追加步骤后男主清单里一起消）→ 对话流程
      // 没有待回步骤 → 插话消息已回完 → 不显示气泡、不唤醒男主。
      final cf = ChatFlowStore.get(personaId);
      final hasPendingStep = cf != null &&
          ((cf['steps'] as List?) ?? const []).any(
              (s) => s['status']?.toString() != 'done');
      if (!hasPendingStep) {
        DebugLogger.log(
          '管家流程',
          '🔕 插话消息男主已回完（流程无待回步骤），不触发插话轮',
        );
        if (mounted) setState(() {}); // 插话按钮恢复"💬 插话"
      } else {
        if (mounted) {
          setState(() {}); // 插话按钮恢复"💬 插话"
          // 8-08 15:5x：标记插话触发轮——这轮结束检查男主是否回了用户
          // （没回 → 注入"只回用户"轮；回了 → 恢复正常续跑）
          _interruptRoundActive = true;
          _interruptFollowUpDone = false;
          unawaited(
            _sendMsg(
              '',
              systemEvent: pendingInterrupt,
              // 8-10 01:2x（用户：插话气泡显示在我气泡那里，不要）：
              // 插话轮不显示用户侧"💬 男主先回你…"气泡——SnackBar
              // 插话时已提示过，男主直接说话即可
              silentBubble: true,
            ),
          );
        }
      }
    }
    // 8-08 15:2x（设计九）：AI 全失败事件排队——这轮结束注入，男主解释
    final pendingProviderError = _pendingProviderErrorEvent;
    if (pendingProviderError != null) {
      _pendingProviderErrorEvent = null;
      if (mounted) {
        unawaited(
          _sendMsg(
            '',
            systemEvent: pendingProviderError,
            bubbleText: '⚠️ AI 服务暂时不可用，男主正在处理…',
          ),
        );
      }
    }
    // 8-08 15:5x（用户反馈核心修复）：插话轮结束检查——男主这轮只调了工具
    // 没回用户 → 再注入"只回用户"轮（禁工具，上限 1 次）；回了 → 正常结束
    if (_interruptRoundActive) {
      if (!roundSpoke && !_interruptFollowUpDone) {
        _interruptFollowUpDone = true;
        DebugLogger.log(
          '管家流程',
          '💬 插话轮男主只调了工具没回话 → 注入"只回用户"轮（兜底）',
        );
        if (mounted) {
          unawaited(
            _sendMsg(
              '',
              systemEvent: '用户还在等你回复（你刚才只顾着调工具，没回她的话）。'
                  '**这一轮只回复她，禁止调用任何工具**（管家会拦截）。她刚才说：$_interruptUserText。'
                  '回完之后判断流程怎么办：她只是闲聊 → 继续原流程；'
                  '她改需求 → 按她说的调整；她说不要 → 结束流程；'
                  '拿不准 → 默认继续，绝不乱取消。',
              bubbleText: '💬 男主先回你…',
            ),
          );
        }
        return;
      }
      // 男主已回（或兜底轮已注入过、男主仍没回 → 放弃干预，交给续跑机制）
      _interruptRoundActive = false;
      // 8-08 19:0x（GPT + 用户定稿）：插话轮结束（男主已回）→ 流程若被
      // 她插话暂挂（paused_by_user），立即唤醒检查轮让他判断 resume/update/
      // cancel——不挂到用户下次说话（检查轮提示已带判断规则）
      if (mounted) {
        unawaited(_maybeAutoContinue(personaId, spoke: roundSpoke));
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
    // 8-08 02:1x：工具工作缓存预热（男主干活中间数据，自管免审批）
    ToolCacheStore.warm(personaId);
    // 8-08 15:2x：工具手册 + 测试任务预热
    ToolManualStore.warm(personaId);
    ToolTestStore.warm(personaId);
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
    // 8-09 16:0x：注销 FlowStore 通知（防泄漏/跨页误刷新）
    if (identical(FlowStore.onChanged, _flowOnChanged)) {
      FlowStore.onChanged = null;
    }
    _anim.removeListener(_onAnimTick);
    _anim.dispose();
    _notifyWakeTimer?.cancel(); // 8-06 notify_user 超时唤醒
    _alarmTimer?.cancel(); // 8-10 定时任务检查器
    _flowBarTimer?.cancel(); // 8-08 16:2x 流程条轮询
    _inputCtrl.dispose(); // 8-08 15:1x：外部输入框 controller
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
                          // 拖桌宠时锁定列表滚动（8-14 14:5x 用户反馈）
                          scrollEnabled: !_petDragging,
                        ),
                        // 桌宠层：覆盖整个消息区，小人自由活动（撞墙自己停）
                        // 8-14 06:5x（用户：桌宠就是放聊天页的）
                        // 8-14 14:4x（用户：不要限高锁位置，自由跑，
                        // 只要不跑到输入框下面——消息区底部=输入框顶，天然满足）
                        Positioned.fill(
                          child: PetChatOverlay(
                            onDragStateChanged: (dragging) {
                              if (dragging != _petDragging) {
                                setState(() => _petDragging = dragging);
                              }
                            },
                          ),
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
                  // 8-08 17:3x（用户反馈："他说那么多话我要让他停止"）：
                  // 停止条显示条件扩展——男主生成中/自动续话中（无流程）也显示，
                  // 否则男主连续说话时用户没地方按停止，只能等 3 次上限
                  // 8-08 21:3x（用户："流程结束了停止窗还在"）：
                  // 流程 done/cancelled 后隐藏——否则男主汇报完流程被
                  // "结束检查轮"唤醒续话时 _autoContinueCount>0，停止条
                  // 一直挂着"男主正在执行流程：已完成"
                  // 8-09 16:0x（用户：流程卡片动态显示，绑定 FlowStore 同一数据源）：
                  // isActive（running/stopped/paused_by_user）才显示——有流程就弹、
                  // 步骤推进/状态变化 via onChanged 实时刷新、结束（done/cancelled）自动消失。
                  // 无流程时不再误挂（旧逻辑 _autoContinueCount>0 会显示"流程执行中"误导）。
                  if (FlowStore.isActive(
                        _state.personaId ??
                            (_state.leadId == null
                                ? ''
                                : '${_state.leadId}_default'),
                      ))
                    _buildFlowStopBar(),
                  // 桌宠层已移入消息区 Stack（Positioned.fill 自由活动）——
                  // 8-14 14:4x：不再用固定高度 SizedBox 限制小人
                  ChatInputBar(
                    externalCtrl: _inputCtrl,
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

        // ===== 📋 每轮记录按钮（8-11 22:2x 用户：聊天页直接看，
        // 不要藏在管家/测试模式里；点开默认就是每轮视图，自动刷新）=====
        Positioned(
          right: 4,
          top: MediaQuery.of(context).padding.top + 4,
          child: GestureDetector(
            onTap: () => showDebugLogSheet(context, initialView: DbgView.rounds),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.black26,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.assignment_outlined,
                size: 15,
                color: Colors.white70,
              ),
            ),
          ),
        ),

        // ===== 调试日志按钮（右上角，testMode 时挪到最左）=====
        if (AIProviderManager.testModeEnabled)
          Positioned(
            right: 140,
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

  // 8-09 23:5x（用户：大流程中间思考多次、只结尾大回复 → 思考别零碎显示，
  // 合并到最近一次大回复的思考链里一次展开全看到）：大流程工具轮思考
  // 攒起 buffer，男主最终回复轮（无 toolCalls）合并挂气泡后清空。
  final List<String> _flowThinkingBuffer = [];

  // 8-10 00:5x（用户：男主消掉大流程自带结尾命令）：男主输出续命
  // （need_continue:true）或合并（next_action:merge）→ 即使对话流程
  // done 也放行唤醒（继续干活/处理后续大流程）；用完即清 + 用户消息重置。
  bool _maleChoseContinue = false;

  /// 工具轮思考攒 buffer（剥工具行；空/无效忽略）。
  void _bufferFlowThinking(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    final clean = stripToolTextLines(raw).trim();
    if (clean.isEmpty) return;
    _flowThinkingBuffer.add(clean);
  }

  /// 取走合并思考（buffer + 本轮）并清空；无内容返回 null。
  String? _takeFlowThinking(String? currentRaw) {
    final parts = <String>[..._flowThinkingBuffer];
    _flowThinkingBuffer.clear();
    if (currentRaw != null && currentRaw.trim().isNotEmpty) {
      final clean = stripToolTextLines(currentRaw).trim();
      if (clean.isNotEmpty) parts.add(clean);
    }
    if (parts.isEmpty) return null;
    return parts.join('\n\n');
  }

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

  // 8-08 14:0x（断点 D 修复）：自动续跑（APP 内第一版唤醒）。
  // 男主回完用户消息任务还 running → 自动继续，不用用户再发消息。
  // 防死循环：currentStep 变了重置计数；同一步连续 3 轮无进展 → 停。
  int _autoResumeRounds = 0;
  String? _autoResumePid;
  int _lastAutoResumeStep = -1;

  /// 8-08 14:4x（男主测试反馈）：男主请求了审批类工具（弹窗等用户点）
  /// → 是"等用户"不是"卡死"，自动续跑无进展判定要排除它
  bool _lastRoundRequestedApproval = false;
  // 8-06 23:55：停止事件排队——男主生成中按停止，等这轮结束自动触发
  String? _pendingStopEvent;
  // 8-08 17:3x（用户反馈："我要让他停止他又不会自动判断"）：
  // 用户按过停止 → 本轮结束后的检查点⑤不再续话/唤醒（男主回应"我安静了"
  // 之后不能被续话机制再拉起来）。用户下次发消息/插话时清除。
  bool _stopRequested = false;
  // 8-08 14:1x（用户需求）：插话事件排队——男主跑工具轮时用户点「💬 插话」，
  // 等这轮结束把收集的消息推给男主（流程保持 running，回复完继续干活）
  String? _pendingInterruptEvent;

  // 8-08 15:2x（设计九，GPT：Provider 挂掉时男主会说话解释，不直接弹窗）：
  // AI 全失败 → 排队注入系统事件让男主解释（上限 1 次，再次失败弹窗兜底）
  String? _pendingProviderErrorEvent;

  // 8-10 21:5x（用户：manage_task 失败后男主消流程 → done 不唤醒 → 失败被遗忘）：
  // 本轮有工具失败（用户拒绝不算）→ 即使流程 done 也唤醒男主处理失败。
  // 检查轮注入失败提醒，处理完重置。
  bool _lastRoundToolFailed = false;
  bool _providerErrorInjected = false;

  // 8-08 15:5x（用户反馈：插话后男主光调工具没回用户）：
  // 插话轮结束检查——男主这轮没说话（只调了工具）→ 再注入"只回用户"轮
  bool _interruptRoundActive = false; // 当前这轮是插话触发轮
  bool _interruptFollowUpDone = false; // 兜底轮已注入（上限 1 次）
  String _interruptUserText = ''; // 插话内容（兜底轮带给她看）

  // 8-08 15:5x（用户需求：男主回复后自动唤醒判断要不要继续说，最多 3 次；
  // 用户说话重置；流程场景走 _maybeAutoResume 不受此限）
  int _autoContinueCount = 0; // 用户消息之间男主主动续话次数
  String? _autoContinuePid;
  // 8-08 18:1x（GPT 意见：结束检查轮 + 明确退出状态）：
  // 男主输出 need_continue:false / next_action:null → 冻结自动唤醒，
  // 直到用户说话/插话/停止才解除。"唤醒"=一次检查机会，不是必须继续说话。
  bool _continueFrozen = false;

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
      note('📋 ⑨ 让男主用 update_setting 只改【喜好】段——弹窗点「就用这版」定案（指令明确，男主直接出最终方案）');
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
      note('📋 ⑩ 让男主用 update_setting 新增【测试段】——弹窗点「就用这版」定案（指令明确，男主直接出最终方案）');
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
      note('📋 ⑪ 让男主用 update_setting 删掉【测试段】——弹窗点「就用这版」定案');
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

      // ⑫ 多轮会话弹窗 + 版本管理（用户手动：
      // 男主问卡片题（一次一题，单选/多选，答完自动下一题）→ 全部答完
      // 自动发 → 出 v1【新方案】（此时没有「就用这版」按钮=还在了解需求）
      // → 反馈框打字"第一版喜好不好，喜好改具体点" → 男主查段落 →
      // 出 v2【最终方案】（出现定案按钮）→ 点版本卡片看 diff → 就用这版）
      await sw('builtin-mock', '⑫/⑫ 设定·多轮会话+版本管理');
      _acceptingStep = '⑫/12 设定·多轮商量+版本管理';
      note(
        '📋 ⑫ 改【喜好】——弹窗自动弹出，男主自动问两道卡片题'
        '（一次只显示一题，答完自动下一题）：\n'
        '1️⃣ 第1题（单选）身份：点 A 勾选（再点取消）→ 点「✓ 答完这题，'
        '下一题」；'
        '第2题（多选）喜好：点 A、B 勾选（可再点取消）→ 点「✓ 答完了，'
        '发给他」→ 自动发给男主 → 男主出 v1【新方案】\n'
        '2️⃣ 注意：底部【没有】「就用这版」按钮——男主还在了解需求，'
        '第一版不能定案（验证点1）；设定原文也不显示（验证点2）\n'
        '3️⃣ 在反馈框打字："第一版喜好不好，喜好写具体点" → 「💬 发给他」'
        ' → 男主查段落 → 出 v2【最终方案】\n'
        '4️⃣ 这时底部出现「✅ 就用这版（留档）」和「♻️ 覆盖我原来写的」（男主确认了解完了，验证点3）；'
        '可点版本编号 v2 卡片看「📝 这版改了」\n'
        '5️⃣ 点「✅ 就用这版（留档）」定案（预期含 身份+喜好C）',
      );
      await say(
        '用 update_setting 把【喜好】改成"测试喜好C"。'
        '弹窗里我会先跟你商量（会给选项），你正常回应我就行。',
        waitLong: true,
      );
      final book12 = await SettingVersionStore.load(testPid);
      final i12 = book12.currentMale.contains('测试喜好C');
      record(
        '⑫ 多轮会话+版本结合后生效',
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

  /// 8-07 19:15：男主回复无标签打回计数（连续 3 次熔断放行，防死循环）
  int _formatFailCount = 0;

  /// 8-07 19:15：男主回复是否带任何标签（<reply>/<msg>/<act>）
  /// 8-07 23:3x：JSON 化——{"msg":..}/{"act":..}/{"reply":..}/{"sys":..} 也算带格式
  static bool _hasAnyTag(String text) =>
      parseStructuredOutput(text).hasFormat;

  /// 8-07 19:15（用户设计）：男主回复 → 解析 <msg>/<act> → 逐条 append
  /// - msg 块 → 对话气泡（spans 混排：话正常 + 动作斜体淡色）
  /// - act 块 → 独立动作气泡（text 加 '[act] ' 前缀，同 [tool] 机制，无头像斜体）
  /// - <reply> 标注在解析前剥掉（不显示；消除待回复走 PendingQueueStore.resolve）
  /// - 无标签裸文本 → 兜底成对话气泡（内容永不丢）
  /// 返回逐条记录（id/text/spansJson）供落库（链式 parent 还原顺序 + 样式）
  Future<List<_BubbleRow>> _appendMaleReply(
    String rawText, {
    String? thinkingChain,
    bool isFirst = false,
  }) async {
    final rows = <_BubbleRow>[];
    // 8-08 22:2x（用户：思考过程折叠区里显示"工具:弹窗通知内容-测试弹窗通知！"）：
    // reasoning 原文可能带文本化工具调用行（中文工具名 + 内容= 格式）——
    // 落库前剥掉，折叠区不再露工具行（剥行正则已支持中文名/内容=格式）
    String? cleanThinking;
    if (thinkingChain != null && thinkingChain.trim().isNotEmpty) {
      cleanThinking = stripToolTextLines(thinkingChain);
      if (cleanThinking.isEmpty) cleanThinking = null;
    }
    // 8-07 23:3x JSON 化：parseStructuredOutput 统一解析（JSON 块 + 旧标签
    // 双兼容）——reply 标注不显示、sys 静默不显示不落库，气泡只含 msg/act
    final parsed = parseStructuredOutput(rawText);
    // 8-08 22:5x（用户：JSON 块附近乱七八糟的文字，浪费 token 还看不见）：
    // 男主输出带结构化块但周围有杂散文字 → 内容照常显示（不重写），
    // 但注入下轮 taskState 提醒他按格式（用完即清，同 _formatHint 机制）
    if (parsed.hasFormat && stripStructuredBlocks(rawText).isNotEmpty) {
      const jsonMessyHint = '你刚才回复里，JSON 块/标签外面带了杂散文字'
          '（如"思考一下{...}完毕"的"思考一下"）——她看不到这些字，还浪费 token。'
          '以后只输出 JSON 对象（每个占一行）和工具调用，周围不要任何其他文字。';
      _formatHint =
          _formatHint == null ? jsonMessyHint : '$_formatHint\n$jsonMessyHint';
      DebugLogger.log('AI路由', '📐 男主 JSON 块带杂散文字，下轮提示按格式');
    }
    final parts = parsed.bubbles;
    if (parts.isEmpty) {
      // 8-09 23:5x（用户：调工具后男主回复被剥成"<"，思考链也看不见）：
      // 正文被剥空/丢弃但思考链非空 → 思考不跟着正文丢。
      // 8-10 01:1x（用户：流程里思考跟着最近的文本走，流程结束没文本
      // 才自己一行兜底）——不再单独挂思考气泡：攒进 buffer，下一个说话
      // 气泡合并（跟最近文本走）；循环退出后 buffer 残留由兜底挂
      //（"（他正在思考…）"占位 + 思考折叠区）。
      if (cleanThinking != null && cleanThinking.isNotEmpty) {
        _bufferFlowThinking(cleanThinking);
        DebugLogger.log(
          'AI路由',
          '🧠 男主文本被剥空但有思考 → 攒 buffer 等最近文本合并（不单独挂）',
        );
      }
      return rows;
    }
    String? firstMsgId;
    // 8-11 06:1x（用户：思考链完全没了——男主输出顺序 reply→act→msg 时，
    // 旧 i==0 把思考挂给了 act 动作气泡（不显示）→ msg 拿不到）：
    // 思考链改挂**第一条 msg 气泡**（act 动作气泡不挂，msg 才是说话气泡）
    var thinkingAttached = false;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final id =
          '${DateTime.now().microsecondsSinceEpoch}_ai${isFirst ? '0' : 'x'}_$i';
      if (part.kind == BubbleKind.act) {
        // 独立动作气泡：[act] 前缀（同 [tool] 机制）→ message_bubble 渲染斜体淡色
        _msgKey.currentState?.appendMessage(
          ChatMessage(id: id, text: '[act] ${part.text}', isMe: false),
        );
        rows.add(_BubbleRow(id, '[act] ${part.text}', null));
      } else {
        final msg = ChatMessage(
          id: id,
          text: part.text,
          isMe: false,
          // 纯文本段落不挂 spans（null = 旧行为）；有动作片段才挂
          spans: (part.spans.length > 1 ||
                  part.spans.first.kind == SpanKind.act)
              ? part.spans
              : null,
          // 思考链只挂第一条 msg 气泡（act 不挂）
          thinkingChain: !thinkingAttached ? cleanThinking : null,
        );
        thinkingAttached = true;
        _msgKey.currentState?.appendMessage(msg);
        rows.add(_BubbleRow(
          id,
          part.text,
          msg.spans == null
              ? null
              : jsonEncode(msg.spans!.map((s) => s.toJson()).toList()),
        ));
        firstMsgId ??= id;
      }
    }
    if (isFirst) _firstAiMsgId = firstMsgId;
    return rows;
  }

  /// 8-08 02:2x：查询类工具名（卡顿防护 + 结果自动进工具缓存共用）
  static const Set<String> kQueryToolNames = {
    'query_logs',
    'list_tools',
    'recall_memory',
    'query_diary',
    'query_setting_history',
    'query_record',
    'query_flow',
  };

  /// 8-07 19:15：query_tool_formats 实现——返回管家支持的调用格式模板。
  /// 文本块模板按锁过滤（textBlockEnabled 默认 false，per-persona 存储）
  static String _textBlockKey(String personaId) =>
      'text_block_enabled_$personaId';

  static Future<bool> _isTextBlockEnabled(String personaId) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_textBlockKey(personaId)) ?? false;
  }

  Future<String> _queryToolFormats(String personaId) async {
    final enabled = await _isTextBlockEnabled(personaId);
    final textBlockLine = enabled
        ? '4. 文本块（已批准）：⟨工具:工具名⟩{"参数":"值"}⟨/工具⟩\n'
            '   → name 填工具名，arguments 填参数 JSON'
        : '4. 文本块（未批准，默认锁定）：⟨工具:工具名⟩{"参数":"值"}⟨/工具⟩\n'
            '   → 想用先调 request_text_block 申请，她批准后才能用';
    return '管家支持这些工具调用格式（选一个照模板写，写完管家自动解析执行，'
        '结果会返回给你）：\n'
        '0. 一句话暗号（推荐，最不容易写错）：工具:工具名 参数名=值 参数名=值\n'
        '   → 例：工具:record_memory 内容=… 类别=日常 / 工具:list_tools\n'
        '1. OpenAI 系（你熟悉的话优先用）：\n'
        '   tool_calls:[{"function":{"name":"工具名","arguments":"{\\"参数\\":\\"值\\"}"}}]\n'
        '   → name 填工具名，arguments 填参数 JSON 字符串\n'
        '2. Claude 系：{"type":"tool_use","name":"工具名","input":{"参数":"值"}}\n'
        '   → name 填工具名，input 填参数\n'
        '3. Gemini 系：{"functionCall":{"name":"工具名","args":{"参数":"值"}}}\n'
        '   → name 填工具名，args 填参数\n'
        '$textBlockLine';
  }

  /// 8-07 19:15：request_text_block 实现——AI 主动申请文本块 → 用户审批
  Future<bool> _approveTextBlock(
    String personaId,
    String personaName,
    String reason,
  ) async {
    if (!mounted) return false;
    final approved = await showDialog<bool>(
      context: context,
      // 8-09 20:5x：同 _approveToolCall——防误触把"没点"当"拒绝"
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('📦 男主申请用文本块'),
        content: Text(
          '$personaName 想用文本块格式调用工具（更简单的兜底格式，'
          '默认锁定）。\n\n理由：${reason.isEmpty ? '（没写理由）' : reason}\n\n'
          '批准后他就能用 ⟨工具:工具名⟩{"参数":"值"}⟨/工具⟩ 调用工具。',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              '保持禁用',
              style: TextStyle(color: Color(0xFF8A7A80)),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('✅ 允许'),
          ),
        ],
      ),
    );
    if (approved == true) {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_textBlockKey(personaId), true);
      DebugLogger.log('工具权限', '📦 已批准文本块：$personaId');
      return true;
    }
    return false;
  }

  /// 男主回复 → 用户可见文本（剥离工具块 + #指令 + 还原代号）。
  /// 8-03 18:2x：渐进显示用——每轮文本单独显示，不等全部跑完
  /// 标签形态剥离（8-08 00:2x 借鉴参考：输出给用户前清所有 <…> 标签形态）。
  /// 只认"< 后跟字母/下划线/中文/竖线"的标签形态（模型自创 <tool_call>、
  /// <|im_start|>、半截 <invoke 都能清）；"<3"（数字开头）、"a<b" 不误伤。
  /// 显示层兜底——JSON 化后男主正常输出已无标签，这是防"模型自创标签"漏网
  /// 8-08 16:3x：正则/剥离实现移到 services/parse_utils.dart（自测页复用）

  Future<String> _displayableText(String raw) async {
    var t = ToolIntentParser.stripToolBlocks(raw);
    // 8-07 21:2x：兜底剥 anthropic invoke XML（防任何路径漏网显示）
    t = stripAnthropicInvokeBlocks(t);
    // 8-08 00:2x：标签形态兜底剥离（模型自创 <…> 全清，界面永远干净）
    t = stripTagShapes(t);
    t = ButlerCommandParser.instance.strip(t);
    // 8-08 21:3x（用户：男主气泡"工具:xxx关键词=yyy"）：DeepSeek 文本化
    // 工具调用泄漏 → 渐进显示路径也剥（落库后渲染走 multi_bubble_parser，
    // 那里同样调 stripToolTextLines）
    t = stripToolTextLines(t);
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
    // 8-07 22:25 借鉴 Clawra 模式：工具报错不输出堆栈/JSON/报错给用户——
    // 技术详情只进上下文+日志（男主看得到，能继续处理），
    // 用户侧气泡显示友好文案；男主拿到完整错误后用角色口吻委婉回应
    var text = r.text;
    if (!r.ok && text.startsWith('工具执行异常')) {
      text = '（详情已记录，他会换个方式处理）';
    }
    _appendToolBubble(
      '${r.ok ? '✅' : '❌'} $toolName ${r.ok ? '完成' : '失败'}：$text',
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
    // 8-08 14:4x：有审批请求 = 在等用户点弹窗（不是卡死）——
    // 自动续跑无进展判定读到这个标志会重置计数
    _lastRoundRequestedApproval = true;
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
    // 8-08 15:1x（用户："弹窗永远都是查工具，以为男主卡住"）：
    // 弹窗标题带流程步骤上下文（第几步/共几步），用户知道这是流程的一部分
    var stepCtx = '';
    try {
      final fpid = personaId ?? '';
      if (fpid.isNotEmpty) {
        final flow = await FlowStore.get(fpid);
        if (flow != null && flow['status'] == 'running') {
          final cur = (flow['currentStep'] as num?)?.toInt() ?? 0;
          final total = (flow['steps'] as List?)?.length ?? 0;
          if (total > 0) stepCtx = ' [流程第${cur + 1}/$total步]';
        }
      }
    } catch (_) {}
    FocusManager.instance.primaryFocus?.unfocus();
    // 8-10 21:5x（用户：点了确认但男主没收到，卡住没再唤醒）：
    // showDialog 万一挂起（context 失效/Navigator.pop 失败/弹窗被吞）→
    // await 永久挂起 → 工具轮卡死 → 检查轮不触发 → 男主再也不醒。
    // 兜底：2 分钟超时强制当拒绝（弹窗还开着就关掉），结果照常回传男主，
    // 绝不卡死。异常（context 失效）也当拒绝。
    bool? approved;
    try {
      approved = await showDialog<bool>(
        context: context,
        // 8-09 20:5x（用户实测：误点弹窗边缘 → 弹窗关闭 → 被当"拒绝"，
        // 男主说"我拒绝"）：授权弹窗必须明确点按钮，点外面关不掉
        // （barrierDismissible:false），防误触把"没点"当成"拒绝"。
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFFFDF7F9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('🔧$stepCtx 男主想$toolName'),
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
      ).timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          DebugLogger.log('指令模块', '⏰ 审批弹窗 2 分钟未确认，超时当拒绝（防卡死）');
          try {
            Navigator.of(context, rootNavigator: true).pop();
          } catch (_) {}
          return false;
        },
      );
    } catch (_) {
      DebugLogger.log('指令模块', '⚠️ 审批弹窗异常（context 失效？）→ 当拒绝，不卡死');
      approved = false;
    }
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
    // 8-10 21:5x：同 _approveToolCall——弹窗挂起会卡死工具轮/唤醒链，
    // 2 分钟超时当拒绝（防卡死），异常也当拒绝
    bool? approved;
    try {
      approved = await showDialog<bool>(
        context: context,
        // 8-09 20:5x：同 _approveToolCall——防误触把"没点"当"拒绝"
        barrierDismissible: false,
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
      ).timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          DebugLogger.log('指令模块', '⏰ 记录确认弹窗 2 分钟未确认，超时当拒绝（防卡死）');
          try {
            Navigator.of(context, rootNavigator: true).pop();
          } catch (_) {}
          return false;
        },
      );
    } catch (_) {
      DebugLogger.log('指令模块', '⚠️ 记录确认弹窗异常 → 当拒绝，不卡死');
      approved = false;
    }
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
      return const _ToolResult(
        false,
        '关系不完整（需要 谁→谁→什么），参数名用英文 subject/predicate/object，'
        '示例：{"subject":"她","predicate":"喜欢","object":"狗","quote":"她原话","category":"记忆"}',
      );
    }
    if (quote.isEmpty) {
      return const _ToolResult(
        false,
        '缺少原话（quote），参数名用 quote（她说的原话），'
        '示例：{"subject":"她","predicate":"喜欢","object":"狗","quote":"她原话"}',
      );
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

  /// 8-08 14:0x（断点 C 根治）：工具参数中文 key → 英文 key 归一化。
  /// 男主（DeepSeek）常传 {动作: next}、{内容: …}，工具只认英文 key，
  /// 导致 next 失败、任务卡死。按工具名做别名映射，模型写错也不卡。
  Map<String, dynamic> _normalizeToolArgs(
    String toolName,
    Map<String, dynamic> args,
  ) {
    if (args.isEmpty) return args;
    // 工具名 → {中文key: 英文key}。覆盖日志里见过的错误写法 + 常见中文。
    const aliases = <String, Map<String, String>>{
      'manage_flow': {
        '动作': 'action', '操作': 'action',
        '目标': 'goal', '目的': 'goal',
        '步骤': 'steps',
      },
      'record_memory': {
        '内容': 'content', '类别': 'category', '分类': 'category',
        '关键词': 'keywords', '标签': 'keywords',
      },
      'recall_memory': {
        '查询': 'query', '关键词': 'query', '内容': 'query',
        '类别': 'category', '分类': 'category',
      },
      'manage_pad': {
        '动作': 'action', '操作': 'action',
        '内容': 'content', '便签': 'content', '临时记忆': 'content',
      },
      'notify_user': {
        '内容': 'messages', '消息': 'messages', '文本': 'messages',
        '标题': 'title', '间隔': 'interval_seconds',
        '等待': 'wait_minutes', '时间': 'wait_minutes',
      },
      'resolve_pending': {
        '回复': 'replied_ids', '已回复': 'replied_ids',
        'ids': 'replied_ids', 'id': 'replied_ids',
      },
      'manage_frequent_tools': {
        '动作': 'action', '操作': 'action',
        '名字': 'name', '名称': 'name', '工具': 'name',
      },
      'manage_tool_cache': {
        '动作': 'action', '操作': 'action',
        '工具': 'tool', '结果': 'result',
      },
      'manage_memory_block': {
        '动作': 'action', '操作': 'action',
        '内容': 'content', '记忆': 'content',
      },
      'save_summary': {
        '内容': 'content', '摘要': 'content', '总结': 'content',
        '范围': 'range', '区间': 'range',
      },
      'manage_tool_manual': {
        '动作': 'action', '操作': 'action',
        '工具': 'tool', '名字': 'tool', '名称': 'tool',
        '用途': 'usage', '格式': 'format', '示例': 'example', '注意': 'note',
      },
      'manage_tool_test': {
        '动作': 'action', '操作': 'action',
        '工具': 'tools', '列表': 'tools', '名字': 'name', '名称': 'name',
        '成功': 'ok', '通过': 'ok', '问题': 'bug', '缺陷': 'bug',
      },
      'write_diary': {
        '内容': 'content', '日期': 'date',
      },
      'query_diary': {
        '日期': 'date', '查询': 'query', '关键词': 'query',
      },
      'query_logs': {
        '查询': 'query', '关键词': 'query',
      },
      'manage_goal': {
        '动作': 'action', '目标': 'goal',
      },
      'query_tool_formats': {
        '工具': 'tool', '名字': 'tool', '名称': 'tool',
      },
      'record_relation': {
        '谁': 'subject', '主体': 'subject', '主语': 'subject',
        '关系': 'predicate', '谓语': 'predicate', '动作': 'predicate',
        '对象': 'object', '宾语': 'object',
        '原话': 'quote', '引语': 'quote',
        '时间': 'time', '类别': 'category', '分类': 'category',
      },
      // 8-10 21:5x（用户：男主 add_record 报"没写原话"被拦）：
      // add_record 没归一化表 → 男主写中文 key（原话/内容/路径…）→
      // text/path 取不到 → 记录失败。补中文→英文映射。
      'add_record': {
        '分类路径': 'path', '路径': 'path', '分类': 'path', '挂到': 'path',
        '类别': 'path', '原话': 'text', '内容': 'text', '文本': 'text',
        '记录': 'text', '话': 'text', '摘要': 'summary', '总结': 'summary',
        '关键词组': 'keyword_groups', '关键词': 'keyword_groups',
        '关键词组合': 'keyword_groups',
      },
    };
    final table = aliases[toolName];
    if (table == null) return args;
    final out = Map<String, dynamic>.from(args);
    table.forEach((cn, en) {
      if (out.containsKey(cn) && !out.containsKey(en)) {
        out[en] = out[cn];
        out.remove(cn);
      }
    });
    return out;
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
        '✅ 工具记录确认: [${category.isEmpty ? '其他' : category}] $content'
        '（session=$_chatSessionId, leaf=$_chatLeafId）',
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
      return const _ToolResult(
        false,
        '没有可弹的消息——参数名用 messages（字符串或字符串列表），'
        '别用中文"内容/消息"。示例：{"messages":["汪～"]}',
      );
    }
    final intervalSec = _parseSecondsArg(args['interval_seconds']);
    final waitMin = _parseMinutesArg(args['wait_minutes']) ?? 5;
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
      // 8-08 14:0x（记忆查不到诊断）：写入/查询的 session 是否一致、命中数。
      // 曾出现 record_memory 成功但 recall_memory 查不到——用日志对 sessionId。
      DebugLogger.log(
        '指令模块',
        '🔍 recall_memory: session=$sessionId query=${query.isEmpty ? category : query}'
        ' → 命中 ${memories.length} 条${memories.isEmpty ? '（查不到！对比写入时的 session）' : ''}',
      );
      if (memories.isEmpty) {
        // 8-09 16:0x（用户：查记忆无结果被男主说成"用户拒绝查"）：
        // 查询动作成功完成、只是没有结果——ok:true（查询完成）不是失败/拒绝。
        // 文本明确"查询完成 + 不是失败"，男主不会再误读
        return _ToolResult(
          true,
          '查询完成：没有找到关于「${query.isEmpty ? category : query}」的记忆'
              '（这是查询结果，不是失败或拒绝）',
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
  /// 8-11 18:0x（用户 17:57 设计）：工具结果行 = 参数（名=值）+ ✅/❌ + 一句话 + 怎么办。
  /// 短结果直接进上下文；超长（>300 字）→ 上下文只留摘要 + 提示查缓存（外置大脑）。
  /// 8-11 20:15（用户拍板）：结果行带工具编号 C1/C2…——三套编号不混
  /// （大流程 T1/T2 / 消息 M1/M2 / 工具 C1/C2）；男主想查详细记录报编号即可。
  String _toolResultLine(
      String toolNo, String name, Map<String, dynamic> args, _ToolResult r) {
    final okMark = r.ok ? '✅成功' : '❌失败';
    final argsBrief = _toolArgsBrief(args);
    final text = r.text.trim();
    var line = '【工具 $name $toolNo】参数（$argsBrief）$okMark';
    if (text.isEmpty) return '$line。';
    if (text.length > 300) {
      line += '：${text.substring(0, 120)}…（完整结果已存工具缓存 $toolNo，'
          '需要时 manage_tool_cache 动作=view 编号=$toolNo 查）';
    } else {
      line += '：$text';
    }
    if (!r.ok && !text.startsWith('用户拒绝')) {
      // 8-12 19:2x（用户：失败要告诉怎么办——查参数就是解决办法）：
      // 具体指引男主用 list_tools {name} 查这个工具的参数/必填，改好重试
      line += '。→ 查「$name」的参数/必填：调 list_tools {name:$name}；'
          '改好重试，或回复她结束这步';
    }
    return line;
  }

  /// 工具参数摘要（名=值，值截断；空参数 → 无参数）
  String _toolArgsBrief(Map<String, dynamic> args) {
    if (args.isEmpty) return '无参数';
    final parts = <String>[];
    args.forEach((k, v) {
      final s = (v?.toString() ?? '').trim();
      if (s.isEmpty || s == 'null') return;
      final short = s.length > 12 ? '${s.substring(0, 12)}…' : s;
      parts.add('$k=$short');
    });
    return parts.isEmpty ? '无参数' : parts.join('、');
  }

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
      if (detail == null) {
        return _ToolResult(
          false,
          '没有「$name」这个工具（想不起来有哪些：list_tools 不带参数查概览）',
        );
      }
      // 8-12 19:2x（用户：男主调用失败要知道怎么办——查参数就是解决办法）：
      // list_tools {name} 除一句话说明外，再带完整参数详情（必填/类型/说明）
      final params = _toolParamsText(name);
      return _ToolResult(true, '$detail\n\n【参数】$params');
    }
    return _ToolResult(true, _toolListText());
  }

  /// 从工具定义（butlerTools）提取某工具的参数详情：必填 + 每个参数
  /// 名/类型/说明/可选值。找不到定义返回提示。
  String _toolParamsText(String name) {
    for (final t in AiChatService.butlerTools) {
      final fn = t['function'] as Map<String, dynamic>?;
      if (fn == null || fn['name'] != name) continue;
      final params = fn['parameters'] as Map<String, dynamic>?;
      if (params == null) return '（无参数说明）';
      final props = params['properties'] as Map<String, dynamic>?;
      if (props == null || props.isEmpty) return '（无参数）';
      final required =
          (params['required'] as List?)?.cast<String>() ?? const <String>[];
      final lines = <String>[];
      props.forEach((k, v) {
        final m = v as Map<String, dynamic>?;
        if (m == null) return;
        final type = m['type']?.toString() ?? '';
        final desc = m['description']?.toString() ?? '';
        final isReq = required.contains(k);
        final enumVals = m['enum'];
        var s = '· $k${isReq ? '（必填）' : ''}：$type $desc'.trim();
        if (enumVals is List && enumVals.isNotEmpty) {
          s += '（可选值：${enumVals.join(' / ')}）';
        }
        lines.add(s);
      });
      if (lines.isEmpty) return '（无参数）';
      final reqText =
          required.isEmpty ? '无必填参数' : '必填：${required.join('、')}';
      return '$reqText\n${lines.join('\n')}';
    }
    return '（工具定义里找不到「$name」）';
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
  /// 8-08 15:5x（用户反馈）：时长解析——支持带单位
  /// （"30分钟"/"1小时"/"2小时30分钟"/"90"/30），解析不了返回 null
  /// 8-08 16:3x：实现移到 services/parse_utils.dart（修复验证中心要复用），
  /// 这里只做转发，逻辑只有一份
  int? _parseMinutesArg(dynamic v) => parseMinutesArg(v);

  /// 8-08 15:5x：秒数解析（interval_seconds 用，"4秒"/"2分钟"/30）
  int? _parseSecondsArg(dynamic v) => parseSecondsArg(v);

  Future<_ToolResult> _executeCountdownCard(Map<String, dynamic> args) async {
    final minutes = _parseMinutesArg(args['minutes']); // null = 纯选择卡片
    final title = args['title']?.toString().trim() ?? '记得回来哦';
    final category = args['category']?.toString().trim() ?? '';
    final allowRequest = args['allow_request'] == true;
    final remindOnExpire = args['remind_on_expire'] != false;
    final remindDelay = _parseMinutesArg(args['remind_delay_minutes']) ?? 0;
    final wakeMin = _parseMinutesArg(args['wake_minutes']) ?? 5;
    // 选项解析（8-07 21:2x：兼容男主传字符串数组 ["A. 选项一", "B. 选项二"]
    // → 转成 message 选项按钮，否则用户看到文字点不了）
    final options = <CardOption>[];
    final rawOptions = args['options'];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        if (o is Map) {
          options.add(CardOption.fromJson(Map<String, dynamic>.from(o)));
        } else if (o is String && o.trim().isNotEmpty) {
          options.add(CardOption(label: o.trim()));
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
      // 8-10 21:5x（用户：manage_task 缺 task_id 失败，男主不知道补什么）：
      // 错误信息写明怎么修——先查任务拿到 ID 再 manage_task
      return const _ToolResult(
        false,
        '管理失败：缺 task_id 参数。先查任务列表/卡片状态拿到任务 ID，'
        '再 manage_task（action=…, task_id=…）',
      );
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
    // 8-10 v3（5.8 分支）：base_version=N → 基于历史版本 vN 的全文做操作
    // （不写 = 基于当前生效版）。拼接 = 基于版本A + update 某段为版本B内容。
    // 版本号 = 按时间排序的序号（v1=最老…vN=最新，跟弹窗版本树一致）。
    final baseVersion = (args['base_version'] as num?)?.toInt();
    var base = current;
    var baseNote = '';
    if (baseVersion != null && baseVersion > 0) {
      final sorted = book.versions
          .where((v) => v.type == type)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (baseVersion > sorted.length) {
        return _ToolResult(
          false,
          '没有版本 v$baseVersion（$typeName 现有 v1~v${sorted.length}，'
          'v1=最老、v${sorted.length}=最新）。不带 base_version = 基于当前生效版改',
        );
      }
      base = sorted[baseVersion - 1].content;
      baseNote = '（基于 v$baseVersion 分支）';
    }
    String newText;
    String opDesc;
    if (action == 'replace') {
      newText = content;
      opDesc = '整体重写$typeName$baseNote${reason.isEmpty ? '' : '：$reason'}';
    } else {
      final sections = _parseSettingSections(base);
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
      settingPid: settingPid,
      settingType: type,
    );
    if (result == null) {
      return _ToolResult(false, '她没回应设定更新（先别催，她可能在忙）');
    }
    if (result.approved.isEmpty) {
      final fb = result.feedback.trim();
      return _ToolResult(
        false,
        '她拒绝了「$typeName」更新。'
        '${fb.isNotEmpty ? '她的反馈：$fb——按她的意见改完再提交。' : '她没说原因，你可以问问她哪里不满意。'}',
      );
    }

    // 批准 → 存为新版本 + 变更日志
    // 8-07 18:2x 用户：定案二选一——'keep'留档（用户原稿进历史，
    // 男主定稿成新当前）/ 'overwrite'覆盖（男主定稿直接替换当前版本内容）
    final finalContent = result.content.trim();
    if (result.approved == 'overwrite') {
      await SettingVersionStore.saveCurrent(settingPid, type, finalContent);
      await SettingVersionStore.addChangelog(
        settingPid,
        type,
        '$opDesc（覆盖了原来的当前版本）',
      );
      DebugLogger.log('指令模块', '📚 $typeName 已覆盖更新（$opDesc）');
      _appendToolBubble('📚 男主更新了$typeName：$opDesc（已覆盖原当前版本）');
      return _ToolResult(
        true,
        '$typeName 已更新生效（$opDesc，已覆盖原当前版本）。当前段落结构：\n'
        '${_sectionsOutline(_parseSettingSections(finalContent))}',
      );
    }
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

  /// 解析男主回复里的【问题N】+【选项】组（8-07 16:4x 用户：问答卡片化——
  /// 一次只弹一个题目，单选/多选由男主定，C=用户自己写）：
  /// 格式：
  ///   【问题1】（单选）身份部分想怎么定？
  ///   【选项】
  ///   A. 内容
  ///   B）内容
  ///   C: 内容
  ///   【问题2】（多选）喜好部分呢？
  ///   【选项】
  ///   A. ...
  /// 也兼容旧格式：单独的【选项】块（无【问题N】）→ 一组 question=''
  static List<
    ({String question, bool multi, List<({String key, String text})> options})
  >
  _parseOptionGroups(String reply) {
    final groups =
        <
          ({
            String question,
            bool multi,
            List<({String key, String text})> options,
          })
        >[];
    final blockReg = RegExp(r'【问题\d*】([\s\S]*?)【选项】([\s\S]*?)(?=【问题\d*】|$)');
    for (final m in blockReg.allMatches(reply)) {
      var question = m.group(1)!.trim();
      // （单选）/（多选）标记：没写默认单选
      var multi = false;
      final multiM = RegExp(r'（\s*多选\s*）').firstMatch(question);
      if (multiM != null) {
        multi = true;
        question = question.replaceFirst(multiM.group(0)!, '').trim();
      } else {
        question = question.replaceFirst(RegExp(r'（\s*单选\s*）'), '').trim();
      }
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
        groups.add((question: question, multi: multi, options: opts));
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
          groups.add((question: '', multi: false, options: opts));
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

  /// 两版设定文本的段落级 diff（8-07 15:5x 用户：男主/用户都要看得出版本
  /// 改了什么）：对比【标签】段，输出 新增/删除/修改 摘要；无差异返回（无变化）
  static String _diffSettingTexts(String oldText, String newText) {
    final a = _parseSettingSections(oldText);
    final b = _parseSettingSections(newText);
    final lines = <String>[];
    for (final sec in b) {
      final old = a.where((x) => x.tag == sec.tag).toList();
      if (old.isEmpty) {
        lines.add('新增【${sec.tag}】${sec.body}');
      } else if (old.first.body != sec.body) {
        lines.add('改【${sec.tag}】：${old.first.body} → ${sec.body}');
      }
    }
    for (final sec in a) {
      if (!b.any((x) => x.tag == sec.tag)) {
        lines.add('删除【${sec.tag}】${sec.body}');
      }
    }
    return lines.isEmpty ? '（无变化）' : lines.join('\n');
  }

  /// 版本段落索引（8-07 15:5x 用户：不把全文塞给男主，只给"每版有哪些段"
  /// 的标签+预览，男主需要哪段用 query_setting_version 查原文）：
  /// v1：①【身份】测试角色 ②【喜好】xxx…
  static String _buildVersionIndex(
    List<({int v, String text, String diff})> versions,
  ) {
    if (versions.isEmpty) return '（无）';
    final buf = StringBuffer();
    for (final ver in versions) {
      final secs = _parseSettingSections(ver.text);
      final parts = <String>[];
      for (var i = 0; i < secs.length; i++) {
        final sec = secs[i];
        final preview = sec.body.length > 12
            ? '${sec.body.substring(0, 12)}…'
            : sec.body;
        parts.add('${i + 1}【${sec.tag.isEmpty ? '未分段' : sec.tag}】$preview');
      }
      buf.writeln('v${ver.v}：${parts.join(' / ')}');
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
  Future<({String approved, String content, String feedback})?>
  _showSettingApprovalDialog({
    required String typeName,
    required String content,
    required String reason,
    String? testStep,
    // 8-07 18:2x 用户：无当前版本 → 弹窗内先选一个版本作为当前
    String? settingPid,
    String? settingType,
  }) async {
    if (!mounted) return null;
    // 8-07 19:5x 用户：状态感知——设定弹窗打开 = 走流程（男主状态感知知道）
    FlowStore.settingDialogActive = true;
    FocusManager.instance.primaryFocus?.unfocus();
    // 检查该类型有没有当前版本（isCurrent）；没有 → 先选版本再聊
    var needPick = false;
    var hasCurrentVersion = true;
    var pickVersions = <SettingVersion>[];
    // 8-10 v3（5.8 版本树）：历史版本概览（按时间排序 v1..vN + 当前生效），
    // 弹窗标题下展示；v0 初始 = 第一个版本（最老的）
    var histVersionTree = <String>[];
    if (settingPid != null && settingType != null) {
      final book = await SettingVersionStore.load(settingPid);
      final sorted = book.versions
          .where((v) => v.type == settingType)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      histVersionTree = [
        for (var i = 0; i < sorted.length; i++)
          'v${i + 1}${sorted[i].isCurrent ? '（当前生效）' : ''}',
      ];
      if (histVersionTree.isNotEmpty) {
        histVersionTree = ['v0 初始', ...histVersionTree];
      }
      hasCurrentVersion = book.versions.any(
        (v) => v.type == settingType && v.isCurrent,
      );
      needPick = !hasCurrentVersion;
      if (needPick) {
        pickVersions = book.versions
            .where((v) => v.type == settingType)
            .toList();
      }
    }
    final ctrl = TextEditingController(text: content);
    final fbCtrl = TextEditingController();
    var maleText = reason.isEmpty ? '我想更新$typeName，你看看这样行不行。' : reason;
    var round = 1;
    var busy = false;
    // 8-07 15:2x 用户：男主方案要打版本号，看得出改了几版、每版长啥样
    // v1 = 男主最初方案；每次男主带【新方案】回复 → 追加新版本
    // 8-07 15:5x：每版带 diff（相对上一版改了哪些段）；用户用嘴说
    // "第X版的XX好/不好"，男主按版本段落索引+查询工具自己结合
    final versions = <({int v, String text, String diff})>[
      (v: 1, text: content, diff: '（初始方案）'),
    ];
    var currentV = 1;
    // 弹窗内版本列表快照（给查询工具 query_setting_version 用）
    _dialogVersions = versions;
    // 8-07 16:4x 用户：问答卡片化——一次只弹一个题目（不用手动滑），
    // 单选点一个/多选点完+自己写 → 自动跳下一个，全部答完自动发男主；
    // 了解需求阶段（asking）不显示设定原文和定案按钮，男主出方案后
    // 才进入 reviewing（看版本卡片+全文+反馈）
    var stage = 'asking'; // 'asking'=男主在收集需求 | 'reviewing'=男主出方案了
    var curQ = 0; // 当前显示第几题（0 起）
    // 每题已答内容：题目 → 答案列表（单选1个/多选多个/自己写）
    final answers = <String, List<String>>{};
    // 自己写的输入控制器（每题一个，用完即弃）
    var customCtrl = TextEditingController();
    var customOpen = false; // 当前题是否打开了"自己写"输入框
    // 男主回复带【问题N】+【选项】块 → 解析成可点卡片题组
    var questionGroups =
        <
          ({
            String question,
            bool multi,
            List<({String key, String text})> options,
          })
        >[];
    // 8-07 16:1x 用户：「就用这版」只在男主确认了解完需求、出【最终方案】
    // 后才出现；【新方案】=还在了解/迭代中，不显示（第一版第二版都不算数）
    var maleHasFinal = false;
    // 8-07 17:0x 修复死锁：弹窗打开自动触发第一轮男主会话
    // （否则 asking 阶段没题目没按钮，用户只能点放弃）
    var autoStarted = false;
    // 会话记录（每轮：她说/男主说，给男主当上下文）
    final history = <String>[];
    final pid = _state.personaId ?? '';
    final pName = _state.personaName ?? _state.lead?.name ?? '角色';

    final approved = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          // 发给男主一轮（"发给他"按钮和"点选项"共用）：男主回复
          // 带【新方案】→ 自动更新设定框并记新版本；带【选项】→ 显示可点选项
          Future<void> sendToMale(String userMsg) async {
            fbCtrl.clear();
            setState(() => busy = true);
            // 8-10 v3（5.8 工具内标签）：卡片会话里的对话带标签，
            // 男主分清"这是工具里她说的，不是新消息"
            history.add('【工具·用户】她说：$userMsg');
            final reply = await _askMaleInSession(
              personaId: pid,
              settingPid: _settingPid(),
              personaName: pName,
              typeName: typeName,
              draft: ctrl.text,
              maleLast: maleText,
              userMsg: userMsg,
              history: history,
              versionIndex: versions.isNotEmpty
                  ? _buildVersionIndex(versions)
                  : null,
              testStep: testStep,
            );
            history.add('【工具·男主】男主说：$reply');
            // 8-07 16:1x：男主确认了解完需求出【最终方案】→ 才亮「就用这版」；
            // 只出【新方案】=还在了解/迭代，按钮不出现
            final finalIdx = reply.indexOf('【最终方案】');
            final idx = finalIdx >= 0 ? finalIdx : reply.indexOf('【新方案】');
            if (idx >= 0) {
              final rest = reply
                  .substring(idx + (finalIdx >= 0 ? '【最终方案】' : '【新方案】').length)
                  .trim();
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
              maleHasFinal = finalIdx >= 0;
              // 男主出方案（或最终方案）→ 进 reviewing 阶段，显示全文+版本
              final newGroups = _parseOptionGroups(reply);
              if (newGroups.isNotEmpty) {
                // 男主又问了新问题 → 回到 asking，从第一题开始答
                questionGroups = newGroups;
                curQ = 0;
                answers.clear();
                customOpen = false;
                stage = 'asking';
              } else {
                questionGroups = [];
                stage = 'reviewing';
              }
              final hasNew = versions.any((x) => x.text == ctrl.text);
              if (!hasNew && idx >= 0) {
                // 8-07 15:5x 用户：从旧版继续改 → 该版之后的版本自动作废
                // （截断），新方案接在后面重新编号
                if (currentV < versions.length) {
                  versions.removeRange(currentV, versions.length);
                }
                final prevText = versions.isEmpty ? '' : versions.last.text;
                versions.add((
                  v: versions.length + 1,
                  text: ctrl.text,
                  diff: _diffSettingTexts(prevText, ctrl.text),
                ));
                currentV = versions.length;
              }
            });
          }

          // 8-07 16:4x 用户：问答卡片——答当前题，答完自动跳下一题；
          // 全部答完自动发男主（不手动攒、不手动滑）
          // 8-07 17:2x 修复：多选点选项只是勾选（可继续选多个），
          // 不会自动发送——多选要再点「✓ 答完这题」才跳题/发送；
          // 单选点选项即答完（自动跳/发）
          String assembleAnswers() {
            final buf = StringBuffer();
            for (final g in questionGroups) {
              final list = answers[g.question] ?? [];
              if (list.isEmpty) continue;
              buf.writeln('【${g.question}】${list.join('；')}');
            }
            return buf.toString().trim();
          }

          void answerQuestion(String question, String ans) {
            setState(() {
              answers.putIfAbsent(question, () => []).add(ans);
              customOpen = false;
              customCtrl.clear();
              if (curQ + 1 < questionGroups.length) {
                curQ++; // 自动跳下一题
              } else {
                // 全部答完 → 组装消息自动发男主
                fbCtrl.clear();
                final msg = assembleAnswers();
                if (msg.isNotEmpty) {
                  // 延迟到 setState 外发（避免在 setState 里 await）
                  Future.microtask(() => sendToMale(msg));
                }
              }
            });
          }

          // 多选「✓ 答完这题」：选够了点它 → 跳下一题 / 全部答完自动发送
          void finishMultiQuestion() {
            setState(() {
              customOpen = false;
              customCtrl.clear();
              if (curQ + 1 < questionGroups.length) {
                curQ++; // 自动跳下一题
              } else {
                // 全部答完 → 组装消息自动发男主
                fbCtrl.clear();
                final msg = assembleAnswers();
                if (msg.isNotEmpty) {
                  Future.microtask(() => sendToMale(msg));
                }
              }
            });
          }

          // 弃用某一版（✕）：删除后重编号，至少保留一版；
          // 若编辑框内容是被删的版 → 载入最后一版；
          // 8-07 15:5x 用户：弃用不丢上下文——被删版本内容进会话历史，
          // 男主下一轮还能看到（他知道中间发生过什么）
          void discardVersion(int v) {
            if (versions.length <= 1) return;
            setState(() {
              final dropped = versions.firstWhere(
                (x) => x.v == v,
                orElse: () => versions.last,
              );
              history.add(
                '【工具·用户】她说：我弃用了 v${dropped.v} 这版（内容：'
                '${dropped.text}）。你可以参考里面的想法，但别直接用。',
              );
              versions.removeWhere((x) => x.v == v);
              for (var i = 0; i < versions.length; i++) {
                versions[i] = (
                  v: i + 1,
                  text: versions[i].text,
                  diff: versions[i].diff,
                );
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

          // 8-07 17:0x 修复死锁：弹窗打开自动触发第一轮男主会话
          // （只触发一次；男主回复带【问题】→ asking 出卡片题，
          //   带【最终方案】→ reviewing 直接出定案按钮）
          if (!autoStarted && !busy && !needPick) {
            autoStarted = true;
            Future.microtask(() => sendToMale('我想更新$typeName：$reason'));
          }

          // 8-07 18:2x：没有当前版本 → 先选一个版本作为当前，选完再进对话
          if (needPick) {
            return AlertDialog(
              backgroundColor: const Color(0xFFFDF7F9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text('先选一个「$typeName」版本作为当前'),
              content: SizedBox(
                width: double.maxFinite,
                child: pickVersions.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          '还没有任何版本。先去右页写一版（➕ 新建），'
                          '或直接在这里放弃，从零开始。',
                          style: TextStyle(fontSize: 13),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final v in pickVersions)
                            ListTile(
                              dense: true,
                              title: Text(
                                _dialogVersionLabel(v),
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                v.content.replaceAll('\n', ' '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                              onTap: () async {
                                final sp = settingPid;
                                if (sp == null) return;
                                await SettingVersionStore.applyVersion(
                                  sp,
                                  v.id,
                                );
                                await SettingVersionStore.addChangelog(
                                  sp,
                                  settingType!,
                                  '弹窗内选用「$_dialogVersionLabel(v)」作为当前$typeName',
                                );
                                if (ctx.mounted) {
                                  setState(() {
                                    needPick = false;
                                    hasCurrentVersion = true;
                                  });
                                }
                              },
                            ),
                        ],
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, ''),
                  child: const Text(
                    '放弃',
                    style: TextStyle(color: Color(0xFF8A7A80)),
                  ),
                ),
              ],
            );
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
                  // 8-10 v3（5.8 版本树）：v0 初始=根，历史版本分支概览
                  if (histVersionTree.isNotEmpty)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3EEF7),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '🌳 版本树：${histVersionTree.join(' → ')}',
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
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
                  // ── asking 阶段：问答卡片（8-07 16:4x 用户：一次只弹一题；
                  // 8-08 19:4x 用户：单选/多选统一——点选项=勾选，点
                  // 「✓ 答完这题」才跳下一题/发送；此阶段【不显示】设定原文
                  // 和定案按钮）──
                  if (stage == 'asking' && questionGroups.isNotEmpty) ...[
                    Text(
                      '🎯 男主在了解需求（第 ${curQ + 1}/${questionGroups.length} 题'
                      '${questionGroups[curQ].multi ? '·可多选' : '·单选'}）：'
                      '${questionGroups.length > 1 ? '点「✓ 答完这题」进下一题' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8A7A80),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 当前题目卡片
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7EAF1),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE8C9D8)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (questionGroups[curQ].question.isNotEmpty) ...[
                            Text(
                              '❓ ${questionGroups[curQ].question}'
                              '${questionGroups[curQ].multi ? '（可多选）' : ''}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF6B5560),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          for (final opt in questionGroups[curQ].options)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: GestureDetector(
                                onTap: busy
                                    ? null
                                    : () {
                                        final q = questionGroups[curQ].question;
                                        if (questionGroups[curQ].multi) {
                                          // 多选：点=加入/取消，不跳题
                                          setState(() {
                                            final list = answers.putIfAbsent(
                                              q,
                                              () => [],
                                            );
                                            final i = list.indexWhere(
                                              (a) =>
                                                  a.startsWith('${opt.key}. '),
                                            );
                                            if (i >= 0) {
                                              list.removeAt(i);
                                            } else {
                                              list.add(
                                                '${opt.key}. ${opt.text}',
                                              );
                                            }
                                          });
                                        } else {
                                          // 8-08 19:4x（用户：单选多选统一）：
                                          // 单选点选项 = 勾选（再点同项=取消），
                                          // 不跳题——点「✓ 答完这题」才发送
                                          setState(() {
                                            final list = answers.putIfAbsent(
                                              q,
                                              () => [],
                                            );
                                            final already = list.any(
                                              (a) => a.startsWith(
                                                '${opt.key}. ',
                                              ),
                                            );
                                            list.clear();
                                            if (!already) {
                                              list.add(
                                                '${opt.key}. ${opt.text}',
                                              );
                                            }
                                          });
                                        }
                                      },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 9,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        answers[questionGroups[curQ].question]
                                                ?.any(
                                                  (a) => a.startsWith(
                                                    '${opt.key}. ',
                                                  ),
                                                ) ==
                                            true
                                        ? const Color(0xFFE8C9D8)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color:
                                          answers[questionGroups[curQ].question]
                                                  ?.any(
                                                    (a) => a.startsWith(
                                                      '${opt.key}. ',
                                                    ),
                                                  ) ==
                                              true
                                          ? const Color(0xFFC896B4)
                                          : const Color(0xFFE8C9D8),
                                      width:
                                          answers[questionGroups[curQ].question]
                                                  ?.any(
                                                    (a) => a.startsWith(
                                                      '${opt.key}. ',
                                                    ),
                                                  ) ==
                                              true
                                          ? 1.5
                                          : 1,
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
                          // "自己写"入口：选项都不满意就自己打字
                          if (!customOpen)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: GestureDetector(
                                onTap: busy
                                    ? null
                                    : () => setState(() => customOpen = true),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                    horizontal: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF0E4EA),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(0xFFD8B8C8),
                                    ),
                                  ),
                                  child: const Text(
                                    '✏️ 我自己写（选项都不满意就自己说）',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF8A5A72),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (customOpen) ...[
                            const SizedBox(height: 6),
                            TextField(
                              controller: customCtrl,
                              maxLines: 2,
                              autofocus: true,
                              decoration: InputDecoration(
                                hintText: '写下你的想法…（写完点「✓ 答完这题」）',
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: busy
                                    ? null
                                    : () {
                                        final txt = customCtrl.text.trim();
                                        if (txt.isEmpty) return;
                                        answerQuestion(
                                          questionGroups[curQ].question,
                                          '我自己写：$txt',
                                        );
                                      },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFC896B4),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    '✓ 答完这题',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          // 8-07 17:2x 修复：多选点选项只是勾选（可继续选多个），
                          // 不会自动发送——选够了点「✓ 答完这题」才跳题/发送
                          // 8-08 19:4x（用户）：单选也统一——点选项=勾选，
                          // 有答案就显示「✓ 答完这题」，点了才跳题/发送
                          if ((answers[questionGroups[curQ].question] ?? [])
                              .isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: busy ? null : finishMultiQuestion,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFC896B4),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    curQ + 1 < questionGroups.length
                                        ? '✓ 答完这题，下一题'
                                        : '✓ 答完了，发给他',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 进度点（小圆点表示题目位置）
                    Row(
                      children: [
                        for (var i = 0; i < questionGroups.length; i++)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == curQ
                                  ? const Color(0xFFC896B4)
                                  : (answers.containsKey(
                                              questionGroups[i].question,
                                            ) &&
                                            (answers[questionGroups[i]
                                                    .question]!
                                                .isNotEmpty)
                                        ? const Color(0xFFE8C9D8)
                                        : const Color(0xFFE0D4DA)),
                            ),
                          ),
                        const SizedBox(width: 6),
                        Text(
                          answers.values.fold<int>(
                                    0,
                                    (sum, l) => sum + (l.isEmpty ? 0 : 1),
                                  ) ==
                                  questionGroups.length
                              ? '✅ 全部答完，正在发给男主…'
                              : '已答 ${answers.values.fold<int>(0, (sum, l) => sum + (l.isEmpty ? 0 : 1))}/${questionGroups.length} 题',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8A7A80),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // ── reviewing 阶段：方案版本卡片区（8-07 16:4x 用户：
                  // 版本像卡片一样调出，点编号=调出该版全文（卡片式），
                  // 方便跟男主说"喜欢 v2 的喜好"）──
                  if (stage == 'reviewing' && versions.length > 1) ...[
                    const Text(
                      '📚 男主方案版本：点编号=像卡片一样调出该版，✕=弃用（男主仍看得到）。跟男主说"第一版的XX好/不好，第二版的XX…"，他能查段落自己结合',
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
                              border: currentV == ver.v
                                  ? Border.all(
                                      color: const Color(0xFF8A5A72),
                                      width: 1.5,
                                    )
                                  : null,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    // 调出该版全文（卡片式查看，不覆盖当前编辑）
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
                    // 当前查看的版本卡片（调出的全文）
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7EAF1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE8C9D8)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '📋 正在查看 v$currentV'
                            '${currentV > 1 ? '\n📝 这版改了：${versions.where((x) => x.v == currentV).first.diff}' : ''}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8A5A72),
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            versions.where((x) => x.v == currentV).first.text,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: Color(0xFF4A3A42),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // ── reviewing 阶段才显示设定全文（8-07 16:4x 用户：
                  // 了解需求时不该看到原文；男主出方案后才能看/改/定案）──
                  if (stage == 'reviewing') ...[
                    Text(
                      '📄 当前方案全文（可以直接改；点「就用这版」= 按这个定案）：',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8A7A80),
                      ),
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
                        hintText: '跟男主说：哪里不对、想要什么…（男主确认了解完会出最终版，才出现「就用这版」）',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
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
                onPressed: busy ? null : () => Navigator.pop(ctx, ''),
                child: const Text(
                  '放弃',
                  style: TextStyle(color: Color(0xFF8A7A80)),
                ),
              ),
              // reviewing 阶段：跟男主说话（哪里不对/想要什么/结合哪几版）
              if (!busy && stage == 'reviewing')
                TextButton(
                  onPressed: () async {
                    final msg = fbCtrl.text.trim();
                    if (msg.isEmpty) return;
                    await sendToMale(msg);
                  },
                  child: const Text(
                    '💬 发给他',
                    style: TextStyle(color: Color(0xFFC896B4)),
                  ),
                ),
              // 8-07 16:1x 用户：只有男主出【最终方案】（确认了解完需求）
              // 才显示「就用这版」；【新方案】=还在了解/迭代，不出现；
              // 16:4x：asking 阶段（还在答题目）也不显示
              // 18:2x 用户：定案二选一——留档（默认）/ 覆盖我原来写的
              if (!busy && stage == 'reviewing' && maleHasFinal) ...[
                if (hasCurrentVersion)
                  TextButton(
                    onPressed: () {
                      setState(() => busy = true);
                      Navigator.pop(ctx, 'overwrite');
                    },
                    child: const Text(
                      '♻️ 覆盖我原来写的',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8A6A96)),
                    ),
                  ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC896B4),
                  ),
                  onPressed: () {
                    // 8-07 15:0x：防连点——先置 busy 再 pop，双击不会 pop 两次
                    setState(() => busy = true);
                    Navigator.pop(ctx, 'keep');
                  },
                  child: const Text('✅ 就用这版（留档）'),
                ),
              ],
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
    customCtrl.dispose();
    _dialogVersions = null;
    FlowStore.settingDialogActive = false;
    if (approved == null) return null;
    // 8-07 18:2x：approved = ''放弃 / 'keep'留档定案 / 'overwrite'覆盖定案
    return (approved: approved, content: outContent, feedback: outFeedback);
  }

  /// 弹窗内版本标签（选当前版本列表用）
  String _dialogVersionLabel(SettingVersion v) {
    final t = v.createdAt;
    return '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
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
    // 8-07 15:5x 用户：不把版本全文塞给男主（他会混乱）——只给段落索引
    // （每版有哪些段+预览），他需要哪段用 query_setting_version 查原文
    String? versionIndex,
    // 8-07 17:0x：验收步骤号（mock 判定剧本用；真实 AI 忽略）
    String? testStep,
  }) async {
    try {
      DebugLogger.log(
        '弹窗会话',
        '💬 问男主（$typeName）：draft ${draft.length}字，主对话摘要 '
        '${PendingQueueStore.pendingUserText(personaId)?.length ?? 0} 字，'
        '历史 ${history.length} 条，轮次${testStep ?? '-'}',
      );
      final personaPrompt = _state.persona?.prompt ?? '';
      final book = SettingVersionStore.cached(settingPid ?? personaId);
      // 8-07 19:5x 用户：弹窗会话也带主对话情况摘要——男主在弹窗里
      // 也知道外面她说了什么（状态感知：弹窗讨论完要接上主对话待回复）
      final _pdUser = PendingQueueStore.pendingUserText(personaId);
      final _pdButler = PendingQueueStore.pendingButlerText(personaId);
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
      // 8-12 18:0x（缓存命中重构）：build 不再拼 taskState——弹窗会话
      // 每轮重建本来就不命中缓存，动态上下文手动追加回 system 保持行为
      final _baseSystem = SystemTemplate.build(
        personaName: personaName,
        personaPrompt: personaPrompt,
        needsWindow: false,
      );
      final system = '$_baseSystem\n\n【当前任务】'
          '【主对话情况】（弹窗外她在主对话说的、还没回的——弹窗讨论完记得接上）：\n'
            '${_pdUser ?? '（主对话暂无待回复）'}\n'
            '${_pdButler != null ? _pdButler + '\n' : ''}'
            '【设定修改会话】你在和她讨论「$typeName」的修改，还没定案。\n'
            '${testStep != null && testStep.isNotEmpty ? '【验收剧本】$testStep\n' : ''}'
            '$currentInfo\n'
            '${versionIndex != null && versionIndex.isNotEmpty ? '【版本段落索引】（她可能说"第X版的XX好/不好"，这是每版的段落标签+预览；需要某段原文时用 query_setting_version 工具查，别凭预览猜）：\n$versionIndex\n' : ''}'
            '你刚才的方案：\n$draft\n'
            '你上一轮说：$maleLast\n'
            '她本轮回复你：$userMsg\n'
            '回应她（像平时聊天一样自然）：可以解释、追问细节、或查资料'
            '（recall_memory/query_diary/query_setting_history/query_record/'
            'query_setting_version/list_tools 可直接查，不用她审批）。'
            '【连续问答】你要了解需求时，一次问一个问题，格式：\n'
            '【问题】问题内容（标注（单选）或（多选），不标默认单选）\n'
            '【选项】\n'
            'A. 选项内容\n'
            'B. 选项内容\n'
            '（选项数量你自己定：2-4 个都行，字母顺着排 A. B. C. D.…；'
            '她也可以不选选项，自己打字补充）\n'
            '她答完当前题会自动到下一题（你一次只发一个问题，别一次堆多个；'
            '等她全部答完，会一次性把答案发给你）。\n'
            '单选：她只能选一个；多选：她可以选多个，也可以补充自己的想法。'
            '她答完/补充完 → 你汇总需求出方案：\n'
            '——还在了解需求/可能还要改 → 最后单独一行写【新方案】然后写完整新内容（这不算定案，她不会点「就用这版」）；\n'
            '——确认她的需求都问清楚了、方案就是定稿 → 最后单独一行写【最终方案】然后写完整新内容（这时她才能点「就用这版」定案）。\n'
            '【结合请求】她说"第X版的XX好/不好"时：用 query_setting_version'
            '查对应版本对应段落的原文，分清她喜欢哪版哪段、不喜欢哪版哪段，'
            '把喜欢的段落组合成一份新方案（冲突的地方问她或取更合适的），'
            '最后按上面规则写【新方案】或【最终方案】。'
            '【别中途断流程】她没点「就用这版」之前，讨论都没结束——'
            '她还在提需求/答问题，你就继续问或改，别急着定案收尾；'
            '你只有在需求全部了解清楚、方案完整时才写【最终方案】。';
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
        AIProviderResult res;
        try {
          res = await AIProviderManager.instance.chat(
            personaId,
            msgs,
            tools: readOnly,
          );
        } on FormatException catch (e) {
          // 8-07 22:15 修复：弹窗会话也拦截空回复（DeepSeek 已知服务端问题），
          // 重试 1 次；仍失败按"卡了一下"处理（不弹红错）
          if (!e.message.contains('空回复')) rethrow;
          DebugLogger.log('设定会话', '⚠️ 弹窗会话空回复 → 重试 1 次');
          res = await AIProviderManager.instance.chat(
            personaId,
            msgs,
            tools: readOnly,
          );
        }
        final calls = res.toolCalls;
        if (calls != null && calls.isNotEmpty) {
          for (final call in calls) {
            final name = call['name']?.toString() ?? '';
            final args = (call['arguments'] as Map<String, dynamic>?) ?? {};
            final r = await _executeReadOnlySessionTool(name, args);
            // 8-07 16:1x 修复：工具结果必须用 role:'tool' + 原 toolCallId 配对
            // （跟主链路一致）——manager 靠 role=='tool' 判定工具轮，
            // 之前用 user role 追加 → mock 的 _handleToolRound 永远不触发，
            // 男主查段落的剧本走不通
            msgs.add(
              AIChatMessage(
                role: 'tool',
                content: '【工具 $name】$r',
                toolCallId: call['id']?.toString() ?? 'call_${i}_$name',
              ),
            );
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
    'query_setting_version',
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
      case 'query_setting_version':
        r = await _executeQuerySettingVersionTool(args);
        break;
      default:
        r = const _ToolResult(false, '这个工具在设定会话里不能用');
    }
    return '${r.ok ? '✅' : '❌'} ${r.text}';
  }

  /// 定时任务管理（8-10 用户：男主写/查/删定时任务，本地保存到点提醒）
  Future<_ToolResult> _executeManageScheduleTool(
    Map<String, dynamic> args,
  ) async {
    final action = args['action']?.toString().trim() ?? '';
    final store = AlarmStore.instance;
    switch (action) {
      case 'add':
        final time = args['time']?.toString().trim() ?? '';
        final text = args['text']?.toString().trim() ?? '';
        if (time.isEmpty || text.isEmpty) {
          return const _ToolResult(false, '新增失败：缺 time（HH:mm）或 text');
        }
        final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time);
        if (m == null) {
          return const _ToolResult(false, '时间格式不对，要 HH:mm（如 19:30）');
        }
        final hh = int.parse(m.group(1)!);
        final mm = int.parse(m.group(2)!);
        if (hh > 23 || mm > 59) {
          return const _ToolResult(false, '时间不对：小时 0-23、分钟 0-59');
        }
        final date = args['date']?.toString().trim() ?? '';
        final item = await store.add(time, text, date: date);
        return _ToolResult(
          true,
          '已设定时任务 #${item.id}：每天 $time 提醒「$text」'
          '${date.isEmpty ? '（每天重复）' : '（$date 一次性）'}。'
          '到点我会收到提醒，插入当前流程处理',
        );
      case 'list':
        final list = await store.pending();
        if (list.isEmpty) {
          return const _ToolResult(true, '当前没有定时任务。需要定时提醒时用 '
              'manage_schedule add（time=HH:mm, text=提醒内容）');
        }
        final sb = StringBuffer('当前定时任务：');
        for (final e in list) {
          sb.write('\n#${e.id} ${e.time} '
              '${e.date.isEmpty ? '（每天）' : '（${e.date}）'}「${e.text}」');
        }
        return _ToolResult(true, sb.toString());
      case 'delete':
        final id = (args['id'] as num?)?.toInt();
        if (id == null) {
          return const _ToolResult(false, '删除失败：缺 id（先 list 查）');
        }
        final ok = await store.delete(id);
        return ok
            ? _ToolResult(true, '已删除定时任务 #$id')
            : _ToolResult(false, '没找到定时任务 #$id（可能已删/已触发）');
      default:
        return _ToolResult(
            false, 'action 不对，要 add / list / delete');
    }
  }

  /// 定时任务检查器：到点的闹钟 → 插入流程步骤（8-10 用户：
  /// 闹钟响了插到当前处理步骤的后面，作为下一个步骤）
  Future<void> _checkAlarms(String personaId) async {
    try {
      final now = DateTime.now();
      final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final list = await AlarmStore.instance.pending();
      for (final e in list) {
        if (e.time != hhmm) continue;
        // 一次性任务：日期对不上不触发
        if (e.date.isNotEmpty && e.date != today) continue;
        // 触发 → 插入流程步骤（男主处理完当前步骤就轮到它）
        await ChatFlowStore.insertButlerStep(
            personaId, '⏰ 定时提醒：${e.text}');
        _appendToolBubble('⏰ 定时提醒到了：「${e.text}」');
        if (e.date.isNotEmpty) {
          await AlarmStore.instance.markDone(e.id); // 一次性 → 标记完成
        }
      }
    } catch (err) {
      DebugLogger.log('管家流程', '✖ 定时任务检查失败: $err');
    }
  }

  /// 工具执行：query_setting_version（8-07 15:5x 用户：男主按需查某版某段
  /// 原文——结合用户"第X版的XX好/不好"时用，不把全文塞给他）
  Future<_ToolResult> _executeQuerySettingVersionTool(
    Map<String, dynamic> args,
  ) async {
    final versions = _dialogVersions;
    if (versions == null || versions.isEmpty) {
      return const _ToolResult(false, '当前没有可查的版本（还没出过方案）');
    }
    final v = (args['version'] as num?)?.toInt();
    final tag = args['tag']?.toString();
    if (v == null || v < 1 || v > versions.length) {
      final list = versions.map((x) => 'v${x.v}').join('、');
      return _ToolResult(false, '版本号不对，当前有：$list');
    }
    final ver = versions.firstWhere((x) => x.v == v);
    if (tag == null || tag.trim().isEmpty) {
      return _ToolResult(true, 'v$v 全文：\n${ver.text}');
    }
    final secs = _parseSettingSections(ver.text);
    final sec = secs.where((x) => x.tag == tag.trim()).toList();
    if (sec.isEmpty) {
      final tags = secs.map((x) => '【${x.tag}】').join('、');
      return _ToolResult(false, 'v$v 里没有【$tag】段，有的段：$tags');
    }
    // 顺便带上该段相对上一版的变化（男主判断"这版改没改这块"用）
    String prevNote = '';
    if (v > 1) {
      final prev = versions.firstWhere((x) => x.v == v - 1);
      final prevSecs = _parseSettingSections(prev.text);
      final prevSec = prevSecs.where((x) => x.tag == tag.trim()).toList();
      if (prevSec.isEmpty) {
        prevNote = '\n（v${v - 1} 没有这段，是 v$v 新增的）';
      } else if (prevSec.first.body != sec.first.body) {
        prevNote = '\n（v${v - 1} 是：${prevSec.first.body}）';
      }
    }
    return _ToolResult(
      true,
      'v$v 的【${sec.first.tag}】：${sec.first.body}$prevNote',
    );
  }

  /// 工具执行：query_setting_history（男主查设定变更历史）
  /// 8-13 02:2x 本体记忆共享：预热记忆块（共享开 → 聚合 Lead 下所有角色）
  Future<void> _warmMemoryBlocks(String personaId, String? lid) async {
    if (personaId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final share = p.getBool('memory_share_$personaId') ?? true;
      if (!share || lid == null || lid.isEmpty) {
        MemoryBlockStore.warm(personaId);
        return;
      }
      final lead = await CharacterService().loadById(lid);
      final members = <({String id, String name})>[
        for (final ps in lead?.personas ?? <Persona>[])
          if (ps.id.isNotEmpty) (id: ps.id, name: ps.name),
      ];
      if (members.isEmpty) {
        MemoryBlockStore.warm(personaId);
      } else {
        MemoryBlockStore.warmShared(members);
      }
    } catch (_) {
      MemoryBlockStore.warm(personaId);
    }
  }

  Future<_ToolResult> _executeQuerySettingHistory(
    Map<String, dynamic> args,
  ) async {
    final pid = _state.personaId ?? '';
    if (pid.isEmpty) return const _ToolResult(false, '查历史失败（缺少角色）');
    final limit = (args['limit'] as num?)?.toInt() ?? 10;
    // 8-13 02:2x 本体记忆共享：共享开 → 聚合 Lead 下所有角色的设定历史
    final share = await _memoryShareEnabled(pid);
    final books = <(String, SettingBook)>[];
    if (share && _state.leadId != null) {
      final lead = await CharacterService().loadById(_state.leadId!);
      for (final ps in lead?.personas ?? <Persona>[]) {
        if (ps.id.isEmpty) continue;
        books.add((ps.name, await SettingVersionStore.load(_settingPidFor(ps.id))));
      }
    }
    if (books.isEmpty) {
      books.add(('', await SettingVersionStore.load(_settingPid())));
    }
    final buf = StringBuffer();
    var anyLog = false;
    for (final (name, book) in books) {
      final log = book.changelog.take(limit).toList();
      if (log.isEmpty) continue;
      anyLog = true;
      buf.writeln(name.isEmpty ? '设定变更历史：' : '【${name}】设定变更历史：');
      for (final e in log) {
        final t = e.time;
        final ts =
            '${t.month.toString().padLeft(2, '0')}-'
            '${t.day.toString().padLeft(2, '0')} '
            '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}';
        buf.writeln('- [$ts] ${e.type == 'user' ? '用户设定' : '男主设定'}：${e.summary}');
      }
      buf.writeln(
        '  当前男主设定：${book.currentMale.isEmpty ? '（空）' : book.currentMale}',
      );
      buf.writeln(
        '  当前用户设定：${book.currentUser.isEmpty ? '（空）' : book.currentUser}',
      );
      buf.writeln();
    }
    if (!anyLog) {
      return const _ToolResult(true, '还没有设定变更记录——你还没主动优化过设定。');
    }
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
          '临时记忆已更新（${lines.length} 行）。'
          '${lines.isEmpty ? '已清空。' : '下一句对话你会带着它。'}',
        );
      case 'append':
        final content = args['content']?.toString().trim() ?? '';
        if (content.isEmpty) return const _ToolResult(false, '临时记忆没写内容');
        await WorkingPadStore.append(personaId, content);
        DebugLogger.log('指令模块', '📋 便签追加一行');
        return _ToolResult(true, '已记到临时记忆：$content');
      case 'remove':
        final from = (args['from'] as num?)?.toInt() ?? 0;
        final to = (args['to'] as num?)?.toInt();
        final n = await WorkingPadStore.remove(personaId, from, to);
        if (n == 0) {
          return _ToolResult(
            false,
            '删除失败：临时记忆没有第 $from 行'
            '（先查一下现在有哪几行）',
          );
        }
        DebugLogger.log('指令模块', '📋 便签删了 $n 行');
        return _ToolResult(true, '临时记忆删了 $n 行（第 $from 行起）。');
      default:
        return _ToolResult(
          false,
          '临时记忆操作失败：未知动作「$action」。'
          '可用动作：set（整体更新，要 content）/append（追加，要 content）'
          '/remove（删行，要 from，可选 to）。'
          '示例：{"action":"set","content":"第一行\\n第二行"}；'
          '{"action":"remove","from":2}',
        );
    }
  }

  /// 工具执行：manage_memory_block（长期/短期记忆块，男主自管免审批）
  /// 8-12 18:0x 用户（缓存命中重构）：固定区记忆——平时冻结，
  /// 只在上下文压缩/整理节点更新；平时想记东西写临时记忆（tool_cache）。
  Future<_ToolResult> _executeManageMemoryBlock(Map<String, dynamic> args) async {
    final personaId = _state.personaId ?? '';
    final action = args['action']?.toString() ?? '';
    final content = args['content']?.toString() ?? '';
    switch (action) {
      case 'set_long':
        return _ToolResult(
            true, await MemoryBlockStore.save(personaId, 'long', content));
      case 'set_short':
        return _ToolResult(
            true, await MemoryBlockStore.save(personaId, 'short', content));
      case 'get_long':
        return _ToolResult(true, await MemoryBlockStore.get(personaId, 'long'));
      case 'get_short':
        return _ToolResult(
            true, await MemoryBlockStore.get(personaId, 'short'));
      case 'clear_long':
        await MemoryBlockStore.save(personaId, 'long', '');
        return const _ToolResult(true, '长期记忆已清空');
      case 'clear_short':
        await MemoryBlockStore.save(personaId, 'short', '');
        return const _ToolResult(true, '短期记忆已清空');
      case 'status': {
        final c = await MemoryBlockStore.count(personaId);
        return _ToolResult(
          true,
          '长期记忆 ${c['long']} 字 / 短期记忆 ${c['short']} 字'
          '（预算 500 字）',
        );
      }
      default:
        return _ToolResult(
          false,
          'manage_memory_block 参数：action=set_long（要 content）/set_short'
          '（要 content）/get_long/get_short/clear_long/clear_short/status',
        );
    }
  }

  /// 工具执行：manage_tool_cache（工具工作缓存，男主自管免审批）
  /// 8-08 02:1x 用户："留个位置给他工具使用的缓存，太多了就让他写进
  /// 他的管记忆的地方让他整理"——干活中间数据放这，干完整理进记忆后 clear。
  Future<_ToolResult> _executeManageToolCache(Map<String, dynamic> args) async {
    final personaId = _state.personaId ?? '';
    final action = args['action']?.toString() ?? '';
    switch (action) {
      case 'add':
        final content = args['content']?.toString() ?? '';
        final r = await ToolCacheStore.add(personaId, content);
        return _ToolResult(true, r);
      case 'clear':
        final r = await ToolCacheStore.clear(personaId);
        return _ToolResult(true, r);
      case 'status':
        final n = await ToolCacheStore.count(personaId);
        final t = ToolCacheStore.text(personaId);
        return _ToolResult(
          true,
          n == 0 ? '工具缓存是空的（add 记入）' : '工具缓存 $n 条：\n$t',
        );
      case 'view':
        // 8-11 20:1x（用户：工具编号查详细记录）——报 T 编号查具体条目
        final no = args['no']?.toString() ?? args['编号']?.toString() ?? '';
        if (no.isEmpty) {
          return _ToolResult(false, 'manage_tool_cache 动作=view 要带 编号（如 编号=C1）');
        }
        final v = await ToolCacheStore.view(personaId, no);
        return _ToolResult(true, v);
      default:
        return _ToolResult(
          false,
          'manage_tool_cache 参数：action=add（要 content）/clear/status/'
          'view（要 编号=C1）',
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
      '临时记忆': 'manage_pad',
      'manage_tool_cache': '整理工具缓存',
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

  /// 当前用户设定（用户 8-06 18:24 设定版本管理·用户框）——独立注入
  /// SystemTemplate【用户状态】段（8-08 22:5x 用户：之前误拼进男主设定段）。
  /// 所有男主对话轮（正常/重写/工具轮）都带，男主知道用户档案不"性情大变"。
  String _currentUserSetting() {
    try {
      final pid = _state.personaId;
      if (pid == null || pid.isEmpty) return '';
      final book = SettingVersionStore.cached(_settingPid());
      if (book == null) return '';
      final user = book.currentUser.trim();
      if (user.isEmpty) return '';
      return '【用户设定·当前版】（分段，改哪段用 update_setting 的 tag 定位）\n'
          '${_formatSectionsNumbered(user)}';
    } catch (_) {
      return '';
    }
  }

  /// 当前 persona 的初始设定（用户写的人设），随每轮请求进 system
  String _currentPersonaPrompt() {
    try {
      var prompt = _state.persona?.prompt ?? '';
      // 8-06 18:24 用户：设定版本管理 —— prompt 附加男主设定（分段，改哪段用 tag 定位）
      // 8-12 18:4x（用户：演变史不做成额外功能——版本记录本身就有：
      // 每版全文/变更用 query_setting_history、指定版本段落用
      // query_setting_version 查，男主定位修改直接查，不注入摘要块）
      final pid = _state.personaId;
      if (pid != null && pid.isNotEmpty) {
        final book = SettingVersionStore.cached(_settingPid());
        if (book != null) {
          final male = book.currentMale.trim();
          if (male.isNotEmpty) {
            prompt +=
                '\n\n【男主设定·当前版】（分段，改哪段用 update_setting 的 tag 定位）\n'
                '${_formatSectionsNumbered(male)}';
          }
          // 8-08 22:5x（用户：用户设定不该拼进男主设定段）：用户设定拆走——
          // 独立走 userProfile 参数 → SystemTemplate【用户状态】段（见
          // _currentUserSetting），不再混在【男主设定】里
          // 8-12 19:0x（用户：人设区就是男主设定+用户设定，用户写的，
          // 不要额外写东西）——这里只拼用户写的内容，不加任何系统提示语。
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

/// 8-07 19:15：多气泡逐条落库记录（链式 parent 还原气泡顺序 + spans 样式）
class _BubbleRow {
  final String id;
  final String text;
  final String? spansJson;
  const _BubbleRow(this.id, this.text, this.spansJson);
}
