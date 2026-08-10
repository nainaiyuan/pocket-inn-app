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
  static Future<int> _nextFlowNo() async {
    try {
      final p = await SharedPreferences.getInstance();
      final n = p.getInt(_counterKey) ?? 0;
      await p.setInt(_counterKey, n + 1);
      return n + 1;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch % 100000;
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
  /// 8-10 19:20（用户纠正）：分两种——
  /// - **没在处理**（无 running 流程）：用户的话 = 新的大流程（当前流程）
  /// - **处理中**（有 running 流程）：用户插话 = **插入的大流程**——
  ///   插到当前处理步骤（当前工具调用所在步骤）的**后面**，先处理完
  ///   用户的话（推为当前），后续步骤男主自己判断（处理完自动回后续）
  static Future<void> feedUser(String personaId, String text) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (!_isTerminal(f) && f!['status'] == 'running') {
      // 处理中 → 插到当前步骤后面（先处理用户的话）
      final steps = _stepsOf(f);
      // 8-10 23:0x：插话步骤分配稳定编号（不挤占已有编号）
      final step = _newStep(text, no: _nextStepNo(steps));
      var cur = -1;
      final curIdx = (f['currentStep'] as num?)?.toInt() ?? 0;
      if (curIdx >= 0 &&
          curIdx < steps.length &&
          steps[curIdx]['status'] != 'done') {
        cur = curIdx;
      }
      if (cur < 0) {
        for (var i = 0; i < steps.length; i++) {
          if (steps[i]['status'] != 'done') {
            cur = i;
            break;
          }
        }
      }
      steps.insert(cur < 0 ? steps.length : cur + 1, step);
      f['steps'] = steps;
      f['currentStep'] = cur < 0 ? steps.length : cur + 1; // 用户的话成为当前
      await _write(personaId, f);
      _log('对话流程', '📥 用户插话插入 #${cur + 2} 位并推为当前步：${_short(text)}');
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
  /// 8-10 19:0x（用户拍板，纠正"回复即消"bug）：
  /// - 回复**带【结束】标签** → 才消步骤（标了回#N 的 / 没标 FIFO 最老）
  /// - 回复**不带【结束】** → 不消！男主只是中途说话（②回复/询问她后继续），
  ///   流程保持 running，回复内容挂到对应步骤的 reply 字段（显示"你回：…"），
  ///   下次检查轮自动唤醒男主继续走，直到他打【结束】才算完。
  /// - 全部消完 → 流程 done（不再唤醒）。
  /// 8-10 22:1x（用户定稿，拆"消步骤"和"结束大流程"两个动作）：
  /// - **回#N（步骤序号）→ 消掉那一步**（不再要求必须带【结束】——
  ///   处理完一条就回#N 消掉，插话也是步骤，先回#N 消插话再继续大流程）
  /// - **结束大流程 = 输出总结论**：最后一句总结这一整个大流程
  ///   （她第一句原话 + 插话都做完/聊到），总结句里**带齐所有步骤的
  ///   回#N**（如"回#1、回#2"），再带【结束】标签。
  /// - **大流程没有独立的"消"动作——只有所有步骤都消完，大流程才结束**
  ///   （8-10 22:45 用户明确：确保里面步骤全部消掉才结束大流程；
  ///   因此不存在"回#flowNo 强制结束"——那会绕过全消前提，已删除）
  /// - 【结束】标签本身只消步骤（回#N 精确 / 无标记 FIFO 最老），
  ///   **不强制结束大流程**——中途误带【结束】不会提前结束；
  ///   带【结束】但还有步骤没回#N → endTagWarned 标记，检查轮提醒
  /// - 无回#N 无【结束】→ 纯对话，不消（回复挂步骤）
  /// - 所有步骤消完 → 流程自动 done（"中间的都消了才是结束大流程"）
  static Future<void> feedReply(String personaId, String replyText) async {
    if (personaId.isEmpty || replyText.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return;
    final hasEndTag = replyText.contains('【结束】');
    final marked = _parseMarkedNos(replyText);

    if (!hasEndTag && marked.isEmpty) {
      // 纯对话（无回#N 无【结束】）→ 不消步骤（8-10 19:0x 用户拍板）：
      // 中途说话 ≠ 结束。回复文本挂到目标步骤（标了回#N 的第一个 /
      // 默认当前步）的 reply 字段，流程保持 running，
      // 下次唤醒男主继续——他必须回#N 消步骤 / 回#flowNo 结束。
      var target = -1;
      if (marked.isNotEmpty) {
        for (final no in marked) {
          if (no >= 1 && no <= steps.length) {
            final idx = no - 1;
            if (steps[idx]['status'] != 'done') {
              target = idx;
              break;
            }
          }
        }
      }
      if (target < 0) {
        // 8-10 19:13（用户：男主每次只看当前步）——默认挂当前步
        final curIdx = (f['currentStep'] as num?)?.toInt() ?? 0;
        if (curIdx >= 0 &&
            curIdx < steps.length &&
            steps[curIdx]['status'] != 'done') {
          target = curIdx;
        }
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
      f['steps'] = steps; // _stepsOf 是拷贝，必须写回（FlowStore BUG-3 教训）
      await _write(personaId, f);
      _log('对话流程',
          '💬 男主回复（无回#N 无【结束】）→ 不消步骤，流程继续'
          '（第 ${target + 1} 步还挂着，下次检查轮唤醒男主继续处理）');
      return;
    }

    // 消步骤：回#N（步骤号）→ 精确消（8-10 22:1x：不再要求【结束】；
    // 8-10 23:0x：按稳定编号 no 匹配，不再按位置 index+1）；
    // 只有【结束】无标记 → FIFO 消最老 pending
    var changed = false;
    if (marked.isNotEmpty) {
      for (final no in marked) {
        final idx = _stepIndexByNo(steps, no);
        if (idx >= 0 && steps[idx]['status'] != 'done') {
          steps[idx]['status'] = 'done';
          steps[idx]['reply'] = replyText.trim();
          changed = true;
        }
      }
    } else if (hasEndTag) {
      // FIFO：消最老 pending
      for (var i = 0; i < steps.length; i++) {
        if (steps[i]['status'] != 'done') {
          steps[i]['status'] = 'done';
          steps[i]['reply'] = replyText.trim();
          changed = true;
          break;
        }
      }
    }
    if (!changed) {
      // 8-10 23:0x（用户实测：男主回#2 但流程只有 #1 → 无效编号
      // 什么都不消、回复也不挂 → finishCheck 判"没说过话"打回 →
      // 流程卡在 running，男主带【结束】也结束不了）：
      // · 带【结束】但编号无效 → FIFO 兜底消最老（男主明确想结束），
      //   消完落到下面 common 逻辑（还有 pending / 全消 done|总结轮）
      // · 纯回#N 无效（无【结束】）→ 回复挂到当前步（男主说过话了，
      //   finishCheck 才能通过），日志警告编号无效，不消步骤
      if (hasEndTag) {
        for (var i = 0; i < steps.length; i++) {
          if (steps[i]['status'] != 'done') {
            steps[i]['status'] = 'done';
            steps[i]['reply'] = replyText.trim();
            changed = true;
            break;
          }
        }
        if (changed) {
          _log('对话流程',
              '⚠️ 回#N 编号无效（${marked.join('、')}，流程只有 ${steps.length} 步），'
              '按【结束】FIFO 兜底消最老');
        }
      } else {
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
              '⚠️ 回#N 编号无效（${marked.join('、')}，流程只有 ${steps.length} 步），'
              '回复挂到第 ${target + 1} 步（不消步骤）');
        }
        return;
      }
    }
    f['steps'] = steps; // _stepsOf 是拷贝，必须写回（FlowStore BUG-3 教训）

    // 还有没回的步骤 → 保留下次处理（流程不结束，唤醒男主走完）
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
      // 8-10 22:1x（用户：总结论才结束大流程）：男主带【结束】但还有
      // 步骤没回#N → 不结束；标记提醒（checkBrief 下次唤醒时提示他
      // 处理完剩下的再总结结束）。正常回#N 消步骤 → 清标记。
      if (hasEndTag) {
        f['endTagWarned'] = true;
        _log('对话流程',
            '⚠️ 男主带【结束】但还有 $stillPending 条没消 → 不结束大流程'
            '（总结论才结束），标记提醒');
      } else {
        f.remove('endTagWarned');
      }
      f.remove('summarizePending'); // 男主继续干活 → 退出总结轮状态
      await _write(personaId, f);
      _log('对话流程',
          '🔚 消了 ${marked.isNotEmpty ? marked.length : 1} 条，'
          '还有 $stillPending 条没回 → 流程继续（检查轮唤醒男主走完）');
      return;
    }

    // 全部消完：
    // - 男主带【结束】（总结论/闲聊收尾）→ 男主主动确认结束 → done
    // - 男主只回#N 消完（没带【结束】）→ 不 done！进**总结轮**（8-10
    //   22:48 用户：大流程不能"自动结束"——男主可能误以为做完了
    //   （插话轮卡住被唤醒后草草处理）。总结轮 = 唤醒男主看一遍整个
    //   大流程（每步工具状态 ✅/❌），确认没有遗漏/要补充的，
    //   才带【结束】总结结束；有遗漏 → 先补充做完）
    if (hasEndTag) {
      f['status'] = 'done';
      f['currentStep'] = steps.length;
      f.remove('endTagWarned');
      f.remove('summarizePending');
      await _write(personaId, f);
      _log('对话流程', '🔚 男主带【结束】总结 → 大流程结束，不再唤醒');
      return;
    }
    f['status'] = 'running'; // 保持 running → 检查轮唤醒总结轮
    f['currentStep'] = steps.length;
    f['summarizePending'] = true; // checkBrief 显示总结轮提示
    f.remove('endTagWarned');
    await _write(personaId, f);
    _log('对话流程',
        '🔎 步骤全消但男主没带【结束】→ 总结轮：唤醒男主看一遍确认'
        '（有没有遗漏/要补充的），确认后带【结束】总结结束');
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

  static Future<void> finish(String personaId) async {
    if (personaId.isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
    f['status'] = 'done';
    f['currentStep'] = (_stepsOf(f).length);
    await _write(personaId, f);
    _log('对话流程', '🔚 男主输出退出标记，流程结束');
  }

  /// 解析男主回复里的消条目标注（第N步，1-based）
  /// 兼容格式：<reply>回#1、#2</reply> / "reply":"回#1、#2" / 回待#1 / 回#1
  static List<int> _parseMarkedNos(String reply) {
    final nos = <int>{};
    for (final m
        in RegExp(r'<reply>([\s\S]*?)</reply>', caseSensitive: false)
            .allMatches(reply)) {
      for (final n in RegExp(r'#(\d+)').allMatches(m.group(1) ?? '')) {
        nos.add(int.tryParse(n.group(1)!) ?? 0);
      }
    }
    for (final m in RegExp(r'"reply"\s*:\s*"([^"]*)"').allMatches(reply)) {
      final raw = (m.group(1) ?? '').replaceAll(r'\"', '"');
      for (final n in RegExp(r'#(\d+)').allMatches(raw)) {
        nos.add(int.tryParse(n.group(1)!) ?? 0);
      }
    }
    for (final m in RegExp(r'回(?:复)?\s*待?#(\d+)').allMatches(reply)) {
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
    sb.writeln('【对话流程${flowNo != null ? ' #$flowNo' : ''}】目标：${f['goal']}');
    if (status == 'done') {
      sb.writeln('✅ 流程已结束（全部回应 + 你确认无工作遗漏）。'
          '没有新消息就别再说话，输出退出标记 {"need_continue": false}。');
      return sb.toString();
    }
    // 全部步骤已消但流程没结束 → 总结轮（8-10 22:48 用户：大流程不能
    // "自动结束"，男主总结确认才结束）——列出所有步骤的工具状态，
    // 男主看一遍：有没有遗漏/要补充的 → 带【结束】总结结束
    final allReplied = steps.every((s) => s['status'] == 'done');
    if (allReplied) {
      sb.writeln('✅ 所有步骤都消了。总结轮——看一遍有没有遗漏/要补充的：');
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        final tools = _asMap(step['tools']);
        sb.writeln('  第${_stepNo(step, i)}步「${_short(step['userText'].toString(), 20)}」'
            '${tools.isEmpty ? '（无工具）' : '工具：${_toolsBrief(tools)}'}');
        final dec = _decisionHint(tools);
        if (dec.isNotEmpty) sb.writeln('    → $dec');
      }
      sb.writeln('有遗漏/没做完的（工具 ❌/没找到）→ 先补充做完再结束；'
          '确认全部做完 → 带【结束】标签总结结束'
          '（sys 字段写"【结束】"，总结这一整个大流程）');
      return sb.toString();
    }
    // ── 步骤清单（8-10 19:13 用户：男主每次只看**当前做的那一步**——
    // 消完自动推下一个上来，已消的进【历史流程】区，不报"还有几条没回"）──
    final doneCount = steps
        .where((s) => s['status'] == 'done' && s['isReview'] != true)
        .length;
    if (doneCount > 0) {
      sb.writeln('（已完成 $doneCount 条 → 历史，不重复显示）');
    }
    // 当前步 = currentStep 指向的未消步骤（兜底：指向已消/越界 → 找第一个未消）
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
      // 8-10 23:0x：显示稳定编号（创建时分配，插话/闹钟插入不影响）
      final no = _stepNo(curStep, steps.indexOf(curStep));
      // 8-10：管家插入的步骤（闹钟/系统事件）标【管家】来源
      final fromMark = curStep['from'] == 'butler' ? '【管家】' : '';
      final ts = (curStep['ts'] ?? '').toString();
      final tools = _asMap(curStep['tools']);
      final reply = (curStep['reply'] as String?)?.toString().trim() ?? '';
      final speaker = curStep['from'] == 'butler' ? '管家' : '她';
      // 8-11 03:2x（用户：男主做了还指他——箭头要变成打勾）：
      // 已做 = 回过话 或 工具全 ✅ → 显示 ✅（打勾），不再用 ▶ 指着
      final hasReply = reply.isNotEmpty;
      final toolsOk = tools.isNotEmpty &&
          tools.values.every((v) => v is Map && v['ok'] == true);
      final done = hasReply || toolsOk;
      final mark = done ? '✅' : '▶';
      // 管家备注（8-10 用户：挂在触发它的那句话后面，合并做；
      // 8-11 03:2x 用户：管家判断 = 第一步——显示在用户的话上面，
      // 男主先看到要处理什么；随本步骤一起消，不用单独回#N）
      final notes = (curStep['butlerNotes'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          <Map<String, dynamic>>[];
      if (notes.isNotEmpty) {
        for (final n in notes) {
          sb.writeln('$mark #$no [${n['ts']}] 管家：${n['text']}'
              '（随本步骤一起消）');
        }
        sb.writeln('  她：${curStep['userText']}');
      } else {
        sb.writeln('$mark #$no [$ts]$fromMark $speaker：${curStep['userText']}'
            '${done ? '（已做，待消）' : ''}');
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
      // 已回复内容（男主中途说过话但没消）
      if (reply.isNotEmpty) {
        sb.writeln('  - 你回：「${_short(reply, 60)}」');
      }
      // 决策点：当前步（工具结果机械提示，8-09 18:3x）
      if (tools.isNotEmpty) {
        final dec = _decisionHint(tools);
        if (dec.isNotEmpty) sb.writeln('  → 判断：$dec');
      }
      // ▶ 判断固定文本（8-10 23:0x：更新为 v3 语义——回#N 消步骤 +
      // 总结轮确认 + 闲聊【结束】收尾；8-11 03:1x：可一次消多个，
      // 最后一步带【结束】= 结束不唤醒）
      sb.writeln('▶ 判断：继续？① 调工具 ② 回复/询问她后继续 '
          '③ 做完了 → 回#N 消掉（可一次消多个；最后一步带【结束】'
          '结束不唤醒；闲聊 → 直接带【结束】收尾）');
      // 8-11 03:2x（用户：管家最后一句要和当前最后一步合并，男主直接
      // 在最后一步判断，不用再被唤醒）；8-11 03:32（用户纠正：管家不能
      // 断言"这是最后一步"——应该询问男主判断后续还有没有步骤）
      final pendingCount =
          steps.where((s) => s['status'] != 'done').length;
      if (pendingCount <= 1) {
        sb.writeln('管家：判断一下——这个大流程后续还有没有步骤？'
            '没有 → 回#N 消掉后直接带【结束】总结结束（不会再唤醒你）；'
            '还有 → 继续处理（追加步骤/调工具/回复她）');
      }
    }
    // 8-10 00:5x（用户：男主消掉大流程自带结尾命令）——结尾命令清单，
    // 男主消掉大流程（最后一步回复）时回复末尾带一个：
    // - 结束（不唤醒）/ 续命继续干活 / 与后续大流程合二为一
    sb.writeln('结尾命令（回复末尾带一个，管家识别，不会显示给她）：\n'
        '· {"need_continue": false} → 结束，不再唤醒\n'
        '· {"need_continue": true} → 续命：还有事要做，唤醒继续干活\n'
        '· {"next_action": "merge"} → 与后续大流程合二为一（剩余步骤'
        '合并一起处理）');
    return sb.toString();
  }

  /// 当前步决策点提示（根据工具结果机械生成，不靠 LLM）
  /// 扫描全部工具：有失败 → 失败提示；有"没找到"类结果 → 没找到提示；
  /// 全成功 → 回复完成提示。（8-09 18:3x：多工具时不能只看最后一个——
  /// "查了没找到→又记录成功"，没找到的事实必须还在决策点上）
  static String _decisionHint(Map<String, dynamic> tools) {
    var anyFail = false;
    var anyNotFound = false;
    var anyOk = false;
    for (final entry in tools.entries) {
      final v = entry.value;
      if (v is! Map) continue;
      final ok = v['ok'] == true;
      final brief = (v['brief'] ?? '').toString();
      if (!ok) {
        anyFail = true;
      } else {
        anyOk = true;
        if (brief.contains('没找到') ||
            brief.contains('没有找到') ||
            brief.contains('无结果') ||
            brief.contains('没有相关') ||
            brief.contains('暂无')) {
          anyNotFound = true;
        }
      }
    }
    if (anyFail) {
      return '工具没成功。继续（换工具/换参数再查）？还是回复她结束这步？';
    }
    if (anyNotFound) {
      return '查了没找到。继续查（换工具/换方式）？还是回复她结束这步？';
    }
    if (anyOk) {
      return '工具已成功，回复她就完成这步。';
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
      // 全部已回应 → 收尾检查（有工具 ❌/没找到 → 回去做完）
      var hasUnfinished = false;
      for (final s in steps) {
        final tools = _asMap(s['tools']);
        if (tools.isEmpty) continue;
        var anyBad = false;
        for (final v in tools.values) {
          if (v is Map) {
            final ok = v['ok'] == true;
            final brief = (v['brief'] ?? '').toString();
            if (!ok ||
                brief.contains('没找到') ||
                brief.contains('没有找到') ||
                brief.contains('无结果') ||
                brief.contains('没有相关') ||
                brief.contains('暂无')) {
              anyBad = true;
            }
          }
        }
        if (anyBad) {
          hasUnfinished = true;
          break;
        }
      }
      if (hasUnfinished) {
        final badIdx = steps.indexWhere((s) {
          final tools = _asMap(s['tools']);
          if (tools.isEmpty) return false;
          for (final v in tools.values) {
            if (v is Map) {
              final ok = v['ok'] == true;
              final brief = (v['brief'] ?? '').toString();
              if (!ok ||
                  brief.contains('没找到') ||
                  brief.contains('没有找到') ||
                  brief.contains('无结果') ||
                  brief.contains('没有相关') ||
                  brief.contains('暂无')) {
                return true;
              }
            }
          }
          return false;
        });
        // 8-10 22:48（用户：总结轮 = 看一遍确认）：
        return '总结轮：所有步骤都消了，但第 ${_stepNo(steps[badIdx], badIdx)} 步工具没做完'
            '（❌/没找到）——先回去补充做完，再带【结束】总结结束。';
      }
      // 8-10 22:48（用户：大流程不能"自动结束"）：步骤全消但男主没带
      // 【结束】→ 总结轮：男主看一遍所有步骤（工具 ✅/❌），确认没有
      // 遗漏/要补充的，才带【结束】总结结束；有遗漏 → 先补充做完
      if (f['summarizePending'] == true) {
        return '总结轮：所有步骤都消了。看一遍整个大流程有没有遗漏/'
            '要补充的——没有 → 带【结束】总结结束（总结这一整个大流程）；'
            '有 → 先补充做完再结束。';
      }
      return '已全部回应，流程待你确认结束——没有遗漏就输出退出标记 '
          '{"need_continue": false}。';
    }
    // 8-10 19:13（用户：男主每次只看当前步，不报"还有几条没回"）——
    // 唤醒只提示当前步：继续处理完，带【结束】消掉
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
    if (curStep == null) return null; // 全消（不该出现，防呆）
    // 8-10 22:1x（用户：男主带【结束】但还有步骤没消 → 不结束大流程）：
    // 提醒男主处理完剩下的再总结结束，别以为带【结束】就完了
    final endTagWarned = f['endTagWarned'] == true;
    // 8-10 22:2x（用户：闲聊一轮收尾，别无限嵌套）：男主回复了但没消
    // 步骤 → 提示分两种：闲聊 → 带【结束】直接收尾；干活 → 回#N 消掉
    final tail = endTagWarned
        ? '（你上轮带了【结束】但还有步骤没消——处理完剩下的再总结结束）'
        : '';
    final curNo = _stepNo(curStep, steps.indexOf(curStep));
    return '当前第 $curNo 步「'
        '${_short(curStep['userText'].toString(), 20)}」还没消。$tail\n'
        '· 这条只是闲聊/不用干活 → 回复带【结束】直接收尾'
        '（消步骤+结束大流程，一轮结束，不会再唤醒你）；\n'
        '· 还要继续干活 → 继续处理，做完回复里带 回#N 消掉那一步。';
  }

  // ---- 工具 ----

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  static String _toolsBrief(Map<String, dynamic> tools) {
    final parts = <String>[];
    tools.forEach((name, v) {
      if (v is Map) {
        final ok = v['ok'] == true ? '✅' : '❌';
        final brief = (v['brief'] ?? '').toString();
        parts.add('$name $ok${brief.isEmpty ? '' : '（${_short(brief, 30)}）'}');
      }
    });
    return parts.join('；');
  }

  static String _short(String s, [int n = 20]) {
    final t = s.trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }
}
