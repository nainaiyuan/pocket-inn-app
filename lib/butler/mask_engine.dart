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

import 'mood_analysis/mood_analyzer_keyword.dart' show KeywordMoodAnalyzer;
import 'risk_filter_wordlist.dart' show RiskWord, privacyMark;
import 'storage/identity_store.dart' show IdentityEntry, IdentityStore;
import 'patterns/pattern_engine.dart' show PatternEngine;

/// 处理结果
class ProcessResult {
  final String text;
  final bool wasModified;
  final Map<String, String> appliedMappings;
  final String? moodContext;

  /// 给男主的内部描述（如"[家人2]：一位男性长辈，用户尊重他"）。
  /// 只注入 system 层（男主认知），绝不进 user 文本 → 男主不会念出来。
  final List<String> maskHints;

  ProcessResult({
    required this.text,
    this.wasModified = false,
    this.appliedMappings = const {},
    this.moodContext,
    this.maskHints = const [],
  });
}

/// 假面层引擎
class MaskEngine {
  // ── 身份注册表 ──
  final Map<String, IdentityEntry> _identities = {};

  // ── 会话映射缓存 <sessionId, <identityId, 代号>> ──
  final Map<String, Map<String, String>> _sessionMappings = {};

  // ── 会话内"已描述过"记录 <sessionId, <identityId, 首次描述时间>> ──
  // 说一次机制：男主已经知道代号对应谁之后，不再重复附描述，
  // 除非管家发现了该身份的新情绪规律（男主需要知道情绪变了）。
  final Map<String, Map<String, DateTime>> _sessionDescribed = {};

  /// 规律引擎（可空，由外部注入）：用于生成"规律联动描述"。
  /// 男主发现用户提到某身份时情绪总是什么样 → 下次提到时附上这条规律；
  /// 规律变化了 → 重新附一次，让男主知道情绪变了。
  PatternEngine? patternEngine;

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

  // ── 关系概述池（内置兜底：身份没写描述时用）──
  // 键：relationType（旧数据兼容）或 category（新身份）
  static const Map<String, List<String>> _relationTemplates = {
    'family_mom': [
      '一位女性长辈（关系亲密，用户感情复杂）',
      '家里的长辈（很亲近，用户有些烦她）',
      '长辈（用户又爱又烦的一位女性长辈）',
      '用户的女性长辈（关系紧密，常有互动）',
    ],
    'family_dad': ['一位男性长辈（关系亲近，用户尊重他）', '家里的长辈（严肃但关心用户）', '男性长辈（用户和他话不多但感情深）'],
    'friend_close': ['用户的好朋友（关系很好）', '一位密友（用户可以倾诉的那种）', '用户亲近的朋友（经常联系）'],
    'work_boss': ['用户的上司（工作上有压力）', '用户的领导（用户有些怕他）', '工作上的上级（用户想讨好他）'],
    'work_colleague': ['用户的同事', '一个工作上的人', '用户的同行'],
    // 分类级兜底
    'family': ['一位家人（关系亲近）', '用户的家人（很熟）', '家里的长辈（常见面）'],
    'friend': ['用户的朋友', '一个和用户很熟的人', '用户常联系的朋友'],
    'work': ['工作相关的人', '用户工作上认识的人', '和用户有工作往来的人'],
    'stranger': ['用户认识的人', '一个用户提到的人'],
  };

  final Random _random = Random();

  // ── 持久化存储（可空 = 纯内存）──
  IdentityStore? _store;

  /// 关联持久化存储
  void attachStore(IdentityStore store) {
    _store = store;
  }

  /// 从存储加载身份（APP 启动时调用）
  Future<void> loadFromStore() async {
    final store = _store;
    if (store == null) return;
    try {
      final entries = await store.all();
      for (final entry in entries) {
        _identities[entry.id] = entry;
        _assignCode(entry);
      }
      print('[MaskEngine] 从存储加载 ${_identities.length} 个身份');
    } catch (e) {
      print('[MaskEngine] 加载身份存储失败: $e');
    }
  }

  /// 已注册的全部身份（给管理页用）
  List<IdentityEntry> get allIdentities => _identities.values.toList();

  /// 身份对应的代号（给管理页用）
  String? codeFor(String identityId) => _identityCodes[identityId];

  // ── 身份管理 ──

