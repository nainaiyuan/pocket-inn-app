import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'working_pad_store.dart';

/// FlowStore —— 男主流程（Flow 层，8-06 23:55 用户定稿）
///
/// 男主做长任务（如测所有工具）时先立流程：goal + steps，然后一条条执行。
/// 流程执行中：用户消息只收集（PendingQueueStore）不传给男主，不打扰执行；
/// 用户可点"⏹ 停止"打断 → status=stopped → 系统事件告诉男主
/// "流程停在哪、用户说了什么"，男主决定继续（resume）还是先回复用户。
///
/// 状态机：running → (next 推进) → running … → finish(done) / cancel(cancelled)
///         running → stop(stopped) → resume(running) / finish / cancel
///         running → 用户插话 pauseByUser(paused_by_user) → resume / update / cancel
///           （8-08 19:0x：插话=暂挂≠stop；男主回完用户后判断继续/修改/取消）
///
/// 8-08 15:2x 步骤状态机升级（设计文档三，GPT 10 问 3/4/5/8）：
/// - steps 从字符串数组升级为对象数组：
///   {name, status: pending|running|done|failed, result, doneType, doneCondition,
///    summary, nextAction, toolsUsed: {toolName: {count, ok, brief, at}}}
/// - 旧数据（字符串数组）读取时自动升级，写回保持新格式
/// - next/finish 管家机械校验当前步完成条件（doneType 三类型），不满足不推进
/// - ai_output / user_confirm 步骤：男主结构化提交 result 才算完成（不从文本抽取）
/// - autoAdvance：工具轮结束管家检查当前步完成条件，明确满足才自动推进
/// - taskList()：目标对照清单（✅已完成/☐未完成/本步已用工具），注入状态块
///
/// 男主自管（免审批），管家只做存储和机械校验，不做语义判断。
class FlowStore {
  /// 8-07 21:48 用户：日志增强（男主 query_logs 自查流程问题）。
  /// 纯 Dart 库不直接依赖 DebugLogger（Flutter），用可注入钩子——
  /// chat_page 初始化时注入，测试环境不注入也能跑。
  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) =>
      logSink?.call(tag, msg);


  FlowStore._();

  static const String _prefix = 'flow_';

  /// 8-07 19:5x 用户：设定弹窗打开状态（chat_page 弹窗打开/关闭时设置）——
  /// 弹窗会话走独立通道，但主对话的状态感知要知道"当前在走流程（弹窗）"
  static bool settingDialogActive = false;

  /// 流程目标（【当前情况】状态行用，简短）
  static String? goalOf(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    final g = f['goal']?.toString().trim() ?? '';
    return g.isEmpty ? null : g;
  }


  static Map<String, dynamic>? _memCache;

  static String _key(String personaId) => '$_prefix$personaId';

  /// 单例缓存读（warm 后同步读，避免每轮 await）
  static void warm(String personaId) {
    if (personaId.isEmpty) return;
    _load(personaId);
  }

  static Future<void> _load(String personaId) async {
    if (personaId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(personaId));
      if (raw != null && raw.isNotEmpty) {
        final parsed = jsonDecode(raw) as Map<String, dynamic>;
        // 8-08 15:2x：旧数据（字符串 steps）读取时升级为对象
        _upgradeSteps(parsed);
        _memCache = parsed;
      } else {
        _memCache = null;
      }
    } catch (e) {
      _memCache = null;
    }
  }

  /// 旧数据兼容：字符串数组 steps → 对象数组（status 按 currentStep 推断）
  static void _upgradeSteps(Map<String, dynamic> f) {
    final raw = f['steps'];
    if (raw is! List || raw.isEmpty) return;
    final first = raw.first;
    if (first is Map) return; // 已是对象
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    final steps = <Map<String, dynamic>>[];
    for (var i = 0; i < raw.length; i++) {
      steps.add({
        'name': raw[i].toString(),
        'status': i < cur
            ? 'done'
            : (i == cur ? 'running' : 'pending'),
        'result': null,
        'doneType': 'tool_result',
        'doneCondition': null,
        'toolsUsed': <String, dynamic>{},
      });
    }
    f['steps'] = steps;
  }

  static Future<Map<String, dynamic>?> _read(String personaId) async {
    if (personaId.isEmpty) return null;
    await _load(personaId);
    return _memCache;
  }

  static Future<void> _write(String personaId, Map<String, dynamic>? flow) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    if (flow == null) {
      await p.remove(_key(personaId));
      _memCache = null;
    } else {
      await p.setString(_key(personaId), jsonEncode(flow));
      _memCache = flow;
    }
  }

  /// 当前流程（无则 null）
  static Future<Map<String, dynamic>?> get(String personaId) =>
      _read(personaId);

  /// 是否有正在跑的流程（running/stopped/paused_by_user 都算"有流程"）
  static bool isActive(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return false;
    final s = f['status']?.toString() ?? '';
    return s == 'running' || s == 'stopped' || s == 'paused_by_user';
  }

  /// 是否执行中（running：用户消息只收集不传）
  static bool isRunning(String personaId) {
    final f = _memCache;
    return f != null && (f['status']?.toString() ?? '') == 'running';
  }

  /// 步骤对象化：String → {name, doneType: tool_result}；
  /// Map → {name: 必填, doneType/doneCondition 可选}
  static Map<String, dynamic> _stepFrom(dynamic s) {
    if (s is Map) {
      final name = (s['name'] ?? s['text'] ?? '').toString().trim();
      final doneType = ['tool_result', 'ai_output', 'user_confirm']
              .contains(s['doneType'])
          ? s['doneType'].toString()
          : 'tool_result';
      return {
        'name': name,
        'status': 'pending',
        'result': null,
        'doneType': doneType,
        'doneCondition': s['doneCondition']?.toString().trim(),
        'toolsUsed': <String, dynamic>{},
      };
    }
    return {
      'name': s.toString().trim(),
      'status': 'pending',
      'result': null,
      'doneType': 'tool_result',
      'doneCondition': null,
      'toolsUsed': <String, dynamic>{},
    };
  }

  /// 立流程：{goal, steps: [..]} → running，currentStep=0
  /// steps 元素：字符串步骤名，或 {name, doneType, doneCondition} 对象
  static Future<String> create(
      String personaId, String goal, List<dynamic> steps) async {
    if (personaId.isEmpty) return '参数错误';
    if (goal.trim().isEmpty) return 'goal 不能为空';
    final clean = <Map<String, dynamic>>[];
    for (final s in steps) {
      final step = _stepFrom(s);
      if (step['name'].toString().isNotEmpty) clean.add(step);
    }
    if (clean.isEmpty) return 'steps 至少要一步';
    final flow = <String, dynamic>{
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'goal': goal.trim(),
      'steps': clean,
      'currentStep': 0,
      'status': 'running',
      'stoppedNote': '',
      'createdAt': DateTime.now().toIso8601String(),
    };
    flow['steps'][0]['status'] = 'running';
    await _write(personaId, flow);
    _log('流程', '📋 create 「$goal」${clean.length}步（步骤对象化）');
    return '流程已立：$goal（${clean.length} 步，从第 1 步开始）';
  }

  /// 8-07 00:1x 用户：用户提了新要求 → 男主更新流程（改目标/步骤），从头执行
  static Future<String> update(String personaId,
      {String? goal, List<dynamic>? steps}) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程（create 先立）';
    if (goal != null && goal.trim().isNotEmpty) {
      f['goal'] = goal.trim();
    }
    if (steps != null) {
      final clean = <Map<String, dynamic>>[];
      for (final s in steps) {
        final step = _stepFrom(s);
        if (step['name'].toString().isNotEmpty) clean.add(step);
      }
      if (clean.isEmpty) return 'steps 至少要一步';
      f['steps'] = clean;
    }
    f['currentStep'] = 0;
    final steps2 = _stepsOf(f);
    if (steps2.isNotEmpty) steps2[0]['status'] = 'running';
    // 暂停/取消中更新 → 回到执行中
    if (f['status'] == 'stopped' || f['status'] == 'cancelled') {
      f['status'] = 'running';
    }
    f['stoppedNote'] = '';
    await _write(personaId, f);
    return '流程已更新：${f['goal']}（${steps2.length} 步，从头开始）';
  }

  /// 记录工具使用（每执行一个工具自动调，8-08 15:2x）
  /// 写进当前步 toolsUsed[toolName] = {count, ok, brief, at}
  static Future<void> recordToolUse(String personaId, String toolName,
      {required bool ok, String? brief}) async {
    if (personaId.isEmpty || toolName.isEmpty) return;
    final f = await _read(personaId);
    if (f == null || f['status'] != 'running') return;
    final steps = _stepsOf(f);
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    if (cur < 0 || cur >= steps.length) return;
    final step = steps[cur];
    final toolsUsed = (step['toolsUsed'] as Map?) ?? <String, dynamic>{};
    final prev = (toolsUsed[toolName] as Map?) ?? <String, dynamic>{};
    toolsUsed[toolName] = {
      'count': ((prev['count'] as num?)?.toInt() ?? 0) + 1,
      'ok': ok,
      'brief': brief ?? (prev['brief']?.toString() ?? ''),
      'at': DateTime.now().toIso8601String(),
    };
    step['toolsUsed'] = toolsUsed;
    await _write(personaId, f);
  }

  /// 机械判定某步是否满足完成条件（doneType 三类型，GPT 13:20 定案）
  /// 返回 (是否完成, 未完成原因)
  static (bool, String) _checkStepDone(Map<String, dynamic> step) {
    final doneType = (step['doneType'] ?? 'tool_result').toString();
    final toolsUsed = (step['toolsUsed'] as Map?) ?? <String, dynamic>{};
    final hasOkTool = toolsUsed.values.any(
        (v) => v is Map && v['ok'] == true);
    final result = (step['result'] ?? '').toString().trim();
    switch (doneType) {
      case 'ai_output':
        if (result.isEmpty) {
          return (
            false,
            '该步是产出类型（ai_output），需提交产出：manage_flow next 时带 '
                '{"result":"这一步的产出"}(+可选 summary/next_action)'
          );
        }
        return (true, '');
      case 'user_confirm':
        if (result.isEmpty) {
          return (
            false,
            '该步需要用户确认（user_confirm），需提交确认结果：manage_flow next 时带 '
                '{"result":"用户确认内容"}'
          );
        }
        return (true, '');
      case 'tool_result':
      default:
        if (!hasOkTool) {
          return (false, '该步还没成功执行任何工具（工具结果需成功才算完成）');
        }
        return (true, '');
    }
  }

  /// 当前步是否满足完成条件（同步读缓存，工具轮结束后 autoAdvance 用）
  static (bool, String) checkCurrentDone(String personaId) {
    final f = _memCache;
    if (f == null || f['status'] != 'running') return (false, '流程不在执行中');
    final steps = _stepsOf(f);
    if (steps.isEmpty) return (false, '没有步骤');
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    if (cur < 0 || cur >= steps.length) return (false, '步骤索引越界');
    return _checkStepDone(steps[cur]);
  }

  /// 完成当前步，推进到下一步（8-08 15:2x：带机械校验 + 结构化提交）
  /// [result]/[summary]/[nextAction]：ai_output/user_confirm 步骤的结构化提交
  /// （GPT 13:20 定案：不从文本抽取，男主显式提交）
  static Future<String> next(String personaId,
      {String? result, String? summary, String? nextAction}) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程（create 先立）';
    if (f['status'] != 'running') return '流程当前不在执行中（${f['status']}）';
    final steps = _stepsOf(f);
    if (steps.isEmpty) return '没有步骤';
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    if (cur < 0 || cur >= steps.length) return '步骤索引越界';
    final step = steps[cur];
    // 结构化提交：result 先存入（即使校验不过也不丢）
    if (result != null && result.trim().isNotEmpty) {
      step['result'] = result.trim();
    }
    if (summary != null && summary.trim().isNotEmpty) {
      step['summary'] = summary.trim();
    }
    if (nextAction != null && nextAction.trim().isNotEmpty) {
      step['nextAction'] = nextAction.trim();
    }
    // 机械校验
    final (ok, reason) = _checkStepDone(step);
    if (!ok) {
      await _write(personaId, f);
      return '第 ${cur + 1} 步还没完成：$reason。别跳过——先完成这步再 next；'
          '如果步骤设计不合理可 update 调整。';
    }
    step['status'] = 'done';
    if (cur + 1 >= steps.length) {
      f['currentStep'] = cur + 1;
      await _write(personaId, f);
      return '第 ${cur + 1} 步完成（最后一步），调 finish 结束流程';
    }
    f['currentStep'] = cur + 1;
    steps[cur + 1]['status'] = 'running';
    await _write(personaId, f);
    _log('流程', '▶ next 第${cur + 1}→${cur + 2}步（${_stepName(step)}→${_stepName(steps[cur + 1])}）');
    return '第 ${cur + 1} 步完成 ✅，现在第 ${cur + 2} 步：${_stepName(steps[cur + 1])}';
  }

  /// autoAdvance（GPT 13:20 定案：默认开，严格判定）：
  /// 工具轮结束后管家检查当前步完成条件，只在明确满足时自动推进。
  /// 返回 null=没推进；'__ALL_DONE__'=全部完成；其他=推进提示文本（注入下一轮）。
  /// 8-08 18:4x（用户反馈："执行完流程，页面上的'男主正在执行流程'不消失，
  /// 还要手动停"）：最后一步完成时直接 status=done 自动收尾——
  /// 流程做完就是做完，不再等男主手动 finish（它的 finish 轮还老撞错）。
  /// finish 幂等兜底：之后男主再调 finish 返回"已结束"提示，不重复沉淀。
  static Future<String?> autoAdvance(String personaId) async {
    final f = await _read(personaId);
    if (f == null || f['status'] != 'running') return null;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    if (cur < 0 || cur >= steps.length) return null;
    final (ok, _) = _checkStepDone(steps[cur]);
    if (!ok) return null;
    steps[cur]['status'] = 'done';
    if (cur + 1 >= steps.length) {
      f['currentStep'] = cur + 1;
      f['status'] = 'done'; // 8-08 18:4x：全部步骤完成 = 流程自动收尾
      f['stoppedNote'] = '';
      await _write(personaId, f);
      _log('流程', '✅ autoAdvance：全部步骤完成，流程自动收尾（done，不再等手动 finish）');
      await _sinkToPad(personaId, f, done: true);
      return '__ALL_DONE__';
    }
    f['currentStep'] = cur + 1;
    steps[cur + 1]['status'] = 'running';
    await _write(personaId, f);
    _log('流程', '▶ autoAdvance 第${cur + 1}→${cur + 2}步（${_stepName(steps[cur + 1])}）');
    return '第 ${cur + 1} 步完成 ✅（自动推进），现在第 ${cur + 2} 步：'
        '${_stepName(steps[cur + 1])}';
  }

  /// 流程完成（8-07 19:5x：完成时流程要点自动沉淀进便签——
  /// 男主流程结束不能忘了流程里需要记住的东西）
  /// 8-08 17:2x（日志复盘：男主 70 秒内重复调 finish 3 次）：幂等防御——
  /// 已结束的流程重复 finish 直接告知，不再重复沉淀便签
  static Future<String> finish(String personaId) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    if (f['status'] == 'done' || f['status'] == 'cancelled') {
      return '流程已经结束（${f['status'] == 'done' ? '已完成' : '已取消'}），无需重复 finish';
    }
    final steps = _stepsOf(f);
    f['status'] = 'done';
    f['stoppedNote'] = '';
    await _write(personaId, f);
    _log('流程', '✅ finish 流程完成');
    await _sinkToPad(personaId, f, done: true);
    return '流程完成：${f['goal']}（${steps.length} 步全部做完）';
  }

  /// 取消流程（取消也沉淀：男主知道流程停在哪，便签里的要点不丢）
  static Future<String> cancel(String personaId) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    f['status'] = 'cancelled';
    f['stoppedNote'] = '';
    await _write(personaId, f);
    _log('流程', '⏹ cancel 流程取消');
    await _sinkToPad(personaId, f, done: false);
    return '流程已取消：${f['goal']}';
  }

  /// 流程结束沉淀：要点写进男主便签（WorkingPadStore），
  /// 并提醒他主对话待回复不会丢（流程结束要接上）
  static Future<void> _sinkToPad(String personaId, Map<String, dynamic> f,
      {required bool done}) async {
    try {
      final now = DateTime.now();
      final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      final steps = _stepsOf(f);
      await WorkingPadStore.append(personaId,
          '[$hhmm] 流程${done ? '已完成' : '已取消'}：${f['goal']}（${steps.length} 步）。'
          '便签里记的要点保留；她主对话的待回复也还挂着，处理完流程记得接上。');
    } catch (_) {
      // 沉淀失败不影响流程主流程
    }
  }

  /// 用户打断（停止按钮）：running → stopped，记下用户消息
  static Future<String> stop(String personaId, {String? userMessages}) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    if (f['status'] != 'running') return '流程不在执行中（${f['status']}）';
    f['status'] = 'stopped';
    f['stoppedNote'] = userMessages ?? '';
    await _write(personaId, f);
    return '已停止：${f['goal']}';
  }

  /// 用户插话 → 流程暂挂（8-08 19:0x，GPT 18:59 + 用户 19:04 定稿）。
  /// 和 stop 的区别：
  /// - stop（⏹按钮）= 用户明确停止，男主决定继续/收尾/取消；
  /// - pauseByUser（插话）= 暂挂（checkpoint=currentStep 天然保存），
  ///   男主回完用户后判断：resume（闲聊/没改需求）/ update（改了需求）/
  ///   cancel（她明确说"不要了"）。拿不准默认 resume，绝不乱 cancel。
  static Future<String> pauseByUser(String personaId,
      {String? userMessage}) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    if (f['status'] != 'running') {
      return '流程不在执行中（${f['status']}），无需暂挂';
    }
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    f['status'] = 'paused_by_user';
    f['stoppedNote'] = userMessage ?? '';
    await _write(personaId, f);
    _log('流程', '⏸ pauseByUser 用户插话暂挂（checkpoint=第 ${cur + 1} 步）');
    return '已暂挂：${f['goal']}（她插话了，你回完她后判断继续/修改/取消）';
  }

  /// 被打断后继续：stopped/paused_by_user → running
  static Future<String> resume(String personaId) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    if (f['status'] != 'stopped' && f['status'] != 'paused_by_user') {
      return '流程不在暂停状态（${f['status']}）';
    }
    f['status'] = 'running';
    f['stoppedNote'] = '';
    await _write(personaId, f);
    _log('流程', '▶ resume 继续流程');
    final steps = _stepsOf(f);
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    return '继续流程：${f['goal']}，第 ${cur + 1} 步：${_stepName(steps[cur])}';
  }

  /// 8-08 19:0x：测试清理（修复验证中心用例用）——删除指定人的流程
  static Future<void> clear(String personaId) => _write(personaId, null);

  /// 步骤对象数组（旧字符串自动升级）
  static List<Map<String, dynamic>> _stepsOf(Map<String, dynamic> f) {
    final raw = f['steps'];
    if (raw is List) {
      final out = <Map<String, dynamic>>[];
      for (final e in raw) {
        if (e is Map) {
          out.add(Map<String, dynamic>.from(e));
        } else {
          out.add({
            'name': e.toString(),
            'status': 'pending',
            'result': null,
            'doneType': 'tool_result',
            'doneCondition': null,
            'toolsUsed': <String, dynamic>{},
          });
        }
      }
      if (out.isNotEmpty) f['steps'] = out; // 升级写回
      return out;
    }
    return <Map<String, dynamic>>[];
  }

  static String _stepName(Map<String, dynamic> s) =>
      (s['name'] ?? '').toString();

  /// 简版摘要（UI 停止条用）：'「goal」第 2/5 步'；无流程返回 null
  static String? summary(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    final goal = f['goal']?.toString() ?? '';
    return '「$goal」第 ${cur + 1}/${steps.length} 步';
  }

  /// 目标对照清单（设计六，GPT 13:20 定案：管家机械生成，不靠 LLM 记忆）：
  /// 目标 + ✅已完成/▶当前/☐未完成 + 本步已用工具 + 完成条件
  static String? taskList(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    final status = f['status']?.toString() ?? '';
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    final sb = StringBuffer();
    sb.writeln('初始目标：${f['goal']}');
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final st = s['status']?.toString() ?? 'pending';
      final name = _stepName(s);
      final result = (s['result'] ?? '').toString().trim();
      final mark = st == 'done'
          ? '✅'
          : (st == 'running' || (i == cur && status == 'running')
              ? (status == 'paused_by_user' ? '⏸' : '▶')
              : '☐');
      var line = '$mark 第${i + 1}步 $name';
      if (st == 'done' && result.isNotEmpty) line += '（结果：$result）';
      sb.writeln(line);
    }
    // 本步已用工具（state_hint 数据源）
    if (cur >= 0 && cur < steps.length) {
      final step = steps[cur];
      final toolsUsed = (step['toolsUsed'] as Map?) ?? <String, dynamic>{};
      if (toolsUsed.isNotEmpty) {
        sb.writeln('本步已用工具：');
        toolsUsed.forEach((name, v) {
          final info = v is Map ? v : const <String, dynamic>{};
          final count = info['count']?.toString() ?? '?';
          final ok = info['ok'] == true ? '✅' : '❌';
          final brief = (info['brief'] ?? '').toString();
          sb.writeln('  $ok $name ×$count${brief.isNotEmpty ? '（$brief）' : ''}');
        });
      }
      final cond = (step['doneCondition'] ?? '').toString().trim();
      final doneType = (step['doneType'] ?? 'tool_result').toString();
      if (cond.isNotEmpty) {
        sb.writeln('本步完成条件：$cond');
      } else {
        final condText = doneType == 'ai_output'
            ? '提交产出（next 时带 result）'
            : doneType == 'user_confirm'
                ? '用户确认（next 时带 result）'
                : '成功执行工具';
        sb.writeln('本步完成条件：$condText');
      }
    }
    // 目标对照提示（机械）
    final allDone = steps.every((s) => s['status'] == 'done');
    if (allDone && status == 'running') {
      sb.writeln('对照检查：所有步骤已完成 → 调 finish 收尾');
    } else if (status == 'running') {
      sb.writeln('对照检查：目标是否已实现？未实现就继续干（基于已有结果推进）；'
          '已实现就调 finish 收尾');
    }
    return sb.toString();
  }

  /// 注入文本（每轮 prompt，状态块【当前流程】用）：有流程才返回
  static String? text(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    final status = f['status']?.toString() ?? '';
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    final curIdx = cur.clamp(0, steps.length - 1);
    final sb = StringBuffer();
    sb.writeln('目标：${f['goal']}');
    sb.writeln('状态：${_statusText(status)}');
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final st = s['status']?.toString() ?? 'pending';
      final name = _stepName(s);
      final mark = st == 'done'
          ? '✅'
          : (st == 'running' || i == curIdx
              ? (status == 'running' ? '▶ 正在做' : '⏸ 停在这')
              : '☐');
      sb.writeln('$mark ${i + 1}. $name');
    }
    if ((status == 'stopped' || status == 'paused_by_user') &&
        (f['stoppedNote']?.toString() ?? '').isNotEmpty) {
      sb.writeln('（她打断时说了：${f['stoppedNote']}）');
    }
    // 8-08 19:0x：插话暂挂 → 明确判断规则（用户 19:04：不能让男主乱取消）
    if (status == 'paused_by_user') {
      sb.writeln('（她插话暂挂了流程。你判断：她只是闲聊/没改需求 → manage_flow '
          'resume 继续原流程；她提了新需求/要查东西 → manage_flow update 修改流程；'
          '她明确说"不要了/取消" → 才 manage_flow cancel；拿不准 → 默认 resume，'
          '绝不因为她随便一句话就取消整个流程）');
    }
    // 8-07 21:2x 用户：男主以为流程自动推进 → 明确告知要手动调 next
    // 8-08 15:2x：autoAdvance 默认开，next 主要给 ai_output/user_confirm 步骤
    if (status == 'running' || status == 'stopped') {
      sb.writeln('（工具类步骤工具成功会自动推进；产出/确认类步骤调 manage_flow next '
          '并带 result 提交；全部做完调 finish；中途要停调 cancel）');
    }
    return sb.toString();
  }

  static String _statusText(String s) {
    switch (s) {
      case 'running':
        return '执行中';
      case 'stopped':
        return '被她打断了，等她决定';
      case 'paused_by_user':
        return '她插话暂挂了，等你判断继续/修改/取消';
      case 'done':
        return '已完成';
      case 'cancelled':
        return '已取消';
      default:
        return s;
    }
  }
}
