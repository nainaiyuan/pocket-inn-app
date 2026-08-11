import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// ChatFlowStore —— 对话流程（8-09 18:1x 用户设计定稿，v2 状态机版）
///
/// 每次对话 = 一个流程，跟长任务流程（FlowStore）同款结构：
///   goal + steps（每条用户消息 = 一步）+ status + currentStep
///
/// 全自动（男主零操作）：
/// - 用户发消息 → 自动立流程/追加步骤（她随时插话 = 追加步骤）
/// - 男主调工具 → 挂到当前步（toolsUsed：{count, ok, brief}）
/// - 男主回复 → 消条目：回复带标注（回#N、#M）→ 精确消多条（合并消，
///   "回一和二一起做"）；无标注 → FIFO 消最老一条（不猜，系统不猜他回了哪几条）
/// - 全部消完 → 流程自动 done
///
/// 每次唤醒注入完整清单：goal + ✅已回/▶当前/☐没回 + 当前步工具链 +
/// **决策点**（查了没找到 → 明确提示：继续查还是回复结束）。
/// 男主看到清单就不会弄混（知道还欠几条）、不会漏（☐ 挂着）、
/// 不会重复回（✅ 已消 + 无新消息还说话会收到警告）。
///
/// 与 FlowStore 分工：FlowStore = 长任务（男主主动立、卡片、可停止）；
/// ChatFlowStore = 每次对话的轻量流程（自动立、自动结束、不锁用户消息——
/// 用户随时说话=插话=追加步骤）。
class ChatFlowStore {
  ChatFlowStore._();

  static const String _prefix = 'chatflow_';
  static const String _counterKey = 'chatflow_counter';