  /// 注册身份
  void registerIdentity(IdentityEntry entry) {
    _identities[entry.id] = entry;
    _assignCode(entry);
    _store?.save(entry).catchError((e) => print('[MaskEngine] 保存身份失败: $e'));
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
    _store
        ?.delete(IdentityStore.table, where: 'id = ?', whereArgs: [id])
        .catchError((e) => print('[MaskEngine] 删除身份失败: $e'));
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
  ///
  /// 描述策略（说一次机制）：
  /// - 会话内首次提到某身份 → 附一条描述（用户描述池随机 / 规律联动 / 内置模板）
  /// - 之后只替换为纯代号（男主已记住映射，不再重复描述 → 降低泄露风险）
  /// - 例外：管家发现该身份的新情绪规律 → 重新附一条规律描述（男主知道情绪变了）
  ProcessResult replaceSensitive({
    required String text,
    required String characterId,
    required String sessionId,
  }) {
    _sessionMappings.putIfAbsent(sessionId, () => {});
    final sessionMap = _sessionMappings[sessionId]!;
    final appliedMappings = <String, String>{};
    final maskHints = <String>[];
    var modified = text;

    // 按标签长度降序替换（避免短标签被长标签的子串影响）
    final sortedIdentities = _identities.values.toList()
      ..sort((a, b) => b.realLabel.length.compareTo(a.realLabel.length));

    for (final entry in sortedIdentities) {
      if (!modified.contains(entry.realLabel)) continue;

      final isFirstTime = !sessionMap.containsKey(entry.id);
      String code;

      if (isFirstTime) {
        // 首次：分配纯代号（描述不固化进映射，避免"每次描述都一样"）
        code = _identityCodes[entry.id] ?? '[其他]';
        sessionMap[entry.id] = code;
        // 描述 + 情绪规律都附上（男主既知道 ta 是谁，也知道你对 ta 的平均情绪）
        final desc = _pickDescription(entry);
        final patternDesc = _buildPatternDescription(entry);
        final parts = [
          if (desc != null) desc,
          if (patternDesc != null) patternDesc,
        ];
        if (parts.isNotEmpty) {
          // 描述只进 maskHints（system 注入），不进 user 文本
          maskHints.add('$code：${parts.join('；')}');
          _sessionDescribed.putIfAbsent(sessionId, () => {})[entry.id] =
              DateTime.now();
        }
      } else {
        code = sessionMap[entry.id]!;
        // 已有映射 → 说一次机制：默认不再附描述
        // 例外：该身份出现了新确认的规律（情绪变了）→ 附规律描述
        if (_hasNewPattern(entry, sessionId)) {
          final desc = _buildPatternDescription(entry);
          if (desc != null) {
            maskHints.add('$code：$desc');
            _sessionDescribed[sessionId]![entry.id] = DateTime.now();
          }
        }
      }

      modified = modified.replaceAll(entry.realLabel, code);
      appliedMappings[entry.id] = code;
    }

    return ProcessResult(
      text: modified,
      wasModified: appliedMappings.isNotEmpty,
      appliedMappings: appliedMappings,
      maskHints: maskHints,
    );
  }

  /// 恢复敏感信息（男主回复 → 显示给用户）
  String restoreSensitive({required String text, required String sessionId}) {
    final sessionMap = _sessionMappings[sessionId];
    if (sessionMap == null) return text;

    var restored = text;
    // 按代码长度降序还原
    final reverseEntries = <MapEntry<String, String>>[];
    for (final id in _identities.keys) {
      if (sessionMap.containsKey(id)) {
        reverseEntries.add(
          MapEntry(sessionMap[id]!, _identities[id]!.realLabel),
        );
      }
    }
    reverseEntries.sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in reverseEntries) {
      // 先还原"代号（描述）"完整形式（男主可能整串引用）
      final withDesc = RegExp(
        '${RegExp.escape(entry.key)}\\s*（[^）]*）',
      );
      restored = restored.replaceAll(withDesc, entry.value);
      // 再还原纯代号
      restored = restored.replaceAll(entry.key, entry.value);
      // 兜底：AI 可能把中文代号"翻译"成英文（[family1]/family1/Family1）
      final en = _categoryEn[entry.key.replaceAll(RegExp(r'[\[\]\d]'), '')];
      if (en != null) {
        final numMatch = RegExp(r'(\d+)').firstMatch(entry.key);
        final num = numMatch?.group(1) ?? '';
        restored = restored.replaceAll(
          RegExp('[$en]\\s*$num|\\b$en\\s*$num\\b', caseSensitive: false),
          entry.value,
        );
      }
    }
    return restored;
  }

  /// 中文类别 → 英文（AI 输出代号时可能英文化，还原兜底）
  static const Map<String, String> _categoryEn = {
    '家人': 'family',
    '亲属': 'relative',
    '朋友': 'friend',
    '闺蜜': 'bestie',
    '损友': 'friend',
    '同事': 'colleague',
    '上司': 'boss',
    '下属': 'subordinate',
    '合作伙伴': 'partner',
    '某人': 'someone',
    '一个人': 'someone',
    '那谁': 'someone',
  };

