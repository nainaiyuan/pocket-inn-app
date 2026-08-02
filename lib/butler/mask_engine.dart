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

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_logger.dart' show DebugLogger;
import 'mood_analysis/mood_analyzer_keyword.dart' show KeywordMoodAnalyzer;
import 'risk_filter_wordlist.dart' show RiskWord;
import 'sensitive_info/sensitive_info_detector.dart'
    show SensitiveInfoDetector, privacyMark;
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

  /// 提醒档敏感词（分数在提醒区间，需用户确认是否屏蔽）
  final List<String> askWords;

  /// 直接屏蔽档敏感词（最高敏/高分/用户已确认过）
  final List<String> blockedWords;

  /// 敏感词挖空前的文本（假面层已替换）——用户选"不屏蔽"时用这个
  final String? maskLayerText;

  /// 命中的固定格式（身份证/手机号/银行卡/邮箱）——弹窗问用户是否发送
  final List<String> formatMatched;

  /// 固定格式挖空前的文本（敏感词已处理）——用户选"发送"时用这个
  final String? formatLayerText;

  ProcessResult({
    required this.text,
    this.wasModified = false,
    this.appliedMappings = const {},
    this.moodContext,
    this.maskHints = const [],
    this.askWords = const [],
    this.blockedWords = const [],
    this.maskLayerText,
    this.formatMatched = const [],
    this.formatLayerText,
  });
}

/// 假面层引擎
class MaskEngine {
  /// 每次对话都附上情绪参考（DeepSeek 无后台记忆 → 每次带，命中缓存）
  /// 开关在假面层页 UI；有后台记忆的模型可关掉（只带一次）
  static bool hintsEveryTurn = true;

  static Future<void> loadHintsEveryTurn() async {
    final prefs = await SharedPreferences.getInstance();
    hintsEveryTurn = prefs.getBool('mask_hints_every_turn') ?? true;
  }

  static Future<void> setHintsEveryTurn(bool value) async {
    hintsEveryTurn = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('mask_hints_every_turn', value);
  }

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

  // ── 每身份平均情绪累积（平均情感基线）──
  // <identityId, <情绪维度, 滚动平均值>>；样本数单独记录
  final Map<String, Map<String, double>> _identityMoodAvg = {};
  final Map<String, int> _identityMoodCount = {};
  static const String _moodAvgPrefsKey = 'mask_identity_mood_avg_v1';
  static const String _moodCountPrefsKey = 'mask_identity_mood_count_v1';

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

  final Random _random = Random();

  /// 生成代号后缀：A、B、…、Z、AA、AB、…（用户 18:58：家人A、家人B，
  /// 多一个加一个，再多 AA、BB 这种，再多了就 3 位 4 位组合下去）
  static String _codeSuffix(int n) {
    var num = n;
    var suffix = '';
    while (num >= 0) {
      suffix = String.fromCharCode(0x41 + (num % 26)) + suffix;
      num = num ~/ 26 - 1;
    }
    return suffix;
  }

  /// 分配唯一标识符 [家人A]、[朋友B] ...（注册时分配，管理页展示用；
  /// 实际对话用会话级轮换 [_pickSessionCode]——用户 18:58：
  /// 代号轮换，男主无法把代号绑定到具体人）
  void _assignCode(IdentityEntry entry) {
    final counter = _codeCounters[entry.category] ?? 0;
    _codeCounters[entry.category] = counter + 1;
    final pool = _codePools[entry.category] ?? const ['某人'];
    final label = pool[_random.nextInt(pool.length)];
    _identityCodes[entry.id] = '[$label${_codeSuffix(counter)}]';
  }

  /// 会话级代号分配：从该类别的代号池里挑一个本会话未使用的代号。
  /// 每次新会话（sessionId 变化）重新轮换 → 男主无法积累"代号=谁"的绑定；
  /// 同一会话内保持一致 → 不影响对话连贯。
  String _pickSessionCode(IdentityEntry entry, Map<String, String> sessionMap) {
    final used = sessionMap.values.toSet();
    final pool = _codePools[entry.category] ?? const ['某人'];
    final label = pool[_random.nextInt(pool.length)];
    var idx = 0;
    while (true) {
      final code = '[$label${_codeSuffix(idx)}]';
      if (!used.contains(code)) return code;
      idx++;
    }
  }

