/// 规律引擎 — 关键词组合→情绪偏移统计
///
/// 关键升级：规律不只关联单关键词，而是关键词组合。
/// 比如：
///   「好友+小狗」→ 开心+40%
///   「好友+借钱」→ 愤怒+30%
///   虽然是同一个"好友"，但不同组合指向不同情绪。
///
/// 查的时候也按组合查：用户聊到"好友"+"狗"时，
/// 优先匹配「好友+小狗」这个精确组合，
/// 其次才看单关键词「好友」的统计。
///
/// 存储结构：
///   每条规律以"排序后的关键词组合"为key
///   比如 ["好友", "小狗"] → 统计开心偏移
///       ["好友", "借钱"] → 统计愤怒偏移
///
/// 基线校准：
///   每次更新前先检测当前情绪是否异常偏离基线。
///   只有真正的异常偏离才更新规律统计。
///   正常波动不更新（避免规律被日常小起伏污染）。
///
/// 用户可以在界面上查看和管理这些规律。

import 'dart:math' as math;
import 'dart:convert';
import '../memory/emotion_arc.dart';
import 'mood_baseline.dart';
import '../memory/user_element.dart';
import '../memory/user_element_store.dart';

/// 关键词组合的情绪偏移统计
class _ComboStats {
  /// 排序后的关键词列表（规律的唯一标识，至少2个词）
  final List<String> keywords;
  int count;

  /// 情绪偏移量（滚动平均）
  double shiftAnger, shiftSad, shiftJoy, shiftAttachment;
  double confidence;
  DateTime lastSeen;
  bool confirmed;

  /// 情绪波动范围（标准差），用于相似度比较
  double rangeAnger = 0, rangeSad = 0, rangeJoy = 0, rangeAttachment = 0;

  /// 逐次命中的完整记录（存基线快照，用于基线变化后复盘）
  final List<_ComboHit> hits;

  List<double> _angerSamples = [], _sadSamples = [], _joySamples = [], _attachmentSamples = [];

  _ComboStats({
    required this.keywords,
    this.count = 0,
    this.shiftAnger = 0, this.shiftSad = 0,
    this.shiftJoy = 0, this.shiftAttachment = 0,
    this.confidence = 0,
    DateTime? lastSeen,
    this.confirmed = false,
    List<_ComboHit>? hits,
  }) : lastSeen = lastSeen ?? DateTime.now(),
       hits = hits ?? [];

  /// 组合的唯一key（排序后用逗号连接）
  String get comboKey => (List.from(keywords)..sort()).join(',');

  /// 总偏移幅度（用于判断这条规律"多明显"）
  double get totalShift =>
      shiftAnger.abs() + shiftSad.abs() + shiftJoy.abs() + shiftAttachment.abs();

  /// 是否活跃
  bool get isActive => DateTime.now().difference(lastSeen).inDays < 60;

  /// 添加一次命中记录（带当时基线快照）
  void addArc(EmotionArc arc, {Map<String, double>? baselineAtTime}) {
    count++;
    lastSeen = arc.time;

    final angerShift = _getShift(arc, ['愤怒', '烦躁', '厌烦']);
    final sadShift = _getShift(arc, ['悲伤', '脆弱', '失望', '委屈']);
    final joyShift = _getShift(arc, ['喜悦', '幸福', '满足', '安心']);
    final attachmentShift = _getShift(arc, ['渴望', '依恋', '思念', '爱意']);

    // 记录本次命中（含基线快照）
    hits.add(_ComboHit(
      date: arc.time,
      shifts: {'愤怒': angerShift, '悲伤': sadShift, '喜悦': joyShift, '依恋': attachmentShift},
      baseline: baselineAtTime ?? {},
    ));

    // 保留样本用于计算波动范围（最多50个）
    _angerSamples.add(angerShift);
    _sadSamples.add(sadShift);
    _joySamples.add(joyShift);
    _attachmentSamples.add(attachmentShift);
    if (_angerSamples.length > 50) _angerSamples.removeAt(0);
    if (_sadSamples.length > 50) _sadSamples.removeAt(0);
    if (_joySamples.length > 50) _joySamples.removeAt(0);
    if (_attachmentSamples.length > 50) _attachmentSamples.removeAt(0);

    shiftAnger = _rollingAvg(shiftAnger, angerShift, count);
    shiftSad = _rollingAvg(shiftSad, sadShift, count);
    shiftJoy = _rollingAvg(shiftJoy, joyShift, count);
    shiftAttachment = _rollingAvg(shiftAttachment, attachmentShift, count);

    // 更新波动范围（标准差）
    rangeAnger = _stdDev(_angerSamples);
    rangeSad = _stdDev(_sadSamples);
    rangeJoy = _stdDev(_joySamples);
    rangeAttachment = _stdDev(_attachmentSamples);

    confidence = (1.0 - 1.0 / (1 + count * 0.25)).clamp(0.0, 0.95);
    if (count >= 3 && confidence > 0.5) confirmed = true;
  }

