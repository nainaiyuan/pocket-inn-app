import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import '../../utils/debug_logger.dart';
import 'bert_tokenizer.dart';
import 'mood_analyzer_keyword.dart';

/// 语义情绪分析器 — 基于 ONNX 量化模型（liudev/roberta-multilabel-28-3-classes）
///
/// - 本地推理（不消耗 API token，离线可用）
/// - 28 类细粒度情绪 + 3 极性 → 映射到管家中文维度
/// - 模型未就绪/加载失败 → analyze 返回 null，调用方回退关键词分析
///
/// 模型文件：assets/models/model_int8.onnx（154MB int8 量化，CI 编译时下载打包）
class SemanticMoodAnalyzer {
  SemanticMoodAnalyzer._();

  static final SemanticMoodAnalyzer instance = SemanticMoodAnalyzer._();

  static const String _modelAsset = 'assets/models/model_int8.onnx';
  static const String _tokenizerAsset = 'assets/models/tokenizer.json';

  // 8-12 21:42（用户拍板：模型自己带维度配置，代码不写死维度数）
  // 换新模型 = 换模型文件 + labels.json，代码一行不用动：
  // - emotion_labels：模型输出顺序 = 标签顺序（维度数动态，不写死 28）
  // - polarity_labels：可选（没有就空数组，跳过极性微调；按名字匹配不按位置）
  // - 未知标签（翻译表查不到）→ 直接透传标签名当维度（不丢，
  //   MoodBaseline 动态注册自动更新情感种类）
  // - 多模型输出合并进同一维度池：有的叠加、没有的新增；冲突交给规律引擎
  //   （校准任务问男主关键词 → 说多了自动匹配），情绪只是给男主的参考
  static const String _labelsAsset = 'assets/models/labels.json';

  OrtSession? _session;
  BertTokenizer? _tokenizer;
  Future<bool>? _initFuture;
  bool _failed = false;
  List<String> _emotionLabels = const [];
  List<String> _polarityLabels = const [];

  /// 模型是否已就绪
  bool get isReady => _session != null && _tokenizer != null;

  /// APP 启动时预热（后台加载，不阻塞任何流程）
  void warmUp() {
    if (_failed || _initFuture != null) return;
    _initFuture = _init().then((ok) {
      if (!ok) _failed = true;
      return ok;
    }).catchError((Object e) {
      _failed = true;
      DebugLogger.log('管家情绪', '语义模型加载失败，回退关键词分析: $e');
      return false;
    });
    // 让调用方拿到 future（供 analyze 等待）
  }

  /// 语义分析。模型未就绪时最多等 [waitMs]；仍不可用则返回 null（回退关键词）。
  Future<Map<String, double>?> analyze(
    String text, {
    int waitMs = 300,
  }) async {
    if (text.trim().isEmpty) return null;
    if (_failed) return null;

    if (_session == null || _tokenizer == null) {
      final future = _initFuture ??= _init().catchError((Object e) {
        _failed = true;
        DebugLogger.log('管家情绪', '语义模型加载失败，回退关键词分析: $e');
        return false;
      });
      final ok = await future.timeout(
        Duration(milliseconds: waitMs),
        onTimeout: () => false,
      );
      if (!ok) return null;
    }
    if (_session == null || _tokenizer == null) return null;

    try {
      final encoded = _tokenizer!.encode(text);
      final inputIds = Int64List.fromList(encoded.inputIds);
      final attentionMask = Int64List.fromList(encoded.attentionMask);

      final inputOrt = OrtValueTensor.createTensorWithDataList(
        inputIds,
        [1, encoded.inputIds.length],
      );
      final maskOrt = OrtValueTensor.createTensorWithDataList(
        attentionMask,
        [1, encoded.attentionMask.length],
      );
      final runOptions = OrtRunOptions();
      // run 返回 List<OrtValue?>（按模型输出顺序），不是 Map
      final outputs = _session!.run(runOptions, {
        'input_ids': inputOrt,
        'attention_mask': maskOrt,
      });
      runOptions.release();
      inputOrt.release();
      maskOrt.release();

      // 取第一个张量输出（logits）；不依赖输出名，找不到就回退
      Object? logits;
      for (final o in outputs) {
        final v = o?.value;
        if (v is List && logits == null) {
          logits = v;
        }
        o?.release();
      }
      if (logits == null) return null;
      final row = (logits as List).first;
      final labels =
          _emotionLabels.isEmpty ? _defaultEmotionLabels : _emotionLabels;
      if (row is! List || row.length < labels.length) return null;
      final scores = <double>[
        for (final v in row) (v as num).toDouble(),
      ];
      var dims = _scoresToDimensions(scores);

      // 否定修正：'不开心' 被模型误判为"开心"（BERT+int8 对否定理解弱）
      // → 正性维度减半，负性维度抬高
      final negated = KeywordMoodAnalyzer.detectNegatedMoods(text);
      if (negated.isNotEmpty && dims != null) {
        const positiveDims = {'开心', '情绪高涨', '依恋', '放松'};
        for (final d in positiveDims) {
          if (dims.containsKey(d)) dims[d] = dims[d]! * 0.4;
        }
        dims['悲伤'] = (dims['悲伤'] ?? 0) + 30;
        dims['负面情绪'] = (dims['负面情绪'] ?? 0) + 30;
        dims.removeWhere((_, v) => v < 5);
        if (dims.isEmpty) dims = null;
      }
      return dims;
    } catch (e) {
      DebugLogger.log('管家情绪', '语义分析失败: $e');
      return null;
    }
  }