  // ── 持久化存储（可空 = 纯内存）──
  IdentityStore? _store;

  /// 关联持久化存储
  void attachStore(IdentityStore store) {
    _store = store;
  }

  /// 持久化存储（管理页读待确认记忆用）
  IdentityStore? get identityStore => _store;

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
    await loadIdentityMoodAverages();
  }

  /// 已注册的全部身份（给管理页用）
  List<IdentityEntry> get allIdentities => _identities.values.toList();

  /// 身份对应的"示例"代号（管理页展示用）。
  /// 注意：实际聊天用会话级轮换代号（用户 18:58），同一身份在不同会话
  /// 可能是 [家人A] 也可能是 [家人B]——管理页这里只是注册时的默认展示。
  String? codeFor(String identityId) => _identityCodes[identityId];

  // ── 每身份平均情绪（平均情感基线）──

  /// 从持久化加载每身份平均情绪（APP 启动时调用）
  Future<void> loadIdentityMoodAverages() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final rawAvg = prefs.getString(_moodAvgPrefsKey);
      if (rawAvg != null) {
        final decoded = jsonDecode(rawAvg) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          final dims = (e.value as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).toDouble()));
          _identityMoodAvg[e.key] = Map<String, double>.from(dims);
        }
      }
      final rawCount = prefs.getString(_moodCountPrefsKey);
      if (rawCount != null) {
        final decoded = jsonDecode(rawCount) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          _identityMoodCount[e.key] = (e.value as num).toInt();
        }
      }
      print('[MaskEngine] 加载每身份平均情绪 ${_identityMoodAvg.length} 个');
    } catch (e) {
      print('[MaskEngine] 加载每身份平均情绪失败: $e');
    }
  }

  /// 持久化每身份平均情绪
  Future<void> _saveIdentityMoodAverages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_moodAvgPrefsKey, jsonEncode(_identityMoodAvg));
    await prefs.setString(_moodCountPrefsKey, jsonEncode(_identityMoodCount));
  }

  /// 累积某身份的平均情绪（滚动平均：新值按 1/n 权重混入）
  void _accumulateIdentityMood(String identityId, Map<String, double> mood) {
    final n = (_identityMoodCount[identityId] ?? 0) + 1;
    _identityMoodCount[identityId] = n;
    final avg = _identityMoodAvg.putIfAbsent(identityId, () => {});
    for (final e in mood.entries) {
      final cur = avg[e.key] ?? 0.0;
      avg[e.key] = cur + (e.value - cur) / n;
    }
    _saveIdentityMoodAverages();
  }

  /// 某身份的平均情感基线描述（不含真实称呼，只含代号+情绪维度）
  /// 如："[家人A]：你提到 ta 时，平均情绪：依恋 65、烦躁 20"
  /// 37批：性别已知时用"她/他"（用户 18:58：添加性别，男主可用她/他）
  String? _buildAverageMoodDescription(IdentityEntry entry, String code) {
    final avg = _identityMoodAvg[entry.id];
    if (avg == null || avg.isEmpty) return null;
    final sorted = avg.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(3).map((e) => '${e.key} ${e.value.round()}').join('、');
    return '$code：你提到${entry.pronoun}时，平均情绪：$top';
  }

  /// 该身份已确认的 #代号# 记忆描述（用户 18:58：男主写 #A# 记忆 → 用户确认 →
  /// 下次轮换后以新代号注入，记忆跟随身份不跟随代号）
  /// 如："[家人C]：这位家人的喜好：喜欢小猫；讨厌下雨"
  Future<String?> _buildIdentityMemoriesDescription(
    IdentityEntry entry,
    String code,
  ) async {
    final store = _store;
    if (store == null) return null;
    try {
      final memories = await store.confirmedMemories(entry.id);
      if (memories.isEmpty) return null;
      final contents = memories.map((m) => m.content).toList();
      return '$code：${entry.pronoun}相关的事：${contents.join('；')}';
    } catch (e) {
      print('[MaskEngine] 加载身份记忆失败: $e');
      return null;
    }
  }

  /// 提取男主回复里的 #代号# 记忆（男主写 → 存 pending → 用户确认）
  /// 格式：#家人A# 她喜欢小猫（每行一条）
  Future<void> extractIdentityMemoriesFromReply(
    String reply,
    String sessionId,
  ) async {
    final store = _store;
    if (store == null) return;
    final sessionMap = _sessionMappings[sessionId];
    if (sessionMap == null || sessionMap.isEmpty) return;

    // 反查：代号 → identityId
    final codeToIdentity = <String, String>{
      for (final e in sessionMap.entries) e.value: e.key,
    };

    final lines = reply.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      // 匹配 #家人A# 内容 或 #A# 内容（A 为代号字母）
      final m = RegExp(r'^#([^\s#]+)#\s*(.+)$').firstMatch(trimmed);
      if (m == null) continue;
      final tag = m.group(1)!.trim();
      final content = m.group(2)!.trim();
      if (content.isEmpty) continue;

      // tag 可能是完整代号 [家人A] / 家人A / 或纯字母 A
      String? identityId;
      if (codeToIdentity.containsKey('[$tag]')) {
        identityId = codeToIdentity['[$tag]'];
      } else if (codeToIdentity.containsKey(tag)) {
        identityId = codeToIdentity[tag];
      } else {
        // 纯字母：匹配该会话中以该字母结尾的代号
        final letter = tag.replaceAll(RegExp(r'[\[\]]'), '');
        for (final e in codeToIdentity.entries) {
          final codeLetter = e.key.replaceAll(RegExp(r'[\[\]\u4e00-\u9fa5]'), '');
          if (codeLetter == letter) {
            identityId = e.value;
            break;
          }
        }
      }
      if (identityId == null) continue;

      await store.addIdentityMemory(identityId: identityId, content: content);
      DebugLogger.log(
        '假面层',
        '📝 男主写了 #$tag# 记忆（身份 $identityId），已存待确认：$content',
      );
    }
  }

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

  /// 替换敏感信息（用户消息 → 发给男主的版本）
  ///
  /// 描述策略（说一次机制）：
  /// - 会话内首次提到某身份 → 附一条描述（用户描述池随机 / 规律联动 / 内置模板）
  /// - 之后只替换为纯代号（男主已记住映射，不再重复描述 → 降低泄露风险）
  /// - 例外：管家发现该身份的新情绪规律 → 重新附一条规律描述（男主知道情绪变了）
  Future<ProcessResult> replaceSensitive({
    required String text,
    required String characterId,
    required String sessionId,
  }) async {
    // 记录当前文本情绪（规律"现在"值参照）
    _latestMood = KeywordMoodAnalyzer().analyze(text).dimensions;
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

      // 累积该身份的平均情绪（平均情感基线数据源）
      _accumulateIdentityMood(entry.id, _latestMood);

      final isFirstTime = !sessionMap.containsKey(entry.id);
      String code;

      if (isFirstTime) {
        // 首次：会话级轮换分配代号（用户 18:58：代号轮换，家人A/B/C…
        // 一次唯一绑定一个代号直到下一次；男主无法把代号绑定到具体人）
        code = _pickSessionCode(entry, sessionMap);
        sessionMap[entry.id] = code;
        // 首次附：平均情感基线（出现一次即可——后续对话自带记忆/上下文）
        // + 中性情绪规律（不含真实称呼，男主不需要知道代号对应谁）
        // + 已确认的 #代号# 记忆（用户 18:58：记忆跟随身份，轮换后以新代号注入）
        // 用户 18:32：基线只出现一次；规律/记忆描述正常提到就拼接
        final moodBase = _buildAverageMoodDescription(entry, code);
        final patternDesc = _buildPatternDescription(entry, code);
        final identityMemories =
            await _buildIdentityMemoriesDescription(entry, code);
        final parts = [
          if (moodBase != null) moodBase,
          if (patternDesc != null) patternDesc,
          if (identityMemories != null) identityMemories,
        ];
        if (parts.isNotEmpty) {
          maskHints.add(parts.join('；'));
          _sessionDescribed.putIfAbsent(sessionId, () => {})[entry.id] =
              DateTime.now();
        }
      } else {
        code = sessionMap[entry.id]!;
        // 已有映射 → 默认不再附描述
        // 开关"每次都附上"（DeepSeek 无后台记忆）→ 每轮都附情绪规律参考
        // （只附中性情绪规律，不附身份描述——男主不需要知道代号对应谁）
        // 或该身份出现了新确认的规律（情绪变了）→ 附规律描述
        final patternDesc = _buildPatternDescription(entry, code);
        if (hintsEveryTurn && patternDesc != null) {
          maskHints.add('$code：$patternDesc');
        } else if (_hasNewPattern(entry, sessionId)) {
          if (patternDesc != null) {
            maskHints.add('$code：$patternDesc');
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

  /// 规律联动描述：从规律引擎找该身份相关的已确认规律，
  /// 生成中性描述（不提具体称呼，只说情绪关联），如：
  /// "曾经（[家人1]+小猫）：依恋 12% → 现在 20%"
  /// 关键词里的真实称呼一律替换成代号（用户 18:32：'代号＋小猫'，不泄露称呼）
  String? _buildPatternDescription(IdentityEntry entry, String code) {
    final engine = patternEngine;
    if (engine == null) return null;
    final matches = engine.confirmedPatterns
        .where((p) => p.keywords.contains(entry.realLabel))
        .toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final p = matches.first;

    // 曾经 vs 现在 对比格式（用户 16:13）：
    // 曾经（小猫+狗狗+…）：依恋 12%
    // 现在：依恋 20%
    // 真实称呼 → 代号（防泄露）
    final combo = p.keywords
        .map((k) => k == entry.realLabel ? code : k)
        .join('+');
    final lastHit = p;

    String? dimValue(String label, double shift, List<String> keys) {
      if (shift.abs() < 5) return null;
      // 曾经 = 最近命中时的基线快照 + 偏移（无快照 → 偏移直接当曾经值）
      double? past;
      if (lastHit != null && lastHit.lastBaseline.isNotEmpty) {
        for (final k in keys) {
          if (lastHit.lastBaseline.containsKey(k)) {
            past = (lastHit.lastBaseline[k] ?? 0) + shift;
            break;
          }
        }
      }
      past ??= shift;
      // 现在 = 当前情绪（最近一次分析值，无则省略"现在"）
      final now = _latestMood[keys.firstWhere(
        (k) => _latestMood.containsKey(k),
        orElse: () => keys.first,
      )];
      if (now == null) return '$label ${past.round()}%';
      return '$label ${past.round()}% → 现在 ${now.round()}%';
    }

    final parts = <String>[
      if (dimValue('依恋', p.shiftAttachment, const ['依恋', '渴望', '思念', '爱意']) != null)
        dimValue('依恋', p.shiftAttachment, const ['依恋', '渴望', '思念', '爱意'])!,
      if (dimValue('开心', p.shiftJoy, const ['喜悦', '幸福', '满足', '安心', '开心']) != null)
        dimValue('开心', p.shiftJoy, const ['喜悦', '幸福', '满足', '安心', '开心'])!,
      if (dimValue('烦躁', p.shiftAnger, const ['愤怒', '烦躁', '厌烦', '生气']) != null)
        dimValue('烦躁', p.shiftAnger, const ['愤怒', '烦躁', '厌烦', '生气'])!,
      if (dimValue('悲伤', p.shiftSad, const ['悲伤', '脆弱', '失望', '委屈', '难过']) != null)
        dimValue('悲伤', p.shiftSad, const ['悲伤', '脆弱', '失望', '委屈', '难过'])!,
    ];
    if (parts.isEmpty) return null;

    return '曾经（$combo）：${parts.join('；')}';
  }

  /// 最近一次情绪分析值（规律"现在"参照；无则空）
  Map<String, double> _latestMood = {};

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

  /// 固定格式敏感信息屏蔽（身份证/手机号/银行卡/邮箱…）
  ///
  /// 只要匹配固定格式 → 挖空为 [PRIVACY_MARK]（每次都执行，不走冷却）
  /// 顺序：身份证 → 手机号 → 邮箱 → 银行卡（兜底 16-19 位纯数字）
  /// 返回 (处理后的文本, 命中的格式标签列表)
  (String, List<String>) applyFormatMask(String text) {
    // 统一走敏感信息模块（规则见 sensitive_info_detector.dart）
    return SensitiveInfoDetector.mask(text);
  }

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
