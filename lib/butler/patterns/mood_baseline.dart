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

  /// 维度集合是**动态**的：模型/分析器输出什么维度，就注册什么维度。
  ///
  /// 不写死维度列表的原因（butler_algorithm.md 第 10 节）：
  /// - 情绪模型会更新换代，新模型输出新维度名
  /// - 管家没见过的维度 = 和男主一起"重新认识用户"（通过校准任务）
  /// - 旧维度靠 60 天半衰期自然衰减，不污染新体系
  ///
  /// [knownDimensions] 返回当前已注册的所有维度。
  List<String> get knownDimensions => List.unmodifiable(_values.keys);

  /// 用一次对话的结束情绪更新基线
  void update(Map<String, double> endMood) {
    _sampleCount++;
    _lastUpdated = DateTime.now();

    // 动态注册：endMood 里出现的每个维度都进基线。
    // 新维度首次出现 → 直接用当前值作为初始基线（而不是默认 50），
    // 这样新维度第二次出现时就能正常比较偏离。
    for (final entry in endMood.entries) {
      final dim = entry.key;
      final current = entry.value;
      _values[dim] = _rollingAvg(_values[dim] ?? current, current, _sampleCount);
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
  /// 动态计算：根据已知维度自动判断正负向。
  /// 正面维度：喜悦/幸福/满足/安心/平静/放松/依恋/爱意/渴望/期待/开心/信任/享受
  /// 负面维度：愤怒/烦躁/厌烦/悲伤/脆弱/失望/委屈/恐惧/焦虑/生气/难过/害怕/疲惫/无聊/需要空间/负面情绪
  double get valence {
    const positiveDims = {
      '喜悦', '幸福', '满足', '安心', '平静', '放松',
      '依恋', '爱意', '渴望', '期待', '开心', '信任', '享受', '情绪高涨',
    };
    const negativeDims = {
      '愤怒', '烦躁', '厌烦', '悲伤', '脆弱', '失望', '委屈',
      '恐惧', '焦虑', '生气', '难过', '害怕', '疲惫', '无聊',
      '需要空间', '负面情绪', '抗拒', '需要安慰', '渴望关注',
    };
    double pos = 0, neg = 0;
    int posCount = 0, negCount = 0;
    for (final entry in _values.entries) {
      if (positiveDims.contains(entry.key)) {
        pos += entry.value;
        posCount++;
      } else if (negativeDims.contains(entry.key)) {
        neg += entry.value;
        negCount++;
      }
    }
    if (posCount == 0 && negCount == 0) return 0;
    final posAvg = posCount > 0 ? pos / posCount : 50.0;
    final negAvg = negCount > 0 ? neg / negCount : 50.0;
    return posAvg - negAvg;
  }

  /// 检测当前情绪是否异常偏离基线
  DeviationResult detectDeviation(Map<String, double> currentMood) {
    if (!isReliable) {
      return DeviationResult(isDeviated: false, reason: '基线样本不足');
    }

    double maxDeviation = 0;
    String maxDim = '';
    final details = <String, double>{};

    for (final dim in _values.keys) {
      // 只比较双方都"认识"的维度：
      // - 基线里必须有该维度（否则默认 50 会误判）
      // - 当前情绪里必须有该维度（否则拿 50 对比没意义）
      final baseline = _values[dim];
      final current = currentMood[dim];
      if (baseline == null || current == null) continue;

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
    final v = valence;
    final pos = v > 10 ? '正面' : (v < -10 ? '负面' : '中性');
    return '（用户情感基线：${pos}，效价${v.toStringAsFixed(0)}，样本${_sampleCount}次，维度${_values.length}个）';
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
    const positiveDims = {
      '喜悦', '幸福', '满足', '安心', '平静', '放松',
      '依恋', '爱意', '渴望', '期待', '开心', '信任', '享受', '情绪高涨',
    };
    const negativeDims = {
      '愤怒', '烦躁', '厌烦', '悲伤', '脆弱', '失望', '委屈',
      '恐惧', '焦虑', '生气', '难过', '害怕', '疲惫', '无聊',
      '需要空间', '负面情绪', '抗拒', '需要安慰', '渴望关注',
    };
    double pos = 0, neg = 0;
    int posCount = 0, negCount = 0;
    for (final entry in details.entries) {
      if (positiveDims.contains(entry.key)) {
        pos += entry.value;
        posCount++;
      } else if (negativeDims.contains(entry.key)) {
        neg += entry.value.abs();
        negCount++;
      }
    }
    if (posCount == 0 && negCount == 0) return 0;
    return (posCount > 0 ? pos / posCount : 0) -
        (negCount > 0 ? neg / negCount : 0);
  }
}

enum DeviationSeverity {
  normal,    // 正常波动（<20分）
  mild,      // 轻度偏离（20-39分）
  significant, // 显著偏离（>=40分）
}
