import 'dart:async';

import '../../../ai_provider/models.dart';
import '../../../butler/context/context_tracker.dart';
import '../../../services/chat_database_service.dart';
import '../../../services/storage_service.dart';
import '../../../utils/debug_logger.dart';
import 'chat_storage_service.dart';

/// 上下文管理器 —— DeepSeek 无后端记忆，靠它让男主"记得"聊天。
///
/// 分层结构（缓存友好）：
///   messages = system(冻结人设) + 摘要区 + 当前话题原文 + 当前消息
///
/// - 摘要区：历史话题的男主视角要点（追加式，稳定时前缀不变 → 缓存命中）
/// - 当前话题原文：只保留当前话题的原始对话（攒够量 → 男主总结进摘要区 → 清空）
/// - 话题切换：本地关键词检测（免费），不立即总结，攒 2-3 个话题才批量总结
/// - 摘要区太大 → 合并缩减（男主把旧摘要再总结成更紧凑的）
///
/// 摘要持久化到 DB（context_summaries 表）：重启后 restore() 恢复摘要 +
/// 从聊天记录重建最近原文（当前话题）。
/// 单个话题状态（关键词 + 原文行）
class TopicState {
  final Set<String> keywords = {};
  final List<String> raw = []; // '用户：…' / '男主：…'
}

class ContextManager {
  static final ContextManager _instance = ContextManager._();
  factory ContextManager() => _instance;
  static ContextManager get instance => _instance;
  ContextManager._();

  /// 当前话题原文预算：模型窗口的 8%（token）
  static const double topicWindowRatio = 0.08;

  /// 管家指令日志（8-05 19:13 用户）：管家自动动作记录（时间+动作+结果）
  final Map<String, List<String>> _butlerLog = {};



  /// 摘要区预算：模型窗口的 15%（token）
  static const double summaryWindowRatio = 0.15;

  /// 中文 1 字 ≈ 0.75 token → 字符预算 = token 预算 × 1.33
  static const double tokenToChar = 1.33;

  /// 无窗口信息时的兜底窗口（deepseek 查表失败用）
  static const int fallbackWindow = 65536;

  /// 当前模型窗口（token）：已确认用确认值，否则按实际模型查表，
  /// 再兜底 deepseek-chat 查表，最后 fallback。
  /// 8-04 17:4x（用户：云端有对话的 AI 按它自己的上下文窗口算，
  /// 不是写死 deepseek）→ 调用方传 modelHint（当前 persona 配的模型）。
  int _windowTokens(String personaId, {String? modelHint}) {
    final w = ContextTracker.instance.windowOf(personaId);
    if (w > 0) return w;
    if (modelHint != null && modelHint.isNotEmpty) {
      final h = ContextTracker.instance.windowByModelHint(modelHint);
      if (h > 0) return h;
    }
    final hint = ContextTracker.instance.windowByModelHint('deepseek-chat');
    return hint > 0 ? hint : fallbackWindow;
  }

  /// 当前话题原文预算（字符数）→ 触发总结（窗口越大，原文窗口越大）
  int topicBudgetChars(String personaId, {String? modelHint}) =>
      (_windowTokens(personaId, modelHint: modelHint) *
              topicWindowRatio *
              tokenToChar)
          .round();

  /// 摘要区预算（字符数）→ 触发合并缩减
  int summaryBudgetChars(String personaId, {String? modelHint}) =>
      (_windowTokens(personaId, modelHint: modelHint) *
              summaryWindowRatio *
              tokenToChar)
          .round();

  /// 摘要区条数（验收/调试用：总结后应有 ≥1 条）
  List<String> summariesFor(String personaId) =>
      List.unmodifiable(_summaries[personaId] ?? const []);

  /// 话题切换的相似度阈值（关键词 Jaccard 低于此值视为换话题）
  static const double topicSwitchThreshold = 0.15;

