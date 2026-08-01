import 'butler_skill.dart';

/// 技能注册表 + 匹配引擎
///
/// 注册所有技能 → match(userText) 返回命中的最高优先级技能（无命中 → 兜底技能）。
/// 与 OpenClaw 的 skills 一致：技能即插即用，注册即生效。
class ButlerSkillRegistry {
  ButlerSkillRegistry._();

  static final ButlerSkillRegistry instance = ButlerSkillRegistry._();

  final List<ButlerSkill> _skills = [];
  ButlerSkill? _fallback;

  /// 注册技能（幂等：重复 id 会先移除旧的）
  void register(ButlerSkill skill) {
    if (skill.isFallback) {
      _fallback = skill;
      return;
    }
    _skills.removeWhere((s) => s.id == skill.id);
    _skills.add(skill);
    _skills.sort((a, b) => b.priority.compareTo(a.priority));
  }

  /// 批量注册内置技能（幂等：重复调用只保留一份）
  void registerAll(List<ButlerSkill> skills) {
    for (final s in skills) {
      register(s);
    }
  }

  /// 清空（测试/重置用）
  void clear() {
    _skills.clear();
    _fallback = null;
  }

  /// 匹配：返回最高优先级命中的技能；无命中返回兜底技能（可能为 null）
  ButlerSkill? match(String userText) {
    for (final skill in _skills) {
      if (skill.matches(userText)) return skill;
    }
    return _fallback;
  }

  /// 全部技能（含兜底）
  List<ButlerSkill> get all => [..._skills, if (_fallback != null) _fallback!];

  ButlerSkill? get fallback => _fallback;
}
