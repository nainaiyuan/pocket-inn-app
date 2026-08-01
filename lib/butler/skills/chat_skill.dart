import 'butler_skill.dart';

/// 聊天兜底技能
///
/// 所有技能都没命中时的默认路径：正常聊天流程
/// （假面替换 → 组合 Prompt → 发送男主 → 拆分存储 → 记录情绪）。
/// 技能本身不做事——"执行"就是 ChatService 的原有聊天流程。
class ChatSkill extends ButlerSkill {
  @override
  String get id => 'chat';

  @override
  String get name => '聊天流程';

  @override
  String get description => '兜底技能：没有技能命中时的正常聊天';

  @override
  List<String> get triggers => const [];

  @override
  int get priority => 0;

  @override
  bool get isFallback => true;

  @override
  bool matches(String userText) => true; // 兜底：永远匹配
}
