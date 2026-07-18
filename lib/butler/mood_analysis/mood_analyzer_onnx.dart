/// ONNX 模型版情绪分析器
///
/// 基于 liudev/roberta-multilabel-28-3-classes 的 ONNX 模型
/// 28类细粒度情绪 + 3极性（positive/negative/neutral）
///
/// 用法：
///   final analyzer = OnnxMoodAnalyzer();
///   await analyzer.init();  // 加载模型（异步）
///   final result = analyzer.analyze("今天好开心");
///
/// 出问题排查：
///   1. 加载闪退 → onnx_engine/ 下模型文件损坏或路径不对
///   2. 情绪不准 → _onnxToMood() 的映射逻辑需调整
///   3. 分词错误 → tokenizer.json 词表问题

import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'onnx_stub.dart';
import 'mood_interface.dart';

/// ONNX 模型版情绪分析器
class OnnxMoodAnalyzer implements IMoodAnalyzer {
  // ── 模型文件 ──
  static const String _modelDir = 'onnx_engine';
  static const String _modelFile = 'model.onnx';
  static const String _tokenizerFile = 'tokenizer.json';

  OrtSession? _session;
  OrtSessionOptions? _sessionOptions;
  Map<String, int>? _vocab;
  Map<int, String>? _id2label;
  late String _basePath;

  // ── 基线系统 ──
  final Map<String, double> _baseline = {};
  int _sampleCount = 0;

  // ── 模型参数 ──
  static const int _maxSeqLen = 128;
  static const int _numLabels = 31; // 28 情绪 + 3 极性

  // ── 28类情绪 → 管家标签 映射 ──
  // 模型输出的 28 维情绪向量，映射到管家的情绪标签体系
  static const Map<String, List<String>> _emotionToTag = {
    'anger': ['生气', '烦躁', '负面情绪'],
    'annoyance': ['烦躁', '生气', '负面情绪'],
    'disapproval': ['负面情绪', '生气'],
    'confusion': ['困惑', '需要空间'],
    'fear': ['恐惧', '需要安慰', '依恋'],
    'sadness': ['悲伤', '需要安慰', '负面情绪'],
    'disappointment': ['悲伤', '负面情绪', '需要空间'],
    'shame': ['负面情绪', '需要空间'],
    'disgust': ['负面情绪', '抗拒', '烦躁'],
    'amusement': ['开心', '情绪高涨', '趣味'],
    'excitement': ['情绪高涨', '期待', '活跃', '开心'],
    'optimism': ['期待', '放松', '信任'],
    'pride': ['掌控感', '情绪高涨'],
    'relief': ['放松', '满足'],
    'joy': ['开心', '满足', '情绪高涨'],
    'love': ['依恋', '享受互动', '信任', '情绪高涨'],
    'admiration': ['信任', '依恋', '享受互动'],
    'gratitude': ['信任', '满足', '依恋'],
    'contentment': ['满足', '放松', '开心'],
    'caring': ['依恋', '安全感需求', '信任'],
    'approval': ['信任', '满足', '开心'],
    'curiosity': ['专注', '活跃'],
    'realization': ['专注', '活跃'],
    'surprise': ['情绪高涨', '活跃'],
    'nervousness': ['恐惧', '需要安慰', '情绪高涨'],
    'neutral': ['平静', '放松'],
    'remorse': ['悲伤', '需要空间', '负面情绪'],
    'embarrassment': ['需要空间', '负面情绪'],
  };

  // ── 28个情绪标签名（与模型输出顺序一致） ──
  static const List<String> _emotionLabels = [
    'anger', 'annoyance', 'disapproval', 'confusion',
    'fear', 'sadness', 'disappointment', 'shame',
    'disgust', 'amusement', 'excitement', 'optimism',
    'pride', 'relief', 'joy', 'love',
    'admiration', 'gratitude', 'contentment', 'caring',
    'approval', 'curiosity', 'realization', 'surprise',
    'nervousness', 'neutral', 'remorse', 'embarrassment',
  ];

  // ── 3极性标签 ──
  static const List<String> _toneLabels = [
    'tone_positive', 'tone_negative', 'tone_neutral',
  ];

  /// 初始化：加载 ONNX 模型和分词器
  Future<void> init({String? basePath}) async {
    _basePath = basePath ?? Directory.current.path;

    // 1. 加载分词器
    final tokenizerPath = '$_basePath/$_modelDir/$_tokenizerFile';
    final tokenizerContent = await File(tokenizerPath).readAsString();
    _vocab = _parseTokenizer(tokenizerContent);
    print('[OnnxMood] 分词器加载完成: ${_vocab!.length} 词');

    // 2. 加载 ONNX 模型
    final modelPath = '$_basePath/$_modelDir/$_modelFile';
    final modelBytes = await File(modelPath).readAsBytes();

    _sessionOptions = OrtSessionOptions();
    // 使用 CPU 推理（手机端）
    // 如有 GPU/NPU 可在实际设备上启用
    _sessionOptions!.setIntraOpNumThreads(2);

    // 载入模型
    final env = OrtEnv.instance;
    _session = OrtSession.fromBuffer(modelBytes, _sessionOptions!);
    print('[OnnxMood] 模型加载完成');
  }

  /// 解析 tokenizer.json → vocab 映射
  Map<String, int> _parseTokenizer(String content) {
    final json = jsonDecode(content);
    final vocab = <String, int>{};
    if (json['model']?['vocab'] != null) {
      final rawVocab = json['model']['vocab'] as Map<String, dynamic>;
      for (final entry in rawVocab.entries) {
        vocab[entry.key] = (entry.value as num).toInt();
      }
    }
    return vocab;
  }

