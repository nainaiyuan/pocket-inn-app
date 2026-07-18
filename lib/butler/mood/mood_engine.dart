/// ⚠️ 已废弃 — 请使用 mood_analyzer_onnx.dart（ONNX 模型版）
///
/// 这个文件是旧版的心情标签引擎，已被 ONNX 模型版取代。
/// 保留是为了：
///   1. 历史参考（关键词表可以抄到 mood_analyzer_keyword.dart）
///   2. 如果有模块还 import 它，不会立刻炸
///
/// 新代码不要引用这个文件。请用 mood_interface.dart 的 IMoodAnalyzer 接口。
///
/// ====================================================================

/// 心情标签引擎
///
/// 独立模块，不依赖管家其他部分。
/// 输入用户文本 → 输出心情标签百分比 + 建议。
///
/// 后续可升级：
/// - 接入 SKEP / BERT-tiny ONNX 推理替换关键词匹配
/// - 联动历史记忆判断趋势（"连续3天依恋>50%"）
/// - 多个男主各自维护情绪模型
///
/// 核心原则：
/// - 标签池全中性词，不出"亲密、性欲、色情"等封号词
/// - 不存储用户原文，只存标签快照
/// - 纯本地运算，不上传

class MoodEngine {
  // ========== 心情标签池 ==========

  static const List<String> moodTags = [
    '依恋',
    '需要回应',
    '情绪高涨',
    '放松',
    '专注',
    '期待',
    '满足',
    '活跃',
    '疲惫',
    '安全感需求',
    '渴望关注',
    '享受互动',
    '信任',
    '开心',
    '寻求安慰',
    '需要空间',
    '抗拒',
    '烦躁',
  ];

  // ========== 关键词组合 → 心情标签 + 权重 ==========

  static final keywordToMood = <String, Map<String, int>>{
    // ===== 依恋类 =====
    '想你':    {'依恋': 3, '需要回应': 2, '渴望关注': 2},
    '想你了':  {'依恋': 3, '需要回应': 2, '渴望关注': 2},
    '爱你':    {'依恋': 3, '开心': 2, '信任': 2},
    '乖':      {'依恋': 2, '信任': 2, '享受互动': 1},
    '抱':      {'安全感需求': 3, '依恋': 2, '寻求安慰': 2},
    '抱紧':    {'安全感需求': 3, '依恋': 3, '需要回应': 2},
    '黏':      {'依恋': 3, '渴望关注': 2, '享受互动': 1},
    '别走':    {'依恋': 3, '安全感需求': 2, '需要回应': 2},
    '陪':      {'依恋': 2, '需要回应': 2, '安全感需求': 1},
    '在我身边':{'依恋': 3, '安全感需求': 2, '信任': 2},
    '属于你':  {'依恋': 3, '信任': 3, '享受互动': 1},

    // ===== 互动类（不用"亲密、色情"标签） =====
    '吻':      {'渴望关注': 3, '依恋': 2, '需要回应': 2, '期待': 2},
    '亲':      {'渴望关注': 2, '依恋': 2, '享受互动': 2},
    '碰':      {'渴望关注': 2, '享受互动': 2, '需要回应': 1},
    '抚':      {'享受互动': 2, '放松': 2, '信任': 2},
    '摸':      {'渴望关注': 2, '享受互动': 2, '需要回应': 1},

    // ===== 情绪类 =====
    '开心':    {'开心': 3, '情绪高涨': 2, '活跃': 1},
    '高兴':    {'开心': 3, '情绪高涨': 2, '活跃': 1},
    '哈哈':    {'开心': 2, '享受互动': 2, '放松': 2},
    '笑':      {'开心': 2, '放松': 2, '享受互动': 1},
    '累':      {'疲惫': 3, '寻求安慰': 2, '需要空间': 1},
    '好累':    {'疲惫': 3, '寻求安慰': 2, '安全感需求': 1},
    '难':      {'疲惫': 2, '寻求安慰': 2, '需要空间': 1},
    '烦':      {'烦躁': 3, '需要空间': 2, '寻求安慰': 1},
    '烦躁':    {'烦躁': 3, '需要空间': 2, '疲惫': 1},
    '难过':    {'寻求安慰': 3, '疲惫': 2, '依恋': 1},
    '哭':      {'寻求安慰': 3, '疲惫': 2, '需要回应': 2},

    // ===== 信任/放松类 =====
    '只有你':  {'信任': 3, '依恋': 2, '专注': 2},
    '秘密':    {'信任': 3, '专注': 2, '需要回应': 1},
    '告诉你':  {'信任': 2, '专注': 2, '期待': 1},
    '相信':    {'信任': 3, '放松': 2, '安全感需求': 1},

    // ===== 期待/活跃类 =====
    '想':      {'期待': 2, '需要回应': 2, '专注': 1},
    '等':      {'期待': 2, '需要回应': 2, '专注': 1},
    '要':      {'需要回应': 2, '期待': 2, '情绪高涨': 1},
    '来':      {'期待': 2, '活跃': 2, '需要回应': 1},
    '今晚':    {'期待': 2, '活跃': 1, '专注': 1},

    // ===== 抗拒类 =====
    '别':      {'需要空间': 2, '抗拒': 2, '烦躁': 1},
    '不要':    {'需要空间': 3, '抗拒': 3, '烦躁': 1},
    '走开':    {'需要空间': 3, '抗拒': 3, '烦躁': 2},
    '不想':    {'需要空间': 2, '疲惫': 2, '烦躁': 1},
    '别烦':    {'烦躁': 3, '需要空间': 3, '抗拒': 2},
  };