  /// 添加一次无情绪偏移的记录（仅存档基线）
  void addBaselineHit(DateTime date, {Map<String, double>? baselineAtTime}) {
    hits.add(_ComboHit(
      date: date,
      shifts: {'愤怒': 0, '悲伤': 0, '喜悦': 0, '依恋': 0},
      baseline: baselineAtTime ?? {},
      isBaseline: true,
    ));
  }

  double _getShift(EmotionArc arc, List<String> labels) {
    double peak = 0, start = 0;
    for (final l in labels) {
      peak = peak > (arc.peakMood[l] ?? 0) ? peak : (arc.peakMood[l] ?? 0);
      start = start > (arc.startMood[l] ?? 50) ? start : (arc.startMood[l] ?? 50);
    }
    return peak - start;
  }

  double _rollingAvg(double old, double val, int n) => (old * (n - 1) + val) / n;

  /// 标准差
  double _stdDev(List<double> samples) {
    if (samples.length < 2) return 15; // 样本太少时给个保守值
    final mean = samples.reduce((a, b) => a + b) / samples.length;
    final variance = samples.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / samples.length;
    return math.sqrt(variance);
  }

  /// 判断此组合的情绪区间是否与另一个组合高度重叠
  /// 区间 = 平均值 ± 标准差，重叠度 = 交集/并集
  /// overlapThreshold: 认为"高度重叠"的阈值（默认0.8 = 80%）
  bool overlapsWith(_ComboStats other, {double overlapThreshold = 0.8}) {
    final myRanges = _rangeMap();
    final otherRanges = other._rangeMap();

    if (myRanges.isEmpty || otherRanges.isEmpty) return false;

    // 计算四个情绪维度的平均重叠度
    double totalOverlap = 0;
    int dimCount = 0;

    for (final key in myRanges.keys) {
      if (!otherRanges.containsKey(key)) continue;
      final myMin = myRanges[key]!.$1;
      final myMax = myRanges[key]!.$2;
      final otherMin = otherRanges[key]!.$1;
      final otherMax = otherRanges[key]!.$2;

      final intersection = math.max(0, math.min(myMax, otherMax) - math.max(myMin, otherMin));
      final union = math.max(myMax, otherMax) - math.min(myMin, otherMin);

      if (union > 0) {
        totalOverlap += intersection / union;
        dimCount++;
      }
    }

    return dimCount > 0 && (totalOverlap / dimCount) >= overlapThreshold;
  }

  /// 情绪区间映射：{维度名: (最小值, 最大值)}
  Map<String, (double, double)> _rangeMap() {
    final map = <String, (double, double)>{};
    if (rangeAnger > 0) map['愤怒'] = (shiftAnger - rangeAnger, shiftAnger + rangeAnger);
    if (rangeSad > 0) map['悲伤'] = (shiftSad - rangeSad, shiftSad + rangeSad);
    if (rangeJoy > 0) map['喜悦'] = (shiftJoy - rangeJoy, shiftJoy + rangeJoy);
    if (rangeAttachment > 0) map['依恋'] = (shiftAttachment - rangeAttachment, shiftAttachment + rangeAttachment);
    return map;
  }

  /// 主要偏移方向
  String get dominantShift {
    final m = {'愤怒': shiftAnger, '悲伤': shiftSad, '喜悦': shiftJoy, '依恋': shiftAttachment};
    final max = m.entries.reduce((a, b) => a.value.abs() > b.value.abs() ? a : b);
    return '${max.key}${max.value > 0 ? '+' : ''}${max.value.toStringAsFixed(0)}';
  }

  String get description {
    final parts = <String>[];
    if (shiftAnger.abs() > 5) parts.add('愤怒${_fmt(shiftAnger)}');
    if (shiftSad.abs() > 5) parts.add('悲伤${_fmt(shiftSad)}');
    if (shiftJoy.abs() > 5) parts.add('喜悦${_fmt(shiftJoy)}');
    if (shiftAttachment.abs() > 5) parts.add('依恋${_fmt(shiftAttachment)}');
    if (parts.isEmpty) return '无明显偏移';
    return '${keywords.join("+")}→${parts.join("、")}';
  }

