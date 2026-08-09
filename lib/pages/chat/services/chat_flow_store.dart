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

  static Map<String, dynamic>? _memCache;

  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) => logSink?.call(tag, msg);

  static String _key(String personaId) => '$_prefix$personaId';

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
      // 追加步骤
      final steps = _stepsOf(f);
      steps.add(_newStep(text));
      f['steps'] = steps;
      await _write(personaId, f);
      _log('对话流程', '📥 追加步骤 ${steps.length}：${_short(text)}');
      return;
    }
    // 立新流程
    final flow = <String, dynamic>{
      'goal': _short(text, 30),
      'status': 'running',
      'currentStep': 0,
      'steps': [_newStep(text)],
      'startedAt': DateTime.now().toIso8601String(),
    };
    await _write(personaId, flow);
    _log('对话流程', '📋 立流程：「${flow['goal']}」1 步');
  }

  static Map<String, dynamic> _newStep(String text) {
    final now = DateTime.now();
    return {
      'no': now.millisecondsSinceEpoch, // 时间戳 id（唯一）
      'userText': text.trim(),
      'ts': '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
      'status': 'pending',
      'tools': <String, dynamic>{}, // toolName -> {count, ok, brief}
      'reply': '',
    };
  }

  /// 工具执行 → 挂到步骤（8-09 18:4x 改：挂载点 = 第一个未消步骤；
  /// 全部已消 → 挂最后一步。支持"先回复再干活"：男主回复消完条目后
  /// 继续调工具，工具挂到最后一步上，工作不会丢）
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
      if (steps[i]['status'] != 'done') {
        target = i;
        break;
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
    if (marked.isNotEmpty) {
      // 精确消：标注 #N = 第 N 步（绝对序号，跟清单显示一致）
      for (final no in marked) {
        if (no >= 1 && no <= steps.length) {
          final idx = no - 1;
          if (steps[idx]['status'] != 'done') {
            steps[idx]['status'] = 'done';
            steps[idx]['reply'] = replyText.trim();
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
          changed = true;
          break;
        }
      }
    }
    if (!changed) return;
    f['steps'] = steps; // _stepsOf 是拷贝，必须写回（FlowStore BUG-3 教训）
    // 8-09 18:4x（用户设计定稿）：回复 ≠ 流程结束！
    // 男主先回复再干活是合法策略——回复只消"对话义务"（✅ 已回），
    // "工作义务"（查/记/做）还在。流程结束 = 男主输出退出标记
    // （need_continue:false，chat_page 调 finish()）才 done。
    // 所以这里不再自动 done，只推进 currentStep 到第一个 pending（或标全部已回）。
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

  /// 男主输出退出标记（need_continue:false）→ 流程结束
  /// 他声明"回完了+干完了"。还有没回的工作 → 也尊重他的判断
  /// （他可能决定放弃某项），流程直接 done。
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
    sb.writeln('【对话流程】目标：${f['goal']}');
    if (status == 'done') {
      sb.writeln('✅ 流程已结束（全部回应 + 你确认无工作遗漏）。'
          '没有新消息就别再说话，输出退出标记 {"need_continue": false}。');
      return sb.toString();
    }
    // 全部已回应但流程没结束（男主没输出退出标记）→ 收尾检查：
    // 回复 ≠ 结束，工作义务还在——提示男主检查每步的工具链有没有 ❌/没找到
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
          '确认都做完了 → 输出退出标记 {"need_continue": false} 结束流程。');
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
      var line = '$mark 第${steps.indexOf(step) + 1}步 ${step['userText']}';
      if (st == 'done') {
        final toolPart = tools.isEmpty ? '' : '（工具：${_toolsBrief(tools)}）';
        final replyPart = reply.isEmpty ? '' : '→ 你回：${_short(reply, 40)}';
        line += '$toolPart$replyPart';
      } else if (tools.isNotEmpty) {
        line += '（处理中：${_toolsBrief(tools)}）';
      }
      sb.writeln(line);
      // 决策点：当前步
      if (isCur && tools.isNotEmpty) {
        final dec = _decisionHint(tools);
        if (dec.isNotEmpty) sb.writeln('   → 判断：$dec');
      }
    }
    // 当前步无工具 → 提示直接回复
    final curStep = cur >= 0 && cur < steps.length ? steps[cur] : null;
    if (curStep != null &&
        curStep['status'] != 'done' &&
        _asMap(curStep['tools']).isEmpty) {
      sb.writeln('→ 当前步：直接回复她就完成（要查东西先调工具再回复）。');
    }
    // 消条目规则提示（合并消教育）
    final pendingCount = steps.where((s) => s['status'] != 'done').length;
    if (pendingCount > 0) {
      sb.writeln('提示：还有 $pendingCount 条没回，先回她。'
          '${pendingCount > 1 ? '一次回多条可标注 {"reply":"回#N、#M"}（N=第几步）一起消；否则默认只消最老一条。' : ''}');
    }
    // 重复回复警告（无未消条目却说话 → 由 buildText 的 done 分支覆盖；
    // 这里防"已消完但流程还没标 done"的边界，其实 done 分支已处理）
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
