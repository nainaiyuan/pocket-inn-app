import '../../utils/debug_logger.dart';
import '../tools/butler_tool_registry.dart';
import 'butler_skill.dart';

/// 记忆检索技能
///
/// 用户问"你还记得吗/我之前说"时触发：
///   🔧 memory_recall（检索用户记忆，按查询词过滤）
/// 把记忆注入 Prompt —— 男主回复时自然接住："我记得你说过…"
///
/// 例：用户说"你还记得我之前说过喜欢喝什么吗" → 男主会真的记得。
class MemoryRecallSkill extends ButlerSkill {
  @override
  String get id => 'memory_recall';

  @override
  String get name => '记忆检索';

  @override
  String get description =>
      '用户问"还记得吗/我之前说"时触发：检索用户记忆注入男主回复，让男主真的记得';

  @override
  List<String> get triggers =>
      ['还记得', '记得吗', '我之前', '我说过', '上次说', '以前说', '你记不记得'];

  @override
  int get priority => 8;

  /// 技能流程图（技能库页面展示用）
  @override
  List<String> get flowSteps => ['触发匹配', '🔧 查记忆', '生成记忆注入'];

  @override
  Future<ButlerSkillResult> execute(ButlerSkillContext ctx) async {
    try {
      final result = await ButlerToolRunner.instance.run(
        ButlerToolRegistry.instance.get('memory_recall')!,
        {'query': ctx.userText},
        argsSummary: '查询词=用户消息',
      );
      if (result == null) {
        return const ButlerSkillResult();
      }
      DebugLogger.log('管家流程', '🎯 技能【$name】命中，已注入记忆');
      return ButlerSkillResult(
        promptInjection: '【记忆检索·管家实时检索】$result',
      );
    } catch (e) {
      DebugLogger.log('管家流程', '技能【$name】执行失败: $e');
      return const ButlerSkillResult();
    }
  }
}
