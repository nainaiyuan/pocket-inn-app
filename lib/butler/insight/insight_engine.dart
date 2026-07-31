import 'dart:math';

import '../butler_database.dart';
import '../butler_memory.dart';

/// 互动洞察引擎
///
/// 从互动记录中分析规律，输出人类可读的结论。
/// 分析维度：
/// 1. 话题共现 — 某个话题出现时用户情绪如何
/// 2. 情绪链 — 用户情绪 → 男主反应 → 用户后续情绪
/// 3. 频率统计 — 最近聊得最多的话题
/// 4. 模式识别 — 男主哪种回应方式效果最好
///
/// 输出：InsightReport — 给用户看的文字总结

class InsightEngine {
  final ButlerDatabase _db;

  InsightEngine({required ButlerDatabase db}) : _db = db;
  /// 生成周报
  Future<InsightReport> generateWeeklyReport() async {
    final records = await _loadRecentRecords();
    if (records.isEmpty) {
      return InsightReport(summary: '最近没有足够的互动记录，下周再来看看吧 💙');
    }

    final topicStats = _analyzeTopics(records);
    final moodPatterns = _analyzeMoodPatterns(records);
    final responseEffectiveness = _analyzeResponseEffectiveness(records);
    final topPatterns = _findTopPatterns(records);

    return InsightReport(
      summary: _formatSummary(topicStats, moodPatterns, responseEffectiveness),
      topicStats: topicStats,
      moodPatterns: moodPatterns,
      responseStats: responseEffectiveness,
      topPatterns: topPatterns,
    );
  }

  /// 生成回忆快照（里程碑）
  Future<InsightReport> generateMilestone({int days = 100}) async {
    // TODO: 查 days 天前的记录，生成对比报告
    return generateWeeklyReport();
  }

  /// 按话题查询关联的情绪
  Future<List<TopicMoodEntry>> queryTopicMood(String topic) async {
    final records = await _loadRecentRecords();
    return records
        .where((r) => r.keywords.toLowerCase().contains(topic.toLowerCase()))
        .map((r) => TopicMoodEntry(
              topic: r.keywords,
              mood: r.moodBefore,
              characterResponse: r.characterResponse,
              userReaction: r.pattern,
            ))
        .toList();
  }

  // ========== 分析器（私有） ==========

  Future<List<_InteractionRecord>> _loadRecentRecords({int days = 7, String? characterId}) async {
    final raw = await _db.getRecentInteractions(
      characterId ?? '',
      limit: 200,
    );

    // 按时间过滤
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return raw
        .where((r) {
          final createdAt = DateTime.tryParse(r['createdAt'] as String? ?? '');
          return createdAt != null && createdAt.isAfter(cutoff);
        })
        .map((r) => _InteractionRecord(
              keywords: r['keywords'] as String? ?? '',
              moodBefore: r['moodBefore'] as int? ?? 0,
              moodAfter: r['moodAfter'] as int? ?? 0,
              pattern: r['pattern'] as String? ?? 'neutral',
              characterResponse: r['characterResponse'] as String? ?? '',
            ))
        .toList();
  }

  /// 话题统计
  TopicStats _analyzeTopics(List<_InteractionRecord> records) {
    final topicCount = <String, int>{};
    final topicMood = <String, List<int>>{};

    for (final r in records) {
      final keywords = r.keywords.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty);
      for (final keyword in keywords) {
        topicCount[keyword] = (topicCount[keyword] ?? 0) + 1;
        topicMood.putIfAbsent(keyword, () => []).add(r.moodBefore);
      }
    }

    // 按频率排序取 top 10
    final sorted = topicCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topTopics = sorted.take(10).map((e) {
      final moods = topicMood[e.key] ?? [];
      final avgMood = moods.isEmpty ? 0.0 : moods.reduce((a, b) => a + b) / moods.length;
      return TopicStat(topic: e.key, count: e.value, avgMood: avgMood);
    }).toList();

