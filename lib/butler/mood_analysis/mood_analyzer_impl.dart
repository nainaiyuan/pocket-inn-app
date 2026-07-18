/// [MoodAnalyzerImpl] — 管家总入口的默认情绪分析器
///
/// 自动选择：
///   1. ONNX 模型版（正式APP主用）
///   2. 关键词简单版（ONNX加载失败时自动回退）
///
/// 外部代码只需 `MoodAnalyzerImpl()`，无需知道具体用哪个后端。

import 'mood_interface.dart';
import 'mood_analyzer_onnx.dart';
import 'mood_analyzer_keyword.dart';

/// 默认情绪分析器
///
/// 自动选后端：ONNX优先，失败则回退到关键词版。
class MoodAnalyzerImpl implements IMoodAnalyzer {
  final IMoodAnalyzer _backend;
  final bool _usingOnnx;

  factory MoodAnalyzerImpl({String? basePath}) {
    IMoodAnalyzer backend;
    bool usingOnnx;

    try {
      backend = _OnnxBackendForImpl();
      usingOnnx = true;
    } catch (e) {
      backend = KeywordMoodAnalyzer();
      usingOnnx = false;
    }

    return MoodAnalyzerImpl._internal(backend, usingOnnx);
  }

  MoodAnalyzerImpl._internal(this._backend, this._usingOnnx);

  bool get isUsingOnnx => _usingOnnx;

  Future<void> init({String? basePath}) async {
    if (_backend is _OnnxBackendForImpl) {
      await (_backend as _OnnxBackendForImpl).init(basePath: basePath);
    }
  }

  @override
  MoodResult analyze(String text) => _backend.analyze(text);

  @override
  Map<String, double> getBaseline() => _backend.getBaseline();

  @override
  void updateBaseline(MoodResult latest) => _backend.updateBaseline(latest);

  @override
  bool checkAnomaly(Map<String, double> current) =>
      _backend.checkAnomaly(current);
}

/// 包装 OnnxMoodAnalyzer，让 MoodAnalyzerImpl 能同步构造
class _OnnxBackendForImpl implements IMoodAnalyzer {
  OnnxMoodAnalyzer? _impl;
  bool _initialized = false;

  Future<void> init({String? basePath}) async {
    final onnx = OnnxMoodAnalyzer();
    await onnx.init(basePath: basePath);
    _impl = onnx;
    _initialized = true;
  }

  @override
  MoodResult analyze(String text) {
    if (!_initialized) {
      return MoodResult(
        dimensions: {'平静': 80, '放松': 50},
        concentration: ConcentrationLevel.low,
        concentrationValue: 10,
      );
    }
    return _impl!.analyze(text);
  }

  @override
  Map<String, double> getBaseline() =>
      _impl?.getBaseline() ?? {};

  @override
  void updateBaseline(MoodResult latest) =>
      _impl?.updateBaseline(latest);

  @override
  bool checkAnomaly(Map<String, double> current) =>
      _impl?.checkAnomaly(current) ?? false;
}
