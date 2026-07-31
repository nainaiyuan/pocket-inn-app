/// 假面层引擎 — 身份替换/恢复核心
///
/// 用户 → 男主：敏感身份替换为代号 + 关系概述
/// 男主 → 用户：反向替换回来
///
/// 所有身份使用唯一标识符 [类别+序号]（如 [家人1]、[朋友2]），
/// 不同身份从不共用代号，确保还原时精确匹配。
///
/// 例：
///   "妈妈" → "[家人1]（一位女性长辈，关系亲近）"
///   "爸爸" → "[家人2]（一位男性长辈，用户尊重他）"
///   "晓晓" → "[朋友1]（用户的好朋友）"
///
/// 出问题排查：
///   - 某词没替换 → _identities 里没注册
///   - 替换错了 → 标签长度排序逻辑问题
///   - 反向替换失败 → sessionMap 被清空了

import 'dart:math';

/// 处理结果
class ProcessResult {
  final String text;
  final bool wasModified;
  final Map<String, String> appliedMappings;
  final String? moodContext;

  ProcessResult({
    required this.text,
    this.wasModified = false,
    this.appliedMappings = const {},
    this.moodContext,
  });
}

/// 假面层引擎
class MaskEngine {
  // ── 身份注册表 ──
  final Map<String, IdentityEntry> _identities = {};

  // ── 会话映射缓存 <sessionId, <identityId, 代号>> ──
  final Map<String, Map<String, String>> _sessionMappings = {};

  // ── 唯一标识符序号池 ──
  final Map<String, int> _codeCounters = {};
  final Map<String, String> _identityCodes = {};

  // ── 代号池（随机分配，按男主不同） ──
  static const Map<String, List<String>> _codePools = {
    'family': ['家人', '亲属', '家人'],
    'friend': ['朋友', '闺蜜', '损友'],
    'work': ['同事', '上司', '下属', '合作伙伴'],
    'stranger': ['某人', '一个人', '那谁'],
  };

  // ── 关系概述池 ──
  static const Map<String, List<String>> _relationTemplates = {
    'family_mom': [
      '一位女性长辈（关系亲密，用户感情复杂）',
      '家里的长辈（很亲近，用户有些烦她）',
      '长辈（用户又爱又烦的一位女性长辈）',
      '用户的女性长辈（关系紧密，常有互动）',
    ],
    'family_dad': [
      '一位男性长辈（关系亲近，用户尊重他）',
      '家里的长辈（严肃但关心用户）',
      '男性长辈（用户和他话不多但感情深）',
    ],
    'friend_close': [
      '用户的好朋友（关系很好）',
      '一位密友（用户可以倾诉的那种）',
      '用户亲近的朋友（经常联系）',
    ],
    'work_boss': [
      '用户的上司（工作上有压力）',
      '用户的领导（用户有些怕他）',
      '工作上的上级（用户想讨好他）',
    ],
    'work_colleague': [
      '用户的同事',
      '一个工作上的人',
      '用户的同行',
    ],
  };

  final Random _random = Random();

  // ── 身份管理 ──

  /// 注册身份
  void registerIdentity(IdentityEntry entry) {
    _identities[entry.id] = entry;
    _assignCode(entry);
  }

  /// 批量注册
  void registerIdentities(List<IdentityEntry> entries) {
    for (final entry in entries) {
      registerIdentity(entry);
    }
  }

  /// 移除身份
  void unregisterIdentity(String id) {
    _identities.remove(id);
    _identityCodes.remove(id);
  }

  /// 获取已注册的所有身份标签
  List<String> getAllLabels() =>
      _identities.values.map((e) => e.realLabel).toList();

  // ── 核心替换逻辑 ──

  /// 分配唯一标识符 [家人1]、[朋友2] ...
  void _assignCode(IdentityEntry entry) {
    final counter = _codeCounters[entry.category] ?? 0;
    _codeCounters[entry.category] = counter + 1;
    _identityCodes[entry.id] = '[${entry.category}${counter + 1}]';
  }

  /// 替换敏感信息（用户消息 → 发给男主的版本）
  ProcessResult replaceSensitive({
    required String text,
    required String characterId,
    required String sessionId,
  }) {
    _sessionMappings.putIfAbsent(sessionId, () => {});
    final sessionMap = _sessionMappings[sessionId]!;
    final appliedMappings = <String, String>{};
    var modified = text;

    // 按标签长度降序替换（避免短标签被长标签的子串影响）
    final sortedIdentities = _identities.values.toList()
      ..sort((a, b) => b.realLabel.length.compareTo(a.realLabel.length));

    for (final entry in sortedIdentities) {
      if (!modified.contains(entry.realLabel)) continue;

      // 复用或生成会话映射
      String code;
      if (sessionMap.containsKey(entry.id)) {
        code = sessionMap[entry.id]!;
      } else {
        final uniqueId = _identityCodes[entry.id] ?? '[其他]';
        final relationSummary = _getRandomRelation(entry.relationType);
        code = relationSummary != null
            ? '$uniqueId（$relationSummary）'
            : uniqueId;
        sessionMap[entry.id] = code;
      }

      modified = modified.replaceAll(entry.realLabel, code);
      appliedMappings[entry.id] = code;
    }

    return ProcessResult(
      text: modified,
      wasModified: appliedMappings.isNotEmpty,
      appliedMappings: appliedMappings,
    );
  }

