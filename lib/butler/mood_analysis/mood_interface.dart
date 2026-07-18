/// 情绪分析模块 — 统一接口定义
///
/// 所有模块通过这个接口调情绪分析，不直接调 mood_engine。
/// 这样以后换算法（mood_engine → SKEP → 其他）不用改调用方。

/// 情绪分析结果
class MoodResult {
  /// 情绪标签维度（全部 0-100）
  final Map<String, double> dimensions;

  /// 情感浓度等级
  final ConcentrationLevel concentration;

  /// 浓度数值（0-100）
  final double concentrationValue;

  /// 是否偏离基线
  final bool isAnomaly;

  /// 偏离的描述（异常时才有值）
  final String? anomalyDescription;

  MoodResult({
    required this.dimensions,
    required this.concentration,
    required this.concentrationValue,
    this.isAnomaly = false,
    this.anomalyDescription,
  });
}

/// 情感浓度等级
enum ConcentrationLevel {
  low,     // 日常/正常
  medium,  // 偏高/有情绪
  high,    // 情绪强烈
}

/// 情绪分析模块接口
abstract class IMoodAnalyzer {
  /// 分析用户文本，返回情绪结果
  MoodResult analyze(String text);

  /// 获取用户的情绪基线
  /// 返回各维度的日常均值
  Map<String, double> getBaseline();

  /// 更新基线（用最新的数据校正）
  void updateBaseline(MoodResult latest);

  /// 检测是否偏离基线
  bool checkAnomaly(Map<String, double> current);
}