  /// 挑选本次附给男主的描述：
  /// 1. 优先：用户写的描述池（随机轮换）
  /// 2. 其次：规律联动描述（管家发现的情绪规律，动态生成）
  /// 3. 回退：relationType 内置模板（旧数据兼容）
  /// 4. 再回退：分类级内置模板
  String? _pickDescription(IdentityEntry entry) {
    if (entry.descriptions.isNotEmpty) {
      return entry.descriptions[_random.nextInt(entry.descriptions.length)];
    }
    final patternDesc = _buildPatternDescription(entry);
    if (patternDesc != null) return patternDesc;
    final byRelation = _relationTemplates[entry.relationType];
    if (byRelation != null && byRelation.isNotEmpty) {
      return byRelation[_random.nextInt(byRelation.length)];
    }
    final byCategory = _relationTemplates[entry.category];
    if (byCategory != null && byCategory.isNotEmpty) {
      return byCategory[_random.nextInt(byCategory.length)];
    }
    return null;
  }

  /// 规律联动描述：从规律引擎找该身份相关的已确认规律，
  /// 生成中性描述（不提具体称呼，只说情绪关联），如：
  /// "最近聊到这位家人时，你的情绪上升12%的烦躁（和唠叨有关）"
  String? _buildPatternDescription(IdentityEntry entry) {
    final engine = patternEngine;
    if (engine == null) return null;
    final matches = engine.confirmedPatterns
        .where((p) => p.keywords.contains(entry.realLabel))
        .toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final p = matches.first;

    final parts = <String>[];
    void add(double v, String label) {
      if (v.abs() >= 5) parts.add('${v > 0 ? '上升' : '下降'}${v.abs().round()}%的$label');
    }

    add(p.shiftJoy, '开心');
    add(p.shiftSad, '悲伤');
    add(p.shiftAnger, '生气');
    add(p.shiftAttachment, '依恋');
    if (parts.isEmpty) return null;

    final others =
        p.keywords.where((k) => k != entry.realLabel).toList();
    final tail = others.isEmpty ? '' : '（和${others.join('、')}有关）';
    return '最近聊到这位${_categoryLabel(entry.category)}时，你的情绪${parts.join('，')}$tail';
  }

  /// 该身份是否有"新确认的规律"（在本次会话首次描述之后出现的）
  bool _hasNewPattern(IdentityEntry entry, String sessionId) {
    final engine = patternEngine;
    if (engine == null) return false;
    final describedAt = _sessionDescribed[sessionId]?[entry.id];
    if (describedAt == null) return false; // 还没描述过 → 由首次逻辑处理
    return engine.confirmedPatterns
        .any((p) =>
            p.keywords.contains(entry.realLabel) &&
            p.lastSeen.isAfter(describedAt));
  }

  String _categoryLabel(String category) {
    switch (category) {
      case 'family':
        return '家人';
      case 'friend':
        return '朋友';
      case 'work':
        return '工作伙伴';
      default:
        return '人';
    }
  }

  /// 生成随机代号（给 AI 回复时用）
  String generateCodeName({
    required String category,
    required String characterId,
  }) {
    final pool = _codePools[category] ?? _codePools['stranger']!;
    return pool[_random.nextInt(pool.length)];
  }

  /// 隐私标记替换（PRIVACY_MARK 模式）
  /// 替换策略：有 replacement 直接替换；没有 → 挖空为 [PRIVACY_MARK]
  /// （挖个坑让男主自己理解意图，不脑补具体内容）
  ProcessResult applyPrivacyMark({
    required String text,
    required List<RiskWord> sensitiveWords,
  }) {
    var modified = text;
    int replaceCount = 0;

    // 长词先替换（避免子串干扰）
    final sorted = [...sensitiveWords]..sort((a, b) => b.word.length.compareTo(a.word.length));
    for (final word in sorted) {
      final to = word.replacement ?? privacyMark;
      modified = modified.replaceAll(word.word, to);
      replaceCount++;
    }

    return ProcessResult(text: modified, wasModified: replaceCount > 0);
  }

  /// 构建心情标签上下文字符串
  /// 根据用户原文生成助理解读标签
  /// 情绪标签上下文（敏感词触发时给男主）
  /// 输出情绪标签 + 建议（如"她现在的情绪：依恋 65、渴望关注 30。用户今天很黏人…"）
  /// 不输出活动词（男主不知道具体活动，只需要知道当前情绪）
  String buildMoodContextString(String originalText) {
    final result = KeywordMoodAnalyzer().analyze(originalText);
    if (result.dimensions.isEmpty) return '';
    final top = result.dimensions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tagParts = top.take(3).map((e) => '${e.key} ${e.value.round()}').join('、');
    final hint = result.anomalyDescription ?? '按这个情绪自然回应';
    return '\n（她现在的情绪：$tagParts。$hint）';
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
