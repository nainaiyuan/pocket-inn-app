import '../modules/butler_module_hub.dart';
import '../storage/storage_registry.dart';
import 'butler_tool.dart';

/// 🔧 情绪弧线查询工具
///
/// 参数：
///   days (int) — 查询最近 N 天（默认 7）
///   characterId (String?) — 只查某个男主的（默认全部）
///
/// 输出：弧线数量 + 高频情绪 TOP3（均值）
class EmotionArcsQueryTool extends ButlerTool {
  @override
  String get id => 'emotion_arcs_query';

  @override
  String get name => '情绪弧线查询';

  @override
  String get description =>
      '查询用户的情绪弧线记录（按天/按男主），看最近的情绪变化和高频情绪';

  @override
  Future<String> call(Map<String, dynamic> args) async {
    final days = (args['days'] as num?)?.toInt() ?? 7;
    final characterId = args['characterId'] as String?;

    final arcs = await StorageRegistry.instance.emotionArcs.loadAll();
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final filtered = arcs.where((a) {
      if (!a.time.isAfter(cutoff)) return false;
      if (characterId != null && a.characterId != characterId) return false;
      return true;
    }).toList();

    if (filtered.isEmpty) {
      return '近 $days 天没有情绪记录';
    }

    final agg = <String, double>{};
    for (final a in filtered) {
      a.peakMood.forEach((k, v) => agg[k] = (agg[k] ?? 0) + v);
    }
    agg.forEach((k, v) => agg[k] = v / filtered.length);
    final top = agg.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topStr = top
        .take(3)
        .map((e) => '${e.key} ${e.value.round()}')
        .join('、');
    return '近 $days 天 ${filtered.length} 条弧线，高频情绪：$topStr';
  }
}

/// 🔧 规律查询工具
///
/// 参数：
///   topN (int) — 返回几条（默认 2）
///   minShift (double) — 只列情绪偏移 ≥ 该值的（默认 5）
///
/// 输出：确认规律（关键词组合 → 情绪偏移），即"触发因素"
class PatternQueryTool extends ButlerTool {
  @override
  String get id => 'pattern_query';

  @override
  String get name => '规律查询';

  @override
  String get description =>
      '查询已确认的情绪规律（关键词组合 → 情绪偏移），即用户情绪的触发因素';

  @override
  Future<String> call(Map<String, dynamic> args) async {
    final topN = (args['topN'] as num?)?.toInt() ?? 2;
    final minShift = (args['minShift'] as num?)?.toDouble() ?? 5;

    final engine = ButlerModuleHub.instance.sharedPatternEngine;
    if (engine == null) return '规律引擎未就绪';

    final patterns = engine.confirmedPatterns
        .where((p) =>
            p.confirmed &&
            p.lastSeen
                .isAfter(DateTime.now().subtract(const Duration(days: 30))))
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final meaningful = patterns
        .where((p) => [
              p.shiftAnger,
              p.shiftSad,
              p.shiftJoy,
              p.shiftAttachment,
            ].any((s) => s.abs() >= minShift))
        .take(topN)
        .toList();

    if (meaningful.isEmpty) return '暂无明显触发因素';

    return meaningful
        .map((p) {
          final shifts = <String>[];
          void add(double v, String name) {
            if (v.abs() >= minShift) {
              shifts.add('${v > 0 ? '$name↑' : '$name↓'}${v.abs().round()}');
            }
          }

          add(p.shiftAnger, '生气');
          add(p.shiftSad, '悲伤');
          add(p.shiftJoy, '开心');
          add(p.shiftAttachment, '依恋');
          return '聊到「${p.keywords.join('、')}」时${shifts.join('，')}（${p.count}次确认）';
        })
        .join('；');
  }
}

/// 🔧 记忆检索工具
///
/// 参数：
///   query (String) — 查询词（用户消息；空 = 返回最近记忆）
///   topN (int) — 返回几条（默认 3）
///
/// 输出：匹配的用户记忆句子（用户想让男主记住的事）
class MemoryRecallTool extends ButlerTool {
  @override
  String get id => 'memory_recall';

  @override
  String get name => '记忆检索';

  @override
  String get description =>
      '检索用户记忆（用户想让男主记住的事），支持按查询词过滤';

  @override
  Future<String> call(Map<String, dynamic> args) async {
    final query = (args['query'] as String? ?? '').trim();
    final topN = (args['topN'] as num?)?.toInt() ?? 3;

    final all = await StorageRegistry.instance.userMemory.loadAll();
    if (all.isEmpty) return '还没有记录任何记忆';

    List<dynamic> matched = all;
    if (query.isNotEmpty) {
      matched = all.where((m) {
        final hay = '${m.toSentence()} ${m.category} ${m.tags.join(' ')}';
        // 查询词按空格拆开，任一命中即可
        return query.split(RegExp(r'\s+')).any((q) => q.isNotEmpty && hay.contains(q));
      }).toList();
    }
    if (matched.isEmpty) return '没有找到相关记忆';

    final top = matched.take(topN).toList();
    return top.map((m) => m.toSentence()).join('；');
  }
}

/// 🔧 基线查询工具
///
/// 输出：整体情绪基线 TOP3（用户长期状态）
class BaselineQueryTool extends ButlerTool {
  @override
  String get id => 'baseline_query';

  @override
  String get name => '基线查询';

  @override
  String get description => '查询用户的整体情绪基线（长期状态分布）';

  @override
  Future<String> call(Map<String, dynamic> args) async {
    final engine = ButlerModuleHub.instance.sharedPatternEngine;
    if (engine == null) return '规律引擎未就绪';

    final baseline = engine.baseline.allValues;
    if (baseline.isEmpty) return '基线尚未建立';

    final top = baseline.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return '整体基线：${top.take(3).map((e) => '${e.key} ${e.value.round()}').join('、')}';
  }
}