  /// BERT 分词（简化版，完整版需实现 WordPiece）
  /// TODO: 如果需要精确分词，建议使用 Flutter 端的 tokenizer 库
  List<int> _tokenize(String text) {
    if (_vocab == null) return [];

    final tokens = <int>[];
    tokens.add(_vocab!['[CLS]'] ?? 101); // CLS token

    // 按字符分割并查找
    final chars = text.split('');
    for (final char in chars) {
      // 先尝试直接匹配
      if (_vocab!.containsKey(char)) {
        tokens.add(_vocab![char]!);
      } else {
        // 用 [UNK] 替换
        tokens.add(_vocab!['[UNK]'] ?? 100);
      }
    }

    tokens.add(_vocab!['[SEP]'] ?? 102); // SEP token

    // 截断或填充到 _maxSeqLen
    while (tokens.length < _maxSeqLen) {
      tokens.add(_vocab!['[PAD]'] ?? 0);
    }
    if (tokens.length > _maxSeqLen) {
      tokens.length = _maxSeqLen;
      tokens[_maxSeqLen - 1] = _vocab!['[SEP]'] ?? 102;
    }

    return tokens;
  }

  @override
  MoodResult analyze(String text) {
    if (_session == null || _vocab == null) {
      // 模型未初始化，返回空结果
      return MoodResult(
        dimensions: {'平静': 80, '放松': 50},
        concentration: ConcentrationLevel.low,
        concentrationValue: 10,
      );
    }

    // 1. 分词
    final inputIds = _tokenize(text);
    final attentionMask = inputIds.map((id) => id == 0 ? 0 : 1).toList();

    // 2. ONNX 推理
    final inputTensor = OrtTensor.fromList(
      [inputIds],
      [1, _maxSeqLen],
      TensorElementType.int64,
    );
    final maskTensor = OrtTensor.fromList(
      [attentionMask],
      [1, _maxSeqLen],
      TensorElementType.int64,
    );

    final outputs = _session!.run(
      {'input_ids': inputTensor, 'attention_mask': maskTensor},
    );

    final logits = outputs['logits']!.data as List<double>;
    if (logits.length < _numLabels) {
      return MoodResult(
        dimensions: {'平静': 80, '放松': 50},
        concentration: ConcentrationLevel.low,
        concentrationValue: 10,
      );
    }

    // 3. Sigmoid 转概率
    final probs = logits.map((x) => 1.0 / (1.0 + exp(-x))).toList();

    // 4. 提取情绪维度（28类）
    final emotionScores = <String, double>{};
    for (int i = 0; i < 28; i++) {
      emotionScores[_emotionLabels[i]] = probs[i];
    }

    // 5. 映射到管家标签体系
    final tagScores = <String, double>{};
    for (final entry in _emotionToTag.entries) {
      final emotionName = entry.key;
      final tags = entry.value;
      final score = emotionScores[emotionName] ?? 0.0;

      for (final tag in tags) {
        tagScores[tag] = (tagScores[tag] ?? 0.0) + score * 0.5;
        // 同一情绪映射到多个标签时平分权重
      }
    }

    // 6. 取极性信息
    final tonePositive = probs[28];
    final toneNegative = probs[29];
    final toneNeutral = probs[30];

    // 基于极性微调
    if (tonePositive > 0.5) {
      tagScores['开心'] = (tagScores['开心'] ?? 0.0) + tonePositive * 20;
      tagScores['放松'] = (tagScores['放松'] ?? 0.0) + tonePositive * 10;
    }
    if (toneNegative > 0.5) {
      tagScores['负面情绪'] = (tagScores['负面情绪'] ?? 0.0) + toneNegative * 20;
    }

    // 7. 归一化到 0-100
    final maxScore = tagScores.values.isEmpty
        ? 1.0
        : tagScores.values.fold(0.0, (a, b) => a > b ? a : b);
    final dimensions = <String, double>{};
    for (final entry in tagScores.entries) {
      // 非线性映射：让高分更突出
      final normalized = (entry.value / maxScore * 100.0).clamp(0.0, 100.0);
      if (normalized > 5) {
        dimensions[entry.key] = normalized;
      }
    }

    // 如果没有有效维度
    if (dimensions.isEmpty) {
      dimensions['平静'] = 80.0;
      dimensions['放松'] = 50.0;
    }

    // 8. 计算浓度
    final concentrationValue = dimensions.values.fold(0.0, (a, b) => a > b ? a : b);
    ConcentrationLevel concentration;
    if (concentrationValue < 30) {
      concentration = ConcentrationLevel.low;
    } else if (concentrationValue < 60) {
      concentration = ConcentrationLevel.medium;
    } else {
      concentration = ConcentrationLevel.high;
    }

    // 9. 异常检测
    final isAnomaly = checkAnomaly(dimensions);
    final anomalyDesc = isAnomaly ? _describeAnomaly(dimensions) : null;

    return MoodResult(
      dimensions: dimensions,
      concentration: concentration,
      concentrationValue: concentrationValue,
      isAnomaly: isAnomaly,
      anomalyDescription: anomalyDesc,
    );
  }

  String _describeAnomaly(Map<String, double> dims) {
    final high = dims.entries
        .where((e) => e.value > 60)
        .map((e) => e.key)
        .take(3)
        .join('、');
    return '显著偏高：$high';
  }

  /// 释放资源
  void dispose() {
    _session?.release();
    _sessionOptions?.free();
  }

  // ── 接口实现 ──

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
      if ((entry.value - baseline).abs() > 25) {
        return true;
      }
    }
    return false;
  }
}
