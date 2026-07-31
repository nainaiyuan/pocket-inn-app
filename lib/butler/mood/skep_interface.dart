/// SKEP 情感分析模型接口
///
/// 当前：占位接口定义
/// 目标：接入 PaddleNLP SKEP → 转 ONNX → Flutter onnxruntime 推理
///
/// 使用方式（模型加载后）：
///   final skep = SkepInterface(modelPath: 'skep_model.onnx');
///   await skep.initialize();
///   final result = skep.predict("今天好开心");
///
/// 输出 vs 当前 MoodEngine：
///   - MoodEngine：关键词匹配，0 模型，轻量但不准
///   - SkepInterface：模型推理，十几MB ONNX 文件，准但首次加载慢
///   - 两者可共存：MoodEngine 做实时快速判断，SKEP 做深度分析后修正

import 'mood_engine.dart';

class SkepInterface {
  final String modelPath;
  bool _initialized = false;

  // ONNX 运行时相关（占位，import onnxruntime）
  // late OrtSession _session;
  // late OrtAllocator _allocator;

  SkepInterface({required this.modelPath});

  /// 是否已初始化
  bool get isInitialized => _initialized;

  /// 初始化模型
  /// 加载 ONNX 文件到内存
  Future<void> initialize() async {
    // TODO: 实际实现
    // final bytes = await File(modelPath).readAsBytes();
    // _session = OrtSession.fromBuffer(bytes, _allocator);
    _initialized = true;
  }

  /// 预测单条文本的情感
  /// 返回情感标签 + 置信度
  SkepResult predict(String text) {
    if (!_initialized) {
      throw StateError('SKEP 模型未初始化，请先调用 initialize()');
    }

    // TODO: 实际推理
    // 1. tokenize 文本
    // 2. 构建输入 tensor
    // 3. session.run()
    // 4. 解析输出 → emotions + scores

    // 占位返回（模拟 SKEP 输出格式）
    return SkepResult(
      emotions: {
        '开心': 0.85,
        '平静': 0.12,
        '烦躁': 0.03,
      },
      polarity: 'positive',
      confidence: 0.85,
      triggerWords: ['开心'],
    );
  }

  /// 批量预测
  List<SkepResult> predictBatch(List<String> texts) {
    return texts.map((t) => predict(t)).toList();
  }

  /// 释放模型资源
  void dispose() {
    _initialized = false;
    // _session?.release();
  }
}

/// SKEP 预测结果
class SkepResult {
  /// 情感维度及其置信度
  /// 如 {'开心': 0.85, '平静': 0.12, '烦躁': 0.03}
  final Map<String, double> emotions;

  /// 整体情感极性：positive / negative / neutral
  final String polarity;

  /// 整体置信度（0-1）
  final double confidence;

  /// 触发词列表（模型抽出来的关键线索）
  final List<String> triggerWords;

  SkepResult({
    required this.emotions,
    required this.polarity,
    required this.confidence,
    this.triggerWords = const [],
  });

  /// 获取最高分情感标签
  String get primary {
    if (emotions.isEmpty) return 'unknown';
    return emotions.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  /// 最高分
  double get primaryScore {
    if (emotions.isEmpty) return 0;
    return emotions.entries.reduce((a, b) => a.value > b.value ? a : b).value;
  }

  /// 转换为 MoodResult（兼容 MoodEngine 的输出）
  MoodResult toMoodResult() {
    // 把 SKEP 的置信度转为归一化百分比
    final total = emotions.values.fold(0.0, (a, b) => a + b);
    if (total <= 0) {
      return MoodResult(tags: {'放松': 40, '信任': 30, '专注': 20}, suggestion: '按你的风格自然回应');
    }

    final tags = <String, double>{};
    final sorted = emotions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in sorted.take(4)) {
      tags[entry.key] = double.parse((entry.value / total * 100).toStringAsFixed(0));
    }

    // 根据情感极性生成建议
    String suggestion;
    switch (polarity) {
      case 'positive':
        suggestion = '用户今天状态不错，可以一起活跃互动';
        break;
      case 'negative':
        suggestion = '用户情绪偏低，可以多一些关心和安抚';
        break;
      default:
        suggestion = '按你的风格自然回应';
    }

    return MoodResult(tags: tags, suggestion: suggestion);
  }
}
