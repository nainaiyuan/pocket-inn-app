import '../../utils/debug_logger.dart';

/// 单个男主的追踪状态
class _ContextState {
  final List<_ContextEntry> entries = [];
  int windowSize = 0; // 上下文窗口长度（#model 问出来的，0=未确认）
  int usedTokens = 0; // 最近一次调用消耗（API usage 精确值）
  bool cleared = true; // 是否处于"全清"状态（换角色后）
  DateTime? lastCallAt; // 上次调用时间
}

/// 已发送内容条目
class _ContextEntry {
  final String contentId;
  final String text;
  final String category;
  final DateTime sentAt;
  bool forgotten; // 被顶出窗口 → 遗忘
  _ContextEntry({
    required this.contentId,
    required this.text,
    required this.category,
    required this.sentAt,
    this.forgotten = false,
  });
}

/// 男主"记得清单"追踪器 —— 滚动计算男主到底还记得什么
///
/// 核心逻辑：
///   1. 每个男主（personaId）维护一张已发送内容清单（内容 + token 位置 + 时间）
///   2. 新内容不断进，旧内容被顶出窗口 → 标记"遗忘"（滚动遗忘）
///   3. 换角色（其他男主/管家调用过 API）→ 该男主清单全清 → 下次全推
///   4. 推内容前查清单：记得 → 不推；忘了 → 推
///   5. 核心内容（基础设定）永不遗忘（除非换角色全清）
///
/// 窗口大小来源：用 #model 问 AI（不硬编码，以 AI 回答为准）；
/// token 消耗用 API 精确值（usage.prompt_tokens）。
class ContextTracker {
  ContextTracker._();
  static final ContextTracker instance = ContextTracker._();

  /// 内容类别
  static const String catCore = 'core'; // 基础设定（角色卡/世界书/预设）
  static const String catMemory = 'memory'; // 记忆注入
  static const String catPattern = 'pattern'; // 规律
  static const String catHistory = 'history'; // 对话历史
  static const String catHandoff = 'handoff'; // 交接记录

  final Map<String, _ContextState> _states = {};

  _ContextState _state(String personaId) =>
      _states.putIfAbsent(personaId, () => _ContextState());

  /// 记录一次 API 调用（token 精确值，来自 usage）
  void recordCall(String personaId, int promptTokens) {
    final s = _state(personaId);
    s.usedTokens = promptTokens;
    s.lastCallAt = DateTime.now();
    s.cleared = false;
  }

  /// 设置窗口长度（#model 解析结果）
  void setWindow(String personaId, int window) {
    if (personaId.isEmpty || window <= 0) return;
    _state(personaId).windowSize = window;
    DebugLogger.log('上下文', '🎯 $personaId 上下文窗口确认: $window token');
  }

  /// 窗口长度（0 = 未确认，需要问 AI）
  int windowOf(String personaId) => _state(personaId).windowSize;

  /// 清空窗口设置回"未确认"（验收重置测试空间用，8-05 21:30：
  /// 上次验收 ⑤ 的 setWindow(800) 持久残留 → 下次验收 ①-③ 提前触发
  /// 总结 → forceRecover → ④ 误判全量带）
  void clearWindow(String personaId) {
    _states.remove(personaId);
  }

  /// 是否已确认窗口
  bool windowConfirmed(String personaId) =>
      _state(personaId).windowSize > 0;

  /// 内置窗口表（男主没报 #model 时的兜底；以男主自报为准）
  static const Map<String, int> knownModels = {
    'deepseek-chat': 65536,
    'deepseek-reasoner': 65536,
    'deepseek-r1': 65536,
    'gpt-4': 8192,
    'gpt-4o': 128000,
    'gpt-4o-mini': 128000,
    'glm-4': 128000,
    'glm-4-plus': 128000,
    'qwen-plus': 131072,
    'qwen-max': 32768,
    'qwen-turbo': 131072,
  };