  static Map<String, dynamic>? _memCache;

  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) => logSink?.call(tag, msg);

  static String _key(String personaId) => '$_prefix$personaId';

  /// 流程编号（8-09 18:33 用户设计）：每个流程一个编号（流程#N），
  /// 男主/用户可引用（合并、插话判断）。计数器持久化，全局自增。
  /// 8-11 20:1x（用户 20:15 拍板）：大流程编号 = T1/T2…（GPT 参考，
  /// Task 任务编号）——和消息 M1/M2、工具 C1/C2 三套字母完全不同，不混。
  static Future<String> _nextFlowNo() async {
    try {
      final p = await SharedPreferences.getInstance();
      final n = p.getInt(_counterKey) ?? 0;
      await p.setInt(_counterKey, n + 1);
      return 'T$n';
    } catch (_) {
      return 'T${DateTime.now().millisecondsSinceEpoch % 100000}';
    }
  }

  // ---- 排队流程（8-12 03:3x 用户：插话自己生成 T2 放工作区 T1 下面
  // 排队，不放待回复；处理完 T1 自动轮到）----
  // _queueCache：内存缓存（buildText 同步读）；SharedPreferences 持久化
  static final Map<String, List<Map<String, dynamic>>> _queueCache = {};

  static String _queueKey(String personaId) => 'chat_flow_queue_$personaId';

  static Future<List<Map<String, dynamic>>> _readQueue(String personaId) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_queueKey(personaId));
      if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _writeQueue(
      String personaId, List<Map<String, dynamic>> q) async {
    _queueCache[personaId] = q;
    final p = await SharedPreferences.getInstance();
    if (q.isEmpty) {
      await p.remove(_queueKey(personaId));
    } else {
      await p.setString(_queueKey(personaId), jsonEncode(q));
    }
  }

  /// 排队流程（读内存缓存，buildText 同步用）
  static List<Map<String, dynamic>> queuedFlows(String personaId) =>
      _queueCache[personaId] ?? const <Map<String, dynamic>>[];

  static Future<void> _enqueue(
      String personaId, Map<String, dynamic> flow) async {
    final q = await _readQueue(personaId);
    q.add(flow);
    await _writeQueue(personaId, q);
  }

  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(personaId));
      if (raw != null && raw.isNotEmpty) {
        _memCache = jsonDecode(raw) as Map<String, dynamic>;
      } else {
        _memCache = null;
      }
      _queueCache[personaId] = await _readQueue(personaId);
    } catch (_) {
      _memCache = null;
    }
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

  static List<Map<String, dynamic>> _stepsOf(Map<String, dynamic> f) {
    final raw = f['steps'];
    if (raw is List) {
      return raw.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return <Map<String, dynamic>>[];
  }

  static bool _isTerminal(Map<String, dynamic>? f) {
    if (f == null) return true;
    final s = f['status']?.toString() ?? '';
    return s == 'done' || s == 'cancelled';
  }

  // ---- 写入（管家机械活，男主零操作）----

  /// 用户消息 → 立流程/追加步骤
  /// 8-11 18:3x（用户 18:30 定义模型）：分两种——
  /// - **没在处理**（无 running 流程）：用户的话 = 新的大流程（当前工作区）；
  ///   男主没被唤醒时连发的多条 = 未处理区，醒来后组织进大流程（平行）
  /// - **处理中**（有 running 流程）：用户插话 = **直接进大流程**（M2/M3…
///   平行待办，男主判断 补充/修改/插入/不做了）。
/// - **男主说 end_TN 时的插话**（手速快连发，结束标签后到）：拆成新流程
///   **排队**（工作区当前流程下面，处理完自动轮到）——8-12 03:4x 用户澄清
  static Future<void> feedUser(String personaId, String text) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (!_isTerminal(f) && f!['status'] == 'running') {
      final steps = _stepsOf(f);
      final allDone =
          steps.isNotEmpty && steps.every((s) => s['status'] == 'done');
      // 8-12 04:5x（用户：男主已回完所有消息但还没说结束，下一句不该再
      // 叠成 M2——"T0 无限叠加到 T一亿"；编号要唯一，一轮对话一个流程）：
      // 全部处理完 + 男主已回 → 新消息 = **新流程排队**（T+N，唯一编号），
      // 等男主 end_T0 + 摘要归档后自动轮到（检查点⑤唤醒处理下一个）。
      // 旧流程保持 running（工作区显示 ✅ 全部处理完 + 下面排队 T1）。
      // 8-12 04:5x（防 T0 无限叠步骤）：步骤超过 20 条也拆排队
      // （安全网——男主长时间没回时的连发消息不把单流程撑爆）。
      if (allDone || steps.length >= 20) {
        final flow = <String, dynamic>{
          'flowNo': await _nextFlowNo(),
          'goal': _short(text, 30),
          'status': 'pending', // 排队中（当前流程归档后轮到）
          'currentStep': 0,
          'steps': [_newStep(text, no: 1)], // 新流程第一步 = M1
          'startedAt': DateTime.now().toIso8601String(),
          'butlerNote': allDone
              ? '上个大流程已全部处理完（等你写结束标记归档），'
                  '她又有新消息，管家自动排队成新流程，处理完上面的自动轮到'
              : '当前流程待办太多（超过 20 条），新消息自动拆成排队新流程',
        };
        await _enqueue(personaId, flow);
        _log('对话流程',
            '📦 ${allDone ? '当前流程已全部处理完（等结束标记）' : '当前流程待办超 20 条'}'
            ' → 新消息排队成 ${flow['flowNo']}（不再叠 M 步骤）');
        return;
      }
      // 处理中（还有没回完的）→ 插话 = 新消息**直接进大流程**（8-11 18:3x 用户：
      // 大流程内所有消息平行，插话跟第一条平行 = M2/M3… 待办；
      // 8-12 03:4x 用户澄清：男主还没说结束时的插话 = M2（当前流程
      // 待办），只有男主说 end_TN 时的插话才拆成新流程排队）
      // 8-10 23:0x：插话步骤分配稳定编号（不挤占已有编号）
      final step = _newStep(text, no: _nextStepNo(steps));
      step['from'] = 'user_interrupt'; // 插话标记（GPT：进当前任务判断）
      steps.add(step); // 挂待办末尾，男主判断怎么处理
      f['steps'] = steps;
      await _write(personaId, f);
      _log('对话流程',
          '📥 用户插话进大流程 #${step['no']}（平行，进待办清单）：'
          '${_short(text)}（处理时男主判断 补充/修改/插入/不做了）');
      return;
    }
    // 没在处理 → 立新流程（8-09 18:33：带流程编号）
    final flow = <String, dynamic>{
      'flowNo': await _nextFlowNo(),
      'goal': _short(text, 30),
      'status': 'running',
      'currentStep': 0,
      'steps': [_newStep(text, no: 1)], // 新流程第一步 = 编号 1
      'startedAt': DateTime.now().toIso8601String(),
    };
    await _write(personaId, flow);
    _log('对话流程', '📋 立流程 #${flow['flowNo']}：「${flow['goal']}」1 步');
  }

  static Map<String, dynamic> _newStep(String text,
      {bool isReview = false, int? no}) {
    final now = DateTime.now();
    return {
      // 8-10 23:0x（用户：插话/系统步骤要有稳定标签才能消）：no = 稳定
      // 编号（创建时分配，插入新步骤不影响已有编号）；不传则时间戳兜底
      'no': no ?? now.millisecondsSinceEpoch,
      'userText': text.trim(),
      'ts': '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
      'status': 'pending',
      'tools': <String, dynamic>{}, // toolName -> {count, ok, brief}
      'reply': '',
      if (isReview) 'isReview': true, // 8-09 18:33：复核步骤（男主回复后自动挂）
    };
  }

  // ---- 步骤稳定编号（8-10 23:0x 用户：插话/系统插入的都要有标签才能消）----
  // 编号 = 步骤创建时分配的 no，插入新步骤（插话/闹钟）不影响已有编号，
  // 男主回#N 永远对应同一个步骤。旧数据（无 no）fallback 按位置 index+1。

  /// 步骤显示编号（优先 no 字段；旧数据 fallback 位置序号）
  static int _stepNo(Map<String, dynamic> step, int index) {
    final n = step['no'];
    return (n is num && n.toInt() > 0) ? n.toInt() : index + 1;
  }

  /// 按编号找步骤下标（优先 no 字段匹配；旧数据 fallback 位置）→ -1 未找到
  static int _stepIndexByNo(List<Map<String, dynamic>> steps, int no) {
    for (var i = 0; i < steps.length; i++) {
      final n = steps[i]['no'];
      if (n is num && n.toInt() == no) return i;
    }
    if (no >= 1 && no <= steps.length) return no - 1; // 兼容旧数据
    return -1;
  }

  /// 下一个稳定编号（现有最大 no + 1；全时间戳旧数据 → 按位置数+1）
  static int _nextStepNo(List<Map<String, dynamic>> steps) {
    var max = 0;
    for (var i = 0; i < steps.length; i++) {
      final n = steps[i]['no'];
      if (n is num && n.toInt() > max) {
        max = n.toInt();
      } else if (n is! num) {
        // 旧数据（时间戳 no）→ 按位置
        if (i + 1 > max) max = i + 1;
      }
    }
    return max + 1;
  }

  /// 管家分析备注 → 挂到最新用户步骤后面（8-10 用户定稿：用户说一句话，
  /// 管家分析出的记忆/习惯/情感波动等信息，插到这句话的流程步骤后面，
  /// 合并在一起做——不单独排队（不进#A）、不塞到正在处理的步骤）
  /// 8-11 03:30（用户澄清）：管家是**提醒**（同步显示在用户的话上面），
  /// 不是独立步骤——无执行中流程时丢弃（提醒必须挂在步骤上）
  static Future<void> feedButlerNote(String personaId, String text) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return;
    final last = steps.last;
    final notes =
        (last['butlerNotes'] as List?)?.cast<Map<String, dynamic>>() ?? <Map<String, dynamic>>[];
    final now = DateTime.now();
    notes.add({
      'ts': '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
      'text': text.trim(),
    });
    last['butlerNotes'] = notes;
    await _write(personaId, f);
    _log('对话流程', '📎 管家备注挂步骤 ${steps.length}：${_short(text)}');
  }

  /// 闹钟/系统事件触发 → 插到**当前处理步骤的后面**作为下一个步骤
  /// （8-10 用户定稿：定时任务到点提醒男主，插到当前的话那里，
  /// 就是当前在处理的步骤的后面，作为下一个步骤；无流程则立新流程）
  static Future<void> insertButlerStep(String personaId, String text) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    final steps0 =
        (f == null || f.isEmpty) ? <Map<String, dynamic>>[] : _stepsOf(f);
    final step = _newStep(text,
        no: steps0.isEmpty ? 1 : _nextStepNo(steps0)); // 稳定编号
    step['from'] = 'butler'; // 来源标记：管家插入（非用户消息）
    if (!_isTerminal(f) && f!['status'] == 'running') {
      final steps = _stepsOf(f);
      if (steps.isEmpty) {
        f['steps'] = [step];
        await _write(personaId, f);
        return;
      }
      // 当前步骤 = 第一个未消步骤；全消 → 插末尾
      var cur = -1;
      for (var i = 0; i < steps.length; i++) {
        if (steps[i]['status'] != 'done') {
          cur = i;
          break;
        }
      }
      steps.insert(cur < 0 ? steps.length : cur + 1, step);
      f['steps'] = steps;
      // 8-10 19:13（用户）：男主每次只看当前步——插入的步骤推为当前，
      // 男主先处理提醒；处理完（消掉）自动回到原来的步骤
      f['currentStep'] = cur < 0 ? steps.length : cur + 1;
      await _write(personaId, f);
      _log('对话流程', '⏰ 闹钟步骤插入 #${cur + 2} 位并推为当前步：${_short(text)}');
      return;
    }
    // 无执行中流程 → 立新流程
    final flow = <String, dynamic>{
      'flowNo': await _nextFlowNo(),
      'goal': _short(text, 30),
      'status': 'running',
      'currentStep': 0,
      'steps': [step],
      'startedAt': DateTime.now().toIso8601String(),
    };
    await _write(personaId, flow);
    _log('对话流程', '⏰ 闹钟立新流程 #${flow['flowNo']}：「${flow['goal']}」');
  }

  /// 工具执行 → 挂到步骤（8-09 18:4x 改：挂载点 = 第一个未消步骤；
  /// 全部已消 → 挂最后一步。支持"先回复再干活"：男主回复消完条目后
  /// 继续调工具，工具挂到最后一步上，工作不会丢）
  /// 8-09 20:1x（用户实测"我喜欢猫"插话"我喜欢狗"）：挂载点跳过复核
  /// 步骤——复核是"判断完整性"不是用户消息，工具挂复核上会让男主
  /// 看到复核步骤带"查了没找到"更混乱。优先挂第一个未消真实步骤；
  /// 只有复核 pending → 挂复核（男主复核阶段补充干活）；全消 → 挂最后一步。
  static Future<void> feedTool(String personaId, String toolName,
      {required bool ok, String? brief, String? flowNo}) async {
    if (personaId.isEmpty || toolName.isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
    // 8-12 02:4x（用户：T1 工作区挂着 T0 的工具结果）：工具执行是异步的，
    // 结果回来时流程可能已切换（旧流程结束/插话拆新流程）→ 校验工具
    // 执行时的流程编号，不匹配不挂（结果已在上下文工具消息里，男主
    // 看得到；避免串到新流程步骤上）
    if (flowNo != null && (f['flowNo']?.toString() != flowNo)) return;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return;
    var target = -1;
    // 8-10 19:13（用户：男主每次只看当前步）——工具挂当前步
    //（男主调工具一定是为当前在做的这条）
    final curIdx = (f['currentStep'] as num?)?.toInt() ?? 0;
    if (curIdx >= 0 &&
        curIdx < steps.length &&
        steps[curIdx]['status'] != 'done') {
      target = curIdx;
    }
    if (target < 0) {
      for (var i = 0; i < steps.length; i++) {
        if (steps[i]['status'] != 'done' && steps[i]['isReview'] != true) {
          target = i;
          break;
        }
      }
    }
    if (target < 0) {
      for (var i = 0; i < steps.length; i++) {
        if (steps[i]['status'] != 'done') {
          target = i; // 只有复核 pending → 挂复核
          break;
        }
      }
    }
    if (target < 0) target = steps.length - 1; // 全消完 → 挂最后一步
    final step = steps[target];
    final tools = _asMap(step['tools']);
    final prev = (tools[toolName] as Map?) ?? <String, dynamic>{};
    tools[toolName] = {
      'count': ((prev['count'] as num?)?.toInt() ?? 0) + 1,
      'ok': ok,
      'brief': brief ?? (prev['brief']?.toString() ?? ''),
    };
    step['tools'] = tools;
    f['steps'] = steps; // _stepsOf 是拷贝，必须写回（FlowStore BUG-3 教训）
    await _write(personaId, f);
  }

  /// 男主回复 → 处理步骤
  /// 8-11 18:0x（用户拍板：去掉"消"补丁，回归 GPT 消息模型）：
  /// - 男主回复**绑定消息编号**（回#N、#M）→ 系统把那条从**未处理消息区**
  ///   移除（标 done）——可一次回多条（回#1、#2 = 一起做）
  /// - 回复**不带编号** → 不消！男主只是中途说话，回复挂当前步（reply 字段），
  ///   未处理区不变
  /// - 编号无效 → 不自动消（去掉了 FIFO 兜底），回复挂当前步 + 日志警告
  /// - 全部处理完 → 流程不自动 done、不强制总结轮——**男主自己判断结束**
  ///   （GPT 完成检查：需求完成？关联消息全处理？插话处理？工具结果用了？
  ///   还有未完成事项？）→ 他输出退出标记（need_continue:false）时
  ///   chat_page 调 finish() 收尾 + 提示写摘要
  /// - 去掉了：【结束】标签消流程、总结轮（全消强制看一遍）、
  ///   endTagWarned、summarizePending、FIFO 无效编号兜底
  static Future<void> feedReply(String personaId, String replyText) async {
    if (personaId.isEmpty || replyText.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return;
    final marked = _parseMarkedNos(replyText);

    if (marked.isEmpty) {
      // 无绑定编号 → 回复挂当前步（不消，流程继续）——男主中途说话
      var target = -1;
      final curIdx = (f['currentStep'] as num?)?.toInt() ?? 0;
      if (curIdx >= 0 &&
          curIdx < steps.length &&
          steps[curIdx]['status'] != 'done') {
        target = curIdx;
      }
      if (target < 0) {
        for (var i = 0; i < steps.length; i++) {
          if (steps[i]['status'] != 'done' && steps[i]['isReview'] != true) {
            target = i;
            break;
          }
        }
      }
      if (target < 0) {
        for (var i = 0; i < steps.length; i++) {
          if (steps[i]['status'] != 'done') {
            target = i;
            break;
          }
        }
      }
      if (target < 0) return;
      steps[target]['reply'] = replyText.trim();
      f['steps'] = steps;
      await _write(personaId, f);
      _log('对话流程', '💬 男主回复（无绑定编号）→ 挂当前步，未处理区不变');
      return;
    }

    // 绑定编号（回#N）→ 从未处理区移除（标 done）
    var changed = false;
    for (final no in marked) {
      final idx = _stepIndexByNo(steps, no);
      if (idx >= 0 && steps[idx]['status'] != 'done') {
        steps[idx]['status'] = 'done';
        steps[idx]['reply'] = replyText.trim();
        changed = true;
      }
    }
    if (!changed) {
      // 编号无效 → 不自动消（GPT：消息还在未处理区），回复挂当前步
      var target = -1;
      final curIdx = (f['currentStep'] as num?)?.toInt() ?? 0;
      if (curIdx >= 0 &&
          curIdx < steps.length &&
          steps[curIdx]['status'] != 'done') {
        target = curIdx;
      } else {
        for (var i = 0; i < steps.length; i++) {
          if (steps[i]['status'] != 'done') {
            target = i;
            break;
          }
        }
      }
      if (target >= 0) {
        steps[target]['reply'] = replyText.trim();
        f['steps'] = steps;
        await _write(personaId, f);
        _log('对话流程',
            '⚠️ end_MN 编号无效（${marked.join('、')}，未处理区 ${steps.length} 条）'
            '→ 不自动消，回复挂当前步');
      }
      return;
    }
    f['steps'] = steps;

    // 还有未处理 → 推下一个为当前；全处理完 → 等男主自己判断结束
    final stillPending = steps
        .where((s) => s['status'] != 'done' && s['isReview'] != true)
        .length;
    if (stillPending > 0) {
      var nextCur = -1;
      for (var i = 0; i < steps.length; i++) {
        if (steps[i]['status'] != 'done') {
          nextCur = i;
          break;
        }
      }
      f['currentStep'] = nextCur < 0 ? steps.length : nextCur;
      await _write(personaId, f);
      _log('对话流程', '🔚 处理完 ${marked.join('、')}，还有 $stillPending 条未处理');
      return;
    }
    // 全部处理完：不自动 done、不强制总结轮——男主自己判断结束
    //（说结束 + 写摘要）。流程保持 running，buildText 显示"全部处理完，
    // 你判断：结束 → 说结束+写摘要"。男主输出退出标记（need_continue:false）
    // → chat_page 调 finish() 收尾。
    f['currentStep'] = steps.length;
    await _write(personaId, f);
    _log('对话流程', '✅ 全部消息处理完，等男主自己判断结束（说结束+写摘要）');
  }
  /// 8-09 19:3x（用户设计定稿 9.4/9.8）：融合 = 男主自己判断重新编排步骤。
  /// 对话流程的步骤合并：把多个步骤（用户消息）合并成一个新步骤。
  /// 例：A"我喜欢猫" + B"我喜欢狗" → merge nos=[1,2] name="记录用户喜欢猫也喜欢狗"
  /// 男主说了新内容（name）就作为合并后的新步骤内容；没给 name →
  /// 自动拼"【合并】原步骤1 + 原步骤2"（保留原话可追溯）。
  /// 返回：'ok' 或错误提示。
  static Future<String> mergeSteps(String personaId,
      {required List<int> nos, String? name}) async {
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') {
      return '没有执行中的对话流程（先让用户发消息）';
    }
    final steps = _stepsOf(f);
    if (steps.isEmpty) return '没有步骤';
    if (nos.length < 2) return 'merge 至少要两个步骤编号';
    // 8-10 23:0x：按稳定编号匹配（不再按位置）
    final idxs = nos.map((x) => _stepIndexByNo(steps, x)).toList();
    if (idxs.any((x) => x < 0)) {
      return '编号不存在（对照清单里的 #N）';
    }
    // 8-09 20:18（用户：复核不能跳过）——复核不能参与合并，
    // 它是流程结尾的确认步骤，男主必须单独回答。
    if (idxs.any((x) => steps[x]['isReview'] == true)) {
      return '复核步骤不能合并——它问的是"还有要补充的吗？要调整流程吗？'
          '还是确认结束？"必须单独回答（回复/调整/输出退出标记）';
    }
    // 合并内容：新名字 or 自动拼原话
    final nameText = (name ?? '').trim();
    final mergedText = nameText.isNotEmpty
        ? nameText
        : '【合并】${idxs.map((x) => _short(steps[x]['userText'].toString(), 20)).join(' + ')}';
    final newStep = <String, dynamic>{
      'no': _nextStepNo(steps), // 稳定编号
      'userText': mergedText,
      'ts': _hhmm(),
      'status': 'pending',
      'tools': <String, dynamic>{},
      'reply': '',
      'mergedFrom':
          idxs.map((x) => steps[x]['userText'].toString()).toList(),
    };
    // 被合并步骤的工具链合并进新步骤（不丢工作记录）
    final tools = <String, dynamic>{};
    for (final x in idxs) {
      final st = steps[x];
      final stTools = _asMap(st['tools']);
      stTools.forEach((name_, v) {
        final prev = (tools[name_] as Map?) ?? <String, dynamic>{};
        final vv = v is Map ? v : const <String, dynamic>{};
        tools[name_] = {
          'count': ((prev['count'] as num?)?.toInt() ?? 0) +
              ((vv['count'] as num?)?.toInt() ?? 1),
          'ok': (prev['ok'] == true) && (vv['ok'] == true),
          'brief': (vv['brief'] ?? prev['brief'] ?? '').toString(),
        };
      });
    }
    if (tools.isNotEmpty) newStep['tools'] = tools;
    // 重建步骤列表：删掉被合并的，新步骤插在第一个被合并步骤的位置
    final sorted = [...idxs]..sort();
    final insertPos = sorted.first; // 8-10 23:0x：用下标（原 nos 编号已转 idxs）
    final newSteps = <Map<String, dynamic>>[];
    for (var i = 0; i < steps.length; i++) {
      if (idxs.contains(i)) continue; // 8-10 23:0x：按稳定编号匹配
      newSteps.add(steps[i]);
    }
    newSteps.insert(insertPos.clamp(0, newSteps.length), newStep);
    f['steps'] = newSteps;
    // currentStep 修正：指向合并后的新步骤（如果原当前步被合并）
    var nextCur = -1;
    for (var i = 0; i < newSteps.length; i++) {
      if (newSteps[i]['status'] != 'done') {
        nextCur = i;
        break;
      }
    }
    f['currentStep'] = nextCur < 0 ? newSteps.length : nextCur;
    await _write(personaId, f);
    _log('对话流程', '🧬 mergeSteps：${nos.join('+')} → 「$mergedText」');
    return 'ok';
  }

  /// 8-09 19:3x（设计九.8 对话流程版）：删除对话流程步骤（编号 1-based）。
  /// 男主判断某条消息不用回了（合并掉了/不需要）→ 删掉。
  static Future<String> deleteSteps(String personaId,
      {required List<int> nos}) async {
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return '没有执行中的对话流程';
    final steps = _stepsOf(f);
    if (steps.isEmpty) return '没有步骤';
    if (nos.isEmpty) return 'delete 需要至少一个步骤编号';
    // 8-10 23:0x：按稳定编号匹配（不再按位置）
    final idxs = nos.map((x) => _stepIndexByNo(steps, x)).toList();
    if (idxs.any((x) => x < 0)) {
      return '编号不存在（对照清单里的 #N）';
    }
    // 8-09 20:18（用户：复核不能跳过）——复核是管家插在大流程结尾的
    // 确认步骤，男主必须回答（补充/调整/确认结束），不能删掉绕过。
    if (idxs.any((x) => steps[x]['isReview'] == true)) {
      return '复核步骤不能删除——它问的是"还有要补充的吗？要调整流程吗？'
          '还是确认结束？"必须回答（回复/调整/输出退出标记）';
    }
    if (idxs.length >= steps.length) return '不能删光所有步骤';
    final newSteps = <Map<String, dynamic>>[];
    for (var i = 0; i < steps.length; i++) {
      if (idxs.contains(i)) continue;
      newSteps.add(steps[i]);
    }
    f['steps'] = newSteps;
    var nextCur = -1;
    for (var i = 0; i < newSteps.length; i++) {
      if (newSteps[i]['status'] != 'done') {
        nextCur = i;
        break;
      }
    }
    f['currentStep'] = nextCur < 0 ? newSteps.length : nextCur;
    await _write(personaId, f);
    _log('对话流程', '🗑 deleteSteps：${nos.join('、')}');
    return 'ok';
  }

  static String _hhmm() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
  }

  /// 男主输出退出标记（need_continue:false）→ 流程结束
  /// 他声明"回完了+干完了"。还有没回的工作 → 也尊重他的判断
  /// （他可能决定放弃某项），流程直接 done。
  /// 8-09 21:0x（用户：一个大流程结束男主至少要跟她说一句）：
  /// 结束校验——男主这个流程里**从没回复过用户**（只调工具）→ 拒绝结束，
  /// 返回原因让管家引导先说话；说过话 → 正常结束返回 null。
  /// （纯聊天流程男主必然回过话；调了工具没回话的才被挡）
  static String? finishCheck(String personaId) {
    final f = _memCache;
    if (f == null || f['status'] != 'running') return null;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final realSteps = steps.where((s) => s['isReview'] != true).toList();
    final hasSpoken = realSteps.any(
        (s) => ((s['reply'] as String?)?.toString().trim() ?? '').isNotEmpty);
    if (!hasSpoken) {
      return '这个流程你还没跟她说过话（只调了工具）。结束前必须说一句：'
          '告诉她结果/说句自然的话——说完这条（不用带退出标记也行，'
          '管家看到你说话就当你回过她了），再结束。';
    }
    return null;
  }

  /// 8-11 19:0x（用户 19:09 固定结束流程）：未标 done 的步骤编号列表。
  /// 8-12 04:1x（用户拍板）：已不再用于归档前打回补标——男主标了
  /// end_TN + save_summary 就直接归档（写了摘要=检查过了，忘标 end_MN
  /// 不阻塞）。保留此方法供日志/排查参考。
  /// 注：只此一处调用（chat_page 结束检查）；checkBrief 不经过这里，
  /// 男主处理中仍能看到全部待办（含插话，每条都要处理判断）。
  /// 8-11 23:5x：返回带前缀编号（M1/B3）——管家消息 B、用户消息 M，
  /// 男主一眼知道补标哪条；调用处只 chat_page 一处。
  static List<String> pendingNos(String personaId) {
    final f = _memCache;
    if (f == null) return const [];
    final steps = _stepsOf(f);
    final nos = <String>[];
    for (var i = 0; i < steps.length; i++) {
      if (steps[i]['status'] != 'done' &&
          steps[i]['from'] != 'user_interrupt') {
        final n = _stepNo(steps[i], i);
        nos.add('${steps[i]['from'] == 'butler' ? 'S' : 'M'}$n');
      }
    }
    return nos;
  }

  static Future<void> finish(String personaId) async {
    if (personaId.isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
    // 8-11 20:2x（用户 20:28）：男主带结束标签后、归档前才进来的插话
    // （用户手速快连发两条——第一条男主处理完带结束标记，第二条才到；
    // 19:09 检查时它还不存在，男主不可能标它）→ **自动拆到下一个任务**，
    // 不跟着旧大流程一起消掉，也不让男主疑惑。
    // 8-12 04:1x（用户拍板：标了 end_TN+摘要=结束，不管中间有没有标完）：
    // 只拆"用户插话"（from == user_interrupt）——男主忘了标 end_MN 的
    // 普通消息不拆（他写了摘要 = 他检查过了，只是忘记打结束标签），
    // 不因没标完打回、不唤醒（防无限唤醒）。
    final steps = _stepsOf(f);
    final lateInterrupts = steps
        .where((s) => s['status'] != 'done' && s['from'] == 'user_interrupt')
        .toList();
    if (lateInterrupts.isNotEmpty) {
      // 8-12 03:4x（用户澄清）：男主说 end_TN 时的插话（手速快连发）
      // → 拆成新流程**排队**（T1/T2 放工作区当前流程下面），当前流程
      // 正常归档，处理完自动轮到排队的
      for (final s in lateInterrupts) {
        final clean = Map<String, dynamic>.from(s);
        clean['no'] = 1; // 每条插话 = 独立新流程 M1
        clean['status'] = 'pending';
        clean['reply'] = '';
        clean['tools'] = <String, dynamic>{};
        clean.remove('from');
        final flow = <String, dynamic>{
          'flowNo': await _nextFlowNo(),
          'goal': _short(clean['userText'].toString(), 30),
          'status': 'pending', // 排队中（当前流程归档后轮到）
          'currentStep': 0,
          'steps': [clean],
          'startedAt': DateTime.now().toIso8601String(),
          // 8-11 20:2x：男主可能没意识到有插话 → 管家备注说明（男主唤醒时看到）
          'butlerNote': '上个大流程结束时她还有话没处理完，'
              '管家自动排队的任务，处理一下',
        };
        await _enqueue(personaId, flow);
      }
      _log('对话流程',
          '📦 男主结束时有 ${lateInterrupts.length} 条插话（结束标签后到）'
          '→ 自动排队成新流程（T1/T2…），当前流程正常归档');
    }
    // 8-11 19:0x（用户 19:09）：管家**不兜底**——男主没标结束 = 没做完。
    // 8-12 04:1x（用户拍板）：结束判定改为"男主标了 end_TN + save_summary
    // 就归档"（他写了摘要 = 他检查过了），不再要求每条都标完 end_MN。
    f['status'] = 'done';
    f['currentStep'] = (_stepsOf(f).length);
    await _write(personaId, f);
    _log('对话流程', '🔚 男主输出退出标记，流程结束（固定结束流程：'
        '男主自己标完所有消息 → 带大流程结束标记 → 写摘要 → 管家归档）');
    // 8-12 03:3x（用户：排队来吧）：有排队流程 → 提升第一个为当前
    // （running），检查点⑤看到 running 自动续跑唤醒男主处理下一个
    final q = await _readQueue(personaId);
    if (q.isNotEmpty) {
      final next = q.removeAt(0);
      next['status'] = 'running';
      await _writeQueue(personaId, q);
      await _write(personaId, next);
      _log('对话流程',
          '🔜 排队流程 ${next['flowNo']} 提升为当前（${_short(
              next['goal']?.toString() ?? '', 24)}），自动轮到');
    }
  }

  /// 解析男主回复里的消条目标注（第N步，1-based）
  /// 兼容格式：`<reply>回#1、#2</reply>` / `"reply":"回#1、#2"` / 回待#1 / 回#1
  /// 8-11 20:1x（用户 20:15）：消息编号 = M1/M2…（GPT 参考 MSG001
  /// 简化，Message）。兼容旧 a1/a2、#1（旧数据/旧习惯）。
  /// 只认 M/a/# 前缀，避免把大流程 T1 里的数字误当消息编号。
  static List<int> _parseMarkedNos(String reply) {
    final nos = <int>{};
    void collect(String s) {
      for (final m in RegExp(r'M(\d+)', caseSensitive: false).allMatches(s)) {
        nos.add(int.tryParse(m.group(1)!) ?? 0);
      }
      for (final m in RegExp(r'a(\d+)', caseSensitive: false).allMatches(s)) {
        nos.add(int.tryParse(m.group(1)!) ?? 0);
      }
      for (final m in RegExp(r'#(\d+)').allMatches(s)) {
        nos.add(int.tryParse(m.group(1)!) ?? 0);
      }
      // 8-11 23:5x：管家（系统）消息 S 编号（回S1 消管家消息）
      for (final m in RegExp(r'S(\d+)', caseSensitive: false).allMatches(s)) {
        nos.add(int.tryParse(m.group(1)!) ?? 0);
      }
    }

    for (final m
        in RegExp(r'<reply>([\s\S]*?)</reply>', caseSensitive: false)
            .allMatches(reply)) {
      collect(m.group(1) ?? '');
    }
    for (final m in RegExp(r'"reply"\s*:\s*"([^"]*)"').allMatches(reply)) {
      collect((m.group(1) ?? '').replaceAll(r'\"', '"'));
    }
    for (final m
        in RegExp(r'回(?:复)?\s*待?#?a?(\d+)', caseSensitive: false)
            .allMatches(reply)) {
      nos.add(int.tryParse(m.group(1)!) ?? 0);
    }
    nos.remove(0);
    return nos.toList()..sort();
  }

  // ---- 读取（注入）----

  /// 当前流程（无则 null）
  static Map<String, dynamic>? get(String personaId) => _memCache;

  /// 是否有未消条目（检查轮/停止条用）
  static bool hasPending(String personaId) {
    final f = _memCache;
    if (f == null || f['status'] != 'running') return false;
    return _stepsOf(f).any((s) => s['status'] != 'done');
  }

  /// 注入文本（对话流程清单 + 决策点；无内容返回 null）
  static String? buildText(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    final status = f['status']?.toString() ?? '';
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final sb = StringBuffer();
    final flowNo = f['flowNo'];
    // 8-11 19:5x（用户 19:53）：【当前工作区】= 大流程，内所有消息 = **待办事项**
    // （M1、M2、M3… 平行），给男主做参考：一条条看过去，能一起做的就一起做，
    // 每条都要处理判断（不能因为"还没轮到"就不看）。
    // 8-12 04:1x（用户：去掉"当前在M1"标记）：不再标 ▶ 当前步——会误导
    // 男主一直处理 M1。全部 ☐ 平铺，工具链挂在对应消息下面（标记打在工具上），
    // 男主自己按顺序处理，做完标 end_MN（标完步骤消失）。
    sb.writeln('【当前工作区${flowNo != null ? ' #$flowNo' : ''}】');
    // 8-11 20:2x：拆出来的新任务带管家备注（男主可能没意识到有插话）
    final bNote = (f['butlerNote'] as String?)?.toString().trim() ?? '';
    if (bNote.isNotEmpty) sb.writeln('💡 $bNote');
    if (status == 'done') {
      sb.writeln('✅ 流程已结束（你确认无工作遗漏）。没有新消息就别再说话，'
          '输出退出标记 {"need_continue": false}。');
      return sb.toString();
    }
    // 全部处理完（未处理区空）→ 男主自己判断结束（GPT 完成检查）
    final allReplied = steps.every((s) => s['status'] == 'done');
    if (allReplied) {
      sb.writeln('✅ 所有消息都处理完了。');
      // 8-12 04:5x（用户：全处理完后新消息拆排队成 T+N）：全 done 时
      // 也要让男主看到下面排队的 T1——不然他以为没新消息，直接归档后
      // T1 才轮到（"下面还有排队的新流程才继续唤醒你"）
      final q = queuedFlows(personaId);
      if (q.isNotEmpty) {
        sb.writeln('—— 下面排队的新流程（处理完上面这个自动轮到）：');
        for (final qf in q) {
          final qSteps = _stepsOf(qf);
          final qText = qSteps.isEmpty
              ? ''
              : qSteps.first['userText']?.toString() ?? '';
          sb.writeln('☐ ${qf['flowNo']}（${_short(qText, 30)}）');
        }
      }
      sb.writeln('· 做完了 → 最后一条 JSON 的 sys 写 end_TN（N=大流程编号）'
          '+ 写摘要（save_summary），管家归档合并历史，之后不再唤醒你'
          '（下面还有排队的新流程才继续唤醒）；');
      sb.writeln('· 还有事 → 继续处理。');
      return sb.toString();
    }
    // 8-12 04:1x（用户：去掉"当前在M1"标记——会误导男主一直处理 M1）：
    // 不再标 ▶ 当前步。所有未处理消息平铺成 ☐ 待办清单（按 M1、M2… 顺序）。
    // 8-12 04:3x（用户：无法确定哪个是未处理 → 每条显示"最后一步"；
    // 判断块只放 M1M2 后面一个，不插在每条中间）：每条 = 消息行 +
    // 工具链（精简成一行）+ 最后一步（男主回了啥精简/最后一个工具结果/无）；
    // 看完所有待办后才有"判断"块（有工具失败/没找到才动态出现，往后挪）。
    // 内部 currentStep 仍保留（工具/回复挂载点用），只是不再注入显示。
    final pendingMs = <Map<String, dynamic>>[]; // 收集待办，判断块用
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s['status'] == 'done') continue;
      pendingMs.add(s);
      final no = _stepNo(s, i);
      final noMark = s['from'] == 'butler' ? 'S' : 'M'; // 8-11 23:5x：管家消息 S 前缀（System 系统消息，用户：管家=系统）
      final fromMark = s['from'] == 'butler' ? '【管家】' : '';
      final ts = (s['ts'] ?? '').toString();
      final spk = s['from'] == 'butler' ? '管家' : '她';
      final tools = _asMap(s['tools']);
      final reply = (s['reply'] as String?)?.toString().trim() ?? '';
      // 管家备注（挂用户消息后面 = GPT 管家分析绑定消息）
      final notes = (s['butlerNotes'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          <Map<String, dynamic>>[];
      if (notes.isNotEmpty) {
        for (final n in notes) {
          sb.writeln('☐ $noMark$no [${n['ts']}] 管家：${n['text']}');
        }
        sb.writeln('  她：${s['userText']}');
      } else {
        sb.writeln('☐ $noMark$no [$ts]$fromMark $spk：${s['userText']}');
      }
      // 工具链（精简成一行：名字 + ✅/❌ + 短结果，标记打在工具上）
      if (tools.isNotEmpty) {
        final parts = <String>[];
        for (final entry in tools.entries) {
          final v = entry.value;
          if (v is! Map) continue;
          final ok = v['ok'] == true;
          final brief = (v['brief'] ?? '').toString();
          parts.add('${entry.key} ${ok ? '✅' : '❌'}'
              '${brief.isEmpty ? '' : '：${_short(brief, 16)}'}');
        }
        sb.writeln('  - 工具（处理 $noMark$no）：${parts.join('｜')}');
      }
      // 最后一步：男主回了啥（精简）／最后一个工具结果（精简）／无
      if (reply.isNotEmpty) {
        sb.writeln('  - 最后一步：你回：「${_short(reply, 40)}」');
      } else if (tools.isNotEmpty) {
        final lastEntry = tools.entries.last;
        final v = lastEntry.value;
        final ok = v is Map && v['ok'] == true;
        final brief = v is Map ? (v['brief'] ?? '').toString() : '';
        sb.writeln('  - 最后一步：${lastEntry.key} ${ok ? '✅' : '❌'}'
            '${brief.isEmpty ? '' : '：${_short(brief, 30)}'}');
      } else {
        sb.writeln('  - 最后一步：无');
      }
    }
    // 判断块：只放 M1M2 后面一个（男主看完待办从这里开始决定；
    // 有工具失败/没找到才动态出现，有工具就往后挪）。不插在每条中间。
    final decLines = <String>[];
    for (final s in pendingMs) {
      final tools = _asMap(s['tools']);
      if (tools.isEmpty) continue;
      final dec = _decisionHint(tools);
      if (dec.isEmpty) continue;
      final no = _stepNo(s, steps.indexOf(s));
      final noMark = s['from'] == 'butler' ? 'S' : 'M';
      decLines.add('  · $noMark$no：$dec');
    }
    if (decLines.isNotEmpty) {
      sb.writeln('—— 判断（看完全部待办，从这里开始决定）');
      sb.writeln(decLines.join('\n'));
    }
    // 排队的新流程（8-12 03:4x：男主说 end_TN 时的插话拆排队；
    // 8-12 04:5x：全处理完后新消息也拆排队）——正常情况显示在
    // 当前流程待办下面（"处理完上面这个自动轮到"）
    final q = queuedFlows(personaId);
    if (q.isNotEmpty) {
      sb.writeln('—— 下面排队的新流程（处理完上面这个自动轮到）：');
      for (final qf in q) {
        final qSteps = _stepsOf(qf);
        final qText = qSteps.isEmpty
            ? ''
            : qSteps.first['userText']?.toString() ?? '';
        sb.writeln('☐ ${qf['flowNo']}（${_short(qText, 30)}）');
      }
    }
    // 引导：平行 + 插话判断 + 结束流程（8-11 19:4x 精简，对齐 GPT：
    // 固定层只放规则，流程细节这里一句话讲完，不叠话术）
    // 8-12 04:1x（用户拍板）：结束 = 男主标了 end_TN + save_summary 就归档，
    // 不用每条都标完 end_MN——他写了摘要 = 他检查过了（只是忘记打结束标签），
    // 管家不因没标完打回（那会造成反复唤醒死循环）。
    sb.writeln('—— 上面都是待办事项（参考）：一条条看过去，能一起做的'
        '就一起做（end_MN 标你处理的是哪条，可一次回多条 end_M1、end_M2；'
        '管家消息用 end_SN，如 end_S1）。'
        '每条都要处理，判断：补充/修改/插入（先做插话，做完回原任务）'
        '/不做了（她叫停）——不能跳过任何一条');
    sb.writeln('—— 结束：做完后最后一条 sys 写 end_TN + 调 save_summary'
        '（save_summary）→ 管家归档，不再唤醒你。'
        '不用每条都标完 end_MN——你写了摘要 = 你检查过了；'
        '下面还有排队的新流程（T2）才继续唤醒你。');
    return sb.toString();
  }

  /// 8-11 04:5x（用户：后续还没做的【单独放一边，标签隔开】——
  /// 不插进【当前流程】工作区；当前步做完自动移上来一条，
  /// 处理完的移上去当【上下文参考】）
  /// 还没做的步骤清单（不含当前步）；没有后续 → null。
  static String? pendingText(String personaId) {
    final cache = _memCache;
    if (cache == null) return null;
    final f = cache[personaId];
    if (f == null || f['closed'] == true) return null;
    final steps = (f['steps'] as List?)?.cast<Map<String, dynamic>>();
    if (steps == null || steps.isEmpty) return null;
    final cur = f['cur'] as int? ?? 0;
    final pending = <String>[];
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s['status'] == 'done') continue;
      if (i == cur) continue;
      final no = _stepNo(s, i);
      final noMark = s['from'] == 'butler' ? 'S' : 'M'; // 8-11 23:5x
      final fromMark = s['from'] == 'butler' ? '【管家】' : '';
      final spk = s['from'] == 'butler' ? '管家' : '她';
      pending.add(
          '☐ $noMark$no $fromMark $spk：${_short(s['userText'].toString(), 24)}');
    }
    if (pending.isEmpty) return null;
    final sb = StringBuffer();
    sb.writeln('（还没做，当前步做完自动移上来一条）');
    for (final line in pending) {
      sb.writeln(line);
    }
    return sb.toString();
  }

  /// 当前步决策点提示（根据工具结果机械生成，不靠 LLM）
  /// 扫描全部工具：有失败 → 失败提示；有"没找到"类结果 → 没找到提示；
  /// 全成功 → 回复完成提示。（8-09 18:3x：多工具时不能只看最后一个——
  /// "查了没找到→又记录成功"，没找到的事实必须还在决策点上）
  static String _decisionHint(Map<String, dynamic> tools) {
    var anyFail = false;
    var anyNotFound = false;
    for (final entry in tools.entries) {
      final v = entry.value;
      if (v is! Map) continue;
      final ok = v['ok'] == true;
      final brief = (v['brief'] ?? '').toString();
      if (!ok) {
        anyFail = true;
      } else {
        if (brief.contains('没找到') ||
            brief.contains('没有找到') ||
            brief.contains('无结果') ||
            brief.contains('没有相关') ||
            brief.contains('暂无')) {
          anyNotFound = true;
        }
      }
    }
    // 8-11 07:0x（用户：成功时"→ 判断：工具已成功，回复她就完成这步"
    // 贴工具记录后面很烦——事实清楚不用教）→ 只保留异常提示
    if (anyFail) {
      return '工具没成功。继续（换工具/换参数再查）？还是回复她结束这步？';
    }
    if (anyNotFound) {
      return '查了没找到。继续查（换工具/换方式）？还是回复她结束这步？';
    }
    return '';
  }

  /// 检查轮简报：'还有 N 条没回：…' / 全部已回 → '已全部回应，收尾检查'
  /// （8-09 18:4x：回复≠结束——全回但流程没 done 也要唤醒收尾检查，
  /// 男主才能回去把没做完的工作做完）
  /// 8-10 00:49（用户：去掉二次复核）：查询对话流程状态——
  /// 'running'（还有步骤/下一个大流程）/ 'done'（已结束）/ null（没流程）。
  /// chat_page 用它决定：done → 不唤醒男主（消掉大流程=结束）；
  /// running → 检查轮带清单唤醒男主继续走下一个大流程。
  static String? statusOf(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    return f['status']?.toString();
  }

  /// T0 全部消息简报（8-12 05:1x 用户：日志"她："只显示本轮触发，
  /// 应该写上 T0 里面所有话，比如 M1 和 M2，而不是单单 M2；
  /// 8-12 06:0x 用户补充：男主的话也要全部——"她：M2"下面男主回 M1
  /// 看着像矛盾，简报要带上男主对每条的回话）：
  /// '✅ M1：我喜欢猫（男主回：我也喜欢）｜✅ S1：管家：…｜☐ M2：…'
  /// （无流程/无步骤返回 ''）
  static String allFlowBrief(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return '';
    final steps = _stepsOf(f);
    if (steps.isEmpty) return '';
    final parts = <String>[];
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final no = _stepNo(s, i);
      final mark = s['status'] == 'done' ? '✅' : '☐';
      final text = s['userText'].toString().trim();
      if (s['from'] == 'butler') {
        // 男主消息（S 步）：管家说的话
        parts.add('$mark S$no：${_short(text, 24)}');
      } else {
        final reply = (s['reply'] as String?)?.toString().trim() ?? '';
        final replyNote = reply.isEmpty ? '' : '（男主回：${_short(reply, 20)}）';
        parts.add('$mark M$no：${_short(text, 24)}$replyNote');
      }
    }
    if (parts.isEmpty) return '';
    final flowNo = f['flowNo'];
    return 'T$flowNo 全部消息：${parts.join('｜')}';
  }

  static String? checkBrief(String personaId) {
    final f = _memCache;
    if (f == null || f['status'] != 'running') return null;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final pending = <Map<String, dynamic>>[];
    for (var i = 0; i < steps.length; i++) {
      if (steps[i]['status'] != 'done') pending.add(steps[i]);
    }
    if (pending.isEmpty) {
      // 全部处理完 → 固定结束流程（8-11 19:0x 用户 19:04/19:07）
      // 8-12 04:5x：全 done + 有排队 → 归档后自动轮到 T1（会唤醒），
      // 没有排队 → 不再唤醒
      final q = queuedFlows(personaId);
      final qNote = q.isEmpty
          ? '之后不再唤醒你。'
          : '归档后自动轮到下面排队的新流程（'
              '${q.map((x) => x['flowNo']).join('、')}）。';
      return '全部消息都处理完了：最后一条 JSON 的 sys 写 end_TN'
          '（结束标记）+ 写摘要（save_summary），管家归档合并历史，$qNote';
    }
    // 还有未处理 → 列出未处理编号（8-12 04:1x 用户：不要"当前第 N 条"
    // 标记——误导男主一直处理 M1；清单本身在工作区，这里只报数）
    final nos = pending.map((s) {
      final i = steps.indexOf(s);
      final n = _stepNo(s, i);
      return '${s['from'] == 'butler' ? 'S' : 'M'}$n';
    }).join('、');
    return '还有 ${pending.length} 条未处理消息（$nos）。\n'
        '· 回复时标注你回的是哪条（end_MN），可一次回多条（end_M1、end_M2）；\n'
        '· 处理完 → 最后一条 sys 写 end_TN + 调 save_summary'
        '（save_summary），管家归档（不用每条都标完，写了摘要=你检查过了）。';
  }

  // ---- 工具 ----

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  static String _short(String s, [int n = 20]) {
    final t = s.trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }
}