  String _fmt(double v) => v > 0 ? '+${v.toStringAsFixed(0)}' : v.toStringAsFixed(0);

  /// 格式化为上下文
  String toContext() {
    if (count < 2) return '';
    return '（[规律] ${description}，共$count次）';
  }

  /// 格式化为用户可读的展示
  String toUserDisplay() {
    if (!confirmed) return '';
    return '▪ ${keywords.join("+")} → ${description.replaceAll("→", "")}（$count次确认）';
  }

  Map<String, dynamic> toJson() => {
    'keywords': keywords,
    'count': count,
    'shifts': {'愤怒': shiftAnger, '悲伤': shiftSad, '喜悦': shiftJoy, '依恋': shiftAttachment},
    'ranges': {'愤怒': rangeAnger, '悲伤': rangeSad, '喜悦': rangeJoy, '依恋': rangeAttachment},
    'confidence': confidence,
    'confirmed': confirmed,
    'last_seen': lastSeen.toIso8601String(),
    'hit_count': hits.length,
  };
}

/// 单次命中记录（含当时基线快照）
class _ComboHit {
  final DateTime date;
  final Map<String, double> shifts;  // 情绪偏移
  final Map<String, double> baseline; // 当时的基线快照
  final bool isBaseline;              // true=无情绪偏移的存档

  _ComboHit({
    required this.date,
    required this.shifts,
    this.baseline = const {},
    this.isBaseline = false,
  });

  Map<String, dynamic> toJson() => {
    'date': date.toIso8601String(),
    'shifts': shifts,
    'baseline': baseline,
    'is_baseline': isBaseline,
  };
}

/// 规律引擎
class PatternEngine {
  final IUserElementStore _elementStore;
  final MoodBaseline baseline;
  final Map<String, _ComboStats> _combos = {};
  final List<EmotionArc> _arcs = [];

  PatternEngine(this._elementStore, {MoodBaseline? baseline})
      : baseline = baseline ?? MoodBaseline();

  /// 加入情绪弧线事件
  Future<List<_ComboStats>> addArc(EmotionArc arc) async {
    // 先更新基线（用结束情绪）
    if (arc.returnedToBaseline) {
      baseline.update(arc.endMood);
    }

    // 检测是否是异常偏离
    final deviation = baseline.detectDeviation(arc.peakMood);
    final isSignificant = deviation.isDeviated &&
        (deviation.severity == DeviationSeverity.mild ||
         deviation.severity == DeviationSeverity.significant);

    // 没有有效关键词 → 只保留弧线，不更新规律统计
    if (arc.triggerKeywords.isEmpty) {
      _arcs.add(arc);
      if (_arcs.length > 2000) _arcs.removeRange(0, _arcs.length - 2000);
      return [];
    }

    _arcs.add(arc);
    if (_arcs.length > 2000) _arcs.removeRange(0, _arcs.length - 2000);

    final keywords = arc.triggerKeywords;
    final updatedStats = <_ComboStats>[];

    // 记录本次基线的快照（用于后续回顾）
    final baselineSnapshot = Map<String, double>.from(baseline.allValues);

    // 单关键词 → 不形成规律（仅作为搜索入口，不进 _combos）
    // 不参与预测，只做网络图中的搜索入口

    // 两词组合（必须有情绪偏离才会生成规律）
    if (keywords.length >= 2 && isSignificant) {
      for (int i = 0; i < keywords.length; i++) {
        for (int j = i + 1; j < keywords.length; j++) {
          final stats = _getOrCreate([keywords[i], keywords[j]]);
          stats.addArc(arc, baselineAtTime: baselineSnapshot);
          updatedStats.add(stats);
        }
      }
    }

    // 三词组合
    if (keywords.length >= 3 && isSignificant) {
      for (int i = 0; i < keywords.length; i++) {
        for (int j = i + 1; j < keywords.length; j++) {
          for (int k = j + 1; k < keywords.length; k++) {
            final stats = _getOrCreate([keywords[i], keywords[j], keywords[k]]);
            stats.addArc(arc, baselineAtTime: baselineSnapshot);
            updatedStats.add(stats);
          }
        }
      }
    }

    // 无情绪偏离的对话 → 仅记录组合存在，偏移量为0
    if (!isSignificant) {
      for (int i = 0; i < keywords.length; i++) {
        for (int j = i + 1; j < keywords.length; j++) {
          final comboKey = ([keywords[i], keywords[j]]..sort()).join(',');
          final stats = _combos.putIfAbsent(comboKey, 
            () => _ComboStats(keywords: [keywords[i], keywords[j]]));
          stats.addBaselineHit(arc.time, baselineAtTime: baselineSnapshot);
        }
      }
    }

    _runDecay();

    // 新确认的规律持久化到用户要素
    for (final stats in updatedStats) {
      if (stats.confirmed && stats.count >= 3) {
        final ctx = stats.toContext();
        if (ctx.isNotEmpty) {
          final existing = await _elementStore.searchRelevant(stats.comboKey, maxResults: 1);
          if (existing.isEmpty || !existing.first.content.contains(stats.keywords.first)) {
            await _elementStore.insert(UserElement(
              id: 'combo_${stats.comboKey.hashCode}_${DateTime.now().millisecondsSinceEpoch}',
              dimension: _mapDimension(stats.dominantShift),
              content: ctx,
              source: '规律引擎',
              importance: stats.confidence,
              triggerWords: stats.keywords,
            ));
          }
        }
      }
    }

    return updatedStats;
  }