  /// 按模型名查窗口（模糊匹配，返回 0 = 未知）
  int windowByModelHint(String modelHint) {
    if (modelHint.isEmpty) return 0;
    final lower = modelHint.toLowerCase();
    for (final entry in knownModels.entries) {
      if (lower.contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }
    return 0;
  }

  /// 记录发送了一条内容（进记得清单）
  void recordSent(
    String personaId,
    String text, {
    required String category,
  }) {
    if (personaId.isEmpty || text.isEmpty) return;
    final s = _state(personaId);
    // 防膨胀：遗忘条目超过 60 条 → 清掉最旧的遗忘条目（核心内容保留）
    final forgotten = s.entries.where((e) => e.forgotten).toList();
    if (forgotten.length > 60) {
      forgotten.sort((a, b) => a.sentAt.compareTo(b.sentAt));
      for (final e in forgotten.take(forgotten.length - 60)) {
        s.entries.remove(e);
      }
      DebugLogger.log('上下文', '🧽 清理遗忘条目（保留最近60条遗忘记录）');
    }
    // 防膨胀：总条目超过 300 → 直接删最旧的遗忘条目
    if (s.entries.length > 300) {
      final toRemove = s.entries
          .where((e) => e.forgotten)
          .toList()
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      while (s.entries.length > 300 && toRemove.isNotEmpty) {
        s.entries.remove(toRemove.removeAt(0));
      }
      DebugLogger.log('上下文', '🧽 条目超300，强制清理遗忘条目');
    }
    final contentId = '${category}_${text.hashCode}';
    for (final e in s.entries) {
      if (e.contentId == contentId) {
        return; // 同内容已登记
      }
    }
    s.entries.add(_ContextEntry(
      contentId: contentId,
      text: text,
      category: category,
      sentAt: DateTime.now(),
    ));
    _rollForget(s);
  }

  /// 滚动遗忘：窗口已确认且估算超 90% → 最旧的非核心内容标记遗忘
  void _rollForget(_ContextState s) {
    if (s.windowSize <= 0) return;
    var est = 0;
    for (final e in s.entries) {
      if (!e.forgotten && e.category != catCore) {
        est += e.text.length;
      }
    }
    final limit = (s.windowSize * 0.9).round();
    if (est <= limit) return;
    final sorted = s.entries
        .where((e) => !e.forgotten && e.category != catCore)
        .toList()
      ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    for (final e in sorted) {
      if (est <= limit) break;
      e.forgotten = true;
      est -= e.text.length;
      DebugLogger.log(
        '上下文',
        '🌬️ 男主遗忘了旧内容: ${e.text.length}字（被顶出窗口）',
      );
    }
  }

  /// 男主是否还记得某内容（清单里有且未遗忘）
  bool remembers(
    String personaId,
    String text, {
    String category = catMemory,
  }) {
    final s = _state(personaId);
    if (s.cleared) return false; // 换角色全清 → 什么都不记得
    final contentId = '${category}_${text.hashCode}';
    for (final e in s.entries) {
      if (e.contentId == contentId) {
        return !e.forgotten;
      }
    }
    return false; // 没发过 → 不记得 → 需要推
  }

  /// 换角色全清（其他男主/管家调用过 API → 上下文全没）
  void clearAll(String personaId) {
    final s = _state(personaId);
    s.entries.clear();
    s.cleared = true;
    s.usedTokens = 0;
    DebugLogger.log('上下文', '🧹 $personaId 上下文全清（角色切换/换 API）');
  }

  /// 标记"该男主正在被调用"（同一男主连续对话 → 上下文延续）
  void touch(String personaId) {
    if (personaId.isEmpty) return;
    final s = _state(personaId);
    s.cleared = false;
    s.lastCallAt = DateTime.now();
  }

  /// 上次调用时间
  DateTime? lastCallOf(String personaId) => _state(personaId).lastCallAt;

  /// 调试摘要
  String summary(String personaId) {
    final s = _state(personaId);
    final remembered = s.entries.where((e) => !e.forgotten).length;
    return '📊 $personaId 记得清单：共${s.entries.length}条，记得$remembered条'
        '，窗口${s.windowSize > 0 ? s.windowSize : '未确认'}'
        '，已用${s.usedTokens}token${s.cleared ? '（全清状态）' : ''}';
  }
}
