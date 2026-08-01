/// 情绪分析器 — 关键词简单版
///
/// 不依赖任何模型文件，纯关键词匹配。
/// 适合：测试、断网备选、模型加载失败回退。
///
/// 用法：
///   final analyzer = KeywordMoodAnalyzer();
///   final result = analyzer.analyze("今天好开心");
///   print(result.dimensions);  // { "开心": 80, "依恋": 20, ... }

import 'mood_interface.dart';

/// 简单的关键词 → 标签映射
class KeywordMoodAnalyzer implements IMoodAnalyzer {
  final Map<String, double> _baseline = {};
  int _sampleCount = 0;

  /// 关键词 → 情绪标签映射表
  static const Map<String, Map<String, double>> _keywordToMood = {
    '开心': {'开心': 80, '情绪高涨': 60, '依恋': 20},
    '高兴': {'开心': 75, '情绪高涨': 55, '依恋': 15},
    '哈哈': {'开心': 70, '情绪高涨': 50, '依恋': 10},
    '好烦': {'生气': 60, '烦躁': 70, '负面情绪': 50},
    '烦死了': {'生气': 75, '烦躁': 80, '负面情绪': 60},
    '难过': {'悲伤': 70, '需要安慰': 60, '负面情绪': 50},
    '伤心': {'悲伤': 75, '需要安慰': 65, '负面情绪': 55},
    '想你': {'依恋': 80, '渴望关注': 70, '需要回应': 50},
    '抱抱': {'依恋': 70, '渴望关注': 65, '需要安慰': 60},
    '累了': {'疲惫': 70, '需要安慰': 40, '需要空间': 30},
    '无聊': {'无聊': 70, '渴望关注': 50, '需要回应': 30},
    '害怕': {'恐惧': 70, '需要安慰': 60, '依恋': 40},
    '生气': {'生气': 80, '烦躁': 60, '负面情绪': 50},
    '爱你': {'依恋': 85, '渴望占有': 60, '情绪高涨': 50},
    '晚安': {'放松': 60, '依恋': 40, '疲惫': 30},
  };

  /// 否定模式：'不/没/别/不太/一点也不' + 情绪词（"不开心"=悲伤，不是开心！）
  static final RegExp _negationPattern = RegExp(
    r'(一点也不|一点都不|不太|不怎么|不|没|别)(开心|高兴|难过|伤心|好烦|烦死了|累|生气|无聊|害怕|想你|爱你)',
  );

  /// 被否定的情绪词反转映射：正性词被否定 → 负性维度
  static const Map<String, Map<String, double>> _negationInversion = {
    '开心': {'悲伤': 55, '烦躁': 40, '负面情绪': 50},
    '高兴': {'悲伤': 50, '烦躁': 35, '负面情绪': 45},
    // 负性词被否定（"不难过"）→ 中性，不反转
  };

  /// 检测文本中被否定的情绪词（如"不开心" → ['开心']）
  static List<String> detectNegatedMoods(String text) {
    final matches = _negationPattern.allMatches(text);
    return matches.map((m) => m.group(2)!).toList();
  }

  /// 从文本中匹配出命中的情绪关键词（触发因素提取用）
  static List<String> matchKeywords(String text) {
    final lowerText = text.toLowerCase();
    final negated = detectNegatedMoods(lowerText);
    final keys = <String>[
      for (final key in _keywordToMood.keys)
        if (!negated.contains(key) && lowerText.contains(key)) key,
    ];
    // 被否定的情绪词也作为关键词展示（"不开心"），让日志/规律可见
    for (final n in negated) {
      keys.add('不$n');
    }
    return keys;
  }

  @override
  MoodResult analyze(String text) {
    final dimensions = <String, double>{};
    final lowerText = text.toLowerCase();
    final negated = detectNegatedMoods(lowerText);

    // 1. 否定反转：'不开心' → 悲伤/烦躁/负面情绪
    for (final mood in negated) {
      final inverted = _negationInversion[mood];
      if (inverted == null) continue;
      for (final e in inverted.entries) {
        dimensions[e.key] = (dimensions[e.key] ?? 0) + e.value;
      }
    }

    // 2. 正常匹配（跳过被否定的词）
    for (final entry in _keywordToMood.entries) {
      if (negated.contains(entry.key)) continue;
      if (lowerText.contains(entry.key)) {
        for (final moodEntry in entry.value.entries) {
          dimensions[moodEntry.key] = (dimensions[moodEntry.key] ?? 0) +
              moodEntry.value * (1.0 / entry.key.length);
        }
      }
    }

    if (dimensions.isEmpty) {
      dimensions['平静'] = 80;
      dimensions['放松'] = 50;
    }

    final maxVal = dimensions.values.fold(0.0, (a, b) => a > b ? a : b);
    ConcentrationLevel concentration;
    if (maxVal < 30) concentration = ConcentrationLevel.low;
    else if (maxVal < 60) concentration = ConcentrationLevel.medium;
    else concentration = ConcentrationLevel.high;

    final isAnomaly = checkAnomaly(dimensions);

    return MoodResult(
      dimensions: dimensions,
      concentration: concentration,
      concentrationValue: maxVal,
      isAnomaly: isAnomaly,
      anomalyDescription: isAnomaly ? _describeAnomaly(dimensions) : null,
    );
  }

  String _describeAnomaly(Map<String, double> dims) {
    final highDims = dims.entries
        .where((e) => e.value > 60)
        .map((e) => e.key)
        .take(3)
        .join('、');
    return '显著偏高：$highDims';
  }

  @override
  Map<String, double> getBaseline() => Map.from(_baseline);

  @override
  void updateBaseline(MoodResult latest) {
    _sampleCount++;
    for (final entry in latest.dimensions.entries) {
      final current = _baseline[entry.key] ?? 0.0;
      final alpha = 1.0 / (_sampleCount + 1);
      _baseline[entry.key] = current + (entry.value - current) * alpha;
    }
  }

  @override
  bool checkAnomaly(Map<String, double> current) {
    if (_sampleCount < 5) return false;
    for (final entry in current.entries) {
      final baseline = _baseline[entry.key] ?? 0.0;
      if ((entry.value - baseline).abs() > 25) return true;
    }
    return false;
  }
}