  /// 当前话题至少多少条消息才允许切换（防碎片化）
  static const int minTopicMessagesBeforeSwitch = 3;

  /// personaId → 当前话题
  final Map<String, TopicState> _topics = {};

  /// personaId → 摘要列表（每条 = 一个话题的要点）
  final Map<String, List<String>> _summaries = {};

  /// personaId → 恢复包（stateful 空闲超时前男主写的"下次要带的上下文"，
  /// 用户 21:52：分类写好，管家好管理；超时后 AI 忘了 → 本次带恢复包接上）
  final Map<String, String> _recovery = {};

  /// personaId → 最后聊天时间戳（毫秒）。stateful 空闲超时检测用。
  /// 持久化到 SharedPreferences（重启不丢）。
  final Map<String, int> _lastChatMs = {};

  static const String _lastChatKeyPrefix = 'ctx_last_chat_';

  /// 距上次聊天的小时数；没记录返回 null。
  /// 用户 21:47：刷新周期 = "用户和 AI 多久没聊天 → 服务器释放上下文缓存"，
  /// 不是每 N 小时强制写；空闲超时 → 下次聊天时 AI 已不记得 → 沉淀+恢复。
  double? hoursSinceLastChat(String personaId) {
    final ms = _lastChatMs[personaId];
    if (ms == null) return null;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms))
            .inMinutes /
        60.0;
  }

  /// 加载最后聊天时间（restore 时调用；重启后也能检测空闲超时）
  void _loadLastChat(String personaId) {
    try {
      final ms = StorageService.instance.getInt('$_lastChatKeyPrefix$personaId');
      if (ms != null) {
        _lastChatMs[personaId] = ms;
      }
    } catch (_) {}
  }

  Future<void> _persistLastChat(String personaId) async {
    try {
      final ms = _lastChatMs[personaId];
      if (ms != null) {
        await StorageService.instance.setInt('$_lastChatKeyPrefix$personaId', ms);
      }
    } catch (_) {}
  }

  // ---- 写入 ----

  /// 时间戳（当天 HH:mm，跨天 MM-dd HH:mm）——8-04 17:0x（用户：
  /// 用户对话/男主对话/工具调用都要带时间戳，才能一一对应）。
  /// 追加式写在行首，旧行不变 → DeepSeek 前缀缓存不受影响。
  static String _ts(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year &&
        t.month == now.month &&
        t.day == now.day;
    final hhmm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return sameDay
        ? hhmm
        : '${t.month.toString().padLeft(2, '0')}-'
            '${t.day.toString().padLeft(2, '0')} $hhmm';
  }

  /// 记录用户消息（同时做话题切换检测）
  void feedUserMessage(String personaId, String text) {
    if (text.trim().isEmpty) return;
    // 记录"最后聊天时间"（stateful 空闲超时检测用：服务器多久没聊天
    // 就释放上下文缓存——用户 21:47 澄清，不是"每N小时强制写"，
    // 是"空闲 N 小时 → 缓存没了"，下次聊天要检测并沉淀+恢复）
    _lastChatMs[personaId] = DateTime.now().millisecondsSinceEpoch;
    unawaited(_persistLastChat(personaId));
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    final words = _extractKeywords(text);
    if (words.isNotEmpty &&
        t.keywords.isNotEmpty &&
        t.raw.length >= minTopicMessagesBeforeSwitch &&
        _jaccard(words, t.keywords) < topicSwitchThreshold) {
      // 话题切换：⚠️ 不能丢旧话题原文（里面是男主回答+用户消息，
      // 丢了历史就"完全没带上男主的回答"——用户 8-03 00:07 报）。
      // 旧话题原文并入新话题的 raw（保留男主回答），只重置关键词。
      final oldRaw = t.raw;
      final fresh = TopicState()..raw.addAll(oldRaw);
      fresh.raw.add('用户 [${_ts(DateTime.now())}]：$text');
      fresh.keywords.addAll(words);
      _topics[personaId] = fresh;
      return;
    }
    t.keywords.addAll(words);
    t.raw.add('用户 [${_ts(DateTime.now())}]：$text');
    // 8-04 16:4x：原文镜像落库（干净文本）——重启后 restore 重建用
    unawaited(ChatStorageService().appendContextRaw(personaId, '用户', text));
  }

  /// 记录男主回复（进当前话题原文）
  void feedAssistantMessage(String personaId, String text) {
    if (text.trim().isEmpty) return;
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    t.raw.add('男主 [${_ts(DateTime.now())}]：$text');
    // 8-04 16:4x：原文镜像落库（干净文本）——重启后 restore 重建用
    unawaited(ChatStorageService().appendContextRaw(personaId, '男主', text));
  }

  /// 记录工具调用（进当前话题原文）——8-04 17:0x（用户：上下文要留
  /// 地方放工具，男主才知道自己做过什么；成功写了什么/失败原因，
  /// 失败后才能继续调工具解决）。
  /// 行格式：'工具 [17:05]：record_memory ✅成功：已记录…'（不截断）
  /// 只针对 stateless（要带上下文的 AI）：stateful 轻量时不带历史。
  void feedToolCall(
      String personaId, String toolName, bool ok, String resultText) {
    if (toolName.trim().isEmpty) return;
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    final mark = ok ? '✅成功' : '❌失败';
    t.raw.add(
        '工具 [${_ts(DateTime.now())}]：$toolName $mark：$resultText');
    // 原文镜像落库（role='工具'，restore 重建时从 created_at 补时间戳）
    unawaited(ChatStorageService()
        .appendContextRaw(personaId, '工具', '$toolName $mark：$resultText'));
  }

  // ---- 读取 / 组装 ----

  /// 组装历史消息（摘要区 + 当前话题原文），插在 system 之后。
  /// 当前话题原文超过预算时截断最旧部分（兜底；正常由总结触发清空）。
  List<AIChatMessage> buildHistoryMessages(String personaId, {String? modelHint}) {
    final out = <AIChatMessage>[];

    // 恢复包（stateful 空闲超时后 AI 忘了 → 本次带"下次要带的上下文"接上；
    // 用户 21:52：男主提前写好的分类存档，管家恢复时带上）
    // 8-05 17:50 用户：恢复包 = 男主已总结过的上下文（精简版）→ 有它就
    // 【替换】整个上下文（摘要+工具历史+历史对话），不重复带。
    // 安全前提：恢复包只在空闲过半时写，写完用户继续聊会重置计时并重新
    // 沉淀 → 超时恢复时恢复包一定是最新的、后面没有新对话 → 替换不丢内容。
    final recovery = _recovery[personaId];
    if (recovery != null && recovery.isNotEmpty) {
      out.add(AIChatMessage(
        role: 'system',
        content: '【MEMORY_SUMMARY·恢复包】（你提前写好的上下文存档）\n$recovery',
      ));
      return out;
    }

    // 摘要区（一条 system 消息，前缀稳定 → 缓存命中）
    // 用户 8-03 02:41 模块化：长期记忆不拼 prompt，男主自己查工具；
    // 摘要区只留"提醒索引"（每天要记得的事/影响后续对话的约定）
    final summaries = _summaries[personaId];
    if (summaries != null && summaries.isNotEmpty) {
      final sb = StringBuffer(
        '【男主摘要】（你上次洗牌时总结的——下次聊天必带；'
        '它平时不动，只有工具历史+对话重新洗牌时才更新）');
      for (final s in summaries) {
        sb.write('\n- $s');
      }
      out.add(AIChatMessage(role: 'system', content: sb.toString()));
    }

    // 当前话题原文 —— 8-04 17:2x（用户：工具历史要独立分区，别混在对话里）：
    // 工具行 → 【工具使用历史】system 块（时间+工具名+成败+失败原因，
    // 不带调用过程/内容详情——记了什么按时间戳在互动历史里对应）；
    // 用户/男主行 → 互动历史（user/assistant，保留时间戳）
    // ⚠️ 不能用 insert(1)：无摘要时 out 为空 → RangeError 越界（重启后首条必崩）
    final t = _topics[personaId];
    if (t != null && t.raw.isNotEmpty) {
      var total = 0;
      final lines = <AIChatMessage>[];
      final toolLines = <String>[];
      // 从尾部取（保留最近），预算内
      for (var i = t.raw.length - 1; i >= 0; i--) {
        total += t.raw[i].length;
        if (total > topicBudgetChars(personaId, modelHint: modelHint)) break;
        final line = t.raw[i];
        if (line.startsWith('工具')) {
          toolLines.add(line);
        } else if (line.startsWith('男主')) {
          lines.add(AIChatMessage(
              role: 'assistant', content: _stripPrefix(line, keepTs: true)));
        } else {
          lines.add(AIChatMessage(
              role: 'user', content: _stripPrefix(line, keepTs: true)));
        }
      }
      // 工具使用历史：独立 system 块（在互动历史之前）
      // 8-04 17:3x（用户：跨天聊天要按日期分区，工具和对话才能对应）：
      // 工具历史也按日期分组（【工具使用历史 · 2026/6/28】）
      if (toolLines.isNotEmpty) {
        final sb = StringBuffer(
            '【工具使用历史】（男主执行过的工具，时间戳与互动历史对应；'
            '成功时记了什么、失败时原因是什么，按日期+时间在互动历史里对照）');
        DateTime? lastDay;
        for (final l in toolLines.reversed) {
          final ts = _toolTs(l);
          final day = ts == null ? null : _tsDate(ts);
          if (day != null && (lastDay == null || !_sameDay(day, lastDay))) {
            sb.write('\n【工具使用历史 · ${_dateLabel(day)}】');
            lastDay = day;
          }
          sb.write('\n${_toolHistoryLine(l)}');
        }
        out.add(AIChatMessage(role: 'system', content: sb.toString()));
      }
      // 历史分区（8-05 19:13 用户定稿定义）：
      // 【管家历史】= 管家（系统）过去发的精简指令记录（几点/动作/完成或失败+原因），
      //   如 '[19:00] 写日记 → ✅完成'——不是男主发言！
      // 【聊天历史】= 用户和男主（AI）的对话，user/assistant 按时间线交替，
      //   各带时间戳+日期分组。
      final butlerLog = _butlerLog[personaId];
      if (butlerLog != null && butlerLog.isNotEmpty) {
        final sb = StringBuffer(
            '【管家历史】（管家自动执行过的指令记录：时间+动作+结果。'
            '男主可参考，如写日记/总结是否成功）');
        DateTime? lastDay;
        for (final l in butlerLog) {
          final day = _tsDate(l);
          if (day != null && (lastDay == null || !_sameDay(day, lastDay))) {
            sb.write('\n【管家历史 · ${_dateLabel(day)}】');
            lastDay = day;
          }
          sb.write('\n$l');
        }
        out.add(AIChatMessage(role: 'system', content: sb.toString()));
      }
      DateTime? lastDay;
      for (final m in lines.reversed) {
        final day = _tsDate(m.content);
        if (day != null && (lastDay == null || !_sameDay(day, lastDay))) {
          out.add(AIChatMessage(
              role: 'system',
              content: '【聊天历史 · ${_dateLabel(day)}】（该日期：几点谁说了什么）'));
          lastDay = day;
        }
        out.add(m);
      }
    }
    return out;
  }

  /// 记录管家自动指令日志（8-05 19:13 用户：管家历史 = 管家发的精简指令，
  /// 时间+动作+结果，男主参考用）。动作如：写日记/总结/沉淀。
  void logButlerAction(String personaId, String action, String result) {
    final now = DateTime.now();
    final ts = _ts(now);
    // 带方括号时间戳（_tsDate 按 [HH:mm] 解析 → 日期分组才能生效）
    (_butlerLog[personaId] ??= []).add('[$ts] $action → $result');
    // 只留最近 20 条（精简，不占窗口）
    final list = _butlerLog[personaId]!;
    if (list.length > 20) list.removeRange(0, list.length - 20);
  }

  /// 工具行提取时间戳：'工具 [06-28 17:01]：query_diary …' → '[06-28 17:01]'
  static String? _toolTs(String rawLine) {
    final m = RegExp(r'^工具 (\[[^\]]+\])：')
        .firstMatch(rawLine.split('\n').first);
    return m?.group(1);
  }

  /// 从时间戳解析日期：'[17:01]' → 今天；'[06-28 17:01]' → 今年6月28日
  /// （跨年修正：时间戳月份 > 当前月份 → 去年，如 12/31 聊到 1/1）
  static DateTime? _tsDate(String ts) {
    final m = RegExp(r'\[(?:(\d{2})-(\d{2}) )?(\d{2}):(\d{2})\]')
        .firstMatch(ts);
    if (m == null) return null;
    final now = DateTime.now();
    final hh = int.parse(m.group(3)!);
    final mm = int.parse(m.group(4)!);
    if (m.group(1) != null) {
      final mon = int.parse(m.group(1)!);
      final y = mon > now.month ? now.year - 1 : now.year;
      return DateTime(y, mon, int.parse(m.group(2)!), hh, mm);
    }
    return DateTime(now.year, now.month, now.day, hh, mm);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 日期标题：2026/6/28（用户 8-04 17:3x 指定格式）
  static String _dateLabel(DateTime d) => '${d.year}/${d.month}/${d.day}';

  /// 工具历史条目：只显示状态，不带调用过程/内容详情。
  /// '工具 [17:04]：query_diary ❌失败：未找到相关日记'
  ///   → '- [17:04] query_diary ❌失败：未找到相关日记'
  /// '工具 [17:02]：record_memory ✅成功：已记录…'
  ///   → '- [17:02] record_memory ✅成功'（成功只报状态，记了什么看互动历史）
  static String _toolHistoryLine(String rawLine) {
    final first = rawLine.split('\n').first;
    final m = RegExp(r'^工具 (\[[^\]]+\])：(.+?) (✅成功|❌失败)')
        .firstMatch(first);
    if (m == null) {
      return '- ${first.replaceFirst('工具 ', '')}';
    }
    final ts = m.group(1)!;
    final name = m.group(2)!.trim();
    final status = m.group(3)!;
    if (status == '✅成功') return '- $ts $name ✅成功';
    final reason = first.contains('❌失败：')
        ? first.split('❌失败：').last.trim()
        : '';
    return reason.isEmpty ? '- $ts $name ❌失败' : '- $ts $name ❌失败：$reason';
  }

  /// 去掉行前缀（'用户 [17:05]：xxx' / '用户：xxx'）
  /// keepTs=true → '[17:05] xxx'（互动历史保留时间戳，用户 8-04 17:2x）
  static String _stripPrefix(String line, {bool keepTs = false}) {
    final idx = line.indexOf('：');
    if (idx < 0) return line;
    final rest = line.substring(idx + 1);
    if (!keepTs) return rest;
    final tsMatch =
        RegExp(r'\[[^\]]+\]').firstMatch(line.substring(0, idx));
    final ts = tsMatch?.group(0) ?? '';
    return ts.isEmpty ? rest : '$ts $rest';
  }

  /// 是否需要触发男主总结（当前话题或待总结原文攒够了）
  bool needsSummarize(String personaId, {String? modelHint}) {
    final t = _topics[personaId];
    if (t == null) return false;
    var total = 0;
    for (final line in t.raw) {
      total += line.length;
    }
    return total >= topicBudgetChars(personaId, modelHint: modelHint);
  }

  /// 取走全部待总结原文（当前话题原文），并清空。
  /// 返回原文全文（含"用户：/男主："前缀），供总结轮使用。
  String takePendingRaw(String personaId) {
    final t = _topics.remove(personaId);
    if (t == null) return '';
    return t.raw.join('\n');
  }

  /// 取走待总结原文（8-05 19:19 用户定稿，19:25 修正编号）：
  /// - 只返回【对话行】（用户/男主），工具行不发——工具/管家历史不重要就扔掉；
  /// - 编号 = 当前原文的【相对编号】，每次从 1 开始（#1-#N，N=当次对话条数）。
  ///   19:25 用户：绝不能全局递增（#1-#50 → #51-#100 无限长，编号占满窗口）；
  ///   总结完原文清空 → 下次新对话重新从 #1 编号。
  /// - 原文取走即清空（被摘要替换）。
  (int, int, String) takePendingRawWithRange(String personaId) {
    final t = _topics.remove(personaId);
    if (t == null) return (0, 0, '');
    final chatLines =
        t.raw.where((l) => !l.startsWith('工具')).toList();
    return (1, chatLines.length, chatLines.join('\n'));
  }

  /// 清空管家指令日志（8-05 19:19 用户：总结后不重要的扔掉）
  void clearButlerLog(String personaId) => _butlerLog.remove(personaId);

  /// 只读查看当前原文（不取走不清空）。
  /// 用户 21:10：写当天日记时用——日记=男主每天结束的总结，
  /// 不能因为写日记就把上下文清了（用户可能还在聊）。
  String peekRaw(String personaId) {
    final t = _topics[personaId];
    if (t == null) return '';
    return t.raw.join('\n');
  }

  /// 验收/调试：当前话题原文长度（判断 needsSummarize 为什么没触发）
  int debugRawLength(String personaId) => peekRaw(personaId).length;

  /// 验收/调试：当前话题是否存在（t==null 时 needsSummarize 直接 false）
  bool debugTopicExists(String personaId) => _topics.containsKey(personaId);

  /// 🔁 组装"让男主重新认识"的上下文（8-04 23:4x 用户）：
  /// 已总结摘要（提醒索引）+ 恢复包（存档）+ 未总结原文。
  /// 用户明确：总结过的原文不重复扔——总结时 takePendingRaw 已清空 raw，
  /// 所以 peekRaw 天然就是"当次未总结的部分"；已总结的只带精炼摘要。
  /// 原文全量不截断（重新认识要的是完整，不是预算内）。
  String buildResyncContext(String personaId) {
    final sb = StringBuffer();
    final summaries = _summaries[personaId];
    if (summaries != null && summaries.isNotEmpty) {
      sb.write('【男主摘要】（你之前总结的提醒：约定/承诺/正在做的事）\n');
      for (final s in summaries) {
        sb.write('- $s\n');
      }
    }
    final recovery = _recovery[personaId];
    if (recovery != null && recovery.isNotEmpty) {
      sb.write('\n【恢复包】（你上次空闲前写的存档）\n$recovery\n');
    }
    final raw = peekRaw(personaId);
    if (raw.trim().isNotEmpty) {
      sb.write('\n【最近聊天原文】（总结之后新聊的，还没总结过）\n$raw');
    }
    return sb.toString();
  }

  /// 重启后恢复：恢复摘要区 + 原文重建。
  /// 8-04 16:4x（用户"切换AI后男主失忆"）：原来只恢复摘要、不重建原文
  /// （DB 里用户消息是原始文本，硬拉会泄露真实称呼——用户 20:04 反馈）。
  /// 现在 feed 时同步落库【假面层替换后的干净文本】镜像（context_raw_logs），
  /// 重启后从这里重建原文 → 男主记得聊过什么，且不泄露称呼。
  Future<void> restore(String personaId, String? sessionId, {String? modelHint}) async {
    try {
      _loadLastChat(personaId);
      final saved = await ChatDatabaseService.instance.loadSummaries(personaId);
      if (saved.isNotEmpty) {
        _summaries[personaId] = saved;
        DebugLogger.log('上下文管理', '♻️ 恢复摘要 ${saved.length} 条（persona $personaId）');
      }
      final recovery = await ChatDatabaseService.instance.loadRecovery(personaId);
      if (recovery != null && recovery.isNotEmpty) {
        _recovery[personaId] = recovery;
        DebugLogger.log('上下文管理', '📦 恢复包已加载（persona $personaId）');
      }
      // 原文重建：只有内存里没有时才拉（restore 只跑一次，正常为空）
      final t = _topics[personaId];
      if (t == null || t.raw.isEmpty) {
        final mirror = await ChatStorageService().loadContextRaw(personaId);
        if (mirror.isNotEmpty) {
          final fresh = TopicState();
          var total = 0;
          for (final m in mirror) {
            // 8-04 17:0x：重建时从落库时间补时间戳 → 跨重启也能一一对应
            final ts =
                _ts(DateTime.fromMillisecondsSinceEpoch(m.createdAt));
            final line = '${m.role} [$ts]：${m.text}';
            total += line.length;
            if (total > topicBudgetChars(personaId, modelHint: modelHint)) break;
            fresh.raw.add(line);
          }
          _topics[personaId] = fresh;
          DebugLogger.log('上下文管理',
              '♻️ 原文重建 ${fresh.raw.length} 条（干净文本镜像，${total} 字）');
        }
      }
    } on Object catch (e) {
      DebugLogger.log('上下文管理', '⚠️ 上下文恢复失败: $e');
    }
  }

  /// 最近一条用户消息原文（去前缀，保留时间戳 '[17:05] xxx'）。
  /// 8-04 17:0x（用户：工具轮组装时📄看不到当前用户消息）：
  /// 工具轮组装发生在用户消息 feed 之后 → 原文最后一条用户消息
  /// 就是"当前这条"，取出来和工具结果合并成【当前互动】。
  String? lastUserMessageFor(String personaId) {
    final t = _topics[personaId];
    if (t == null) return null;
    for (var i = t.raw.length - 1; i >= 0; i--) {
      final line = t.raw[i];
      if (line.startsWith('用户')) {
        return _stripPrefix(line, keepTs: true);
      }
    }
    return null;
  }

  /// 追加一条摘要（男主总结输出）——同步持久化到 DB
  Future<void> appendSummary(String personaId, String summary) async {
    final list = _summaries.putIfAbsent(personaId, () => []);
    // 摘要本身可能多行 → 按行拆成多条，便于后续缩减
    for (final line in summary.split('\n')) {
      final l = line.trim().replaceAll(RegExp(r'^[-•*\d.、]+'), '').trim();
      if (l.isNotEmpty) {
        list.add(l);
        await ChatDatabaseService.instance.saveSummary(personaId, l);
      }
    }
  }

  /// 保存恢复包（内存 + DB 覆盖式）。
  /// 用户 21:52：stateful 空闲超时前男主写的"下次要带的上下文"，
  /// 分类存好（日记/摘要/恢复包三样分开），管家好管理。
  Future<void> saveRecovery(String personaId, String content) async {
    final c = content.trim();
    if (c.isEmpty) return;
    _recovery[personaId] = c;
    await ChatDatabaseService.instance.saveRecovery(personaId, c);
  }

  /// 读恢复包；没有返回 null。
  String? recoveryFor(String personaId) => _recovery[personaId];

  /// 摘要区是否需要合并缩减
  bool needsCompact(String personaId, {String? modelHint}) {
    final list = _summaries[personaId];
    if (list == null || list.isEmpty) return false;
    var total = 0;
    for (final s in list) {
      total += s.length;
    }
    return total >= summaryBudgetChars(personaId, modelHint: modelHint);
  }

  /// 取走摘要区全文并清空（供缩减轮使用）——同步清 DB
  Future<String> takeSummariesForCompact(String personaId) async {
    final list = _summaries.remove(personaId);
    if (list == null || list.isEmpty) return '';
    await ChatDatabaseService.instance.clearSummaries(personaId);
    return list.map((s) => '- $s').join('\n');
  }

  /// 总结失败回滚：原文放回当前话题（下次再试）
  void restoreRaw(String personaId, String raw) {
    if (raw.trim().isEmpty) return;
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    t.raw.addAll(raw.split('\n').where((l) => l.trim().isNotEmpty));
  }

  /// 缩减失败回滚：摘要区放回——同步写 DB
  Future<void> restoreSummaries(String personaId, String old) async {
    if (old.trim().isEmpty) return;
    final list = _summaries.putIfAbsent(personaId, () => []);
    for (final line in old.split('\n')) {
      final l = line.trim().replaceAll(RegExp(r'^[-•*\d.、]+'), '').trim();
      if (l.isNotEmpty) {
        list.add(l);
        await ChatDatabaseService.instance.saveSummary(personaId, l);
      }
    }
  }

  // ---- 关键词 / 相似度（本地，免费） ----

  // ── AI 切换检测（8-04 16:4x 用户："切换AI第一次必须全量带"）──
  // 记录"上次给这个 persona 组装上下文的 provider id"（持久化）。
  // 变了 = 切换/首次 → 本次全量带（stateful 也带，否则 AI 不知道发生了什么）；
  // 没变 = 连续对话 → stateful 轻量、stateless 照旧全量。
  static const String _providerKeyPrefix = 'ctx_last_provider_';

  /// 标记本次使用的 provider，返回是否"切换/首次"。
  /// [providerId] 为 null（无可用 provider）时只返回当前状态不更新。
  bool noteProviderUsed(String personaId, String? providerId) {
    final last = StorageService.instance.getString('$_providerKeyPrefix$personaId');
    if (providerId == null || providerId.isEmpty) {
      return last == null || last.isEmpty;
    }
    final switched = last == null || last.isEmpty || last != providerId;
    if (switched) {
      StorageService.instance.setString('$_providerKeyPrefix$personaId', providerId);
    }
    return switched;
  }

  /// 清掉"最近使用 AI"记录（8-04 21:1x 自检页 T2 二次跑失败修复：
  /// 测试 persona 上次跑的 lastProvider 残留 → 再跑变"连续使用"而非"首次"）
  Future<void> clearProviderUsed(String personaId) async {
    try {
      await StorageService.instance.remove('$_providerKeyPrefix$personaId');
    } catch (_) {}
  }

  /// 验收/测试钩子（8-04 21:3x 用户：stateful 空闲超时路径也要测）：
  /// 模拟"上次聊天时间"，自检页 T13 + 一键验收 ⑦沉淀/⑧超时恢复 用。
  /// 只改内存（持久化 lastChat 由 feed 维护，测试结束不残留）。
  void debugSetLastChatAt(String personaId, DateTime time) {
    _lastChatMs[personaId] = time.millisecondsSinceEpoch;
  }

  static const _stopWords = {
    '的', '了', '吗', '呢', '啊', '吧', '我', '你', '他', '她', '它',
    '这', '那', '是', '在', '有', '和', '就', '都', '也', '很', '还',
    '什么', '怎么', '今天', '昨天', '明天', '我们', '你们', '他们',
  };

  Set<String> _extractKeywords(String text) {
    final out = <String>{};
    final re = RegExp(r'[\u4e00-\u9fa5]{2,}|[a-zA-Z]{2,}');
    for (final m in re.allMatches(text)) {
      final w = m.group(0)!;
      if (!_stopWords.contains(w)) out.add(w);
    }
    return out;
  }

  double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final inter = a.intersection(b).length;
    final union = a.union(b).length;
    return union == 0 ? 0 : inter / union;
  }
}