    return TopicStats(topTopics: topTopics, totalTopics: topicCount.length);
  }

  /// 情绪模式分析
  List<MoodPattern> _analyzeMoodPatterns(List<_InteractionRecord> records) {
    // 用户同一个情绪的前后变化
    // moodBefore > 50 且 moodAfter < moodBefore → "聊完后情绪好转"
    const moodLabels = {0: '放松', 1: '开心', 2: '依恋', 3: '期待', 4: '烦躁', 5: '疲惫'};

    final patterns = <MoodPattern>[];
    var improved = 0, worsened = 0, stable = 0;

    for (final r in records) {
      final diff = r.moodAfter - r.moodBefore;
      if (diff < -20) improved++;
      else if (diff > 20) worsened++;
      else stable++;
    }

    final total = records.length;
    if (total > 0) {
      patterns.add(MoodPattern(
        name: '情绪改善',
        description: '聊天后情绪明显好转',
        percentage: (improved / total * 100).round(),
      ));
      patterns.add(MoodPattern(
        name: '情绪波动',
        description: '聊天后情绪有所起伏',
        percentage: (worsened / total * 100).round(),
      ));
      patterns.add(MoodPattern(
        name: '情绪稳定',
        description: '聊天前后情绪变化不大',
        percentage: (stable / total * 100).round(),
      ));
    }

    return patterns;
  }

  /// 男主回应有效性分析
  ResponseStats _analyzeResponseEffectiveness(List<_InteractionRecord> records) {
    // pattern: 'positive' / 'negative' / 'neutral'
    // 统计什么类型的回应最容易得到正面反馈
    var totalPositive = 0, total = 0;

    for (final r in records) {
      total++;
      if (r.pattern == 'positive') totalPositive++;
    }

    return ResponseStats(
      positiveRate: total > 0 ? (totalPositive / total * 100).round() : 0,
      totalInteractions: total,
      bestPattern: '倾听陪伴', // 占位
    );
  }

  /// 找到最显著的规律
  List<String> _findTopPatterns(List<_InteractionRecord> records) {
    // TODO: 真正的关联规则挖掘
    // 当前占位
    return ['数据不足，暂时无法发现规律'];
  }

  /// 格式化输出总结
  String _formatSummary(
    TopicStats topics,
    List<MoodPattern> moods,
    ResponseStats responses,
  ) {
    final lines = <String>[];

    if (topics.topTopics.isNotEmpty) {
      final top = topics.topTopics.first;
      lines.add('本周聊得最多的是"${top.topic}"，一共 ${top.count} 次');
    }

    if (moods.length >= 3) {
      lines.add('聊天后情绪改善的比例是 ${moods[0].percentage}%');
      if (moods[0].percentage > 60) {
        lines.add('看起来每次聊完你都会轻松一些 ✨');
      }
    }

    if (responses.totalInteractions > 10) {
      lines.add('他最近的表现不错，正面回应率 ${responses.positiveRate}%');
    }

    if (lines.isEmpty) {
      return '这周互动不多，但没关系，慢慢来 💙';
    }

    return lines.join('\n');
  }
}

// ========== 数据模型 ==========

/// 洞察报告
class InsightReport {
  /// 文字总结（给用户看的）
  final String summary;

  /// 话题统计
  final TopicStats? topicStats;

  /// 情绪模式
  final List<MoodPattern>? moodPatterns;

  /// 回应有效性
  final ResponseStats? responseStats;

  /// 发现的规律
  final List<String> topPatterns;

  InsightReport({
    required this.summary,
    this.topicStats,
    this.moodPatterns,
    this.responseStats,
    this.topPatterns = const [],
  });
}

/// 话题统计
class TopicStats {
  final List<TopicStat> topTopics;
  final int totalTopics;

  TopicStats({required this.topTopics, required this.totalTopics});
}

class TopicStat {
  final String topic;
  final int count;
  final double avgMood;

  TopicStat({required this.topic, required this.count, required this.avgMood});
}

/// 情绪模式
class MoodPattern {
  final String name;
  final String description;
  final int percentage;

  MoodPattern({required this.name, required this.description, required this.percentage});
}

/// 回应有效性
class ResponseStats {
  final int positiveRate;
  final int totalInteractions;
  final String bestPattern;

  ResponseStats({required this.positiveRate, required this.totalInteractions, required this.bestPattern});
}

/// 话题-情绪关联
class TopicMoodEntry {
  final String topic;
  final int mood;
  final String characterResponse;
  final String userReaction;

  TopicMoodEntry({
    required this.topic,
    required this.mood,
    required this.characterResponse,
    required this.userReaction,
  });
}

// ========== 内部数据模型 ==========

class _InteractionRecord {
  final String keywords;
  final int moodBefore;
  final int moodAfter;
  final String pattern;
  final String characterResponse;

  _InteractionRecord({
    required this.keywords,
    required this.moodBefore,
    required this.moodAfter,
    required this.pattern,
    required this.characterResponse,
  });
}