  // ========== 公开方法 ==========

  /// 分析文本，返回心情标签百分比
  /// 返回 Map<String, double> 如 {'依恋': 65.0, '开心': 30.0}
  /// 空文本或未匹配 → 返回默认平静状态
  MoodResult analyze(String text) {
    if (text.trim().isEmpty) {
      return MoodResult(tags: {'放松': 40, '信任': 30, '专注': 20}, suggestion: '按你的风格自然回应');
    }

    final scores = <String, int>{};

    for (final entry in keywordToMood.entries) {
      if (text.contains(entry.key)) {
        for (final moodEntry in entry.value.entries) {
          scores[moodEntry.key] = (scores[moodEntry.key] ?? 0) + moodEntry.value;
        }
      }
    }

    if (scores.isEmpty) {
      return MoodResult(tags: {'放松': 40, '信任': 30, '专注': 20}, suggestion: '按你的风格自然回应');
    }

    // 归一化百分比
    final total = scores.values.fold(0, (a, b) => a + b);
    final result = <String, double>{};
    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(4);
    for (final entry in top) {
      result[entry.key] = (entry.value / total * 100).roundToDouble();
    }

    return MoodResult(tags: result, suggestion: _getSuggestion(result));
  }

  /// 生成给男主 AI 的上下文片段
  /// 可直接嵌入 Prompt
  String buildContextString(String userText) {
    final result = analyze(userText);
    if (result.tags.isEmpty) return '';

    final tagParts = result.tags.entries
        .map((e) => '${e.key} ${e.value.round()}%')
        .join('，');

    return '（用户状态：$tagParts。${result.suggestion}）';
  }

  // ========== 内部方法 ==========

  /// 根据标签生成建议
  String _getSuggestion(Map<String, double> tags) {
    final sorted = tags.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (sorted.isEmpty) return '按你的风格自然回应';

    final primary = sorted.first.key;
    final value = sorted.first.value;
    final has = (String tag) => tags.containsKey(tag);

    if (primary == '疲惫' || primary == '寻求安慰') {
      if (has('需要空间')) return '用户情绪偏低且可能需要空间，温柔回应即可';
      return '用户情绪偏低，可以多一些关心和安抚';
    }
    if (primary == '烦躁' || primary == '抗拒') {
      return '用户情绪不太好，回应时温和一些，不要施压';
    }
    if (primary == '依恋' || primary == '渴望关注') {
      if (value > 60) return '用户今天很黏人，可以多给一些关注和陪伴感';
      return '用户有陪伴需求，可以多给一些关注';
    }
    if (primary == '开心' || primary == '情绪高涨') {
      return '用户今天状态不错，可以一起活跃互动';
    }
    if (primary == '需要空间') {
      return '用户可能需要一些个人空间，回复可以温和克制';
    }
    if (primary == '信任' && value > 50) {
      return '用户对你敞开心扉，回应时可以多一些真实感';
    }

    return '按你的风格自然回应';
  }
}

/// 心情分析结果
class MoodResult {
  final Map<String, double> tags;   // 心情标签百分比
  final String suggestion;           // 给男主的建议

  MoodResult({required this.tags, required this.suggestion});

  /// 获取最高分标签名
  String get primaryTag {
    if (tags.isEmpty) return '平静';
    return tags.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  /// 获取最高分
  double get primaryScore {
    if (tags.isEmpty) return 0;
    return tags.entries.reduce((a, b) => a.value > b.value ? a : b).value;
  }

  /// 是否包含某个标签
  bool has(String tag) => tags.containsKey(tag);

  /// 浓度等级（0-3）
  /// 基于依恋 + 渴望关注的总计
  int get intensityLevel {
    final score = (tags['依恋'] ?? 0) + (tags['渴望关注'] ?? 0);
    if (score > 120) return 3;
    if (score > 80) return 2;
    if (score > 40) return 1;
    return 0;
  }

  @override
  String toString() {
    final tagStr = tags.entries.map((e) => '${e.key}:${e.value.round()}%').join(', ');
    return 'MoodResult{$tagStr | $suggestion}';
  }
}
