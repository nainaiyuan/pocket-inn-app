import 'dart:async';

import '../../../ai_provider/models.dart';
import '../../../butler/context/context_tracker.dart';
import '../../../services/chat_database_service.dart';
import '../../../services/storage_service.dart';
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
      fresh.raw.add('用户：$text');
      fresh.keywords.addAll(words);
      _topics[personaId] = fresh;
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

    // 恢复包（stateful 空闲超时后 AI 忘了 → 本次带"下次要带的上下文"接上；
    // 用户 21:52：男主提前写好的分类存档，管家恢复时带上）
    final recovery = _recovery[personaId];
    if (recovery != null && recovery.isNotEmpty) {
      out.add(AIChatMessage(
        role: 'system',
        content: '【上次的上下文（你提前写好的恢复包）】\n$recovery',
      ));
    }

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

  /// 只读查看当前原文（不取走不清空）。
  /// 用户 21:10：写当天日记时用——日记=男主每天结束的总结，
  /// 不能因为写日记就把上下文清了（用户可能还在聊）。
  String peekRaw(String personaId) {
    final t = _topics[personaId];
    if (t == null) return '';
    return t.raw.join('\n');
  }

  /// 重启后恢复：只恢复摘要区（男主总结的要点）。
  /// [sessionId] 不再重建当前话题原文——历史 = 本次对话实时记录的上下文
  /// （feedUserMessage/feedAssistantMessage，均为假面层替换后的干净文本）。
  /// DB 里用户消息是原始文本、男主消息是还原后文本，硬拉会泄露真实称呼
  /// （用户 20:04 反馈"三个用户/漏了妈妈"）；没历史就不加历史。
  Future<void> restore(String personaId, String? sessionId) async {
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
