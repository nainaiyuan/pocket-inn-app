/// 关系记录 — 统一的知识记录格式（8-07 01:13 用户）
///
/// 用户原话："我们和男主说的是这样记：用户→家人→妈妈→喜欢/讨厌…
/// 下面有个具体的话，不管是情绪、记忆、规律都可以这样记录，
/// 点开详情就有后续的话的汇总。"
///
/// 结构：subject → predicate → object ＋ 原话(quote) ＋ 时间(time)
/// 归属(characterId)：A 男主 / B 男主 / null = 所有男主共同
/// 类型(category)：记忆 / 情绪 / 规律 / 行为
class RelationRecord {
  final String id;
  final String subject;      // 谁（用户 / 妈妈 / A男主 / 小猫…）
  final String predicate;    // 关系（喜欢 / 讨厌 / 是 / 想要…）
  final String object;       // 指向（妈妈 / 小猫 / 抱抱…）
  final String quote;        // 原话（用户当时说的话，一字不改）
  final String? time;        // 什么时间（每天晚上 / 上周 / 去年3月…）
  final String? characterId; // 归属男主（null = 共同）
  final String category;     // 记忆 / 情绪 / 规律 / 行为
  final DateTime createdAt;

  RelationRecord({
    required this.id,
    required this.subject,
    required this.predicate,
    required this.object,
    required this.quote,
    this.time,
    this.characterId,
    this.category = '记忆',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 展示用完整句子：谁 → 关系 → 什么（时间）
  String get sentence {
    final parts = <String>[
      subject,
      predicate,
      object,
      if (time != null && time!.isNotEmpty) '（$time）',
    ];
    return parts.join('');
  }

  /// 归属标签：共同 / A / B
  String get ownerLabel {
    if (characterId == null || characterId!.isEmpty) return '共同';
    final idx = characterId!.indexOf('_');
    if (idx > 0) {
      final lead = characterId!.substring(0, idx);
      final num = lead.replaceAll(RegExp(r'[^0-9]'), '');
      if (num.isNotEmpty) return '男主$num';
    }
    return characterId!;
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'subject': subject,
    'predicate': predicate,
    'object': object,
    'quote': quote,
    'time': time,
    'character_id': characterId,
    'category': category,
    'created_at': createdAt.toIso8601String(),
  };

  factory RelationRecord.fromMap(Map<String, dynamic> map) => RelationRecord(
    id: map['id'] as String,
    subject: map['subject'] as String,
    predicate: map['predicate'] as String,
    object: map['object'] as String,
    quote: map['quote'] as String,
    time: map['time'] as String?,
    characterId: map['character_id'] as String?,
    category: (map['category'] as String?) ?? '记忆',
    createdAt: DateTime.parse(map['created_at'] as String),
  );
}
