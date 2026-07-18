/// 情绪基线校准模块
///
/// 维护用户对男主的**全局情感基线**。
/// 基线 = 用户和男主聊天时的"正常"情绪状态。
///
/// 核心用途：
///   1. 检测异常偏离（用户突然和平时不一样了）
///   2. 作为规律引擎的参考系（偏移量相对于基线）
///   3. 确认情绪是否回归基线（对话是否正常结束）
///
/// 基线是滚动平均：每次聊天结束用最终情绪更新。
/// 长期（30天）不说话 → 基线重置归零。

class MoodBaseline {
  /// 各情绪维度的基线值（0-100的滚动平均）
  final Map<String, double> _values = {};

  /// 基线样本数（用于计算置信度）
  int _sampleCount = 0;

  /// 最后一次更新的时间
  DateTime _lastUpdated = DateTime.now();

  /// 情绪维度的完整列表
  static const List<String> emotionDimensions = [
    '喜悦', '幸福', '满足', '安心',
    '平静', '放松',
    '愤怒', '烦躁', '厌烦',
    '悲伤', '脆弱', '失望', '委屈',
    '恐惧', '焦虑',
    '渴望', '依恋', '思念', '爱意',
  ];

  /// 用一次对话的结束情绪更新基线
  void update(Map<String, double> endMood) {
    _sampleCount++;
    _lastUpdated = DateTime.now();

    for (final dim in emotionDimensions) {
      final current = endMood[dim] ?? 50;
      _values[dim] = _rollingAvg(_values[dim] ?? 50, current, _sampleCount);
    }
  }

  double _rollingAvg(double oldVal, double newVal, int n) {
    return (oldVal * (n - 1) + newVal) / n;
  }

  /// 获取基线值
  double get(String dimension) => _values[dimension] ?? 50;

  /// 获取完整的基线分布
  Map<String, double> get allValues => Map.from(_values);

  /// 基线是否"可信"（样本够多）
  bool get isReliable => _sampleCount >= 5;

  /// 基线是否"新鲜"（30天内更新过）
  bool get isFresh {
    return DateTime.now().difference(_lastUpdated).inDays < 30;
  }

  /// 整体效价（正面-负面，-100~100）
  double get valence {
    final pos = (_values['喜悦'] ?? 50) +
        (_values['幸福'] ?? 50) +
        (_values['满足'] ?? 50) +
        (_values['安心'] ?? 50) +
        (_values['依恋'] ?? 50);
    final neg = (_values['愤怒'] ?? 50) +
        (_values['悲伤'] ?? 50) +
        (_values['恐惧'] ?? 50) +
        (_values['焦虑'] ?? 50) +
        (_values['烦躁'] ?? 50);
    return pos / 5 - neg / 5;
  }

  /// 检测当前情绪是否异常偏离基线
  DeviationResult detectDeviation(Map<String, double> currentMood) {
    if (!isReliable) {
      return DeviationResult(isDeviated: false, reason: '基线样本不足');
    }

    double maxDeviation = 0;
    String maxDim = '';
    final details = <String, double>{};

    for (final dim in emotionDimensions) {
      final baseline = _values[dim] ?? 50;
      final current = currentMood[dim] ?? 50;
      final deviation = current - baseline;
      details[dim] = deviation;

      if (deviation.abs() > maxDeviation.abs()) {
        maxDeviation = deviation;
        maxDim = dim;
      }
    }

    final absDev = maxDeviation.abs();

    if (absDev < 20) {
      return DeviationResult(
        isDeviated: false,
        maxDimension: maxDim,
        maxDeviation: maxDeviation,
        details: details,
        reason: '正常波动',
        severity: DeviationSeverity.normal,
      );
    }

    if (absDev < 40) {
      return DeviationResult(
        isDeviated: true,
        maxDimension: maxDim,
        maxDeviation: maxDeviation,
        details: details,
        reason: '轻度偏离：$maxDim${maxDeviation > 0 ? "+" : ""}${maxDeviation.toStringAsFixed(0)}',
        severity: DeviationSeverity.mild,
      );
    }

    return DeviationResult(
      isDeviated: true,
      maxDimension: maxDim,
      maxDeviation: maxDeviation,
      details: details,
      reason: '显著偏离：$maxDim${maxDeviation > 0 ? "+" : ""}${maxDeviation.toStringAsFixed(0)}',
      severity: DeviationSeverity.significant,
    );
  }

  /// 检测情绪是否回归基线
  bool hasReturnedToBaseline(Map<String, double> currentMood) {
    final result = detectDeviation(currentMood);
    return !result.isDeviated || result.severity == DeviationSeverity.normal;
  }

  /// 重置基线
  void reset() {
    _values.clear();
    _sampleCount = 0;
    _lastUpdated = DateTime.now();
  }

  String toContext() {
    if (!isReliable) return '（用户情感基线：样本不足，暂不可用）';
    final pos = (_values['喜悦'] ?? 0) > 50 ? '正面' : '中性偏负';
    return '（用户情感基线：${pos}，效价${valence.toStringAsFixed(0)}，样本${_sampleCount}次）';
  }
}

/// 偏离结果
class DeviationResult {
  final bool isDeviated;
  final String maxDimension;
  final double maxDeviation;
  final Map<String, double> details;
  final String reason;
  final DeviationSeverity severity;

  DeviationResult({
    required this.isDeviated,
    this.maxDimension = '',
    this.maxDeviation = 0,
    this.details = const {},
    required this.reason,
    this.severity = DeviationSeverity.normal,
  });

  /// 偏离的方向（正向=更正面，负向=更负面）
  double get valenceShift {
    double pos = 0, neg = 0;
    for (final entry in details.entries) {
      if (['喜悦', '幸福', '满足', '安心', '依恋'].contains(entry.key)) {
        pos += entry.value;
      } else if (['愤怒', '悲伤', '恐惧', '焦虑', '烦躁'].contains(entry.key)) {
        neg += entry.value.abs();
      }
    }
    return pos / 5 - neg / 5;
  }
}

enum DeviationSeverity {
  normal,    // 正常波动（<20分）
  mild,      // 轻度偏离（20-39分）
  significant, // 显著偏离（>=40分）
}
