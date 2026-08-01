/// 管家技能体系 — 把管家能力封装成"技能"（像 OpenClaw 的 skills 一样）
///
/// 每个技能 = 名字 + 描述（何时用）+ 触发条件（关键词）+ 执行体（内部跑流程）。
/// 用户消息进来 → 技能引擎匹配 → 命中则触发技能 → 技能产出注入 Prompt 或直接回复。
/// 没命中任何技能 → 兜底技能（聊天流程）接管。
library;

/// 技能执行上下文：技能需要知道的信息
class ButlerSkillContext {
  /// 用户原始输入
  final String userText;

  /// 当前聊天的男主 id / 名字
  final String characterId;
  final String characterName;

  /// 会话 id
  final String sessionId;

  const ButlerSkillContext({
    required this.userText,
    required this.characterId,
    required this.characterName,
    required this.sessionId,
  });
}

/// 技能执行结果
class ButlerSkillResult {
  /// 注入 Prompt 的文本（男主会看到，比如情绪洞察、检索到的记忆）
  final String? promptInjection;

  /// 直接回复（不走男主，管家代答；暂未启用）
  final String? directReply;

  const ButlerSkillResult({this.promptInjection, this.directReply});
}

/// 技能基类
abstract class ButlerSkill {
  /// 唯一 id（流程树里显示）
  String get id;

  /// 技能名（流程树里显示）
  String get name;

  /// 技能描述：这个技能是干嘛的、什么时候触发
  String get description;

  /// 触发关键词（任一命中即触发）
  List<String> get triggers;

  /// 优先级：越大越优先（多个技能同时命中时取最高）
  int get priority => 5;

  /// 是否兜底技能（所有技能都没命中时接管；聊天流程）
  bool get isFallback => false;

  /// 流程图步骤（技能库页面展示；可选，默认无）
  List<String> get flowSteps => const [];

  /// 是否被当前输入触发
  bool matches(String userText) => triggers.any(userText.contains);

  /// 执行技能
  Future<ButlerSkillResult> execute(ButlerSkillContext ctx) async {
    return const ButlerSkillResult();
  }
}
