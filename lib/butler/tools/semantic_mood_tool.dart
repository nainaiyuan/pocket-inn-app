import '../mood_analysis/semantic_mood_analyzer.dart';
import 'butler_tool.dart';

/// 🔧 语义情绪分析工具
///
/// 参数：
///   text (String) — 要分析的文本
///
/// 输出：ONNX 模型识别的情绪维度 TOP（本地推理，模型未就绪时返回提示）
class SemanticMoodTool extends ButlerTool {
  @override
  String get id => 'semantic_mood_analyze';

  @override
  String get name => '语义情绪分析';

  @override
  String get description =>
      '用 ONNX 语义模型分析一段文本的情绪（28类细粒度情绪，本地推理）';

  @override
  Future<String> call(Map<String, dynamic> args) async {
    final text = args['text'] as String? ?? '';
    if (text.trim().isEmpty) return '无文本可分析';

    final dims = await SemanticMoodAnalyzer.instance.analyze(
      text,
      waitMs: 500,
    );
    if (dims == null) {
      return '语义模型未就绪（回退关键词分析）';
    }
    final top = dims.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return top
        .take(3)
        .map((e) => '${e.key} ${e.value.round()}')
        .join('、');
  }
}