  /// 匹配当前用户输入 → 返回最相关的规律上下文（含基线信息）
  Future<List<String>> getMatchingContexts(String userInput) async {
    final inputKeywords = _extractKnownKeywords(userInput);
    if (inputKeywords.isEmpty) return [];

    final matched = <_ScoredCombo>[];

    for (final combo in _combos.values) {
      if (!combo.confirmed || combo.count < 2) continue;

      final matchCount = combo.keywords.where((k) => inputKeywords.contains(k)).length;

      if (matchCount > 0) {
        final matchRatio = matchCount / combo.keywords.length;
        final shiftScore = (combo.totalShift / 100).clamp(0.0, 1.0);
        final totalScore = matchRatio * 0.5 + shiftScore * 0.3 + combo.confidence * 0.2;
        matched.add(_ScoredCombo(combo: combo, score: totalScore));
      }
    }

    matched.sort((a, b) => b.score.compareTo(a.score));

    // 取 top-3 规律 + 基线信息
    final contexts = matched.take(3).map((m) => m.combo.toContext()).toList();
    final baselineCtx = baseline.toContext();
    if (baselineCtx.isNotEmpty) {
      contexts.insert(0, baselineCtx);
    }
    return contexts;
  }

  /// 提取输入中已知的关键词
  Set<String> _extractKnownKeywords(String input) {
    final known = <String>{};
    for (final key in _combos.keys) {
      // key = 排序后的逗号分隔关键词列表
      for (final kw in key.split(',')) {
        if (input.contains(kw)) known.add(kw);
      }
    }
    return known;
  }

  _ComboStats _getOrCreate(List<String> keywords) {
    final key = (List.from(keywords)..sort()).join(',');
    return _combos.putIfAbsent(key, () => _ComboStats(keywords: keywords));
  }

  void _runDecay() {
    final toRemove = <String>[];
    for (final entry in _combos.entries) {
      if (!entry.value.isActive) {
        entry.value.confidence *= 0.5;
        if (entry.value.confidence < 0.1) toRemove.add(entry.key);
      }
    }
    for (final key in toRemove) _combos.remove(key);
  }

  UserDimension _mapDimension(String shift) {
    if (shift.contains('愤怒') || shift.contains('悲伤')) return UserDimension.mood;
    if (shift.contains('喜悦')) return UserDimension.preference;
    if (shift.contains('依恋')) return UserDimension.relation;
    return UserDimension.habit;
  }

  // ============================================================
  // 用户可操作的接口
  // ============================================================

  /// 获取所有已确认的规律（给用户看）
  List<Map<String, dynamic>> getAllConfirmedPatterns() {
    final result = <Map<String, dynamic>>[];
    for (final combo in _combos.values) {
      if (combo.confirmed) {
        result.add(combo.toJson());
      }
    }
    // 按置信度排序
    result.sort((a, b) => (b['confidence'] as double).compareTo(a['confidence'] as double));
    return result;
  }

  /// 获取某个关键词相关的所有规律（给用户看详情）
  List<Map<String, dynamic>> getPatternsByKeyword(String keyword) {
    final result = <Map<String, dynamic>>[];
    for (final combo in _combos.values) {
      if (combo.confirmed && combo.keywords.contains(keyword)) {
        result.add(combo.toJson());
      }
    }
    return result;
  }

  /// 用户要求删除某条规律
  void deletePattern(String comboKey) {
    _combos.remove(comboKey);
  }

