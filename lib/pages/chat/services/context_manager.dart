import '../../../ai_provider/models.dart';
import '../../../butler/context/context_tracker.dart';
import '../../../models/chat_session.dart';
import '../../../services/chat_database_service.dart';
import '../../../utils/debug_logger.dart';

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

  /// 摘要区预算：模型窗口的 15%（token）
  static const double summaryWindowRatio = 0.15;

  /// 中文 1 字 ≈ 0.75 token → 字符预算 = token 预算 × 1.33
  static const double tokenToChar = 1.33;

  /// 无窗口信息时的兜底窗口（deepseek 查表失败用）
  static const int fallbackWindow = 65536;

  /// 当前模型窗口（token）：已确认用确认值，否则查表，再兜底
  int _windowTokens(String personaId) {
    final w = ContextTracker.instance.windowOf(personaId);
    if (w > 0) return w;
    final hint = ContextTracker.instance.windowByModelHint('deepseek-chat');
    return hint > 0 ? hint : fallbackWindow;
  }

  /// 当前话题原文预算（字符数）→ 触发总结（窗口越大，原文窗口越大）
  int topicBudgetChars(String personaId) =>
      (_windowTokens(personaId) * topicWindowRatio * tokenToChar).round();

  /// 摘要区预算（字符数）→ 触发合并缩减
  int summaryBudgetChars(String personaId) =>
      (_windowTokens(personaId) * summaryWindowRatio * tokenToChar).round();

  /// 话题切换的相似度阈值（关键词 Jaccard 低于此值视为换话题）
  static const double topicSwitchThreshold = 0.15;

  /// 当前话题至少多少条消息才允许切换（防碎片化）
  static const int minTopicMessagesBeforeSwitch = 3;

  /// personaId → 当前话题
  final Map<String, TopicState> _topics = {};

  /// personaId → 摘要列表（每条 = 一个话题的要点）
  final Map<String, List<String>> _summaries = {};

  // ---- 写入 ----

  /// 记录用户消息（同时做话题切换检测）
  void feedUserMessage(String personaId, String text) {
    if (text.trim().isEmpty) return;
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    final words = _extractKeywords(text);
    if (words.isNotEmpty &&
        t.keywords.isNotEmpty &&
        t.raw.length >= minTopicMessagesBeforeSwitch &&
        _jaccard(words, t.keywords) < topicSwitchThreshold) {
      // 话题切换：旧话题原文留在 raw 里，等批量总结；开新话题
      _topics[personaId] = TopicState()..raw.add('用户：$text');
      _topics[personaId]!.keywords.addAll(words);
      return;
    }
    t.keywords.addAll(words);
    t.raw.add('用户：$text');
  }

  /// 记录男主回复（进当前话题原文）
  void feedAssistantMessage(String personaId, String text) {
    if (text.trim().isEmpty) return;
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    t.raw.add('男主：$text');
  }

  // ---- 读取 / 组装 ----

  /// 组装历史消息（摘要区 + 当前话题原文），插在 system 之后。
  /// 当前话题原文超过预算时截断最旧部分（兜底；正常由总结触发清空）。
  List<AIChatMessage> buildHistoryMessages(String personaId) {
    final out = <AIChatMessage>[];

    // 摘要区（一条 system 消息，前缀稳定 → 缓存命中）
    final summaries = _summaries[personaId];
    if (summaries != null && summaries.isNotEmpty) {
      final sb = StringBuffer('【对话摘要（按话题）】');
      for (final s in summaries) {
        sb.write('\n- $s');
      }
      out.add(AIChatMessage(role: 'system', content: sb.toString()));
    }

    // 当前话题原文（user/assistant 交替）
    // ⚠️ 不能用 insert(1)：无摘要时 out 为空 → RangeError 越界（重启后首条必崩）
    final t = _topics[personaId];
    if (t != null && t.raw.isNotEmpty) {
      var total = 0;
      final lines = <AIChatMessage>[];
      // 从尾部取（保留最近），预算内
      for (var i = t.raw.length - 1; i >= 0; i--) {
        total += t.raw[i].length;
        if (total > topicBudgetChars(personaId)) break;
        final line = t.raw[i];
        lines.add(line.startsWith('男主：')
            ? AIChatMessage(role: 'assistant', content: line.substring(3))
            : AIChatMessage(role: 'user', content: line.substring(3)));
      }
      // 倒序收集后正序追加（摘要区之后、当前消息之前）
      out.addAll(lines.reversed);
    }
    return out;
  }

  /// 是否需要触发男主总结（当前话题或待总结原文攒够了）
  bool needsSummarize(String personaId) {
    final t = _topics[personaId];
    if (t == null) return false;
    var total = 0;
    for (final line in t.raw) {
      total += line.length;
    }
    return total >= topicBudgetChars(personaId);
  }

  /// 取走全部待总结原文（当前话题原文），并清空。
  /// 返回原文全文（含"用户：/男主："前缀），供总结轮使用。
  String takePendingRaw(String personaId) {
    final t = _topics.remove(personaId);
    if (t == null) return '';
    return t.raw.join('\n');
  }

  /// 重启后恢复：摘要从 DB 读 + 从聊天记录重建最近原文（当前话题）。
  /// [sessionId] 为当前聊天会话；null 时只恢复摘要。
  Future<void> restore(String personaId, String? sessionId) async {
    try {
      final saved = await ChatDatabaseService.instance.loadSummaries(personaId);
      if (saved.isNotEmpty) {
        _summaries[personaId] = saved;
        DebugLogger.log('上下文管理', '♻️ 恢复摘要 ${saved.length} 条（persona $personaId）');
      }
      if (sessionId != null) {
        final lines = await ChatDatabaseService.instance
            .loadRecentChatLines(sessionId, maxChars: topicBudgetChars(personaId));
        if (lines.isNotEmpty) {
          final t = _topics.putIfAbsent(personaId, TopicState.new);
          for (final (role, text) in lines) {
            t.raw.add(role == ChatNodeRole.assistant.value ? '男主：$text' : '用户：$text');
          }
          DebugLogger.log('上下文管理', '♻️ 重建当前话题原文 ${lines.length} 条');
        }
      }
    } on Object catch (e) {
      DebugLogger.log('上下文管理', '⚠️ 上下文恢复失败: $e');
    }
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

  /// 摘要区是否需要合并缩减
  bool needsCompact(String personaId) {
    final list = _summaries[personaId];
    if (list == null || list.isEmpty) return false;
    var total = 0;
    for (final s in list) {
      total += s.length;
    }
    return total >= summaryBudgetChars(personaId);
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
