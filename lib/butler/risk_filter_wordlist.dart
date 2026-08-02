/// 风险词表（敏感词配置——外置 + 用户可编辑）
///
/// 设计（设计文档 9.2-9.4 + 风险过滤 README + 用户 15:58 需求）：
/// - 判定：不是"包含就替换"——按分级 + 搭配 + 白名单 + 冷却决定是否触发
/// - 替换策略：有 replacement 直接替换；没有 → 挖空为 [PRIVACY_MARK]
///   （挖个坑，男主看到标记自己理解意图，不脑补具体词）
/// - 分级：
///   - hard = 强敏感（动作类）：单独出现即触发（但白名单词组覆盖时不触发）
///   - soft = 弱敏感（身体部位/日常常见词）：需搭配 hard 词，
///     或同轮 soft 命中 ≥2 个（浓度）才触发
///     例："嘴唇干"（唇，soft 单命中）→ 不触发；"想亲你"（亲，hard）→ 触发
/// - 白名单（例外词组）："亲爱的"里的"亲"不敏感 → 不触发
/// - 冷却（持续时间维度）：触发后 coolDownMinutes 分钟内不重复挖空
/// - 分类：用户给敏感词分组（亲密/身体/家人…），辅助判定与组织
///
/// 用户配置存储（SharedPreferences，见 RiskWordStore）：
/// - 'risk_words_v2'：用户词表（首次启动写入默认表；删词 = 从存储删，真删）
/// - 'risk_exceptions_v2'：用户白名单（默认表 + 用户追加）

class RiskWord {
  final String word;
  final String kind; // 'severe' | 'hard' | 'soft'
  final String category; // 分类（亲密/身体/家人/其他…）——辅助判定与组织
  final String? replacement; // 有替换词直接替换；null = 挖空 [PRIVACY_MARK]
  final int coolDownMinutes; // 触发后冷却分钟（持续时间维度，防反复打码）

  const RiskWord(
    this.word, {
    this.kind = 'hard',
    this.category = '其他',
    this.replacement,
    this.coolDownMinutes = 10,
  });

  bool get isHard => kind == 'hard';

  /// 最高敏：任何场景直接屏蔽（求知也不豁免）——性行为等
  bool get isSevere => kind == 'severe';

  Map<String, dynamic> toJson() => {
        'word': word,
        'kind': kind,
        'category': category,
        if (replacement != null) 'replacement': replacement,
        'coolDownMinutes': coolDownMinutes,
      };

  factory RiskWord.fromJson(Map<String, dynamic> j) => RiskWord(
        (j['word'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'hard',
        category: (j['category'] as String?) ?? '其他',
        replacement: j['replacement'] as String?,
        coolDownMinutes: (j['coolDownMinutes'] as num?)?.toInt() ?? 10,
      );
}

/// 敏感词标记（挖坑）：男主看到这个标记 → 理解意图，不脑补内容
const String privacyMark = '[PRIVACY_MARK]';

/// 默认词表（预置——用户可删可改，首次启动写入存储后以用户配置为准）
const List<RiskWord> defaultRiskWordlist = [
  // ── 测试词（用户 15:58："爸爸妈妈各种要测试的你先自带，到时候我再删"）──
  RiskWord('爸爸', category: '家人'),
  RiskWord('妈妈', category: '家人'),
  RiskWord('老公', category: '家人'),
  RiskWord('老婆', category: '家人'),
  // ── 强敏感（动作类）：单独出现即触发 ──
  RiskWord('亲', category: '亲密'),
  RiskWord('吻', category: '亲密'),
  RiskWord('抱', category: '亲密'),
  RiskWord('摸', category: '亲密'),
  RiskWord('舔', category: '亲密'),
  RiskWord('咬', category: '亲密'),
  RiskWord('揉', category: '亲密'),
  RiskWord('捏', category: '亲密'),
  RiskWord('含', category: '亲密'),
  RiskWord('吸', category: '亲密'),
  RiskWord('啃', category: '亲密'),
  RiskWord('插', category: '亲密'),
  RiskWord('塞', category: '亲密'),
  RiskWord('顶', category: '亲密'),
  RiskWord('脱', category: '亲密'),
  RiskWord('裸', category: '亲密'),
  RiskWord('湿', category: '亲密'),
  RiskWord('颤', category: '亲密'),
  // ── 弱敏感（身体部位 / 日常常见词）：需搭配或浓度达标才触发 ──
  RiskWord('胸', kind: 'soft', category: '身体'),
  RiskWord('腿', kind: 'soft', category: '身体'),
  RiskWord('臀', kind: 'soft', category: '身体'),
  RiskWord('腰', kind: 'soft', category: '身体'),
  RiskWord('口', kind: 'soft', category: '身体'),
  RiskWord('唇', kind: 'soft', category: '身体'),
  RiskWord('舌', kind: 'soft', category: '身体'),
  RiskWord('入', kind: 'soft', category: '身体'),
  RiskWord('抽', kind: 'soft', category: '身体'),
  RiskWord('送', kind: 'soft', category: '身体'),
  RiskWord('进', kind: 'soft', category: '身体'),
  RiskWord('流', kind: 'soft', category: '身体'),
];

/// 默认白名单（例外词组）：命中词被这些词组覆盖 → 该词不触发
/// 例："亲爱的"（亲）、"进口"（进+口 双 soft）、"亲人/亲情"
const List<String> defaultExceptions = [
  '亲爱的',
  '亲人',
  '亲情',
  '亲爱',
  '进口',
  '进入',
  '进出',
  '进口商品',
  '口腔',
  '口红',
  '入口',
  '出口',
];