  Future<bool> _init() async {
    try {
      DebugLogger.log('管家情绪', '语义模型加载中（154MB int8）…');
      final sw = Stopwatch()..start();

      OrtEnv.instance.init();
      final modelData = await rootBundle.load(_modelAsset);
      final sessionOptions = OrtSessionOptions();
      _session = OrtSession.fromBuffer(
        modelData.buffer.asUint8List(),
        sessionOptions,
      );
      sessionOptions.release();

      final tokenizerData = await rootBundle.load(_tokenizerAsset);
      _tokenizer = BertTokenizer.fromJsonBytes(
        tokenizerData.buffer.asUint8List(),
      );

      // 模型结构配置：情绪标签 + 极性标签（不写死；读失败回退内置默认）
      try {
        final labelsJson = await rootBundle.loadString(_labelsAsset);
        final decoded = jsonDecode(labelsJson) as Map<String, dynamic>;
        _emotionLabels = [
          for (final e in (decoded['emotion_labels'] as List? ?? const []))
            e.toString(),
        ];
        _polarityLabels = [
          for (final e in (decoded['polarity_labels'] as List? ?? const []))
            e.toString(),
        ];
      } catch (e) {
        DebugLogger.log('管家情绪', 'labels.json 读取失败，用内置默认: $e');
        _emotionLabels = _defaultEmotionLabels;
        _polarityLabels = const ['positive', 'negative', 'neutral'];
      }

      sw.stop();
      DebugLogger.log(
        '管家情绪',
        '语义模型就绪（${sw.elapsedMilliseconds}ms），后续走语义级情绪分析',
      );
      return true;
    } catch (e) {
      DebugLogger.log('管家情绪', '语义模型加载异常: $e');
      return false;
    }
  }

  // ── 标签 → 管家中文维度 ──
  // 8-12 21:42：标签清单不再写死在这里——模型自带的 labels.json 为准
  // （换新模型只换配置）；下面这份只是 labels.json 读取失败时的兜底。

  static const List<String> _defaultEmotionLabels = [
    'anger', 'annoyance', 'disapproval', 'confusion', 'embarrassment',
    'fear', 'sadness', 'disappointment', 'shame', 'disgust',
    'amusement', 'excitement', 'optimism', 'pride', 'relief',
    'joy', 'love', 'admiration', 'gratitude', 'contentment',
    'caring', 'approval', 'curiosity', 'realization', 'surprise',
    'nervousness', 'neutral', 'remorse',
  ];

