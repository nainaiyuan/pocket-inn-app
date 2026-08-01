import '../../utils/debug_logger.dart';
import '../tools/butler_tool_registry.dart';
import 'butler_skill.dart';

/// 情绪规律查询技能
///
/// 用户主动问"规律/什么让我烦/一聊到xxx就怎样"时触发：
///   🔧 pattern_query（查已确认的情绪规律：关键词组合 → 情绪偏移）
/// 把规律注入 Prompt —— 男主回复时点出用户的情绪触发因素。
///
/// 例：用户说"我发现自己一聊到工作就烦" → 男主会接住并共情。
class PatternQuerySkill extends ButlerSkill {
  @override
  String get id => 'pattern_query_skill';

  @override
  String get name => '情绪规律查询';

  @override
  String get description =>
      '用户主动问情绪规律/触发因素时触发：查已确认的规律（关键词→情绪偏移）注入男主回复';

  @override
  List<String> get triggers =>
      ['规律', '什么让我', '一提到', '一聊到', '一说到', '为什么我'];

  @override
  int get priority => 8;

  /// 技能流程图（技能库页面展示用）
  @override
  List<String> get flowSteps => ['触发匹配', '🔧 查规律', '生成规律注入'];

  @override
  Future<ButlerSkillResult> execute(ButlerSkillContext ctx) async {
    try {
      final result = await ButlerToolRunner.instance.run(
        ButlerToolRegistry.instance.get('pattern_query')!,
        const {'topN': 2, 'minShift': 5},
        argsSummary: '触发因素（规律）',
      );
      if (result == null || result.isEmpty) {
        return const ButlerSkillResult();
      }
      DebugLogger.log('管家流程', '🎯 技能【$name】命中，已注入规律');
      return ButlerSkillResult(
        promptInjection: '【规律洞察·管家实时检索】$result',
      );
    } catch (e) {
      DebugLogger.log('管家流程', '技能【$name】执行失败: $e');
      return const ButlerSkillResult();
    }
  }
}
