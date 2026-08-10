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
  /// 无流程或已结束 → 立新流程（goal=第一条消息截断，steps=[这条]）；
  /// 有执行中流程 → 追加步骤（她随时插话 = 追加，跟长任务插话一致）
  static Future<void> feedUser(String personaId, String text) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (!_isTerminal(f) && f!['status'] == 'running') {
      // 追加步骤（8-10 00:49：复核已去掉，无置顶逻辑）
      final steps = _stepsOf(f);
      steps.add(_newStep(text));
      f['steps'] = steps;
      await _write(personaId, f);
      _log('对话流程', '📥 追加步骤 ${steps.length}：${_short(text)}');
      return;
    }
    // 立新流程（8-09 18:33：带流程编号）
    final flow = <String, dynamic>{
      'flowNo': await _nextFlowNo(),
      'goal': _short(text, 30),
      'status': 'running',
      'currentStep': 0,
      'steps': [_newStep(text)],
      'startedAt': DateTime.now().toIso8601String(),
    };
    await _write(personaId, flow);
    _log('对话流程', '📋 立流程 #${flow['flowNo']}：「${flow['goal']}」1 步');
  }

  static Map<String, dynamic> _newStep(String text, {bool isReview = false}) {
    final now = DateTime.now();
    return {
      'no': now.millisecondsSinceEpoch, // 时间戳 id（唯一）
      'userText': text.trim(),
      'ts': '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
      'status': 'pending',
      'tools': <String, dynamic>{}, // toolName -> {count, ok, brief}
      'reply': '',
      if (isReview) 'isReview': true, // 8-09 18:33：复核步骤（男主回复后自动挂）
    };
  }

  /// 管家分析备注 → 挂到最新用户步骤后面（8-10 用户定稿：用户说一句话，
  /// 管家分析出的记忆/习惯/情感波动等信息，插到这句话的流程步骤后面，
  /// 合并在一起做——不单独排队（不进#A）、不塞到正在处理的步骤）
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
    for (var i = 0; i < steps.length; i++) {
      if (steps[i]['status'] != 'done' && steps[i]['isReview'] != true) {
        target = i;
        break;
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

  /// 男主回复 → 消条目（完成步骤）
  /// 标注（回#N 数字是"没回的第几条"？不——v2 用步骤序号）：
  /// 简化：标注解析按步骤在清单里的显示序号（第1步、第2步）。
  /// 无标注 → FIFO 消最老 pending 步（默认回最老的，不猜）。
  /// 全部消完 → 流程 done。
  static Future<void> feedReply(String personaId, String replyText) async {
    if (personaId.isEmpty || replyText.trim().isEmpty) return;
    await warm(personaId);
    final f = _memCache;
    if (f == null || f['status'] != 'running') return;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return;
    final marked = _parseMarkedNos(replyText);
    var changed = false;
    var repliedReal = false; // 本轮消掉的条目里有真实用户步骤吗（复核追加条件）
    if (marked.isNotEmpty) {
      // 精确消：标注 #N = 第 N 步（绝对序号，跟清单显示一致）
      for (final no in marked) {
        if (no >= 1 && no <= steps.length) {
          final idx = no - 1;
          if (steps[idx]['status'] != 'done') {
            steps[idx]['status'] = 'done';
            steps[idx]['reply'] = replyText.trim();
            if (steps[idx]['isReview'] != true) repliedReal = true;
            changed = true;
          }
        }
      }
    } else {
      // FIFO：消最老 pending
      for (var i = 0; i < steps.length; i++) {
        if (steps[i]['status'] != 'done') {
          steps[i]['status'] = 'done';
          steps[i]['reply'] = replyText.trim();
          if (steps[i]['isReview'] != true) repliedReal = true;
          changed = true;
          break;
        }
      }
    }
    if (!changed) return;
    f['steps'] = steps; // _stepsOf 是拷贝，必须写回（FlowStore BUG-3 教训）
    // 8-09 20:1x（用户重新定义复核，纠正 18:33 实现）：
    // 【复核的真实语义】大流程结尾的"确认是否结束"步骤：
    // - 触发条件 = **这个流程（含插话小流程）里用过工具**。
    //   不管大流程还是小流程，只要调过工具 → 大流程结尾默认插复核，
    //   问男主：有补充吗？要调整流程吗？还是确认结束？
    // - **没调工具**（纯对话/纯插话）→ 默认流程已结束，不插复核。
    // - 男主**没确认** → 复核留在末尾；下个大流程（新用户消息）开始时
    //   复核置顶到第一步，男主先确认旧流程再处理新消息。
    // 防循环：消掉复核步骤本身不追加（repliedReal=false 已挡）；已有
    // pending 复核不重复追加。
    final allDone = steps.every((s) => s['status'] == 'done');
    final hasPendingReview =
        steps.any((s) => s['isReview'] == true && s['status'] != 'done');
    if (allDone && repliedReal && !hasPendingReview) {
      // 8-10 00:49（用户：去掉二次复核）——大流程全部消完 → 直接结束。
      // 男主模式 = 先干活再回复：回复（消掉大流程）本身就是结束，
      // 不再插复核二次唤醒确认（男主想补充会在最后回复里说；
      // 有下一个大流程 → 检查轮带清单唤醒男主继续走）。
      // 8-09 21:0x 规则保留在 finishCheck：男主没跟用户说过话就
      // 想结束（输出退出标记）→ 打回先补一句。
      f['status'] = 'done';
      f['currentStep'] = steps.length;
      await _write(personaId, f);
      _log('对话流程', '✔ 大流程已全部回应 → 直接结束（无复核，不二次唤醒）');
      return;
    }
    // 推进 currentStep 到第一个 pending（或标全部已回）
    var nextCur = -1;
    for (var i = 0; i < steps.length; i++) {
      if (steps[i]['status'] != 'done') {
        nextCur = i;
        break;
      }
    }
    f['currentStep'] = nextCur < 0 ? steps.length : nextCur;
    await _write(personaId, f);
    _log('对话流程', nextCur < 0
        ? '✔ 全部已回应（流程待男主退出标记结束）'
        : '✔ 消条目 → 当前第 ${nextCur + 1} 步');
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
    if (nos.any((x) => x < 1 || x > steps.length)) {
      return '编号超出范围（1-${steps.length}）';
    }
    // 8-09 20:18（用户：复核不能跳过）——复核不能参与合并，
    // 它是流程结尾的确认步骤，男主必须单独回答。
    if (nos.any((x) => steps[x - 1]['isReview'] == true)) {
      return '复核步骤不能合并——它问的是"还有要补充的吗？要调整流程吗？'
          '还是确认结束？"必须单独回答（回复/调整/输出退出标记）';
    }
    // 合并内容：新名字 or 自动拼原话
    final nameText = (name ?? '').trim();
    final mergedText = nameText.isNotEmpty
        ? nameText
        : '【合并】${nos.map((x) => _short(steps[x - 1]['userText'].toString(), 20)).join(' + ')}';
    final newStep = <String, dynamic>{
      'no': DateTime.now().millisecondsSinceEpoch,
      'userText': mergedText,
      'ts': _hhmm(),
      'status': 'pending',
      'tools': <String, dynamic>{},
      'reply': '',
      'mergedFrom': nos.map((x) => steps[x - 1]['userText'].toString()).toList(),
    };
    // 被合并步骤的工具链合并进新步骤（不丢工作记录）
    final tools = <String, dynamic>{};
    for (final x in nos) {
      final st = steps[x - 1];
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
    final sorted = [...nos]..sort();
    final insertPos = sorted.first - 1;
    final newSteps = <Map<String, dynamic>>[];
    for (var i = 0; i < steps.length; i++) {
      if (nos.contains(i + 1)) continue;
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
    if (nos.any((x) => x < 1 || x > steps.length)) {
      return '编号超出范围（1-${steps.length}）';
    }
    // 8-09 20:18（用户：复核不能跳过）——复核是管家插在大流程结尾的
    // 确认步骤，男主必须回答（补充/调整/确认结束），不能删掉绕过。
    if (nos.any((x) => steps[x - 1]['isReview'] == true)) {
      return '复核步骤不能删除——它问的是"还有要补充的吗？要调整流程吗？'
          '还是确认结束？"必须回答（回复/调整/输出退出标记）';
    }
    if (nos.length >= steps.length) return '不能删光所有步骤';
    final newSteps = <Map<String, dynamic>>[];
    for (var i = 0; i < steps.length; i++) {
      if (nos.contains(i + 1)) continue;
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
    // 全部已回应但流程没结束（男主没输出退出标记）→ 收尾检查：
    // 回复 ≠ 结束，工作义务还在——提示男主检查每步的工具链有没有 ❌/没找到
    // 8-10 00:49（用户：去掉二次复核）：不再有复核步骤分支，
    // 全部回应后直接收尾检查（确认做完 → 输出退出标记结束）。
    final allReplied = steps.every((s) => s['status'] == 'done');
    if (allReplied) {
      sb.writeln('✅ 已全部回应。收尾检查（回复≠结束，工作做完才结束）：');
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        final tools = _asMap(step['tools']);
        if (tools.isEmpty) continue;
        sb.writeln('  第${i + 1}步「${_short(step['userText'].toString(), 20)}」'
            '工具：${_toolsBrief(tools)}');
        final dec = _decisionHint(tools);
        if (dec.isNotEmpty) sb.writeln('    → $dec');
      }
      sb.writeln('没做完的（工具 ❌/没找到）→ 继续做完再结束；'
          '确认都做完了 → 回复末尾带结束命令结束流程：'
          '{"need_continue": false}');
      return sb.toString();
    }
    // 步骤清单（最多显示 6 步）
    final show = steps.length > 6 ? steps.sublist(steps.length - 6) : steps;
    final hidden = steps.length - show.length;
    if (hidden > 0) sb.writeln('（更早 $hidden 步已完成）');
    for (var i = 0; i < show.length; i++) {
      final step = show[i];
      final st = step['status']?.toString() ?? 'pending';
      final isCur = (st != 'done') && (steps.indexOf(step) == cur);
      final mark = st == 'done'
          ? '✅'
          : (isCur ? '▶' : '☐');
      final tools = _asMap(step['tools']);
      final reply = (step['reply'] as String?)?.toString().trim() ?? '';
      // 8-09 20:1x（用户实测）：复核步骤不在清单里占"第N步"位置——
      // 它会让男主以为要"回#N"，把已回复的内容重复说。
      // 复核只在末尾作为整体判断引导出现（见下方"复核"段）。
      if (step['isReview'] == true) continue;
      var line = '$mark 第${steps.indexOf(step) + 1}步 ${step['userText']}';
      if (st == 'done') {
        final toolPart = tools.isEmpty ? '' : '（工具：${_toolsBrief(tools)}）';
        final replyPart = reply.isEmpty ? '' : '→ 你回：${_short(reply, 40)}';
        line += '$toolPart$replyPart';
      } else if (tools.isNotEmpty) {
        line += '（处理中：${_toolsBrief(tools)}）';
      }
      sb.writeln(line);
      // 管家备注（8-10 用户：挂在触发它的那句话后面，合并做——
      // 记忆/习惯/情感波动等分析信息，男主处理这条时一起看一起做）
      final notes = (step['butlerNotes'] as List?)?.cast<Map<String, dynamic>>() ??
          <Map<String, dynamic>>[];
      for (final n in notes) {
        sb.writeln('  - [${n['ts']}] 管家：${n['text']}');
      }
      // 决策点：当前步
      if (isCur && tools.isNotEmpty) {
        final dec = _decisionHint(tools);
        if (dec.isNotEmpty) sb.writeln('   → 判断：$dec');
      }
    }
    // 当前步无工具 → 提示男主判断：直接回复消掉 or 调工具再回复消掉
    // 8-10 00:5x（用户：插话轮要让男主判断"直接回消掉还是要调用工具
    // 再说话消掉"，每轮插话都这样）
    final curStep = cur >= 0 && cur < steps.length ? steps[cur] : null;
    if (curStep != null &&
        curStep['status'] != 'done' &&
        _asMap(curStep['tools']).isEmpty) {
      sb.writeln('→ 当前步：判断——直接回复她消掉这条，'
          '还是要先调工具（查东西/记记忆）再回复消掉？');
    }
    // 8-09 20:1x：复核已去掉（8-10 00:49），无复核引导。
    // "没回"只数真实用户步骤（isReview != true）。
    final realPendingCount =
        steps.where((s) => s['status'] != 'done' && s['isReview'] != true).length;
    if (realPendingCount > 0) {
      sb.writeln('提示：还有 $realPendingCount 条没回（用户消息），先回她。'
          '${realPendingCount > 1 ? '一次回多条可标注 {"reply":"回#N、#M"}（N=第几步）一起消；否则默认只消最老一条。' : ''}');
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
        return '已全部回应，但第 ${steps.indexWhere((s) {
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
        }) + 1} 步有工具没做完（❌/没找到）——回去继续做完，'
            '做完输出退出标记结束流程。';
      }
      return '已全部回应，流程待你确认结束——没有遗漏就输出退出标记 '
          '{"need_continue": false}。';
    }
    // 8-09 18:33：pending 里最老的是复核步骤 → 引导回答完整性判断
    // 8-09 20:1x：复核不算"没回"——先看有没有真实用户步骤 pending
    final realPending = pending.where((s) => s['isReview'] != true).toList();
    if (realPending.isNotEmpty) {
      final briefs = realPending
          .take(3)
          .map((s) => '第${steps.indexOf(s) + 1}步「${_short(s['userText'].toString(), 20)}」')
          .join('、');
      final more = realPending.length > 3 ? ' 等${realPending.length}条' : '';
      return '还有 ${realPending.length} 条没回：$briefs$more——先回她，回完再结束；'
          '回多条可标注 {"reply":"回#N、#M"} 一起消。';
    }
    final briefs = pending
        .take(3)
        .map((s) => '第${steps.indexOf(s) + 1}步「${_short(s['userText'].toString(), 20)}」')
        .join('、');
    final more = pending.length > 3 ? ' 等${pending.length}条' : '';
    return '还有 ${pending.length} 条没回：$briefs$more——先回她，回完再结束；'
        '回多条可标注 {"reply":"回#N、#M"} 一起消。';
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
