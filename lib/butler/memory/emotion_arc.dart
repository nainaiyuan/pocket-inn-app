/// 情绪弧线事件记录
///
/// 一次对话中用户的完整情绪变化轨迹。
///
/// 存的是"从什么情绪开始 → 被什么触发 → 峰值在哪 → 最终回到哪"
/// 不存男主说了什么，只存用户的变化。
///
/// 多次同类事件 → 规律确认。
///
/// 检索时直接推给男主看，男主自己判断。

import '../mood_analysis/mood_interface.dart';

/// 情绪弧线事件
class EmotionArc {
  final String id;
  final DateTime time;
  final List<String> triggerKeywords;  // 触发关键词（老板、下雨、加班…）
  final String? topic;                  // 话题（工作、天气…）
  final Map<String, double> startMood; // 初始情绪分布
  final Map<String, double> peakMood;  // 峰值情绪分布（本轮最强烈的）
  final Map<String, double> endMood;   // 结束情绪分布
  final bool returnedToBaseline;       // 是否回归基线
  final int durationMinutes;            // 持续时长
  final String? summary;               // 一句话摘要（来自MemoryWriter）

  EmotionArc({
    required this.id,
    required this.time,
    this.triggerKeywords = const [],
    this.topic,
    required this.startMood,
    required this.peakMood,
    required this.endMood,
    this.returnedToBaseline = true,
    this.durationMinutes = 0,
    this.summary,
  });

  /// 这条事件的"关键词+情绪偏移"特征
  /// 规律引擎靠这个做匹配
  Map<String, dynamic> get signature {
    // 计算：峰值相对起点的偏移
    final shifts = <String, double>{};
    for (final entry in peakMood.entries) {
      final start = startMood[entry.key] ?? 50;
      shifts[entry.key] = entry.value - start;
    }
    return {
      'keywords': triggerKeywords,
      'topic': topic,
      'peak_shift': shifts,
      'returned': returnedToBaseline,
    };
  }

  /// 格式化成上下文给男主看
  String toContext() {
    final keywordStr = triggerKeywords.isNotEmpty ? '提到${triggerKeywords.join("、")}，' : '';
    final peakStr = peakMood.entries
        .where((e) => e.value > 50)
        .map((e) => '${e.key} ${e.value.toStringAsFixed(0)}%')
        .join('、');
    final endStr = returnedToBaseline ? '情绪回归' : '情绪未完全恢复';
    return '（[事件] $keywordStr用户情绪变化：$peakStr → $endStr）';
  }
}