  /// 恢复敏感信息（男主回复 → 显示给用户）
  String restoreSensitive({
    required String text,
    required String sessionId,
  }) {
    final sessionMap = _sessionMappings[sessionId];
    if (sessionMap == null) return text;

    var restored = text;
    // 按代码长度降序还原
    final reverseEntries = <MapEntry<String, String>>[];
    for (final id in _identities.keys) {
      if (sessionMap.containsKey(id)) {
        reverseEntries.add(MapEntry(sessionMap[id]!, _identities[id]!.realLabel));
      }
    }
    reverseEntries.sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in reverseEntries) {
      restored = restored.replaceAll(entry.key, entry.value);
    }
    return restored;
  }

  /// 获取随机关系概述
  String? _getRandomRelation(String relationType) {
    final templates = _relationTemplates[relationType];
    if (templates == null || templates.isEmpty) return null;
    return templates[_random.nextInt(templates.length)];
  }

  /// 生成随机代号（给 AI 回复时用）
  String generateCodeName({
    required String category,
    required String characterId,
  }) {
    final pool = _codePools[category] ?? _codePools['stranger']!;
    return pool[_random.nextInt(pool.length)];
  }

  /// 隐私标记替换（PRIVACY_MARK模式）
  /// 用*替换敏感词
  ProcessResult applyPrivacyMark({
    required String text,
    required List<String> sensitiveWords,
  }) {
    var modified = text;
    int replaceCount = 0;

    for (final word in sensitiveWords) {
      modified = modified.replaceAll(word, '*' * word.length);
      replaceCount++;
    }

    return ProcessResult(
      text: modified,
      wasModified: replaceCount > 0,
    );
  }

  /// 构建心情标签上下文字符串
  /// 根据用户原文生成助理解读标签
  String buildMoodContextString(String originalText) {
    final lower = originalText.toLowerCase();
    final tags = <String>[];

    if (lower.contains('亲') || lower.contains('吻') || lower.contains('抱')) {
      tags.add('亲密互动');
    }
    if (lower.contains('想你') || lower.contains('爱你') || lower.contains('依恋')) {
      tags.add('依恋表达');
    }
    if (lower.contains('摸') || lower.contains('抚') || lower.contains('触')) {
      tags.add('肢体接触');
    }
    if (lower.contains('别走') || lower.contains('陪') || lower.contains('留下')) {
      tags.add('陪伴需求');
    }

    if (tags.isEmpty) return '';
    return '\n（标签：${tags.join(' / ')}）';
  }

  // ── 会话管理 ──

  /// 清除会话映射
  void clearSession(String sessionId) {
    _sessionMappings.remove(sessionId);
  }

  /// 获取会话映射
  Map<String, String> getSessionMapping(String sessionId) =>
      Map.from(_sessionMappings[sessionId] ?? {});

  // ── 禁区检测 ──

  /// 检测文本是否包含隐私禁区（身份证、银行卡、手机号等）
  /// 这些不应该发送给任何第三方
  BlocklistResult checkBlocklist(String text) {
    final matched = <String>{};

    if (RegExp(r'\b\d{18}\b').hasMatch(text)) matched.add('身份证号');
    if (RegExp(r'\b\d{16}\b').hasMatch(text)) matched.add('银行卡号');
    if (RegExp(r'\b1[3-9]\d{9}\b').hasMatch(text)) matched.add('手机号');

    return BlocklistResult(
      isBlocked: matched.isNotEmpty,
      matchedLabels: matched.toList(),
    );
  }
}

/// 禁区检测结果
class BlocklistResult {
  final bool isBlocked;
  final List<String> matchedLabels;

  BlocklistResult({required this.isBlocked, this.matchedLabels = const []});
}

/// 身份条目
class IdentityEntry {
  final String id;           // 'family_mom'
  final String realLabel;    // '妈妈'
  final String category;     // 'family' | 'friend' | 'work'
  final String relationType; // 'family_mom' | 'friend_close' | 'work_colleague'
  final String importance;   // 'core' | 'normal' | 'temp'
  final String? attitude;    // 用户态度标签

  IdentityEntry({
    required this.id,
    required this.realLabel,
    required this.category,
    required this.relationType,
    this.importance = 'normal',
    this.attitude,
  });
}
