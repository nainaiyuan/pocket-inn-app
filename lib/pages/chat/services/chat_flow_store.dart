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
  /// - **处理中**（有 running 流程）：用户插话 = **直接进大流程**，跟第一条
  ///   平行（排在后面 = 暂挂，还没轮到它，男主先处理第一句话的东西）。
  ///   男主处理插话时**自己判断**：补充当前任务 / 修改当前任务 /
  ///   插入新任务（先做插话，做完回原任务）/ 不做了（她叫停当前任务）
  ///   （8-11 18:2x 用户：男主收到插话必须判断该干嘛，不能跳过）
  static Future<void> feedUser(String personaId, String text) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (!_isTerminal(f) && f!['status'] == 'running') {
      // 处理中 → 插话 = 新消息**直接进大流程**（8-11 18:3x 用户：
      // 大流程内所有消息平行，插话跟第一条平行，排在后面=暂挂（还没轮到）；
      // 男主处理时自己判断 补充/修改/插入/不做了。不打断当前处理）
      final steps = _stepsOf(f);
      // 8-10 23:0x：插话步骤分配稳定编号（不挤占已有编号）
      final step = _newStep(text, no: _nextStepNo(steps));
      step['from'] = 'user_interrupt'; // 插话标记（GPT：进当前任务判断）
      steps.add(step); // 挂未处理区末尾，男主判断怎么处理
      f['steps'] = steps;
      // 不推为当前——男主正在处理的保持不变，插话在未处理区等判断
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
      {required bool ok, String? brief}) async {
    if (personaId.isEmpty || toolName.isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
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
            '⚠️ 回MN 编号无效（${marked.join('、')}，未处理区 ${steps.length} 条）'
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
  /// 归档前检查用——管家不自动标，没标完 = 没做完，提示男主补标。
  static List<int> pendingNos(String personaId) {
    final f = _memCache;
    if (f == null) return const [];
    final steps = _stepsOf(f);
    final nos = <int>[];
    for (var i = 0; i < steps.length; i++) {
      if (steps[i]['status'] != 'done') {
        nos.add(_stepNo(steps[i], i));
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
    final steps = _stepsOf(f);
    final lateInterrupts =
        steps.where((s) => s['status'] != 'done').toList();
    if (lateInterrupts.isNotEmpty) {
      final newSteps = <Map<String, dynamic>>[];
      for (var i = 0; i < lateInterrupts.length; i++) {
        final s = Map<String, dynamic>.from(lateInterrupts[i]);
        s['no'] = i + 1; // 新流程重新编号 M1/M2…
        s['status'] = 'pending';
        s['reply'] = '';
        s['tools'] = <String, dynamic>{};
        s.remove('from');
        newSteps.add(s);
      }
      final flow = <String, dynamic>{
        'flowNo': await _nextFlowNo(),
        'goal': _short(lateInterrupts.first['userText'].toString(), 30),
        'status': 'running',
        'currentStep': 0,
        'steps': newSteps,
        'startedAt': DateTime.now().toIso8601String(),
        // 8-11 20:2x：男主可能没意识到有插话 → 管家备注说明（男主唤醒时看到）
        'butlerNote': '上个大流程你带结束标记时，她还有 ${lateInterrupts.length} 条'
            '话刚发出来没看到，管家自动开的新任务，处理一下',
      };
      await _write(personaId, flow);
      _log('对话流程',
          '📦 男主结束时有 ${lateInterrupts.length} 条插话（结束标签后才到）'
          '→ 自动拆成新任务 T${flow['flowNo']}，不跟着消');
      return; // 旧流程已被新流程取代（对话原文已进历史 topics，不丢）
    }
    // 8-11 19:0x（用户 19:09）：管家**不兜底**——男主没标结束 = 没做完。
    // 归档前调用方（chat_page）已确认步骤全标完；这里只做归档。
    f['status'] = 'done';
    f['currentStep'] = (_stepsOf(f).length);
    await _write(personaId, f);
    _log('对话流程', '🔚 男主输出退出标记，流程结束（固定结束流程：'
        '男主自己标完所有消息 → 带大流程结束标记 → 写摘要 → 管家归档）');
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
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    final sb = StringBuffer();
    final flowNo = f['flowNo'];
    // 8-11 19:5x（用户 19:53）：【当前工作区】= 大流程，内所有消息 = **待办事项**
    // （#1、#2、#3… 平行），给男主做参考：一条条看过去，能一起做的就一起做，
    // 每条都要处理判断（不能因为"还没轮到"就不看）。正在处理的标 ▶/✅
    // （子分支挂下面），还没处理的标 ☐（待办）。
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
      sb.writeln('· 做完了 → 在这条回复上带"大流程也结束了"（结束标记）'
          '+ 写摘要（save_summary），管家归档合并历史，之后不再唤醒你；');
      sb.writeln('· 还有事 → 继续处理。');
      return sb.toString();
    }
    // 正在处理：当前步
    Map<String, dynamic>? curStep;
    if (cur >= 0 && cur < steps.length && steps[cur]['status'] != 'done') {
      curStep = steps[cur];
    } else {
      for (final s in steps) {
        if (s['status'] != 'done') {
          curStep = s;
          break;
        }
      }
    }
    if (curStep != null) {
      final no = _stepNo(curStep, steps.indexOf(curStep));
      final fromMark = curStep['from'] == 'butler' ? '【管家】' : '';
      final ts = (curStep['ts'] ?? '').toString();
      final tools = _asMap(curStep['tools']);
      final reply = (curStep['reply'] as String?)?.toString().trim() ?? '';
      final speaker = curStep['from'] == 'butler' ? '管家' : '她';
      final hasReply = reply.isNotEmpty;
      final toolsOk = tools.isNotEmpty &&
          tools.values.every((v) => v is Map && v['ok'] == true);
      final done = hasReply || toolsOk;
      final mark = done ? '✅' : '▶';
      // 管家备注（挂用户消息后面 = GPT 管家分析绑定消息）
      final notes = (curStep['butlerNotes'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          <Map<String, dynamic>>[];
      if (notes.isNotEmpty) {
        for (final n in notes) {
          sb.writeln('$mark M$no [${n['ts']}] 管家：${n['text']}');
        }
        sb.writeln('  她：${curStep['userText']}');
      } else {
        sb.writeln('$mark M$no [$ts]$fromMark $speaker：${curStep['userText']}');
      }
      // 工具链（这条下面做了什么）
      for (final entry in tools.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final ok = v['ok'] == true;
        final brief = (v['brief'] ?? '').toString();
        sb.writeln('  - 你：调 ${entry.key} ${ok ? '✅' : '❌'}'
            '${brief.isEmpty ? '' : '：$brief'}');
      }
      if (reply.isNotEmpty) {
        sb.writeln('  - 你回：「${_short(reply, 60)}」');
      }
      if (tools.isNotEmpty) {
        final dec = _decisionHint(tools);
        if (dec.isNotEmpty) sb.writeln('  → 判断：$dec');
      }
    }
    // 待办事项（参考）：其他非 done 消息 ☐ 列出——男主一条条看过去
    final curIdx0 = curStep == null ? -1 : steps.indexOf(curStep);
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s['status'] == 'done') continue;
      if (i == curIdx0) continue; // 当前步已在上方显示
      final no = _stepNo(s, i);
      final fromMark = s['from'] == 'butler' ? '【管家】' : '';
      final ts = (s['ts'] ?? '').toString();
      final spk = s['from'] == 'butler' ? '管家' : '她';
      sb.writeln('☐ M$no [$ts]$fromMark $spk：'
          '${_short(s['userText'].toString(), 30)}（待办）');
    }
    // 引导：平行 + 插话判断 + 结束流程（8-11 19:4x 精简，对齐 GPT：
    // 固定层只放规则，流程细节这里一句话讲完，不叠话术）
    sb.writeln('—— 上面都是待办事项（参考）：一条条看过去，能一起做的'
        '就一起做（回MN 标你处理的是哪条，可一次回多条 回M1、回M2）。'
        '每条都要处理，判断：补充/修改/插入（先做插话，做完回原任务）'
        '/不做了（她叫停）——不能跳过任何一条');
    sb.writeln('—— 结束：全部标完 → 说"大流程也结束了" + 写摘要'
        '（save_summary）→ 管家归档，不再唤醒你（你没标完=没做完，'
        '管家不替标）。');
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
      final fromMark = s['from'] == 'butler' ? '【管家】' : '';
      final spk = s['from'] == 'butler' ? '管家' : '她';
      pending.add(
          '☐ M$no $fromMark $spk：${_short(s['userText'].toString(), 24)}');
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
      return '全部消息都处理完了：在这条回复上带"大流程也结束了"'
          '（结束标记）+ 写摘要（save_summary），管家归档合并历史，'
          '之后不再唤醒你。';
    }
    // 还有未处理 → 提示当前步 + 未处理数
    final curIdx = (f['currentStep'] as num?)?.toInt() ?? 0;
    Map<String, dynamic>? curStep;
    if (curIdx >= 0 &&
        curIdx < steps.length &&
        steps[curIdx]['status'] != 'done') {
      curStep = steps[curIdx];
    } else {
      for (final s in steps) {
        if (s['status'] != 'done') {
          curStep = s;
          break;
        }
      }
    }
    if (curStep == null) return null;
    final curNo = _stepNo(curStep, steps.indexOf(curStep));
    final pendingCount = pending.length;
    return '还有 $pendingCount 条未处理消息。当前第 $curNo 条「'
        '${_short(curStep['userText'].toString(), 20)}」还没处理。\n'
        '· 回复时标注你回的是哪条（回MN），可一次回多条（回M1、回M2）；\n'
        '· 全部处理完 → 固定结束流程：说"大流程做完了" + 写摘要'
        '（save_summary）。';
  }

  // ---- 工具 ----

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  static String _short(String s, [int n = 20]) {
    final t = s.trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }
}
