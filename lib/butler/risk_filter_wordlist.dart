/// 风险词表（外置配置——改词表不碰代码）
///
/// 设计（设计文档 9.2-9.4 + 风险过滤 README）：
/// - 判定：不是"包含就替换"——按分级 + 搭配 + 浓度决定是否触发
/// - 替换策略：有 replacement 直接替换；没有 → 挖空为 [PRIVACY_MARK]
///   （挖个坑，男主看到标记自己理解意图，不脑补具体词）
///
/// 分级：
/// - hard = 强敏感（动作类）：单独出现即触发
/// - soft = 弱敏感（身体部位/日常常见词）：需搭配 hard 词，
///   或同轮 soft 命中 ≥2 个（浓度）才触发
///   例："嘴唇干"（唇，soft 单命中）→ 不触发；"想亲你"（亲，hard）→ 触发

class RiskWord {
  final String word;
  final String kind; // 'hard' | 'soft'
  final String? replacement; // 有替换词直接替换；null = 挖空 [PRIVACY_MARK]

  const RiskWord(this.word, {this.kind = 'hard', this.replacement});

  bool get isHard => kind == 'hard';
}

/// 敏感词标记（挖坑）：男主看到这个标记 → 理解意图，不脑补内容
const String privacyMark = '[PRIVACY_MARK]';

const List<RiskWord> riskWordlist = [
  // ── 强敏感（动作类）：单独出现即触发 ──
  RiskWord('亲'),
  RiskWord('吻'),
  RiskWord('抱'),
  RiskWord('摸'),
  RiskWord('舔'),
  RiskWord('咬'),
  RiskWord('揉'),
  RiskWord('捏'),
  RiskWord('含'),
  RiskWord('吸'),
  RiskWord('啃'),
  RiskWord('插'),
  RiskWord('塞'),
  RiskWord('顶'),
  RiskWord('脱'),
  RiskWord('裸'),
  RiskWord('湿'),
  RiskWord('颤'),
  // ── 弱敏感（身体部位 / 日常常见词）：需搭配或浓度达标才触发 ──
  RiskWord('胸', kind: 'soft'),
  RiskWord('腿', kind: 'soft'),
  RiskWord('臀', kind: 'soft'),
  RiskWord('腰', kind: 'soft'),
  RiskWord('口', kind: 'soft'),
  RiskWord('唇', kind: 'soft'),
  RiskWord('舌', kind: 'soft'),
  RiskWord('入', kind: 'soft'),
  RiskWord('抽', kind: 'soft'),
  RiskWord('送', kind: 'soft'),
  RiskWord('进', kind: 'soft'),
  RiskWord('流', kind: 'soft'),
];