  /// 用户要求删除某个关键词相关的所有数据（包括规律、hits、弧线）
  /// 用于"把前任相关的都删了"这种场景
  void deleteKeyword(String keyword) {
    // 1. 删除包含该关键词的所有规律组合
    final toRemove = _combos.keys
        .where((key) => key.split(',').any((k) => k.trim() == keyword))
        .toList();
    for (final key in toRemove) {
      _combos.remove(key);
    }

    // 2. 删除包含该关键词的所有弧线
    _arcs.removeWhere((arc) =>
        arc.triggerKeywords.any((k) => k == keyword));

    // 3. 同步删除用户要素中关联的记录
    // （交由外部调用方处理）
  }

  /// 获取按关键词分组的规律展示文本
  String getDisplayText() {
    // 按关键词分组
    final grouped = <String, List<_ComboStats>>{};
    for (final combo in _combos.values) {
      if (!combo.confirmed) continue;
      for (final kw in combo.keywords) {
        grouped.putIfAbsent(kw, () => []);
        grouped[kw]!.add(combo);
      }
    }

    final lines = <String>['📊 我发现你的规律：'];
    for (final entry in grouped.entries) {
      lines.add('');
      lines.add('【${entry.key}】');
      for (final combo in entry.value) {
        lines.add('  ${combo.toUserDisplay()}');
      }
    }

    return lines.join('\n');
  }

  /// 检查是否有情感区间高度重叠的规律组合
  /// 条件：两个子组合共享根关键词、都已确认、至少存在60天、区间重叠度>80%
  /// 返回：需要问男主确认的相似规律列表（一天最多返回一条）
  List<SimilarPatternResult> checkSimilarPatterns() {
    final now = DateTime.now();

    // 按"根关键词+主要情绪维度"分组
    final clusters = <String, List<_ComboStats>>{};
    for (final combo in _combos.values) {
      if (!combo.confirmed || combo.count < 3) continue;
      if (combo.keywords.length != 2) continue; // 只看两词组合
      final age = now.difference(combo.lastSeen).inDays.abs();
      if (age < _minSimilarDays) continue;

      // 分组key = "根关键词|主导情绪"
      final clusterKey = '${combo.keywords[0]}|${combo.dominantShift}';
      clusters.putIfAbsent(clusterKey, () => []);
      clusters[clusterKey]!.add(combo);
    }

    for (final entry in clusters.entries) {
      final combos = entry.value;
      if (combos.length < 2) continue;

      // 聚类：两两比较，互相重叠的组合归为一组
      final merged = <int>{}; // 已归组的索引
      for (int i = 0; i < combos.length; i++) {
        if (merged.contains(i)) continue;

        final cluster = <int>[i];
        for (int j = i + 1; j < combos.length; j++) {
          if (merged.contains(j)) continue;
          // 检查与cluster内任一成员重叠
          final overlaps = cluster.any((ci) =>
            combos[ci].overlapsWith(combos[j], overlapThreshold: _overlapThreshold));
          if (overlaps) {
            cluster.add(j);
            merged.add(j);
          }
        }

        // 聚类 >= 2 个组合才值得问
        if (cluster.length >= 2) {
          merged.addAll(cluster);
          final subCombos = cluster.map((idx) => combos[idx].keywords).toList();
          return [
            SimilarPatternResult(
              rootKeyword: combos[cluster.first].keywords[0],
              subCombos: subCombos,
              overlapScore: 0.85, // 聚类通过后取固定高分
              dominantMood: combos[cluster.first].dominantShift,
            )
          ];
        }
      }
    }

    return [];
  }
}

class _ScoredCombo {
  final _ComboStats combo;
  final double score;
  _ScoredCombo({required this.combo, required this.score});
}

/// 相似规律检测结果（供内部任务系统使用）
class SimilarPatternResult {
  final String rootKeyword;          // 共享的根关键词
  final List<List<String>> subCombos; // 子关键词列表
  final double overlapScore;
  final String dominantMood;

  SimilarPatternResult({
    required this.rootKeyword,
    required this.subCombos,
    required this.overlapScore,
    required this.dominantMood,
  });

  String get description {
    final items = subCombos.map((k) => k.join('+')).join('、');
    return '$items 情绪一直很像，都是"$rootKeyword"相关的事情';
  }

  String get taskQuery {
    final items = subCombos.map((k) => k.join('+')).join(',');
    return '#same $items';
  }
}

/// 最低活跃天数才触发相似检查
const int _minSimilarDays = 60;
/// 情绪区间重叠阈值
const double _overlapThreshold = 0.8;
