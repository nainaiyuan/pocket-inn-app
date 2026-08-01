import '../../utils/debug_logger.dart';
import '../tools/butler_tool_registry.dart';
import 'butler_skill.dart';

/// 情绪状态洞察技能
///
/// 用户提到"心情/情绪/心态"时触发。
/// 技能执行 = 依次调用管家工具：
///   🔧 baseline_query（整体基线）→ 🔧 emotion_arcs_query（近7天弧线）→ 🔧 pattern_query（触发因素）
/// 然后把工具结果拼成"情绪洞察"注入 Prompt —— 男主回复时自然接住用户的情绪状态。
///
/// 例：用户说"我今天心情好差" → 男主会知道"她最近聊到妈妈时烦躁会上升"。
/// 日志页流程树能看到本次技能调用的每个工具：输入、输出、耗时。
class MoodStatusSkill extends ButlerSkill {
  @override
  String get id => 'mood_status';

  @override
  String get name => '情绪状态洞察';

  @override
  String get description =>
      '用户提到心情、情绪、心态、烦不烦时触发：调用基线/弧线/规律工具，生成洞察注入男主回复';

  @override
  List<String> get triggers => ['心情', '情绪', '心态', '烦不烦', '最近怎么'];

  @override
  int get priority => 10;

  /// 技能流程图（技能库页面展示用）
  @override
  List<String> get flowSteps =>
      ['触发匹配', '🔧 查基线', '🔧 查弧线', '🔧 查规律', '生成洞察注入'];

  @override
  Future<ButlerSkillResult> execute(ButlerSkillContext ctx) async {
    try {
      final tools = ButlerToolRegistry.instance;
      final runner = ButlerToolRunner.instance;

      // 1. 查整体基线
      final baseline = await runner.run(
        tools.get('baseline_query')!,
        const {},
        argsSummary: '整体情绪基线',
      );

      // 2. 查近 7 天弧线
      final arcs = await runner.run(
        tools.get('emotion_arcs_query')!,
        const {'days': 7},
        argsSummary: '近 7 天弧线',
      );

      // 3. 查触发因素（规律）
      final patterns = await runner.run(
        tools.get('pattern_query')!,
        const {'topN': 2, 'minShift': 5},
        argsSummary: '触发因素（规律）',
      );

      final parts = <String>[
        if (baseline != null && baseline.isNotEmpty) baseline,
        if (arcs != null && arcs.isNotEmpty) arcs,
        if (patterns != null && patterns.isNotEmpty) '触发因素：$patterns',
      ];
      if (parts.isEmpty) {
        return const ButlerSkillResult();
      }

      DebugLogger.log('管家流程', '🎯 技能【$name】命中，已生成情绪洞察');
      return ButlerSkillResult(
        promptInjection: '【情绪洞察·管家实时检索】${parts.join('；')}',
      );
    } catch (e) {
      DebugLogger.log('管家流程', '技能【$name】执行失败: $e');
      return const ButlerSkillResult();
    }
  }
}
