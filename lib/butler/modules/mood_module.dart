/// 情绪分析模块 — 分析用户消息的情绪，产出 Prompt 片段
///
/// 用 [IMoodAnalyzer] 接口，具体实现可换：
/// - KeywordMoodAnalyzer（关键词版，默认，无模型依赖）
/// - OnnxMoodAnalyzer（ONNX 模型版，需模型文件）
///
/// 模块产出：
/// - contextFragments：情绪标签文本（拼进男主 Prompt）
/// - data['mood_result']：结构化情绪结果（给其他模块用）
library;

import '../modules/butler_module.dart';
import '../mood_analysis/mood_analyzer_impl.dart';
import '../mood_analysis/mood_interface.dart';

/// 情绪分析模块
class MoodModule extends ButlerModule {
  /// 使用的分析器（可替换实现）
  final IMoodAnalyzer analyzer;

  MoodModule({IMoodAnalyzer? analyzer})
    : analyzer = analyzer ?? MoodAnalyzerImpl();

  @override
  String get id => 'mood';

  @override
  String get name => '情绪分析';

  @override
  String get description => '分析用户消息的情绪，把情绪标签拼进男主看到的上下文';

  @override
  ButlerModuleStage get stage => ButlerModuleStage.analyze;

  @override
  bool get enabled => true;

  @override
  Future<ButlerModuleResult> onUserMessage(
    ButlerContext context,
    String text,
  ) async {
    if (text.trim().isEmpty) {
      return ButlerModuleResult.pass(text);
    }

    final result = analyzer.analyze(text);

    // 结构化数据给其他模块用
    final data = <String, dynamic>{
      'mood_result': result,
      'mood_dimensions': result.dimensions,
      'mood_concentration': result.concentration.name,
      'mood_is_anomaly': result.isAnomaly,
    };

    // 拼 Prompt 片段
    final fragment = _buildFragment(result);
    if (fragment.isEmpty) {
      return ButlerModuleResult(text: text, data: data);
    }

    return ButlerModuleResult(
      text: text,
      contextFragments: [fragment],
      data: data,
    );
  }

  String _buildFragment(MoodResult result) {
    // 只把显著情绪拼进去，平静状态不打扰男主
    final strong = result.dimensions.entries
        .where((e) => e.value >= 40)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (strong.isEmpty) return '';

    final parts = strong.take(3).map((e) => '${e.key}${e.value.round()}').join('、');
    var text = '（用户情绪：$parts，浓度${result.concentrationValue.round()}）';

    if (result.isAnomaly && result.anomalyDescription != null) {
      text += '\n（注意：${result.anomalyDescription}，请温柔回应）';
    }
    return text;
  }
}