  static const Map<String, Map<String, double>> _labelToDims = {
    'anger': {'生气': 80, '烦躁': 60, '负面情绪': 50},
    'annoyance': {'烦躁': 70, '生气': 50, '负面情绪': 40},
    'disapproval': {'负面情绪': 50, '生气': 30},
    'confusion': {'困惑': 60, '好奇': 40},
    'embarrassment': {'需要空间': 50, '负面情绪': 30},
    'fear': {'恐惧': 70, '需要安慰': 60, '依恋': 30},
    'sadness': {'悲伤': 80, '需要安慰': 60, '负面情绪': 50},
    'disappointment': {'悲伤': 60, '负面情绪': 50},
    'shame': {'需要空间': 50, '负面情绪': 40},
    'disgust': {'负面情绪': 60, '生气': 30},
    'amusement': {'开心': 70, '情绪高涨': 50},
    'excitement': {'情绪高涨': 75, '开心': 60},
    'optimism': {'开心': 60, '放松': 40},
    'pride': {'开心': 50, '情绪高涨': 40},
    'relief': {'放松': 70, '开心': 40},
    'joy': {'开心': 85, '情绪高涨': 60},
    'love': {'依恋': 85, '渴望占有': 50, '开心': 40},
    'admiration': {'依恋': 50, '开心': 40},
    'gratitude': {'依恋': 40, '开心': 40},
    'contentment': {'放松': 60, '开心': 50, '平静': 40},
    'caring': {'依恋': 60, '渴望关注': 40},
    'approval': {'开心': 30}, // 调低：int8 量化下 approval 常虚高（"我不开心"实测 0.69 噪音）
    'curiosity': {'好奇': 60},
    'realization': {'好奇': 40, '情绪高涨': 30},
    'surprise': {'情绪高涨': 50, '开心': 30},
    'nervousness': {'恐惧': 50, '烦躁': 40, '需要安慰': 30},
    'neutral': {'平静': 60},
    'remorse': {'悲伤': 60, '需要安慰': 40, '负面情绪': 50},
  };

  /// 极性标签按名字找索引（不写死位置；没有返回 null）
  int? _polarityIndexOf(String name) {
    for (var i = 0; i < _polarityLabels.length; i++) {
      if (_polarityLabels[i].toLowerCase() == name) return i;
    }
    return null;
  }

  static double _sigmoid(double x) => 1 / (1 + math.exp(-x));

  /// logits → 管家维度 Map（值 0-100）
  /// 激活阈值 0.5；结构按 labels.json（情绪标签数动态；极性可选、按名字匹配）
  Map<String, double>? _scoresToDimensions(List<double> scores) {
    final dims = <String, double>{};
    final labels =
        _emotionLabels.isEmpty ? _defaultEmotionLabels : _emotionLabels;

    // 情绪类（sigmoid > 0.5 视为激活）：翻译表查得到 → 叠加中文维度；
    // 查不到（新模型新标签）→ 透传标签名当维度（MoodBaseline 自动注册）
    var anyActive = false;
    for (var i = 0; i < labels.length && i < scores.length; i++) {
      final prob = _sigmoid(scores[i]);
      if (prob < 0.5) continue;
      anyActive = true;
      final label = labels[i];
      final mapped = _labelToDims[label];
      if (mapped != null) {
        for (final e in mapped.entries) {
          dims[e.key] = (dims[e.key] ?? 0) + e.value * prob;
        }
      } else {
        dims[label] = (dims[label] ?? 0) + 70 * prob;
      }
    }

    // 极性（按名字匹配，有就微调、没有跳过；不写死位置/个数）
    final emotionLen = labels.length;
    double? pos, neg, neu;
    final posIdx = _polarityIndexOf('positive');
    final negIdx = _polarityIndexOf('negative');
    final neuIdx = _polarityIndexOf('neutral');
    if (posIdx != null && emotionLen + posIdx < scores.length) {
      pos = _sigmoid(scores[emotionLen + posIdx]);
    }
    if (negIdx != null && emotionLen + negIdx < scores.length) {
      neg = _sigmoid(scores[emotionLen + negIdx]);
    }
    if (neuIdx != null && emotionLen + neuIdx < scores.length) {
      neu = _sigmoid(scores[emotionLen + neuIdx]);
    }
    if (pos != null && neg != null && neu != null) {
      if (pos >= neg && pos >= neu && pos > 0.5) {
        dims['开心'] = (dims['开心'] ?? 0) + 15 * pos;
        dims['情绪高涨'] = (dims['情绪高涨'] ?? 0) + 10 * pos;
        anyActive = true;
      } else if (neg >= neu && neg > 0.5) {
        dims['负面情绪'] = (dims['负面情绪'] ?? 0) + 20 * neg;
        dims['悲伤'] = (dims['悲伤'] ?? 0) + 10 * neg;
        anyActive = true;
      }
    }
    if (!anyActive) return null;

    // 归一化到 0-100 并保留有效维度
    final result = <String, double>{};
    for (final e in dims.entries) {
      final v = e.value.clamp(0.0, 100.0);
      if (v >= 5) result[e.key] = v;
    }
    return result.isEmpty ? null : result;
  }
}
