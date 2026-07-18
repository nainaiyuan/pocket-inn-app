/// 用户要素模型
///
/// 两种要素：
///   1. 原子要素 — 单点事实（"用户怕打雷"、"用户喜欢猫"）
///   2. 信号模式 — 条件组合（情绪+话题+时间→用户倾向）
///
/// 管家的视角：
///   看到的是 [信号A:XX%] + [信号B:XX%] + [时间/场景] → 用户倾向
///   不是整句结论，是条件组合。

/// 要素维度分类
enum UserDimension {
  physiology,  // 生理周期
  mood,        // 情绪模式
  habit,       // 行为习惯
  scene,       // 场景关联
  preference,  // 偏好
  relation;

  String get label {
    switch (this) {
      case UserDimension.physiology: return '生理';
      case UserDimension.mood: return '情绪';
      case UserDimension.habit: return '习惯';
      case UserDimension.scene: return '场景';
      case UserDimension.preference: return '偏好';
      case UserDimension.relation: return '关系';
    }
  }

  int get defaultImportance {
    switch (this) {
      case UserDimension.physiology: return 7;
      case UserDimension.mood: return 5;
      case UserDimension.habit: return 4;
      case UserDimension.scene: return 5;
      case UserDimension.preference: return 3;
      case UserDimension.relation: return 6;
    }
  }
}

/// 单条用户要素
class UserElement {
  final String id;
  final UserDimension dimension;
  final String content;   // 要素内容，简练
  final String source;    // 来源
  double importance;      // 0.0~1.0
  final List<String> triggerWords;  // 触发词（关键词降级用）
  final List<double>? embedding;    // 向量
  final DateTime discoveredAt;
  DateTime lastConfirmedAt;
  DateTime lastUsedAt;
  int confirmCount;
  bool isActive;

  UserElement({
    required this.id,
    required this.dimension,
    required this.content,
    this.source = '自动发现',
    double? importance,
    List<String>? triggerWords,
    this.embedding,
    DateTime? discoveredAt,
    DateTime? lastConfirmedAt,
    DateTime? lastUsedAt,
    this.confirmCount = 1,
    this.isActive = true,
  })  : importance = importance ?? (dimension.defaultImportance / 10.0),
        triggerWords = triggerWords ?? _extractTriggerWords(content),
        discoveredAt = discoveredAt ?? DateTime.now(),
        lastConfirmedAt = lastConfirmedAt ?? DateTime.now(),
        lastUsedAt = lastUsedAt ?? DateTime.now();

  static List<String> _extractTriggerWords(String content) {
    final words = content
        .replaceAll(RegExp(r'[，。！？、；：""''（）【】《》\s]'), ',')
        .split(',')
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty && w.length > 1)
        .toList();
    return words.isNotEmpty ? words : [content.substring(0, content.length > 4 ? 4 : content.length)];
  }

  double get freshnessScore {
    if (!isActive) return 0;
    final daysSinceConfirm = DateTime.now().difference(lastConfirmedAt).inDays;
    final daysSinceUse = DateTime.now().difference(lastUsedAt).inDays;
    double score = importance;
    if (daysSinceConfirm > 30) score *= 0.7;
    if (daysSinceConfirm > 90) score *= 0.5;
    if (daysSinceConfirm > 180) score *= 0.3;
    if (daysSinceUse < 7) score *= 1.1;
    score *= (1.0 + (confirmCount - 1) * 0.05);
    return score.clamp(0.0, 1.0);
  }

  bool get isStale => freshnessScore < 0.15 || DateTime.now().difference(lastConfirmedAt).inDays > 365;

  Map<String, dynamic> toMap() => {
    'id': id,
    'dimension': dimension.name,
    'content': content,
    'source': source,
    'importance': importance,
    'trigger_words': triggerWords.join(','),
    'embedding': embedding != null ? embedding!.map((e) => e.toStringAsFixed(6)).join(',') : null,
    'discovered_at': discoveredAt.toIso8601String(),
    'last_confirmed_at': lastConfirmedAt.toIso8601String(),
    'last_used_at': lastUsedAt.toIso8601String(),
    'confirm_count': confirmCount,
    'is_active': isActive ? 1 : 0,
  };

  factory UserElement.fromMap(Map<String, dynamic> map) => UserElement(
    id: map['id'] as String,
    dimension: UserDimension.values.firstWhere((d) => d.name == map['dimension']),
    content: map['content'] as String,
    source: map['source'] as String? ?? '自动发现',
    importance: (map['importance'] as num?)?.toDouble(),
    triggerWords: (map['trigger_words'] as String?)?.split(',').where((w) => w.isNotEmpty).toList(),
    embedding: map['embedding'] is String ? (map['embedding'] as String).split(',').map((s) => double.tryParse(s) ?? 0.0).toList() : null,
    discoveredAt: DateTime.parse(map['discovered_at'] as String),
    lastConfirmedAt: DateTime.parse(map['last_confirmed_at'] as String),
    lastUsedAt: DateTime.parse(map['last_used_at'] as String),
    confirmCount: map['confirm_count'] as int? ?? 1,
    isActive: (map['is_active'] as int?) == 1,
  );

  @override
  String toString() => '[${dimension.label}] $content (${(importance*100).toInt()}%)';
}

/// 信号模式 — 管家的"规律单位"
///
/// 不是一句人话，是条件组合：
///   signals: {话题:工作, 情绪:烦躁(80%), 行为:主动找人}
///   implication: "用户想找人吐槽工作"
///   confidence: 0.85（验证了6次）
class SignalPattern {
  final String id;
  final String implication;     // 简短含义（供调度引擎展示）
  final UserDimension dimension;
  final Map<String, double> signals;  // 信号名→权重
  double confidence;             // 0~1
  int confirmCount;
  DateTime lastMatched;

  SignalPattern({
    required this.id,
    required this.implication,
    required this.dimension,
    required this.signals,
    this.confidence = 0.2,
    this.confirmCount = 1,
    DateTime? lastMatched,
  }) : lastMatched = lastMatched ?? DateTime.now();

  /// 这条模式当前的信号组合是否匹配
  double matchScore(Map<String, double> currentSignals) {
    double totalWeight = 0;
    double matchedWeight = 0;

    for (final entry in signals.entries) {
      totalWeight += entry.value;
      if (currentSignals.containsKey(entry.key)) {
        // 信号存在即有分，取信号强度*权重
        matchedWeight += entry.value * currentSignals[entry.key]!;
      }
    }

    if (totalWeight == 0) return 0;
    final rawScore = matchedWeight / totalWeight;

    // 用置信度修正
    return rawScore * confidence;
  }

  /// 匹配成功时更新
  void reconfirm() {
    confirmCount++;
    lastMatched = DateTime.now();
    confidence = (confidence + 0.12).clamp(0.0, 0.95);
  }

  void decay(int daysSinceLastMatch) {
    if (daysSinceLastMatch > 45) {
      confidence = (confidence - 0.08 * (daysSinceLastMatch / 30)).clamp(0.0, 1.0);
    }
  }

  bool get isConfirmed => confidence >= 0.5;
  bool get isForgotten => confidence < 0.08;

  String toContextString() =>
    '（[${dimension.label}模式] $implication 置信度:${(confidence*100).toInt()}%）';
}
