/// 敏感词配置存储（SharedPreferences）
///
/// 用户可编辑的敏感词表 + 白名单：
/// - 首次启动：把默认表写入存储（之后以用户配置为准，删了真删）
/// - 用户增删改 → 写回存储
/// - 内存缓存：加载一次后复用，避免每次判定都读磁盘
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'risk_filter_wordlist.dart';

class RiskWordStore {
  RiskWordStore._();
  static final RiskWordStore instance = RiskWordStore._();

  static const _wordsKey = 'risk_words_v2';
  static const _exceptionsKey = 'risk_exceptions_v2';
  static const _userPrefsKey = 'risk_user_prefs';
  static const _tempAllowsKey = 'risk_temp_allows';

  /// 用户偏好：词 → 'block'（用户明确说过要屏蔽 → 以后直接屏蔽不再问）
  static const String prefBlock = 'block';

  /// 临时豁免时长（用户选"这次不屏蔽" → 该词 N 分钟内不屏蔽）
  static const Duration tempAllowDuration = Duration(minutes: 30);

  List<RiskWord>? _words;
  List<String>? _exceptions;
  Map<String, String>? _userPrefs;
  Map<String, DateTime>? _tempAllows;
  bool _loaded = false;

  /// 加载词表（首次写入默认表；之后返回用户配置）
  Future<List<RiskWord>> loadWords() async {
    if (_loaded && _words != null) return _words!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_wordsKey);
    if (raw == null) {
      // 首次：写入默认表
      final defaultJson = defaultRiskWordlist
          .map((w) => jsonEncode(w.toJson()))
          .toList();
      await prefs.setStringList(_wordsKey, defaultJson);
      _words = List.of(defaultRiskWordlist);
    } else {
      _words = raw
          .map((s) {
            try {
              return RiskWord.fromJson(
                jsonDecode(s) as Map<String, dynamic>,
              );
            } catch (_) {
              return null;
            }
          })
          .whereType<RiskWord>()
          .where((w) => w.word.isNotEmpty)
          .toList();
    }
    await _loadPrefs();
    _loaded = true;
    return _words!;
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _userPrefs = {};
    for (final e in (prefs.getStringList(_userPrefsKey) ?? [])) {
      final i = e.indexOf(':');
      if (i > 0) _userPrefs![e.substring(0, i)] = e.substring(i + 1);
    }
    _tempAllows = {};
    final now = DateTime.now();
    for (final e in (prefs.getStringList(_tempAllowsKey) ?? [])) {
      final i = e.lastIndexOf(':');
      if (i <= 0) continue;
      final until = DateTime.tryParse(e.substring(i + 1));
      if (until != null && until.isAfter(now)) {
        _tempAllows![e.substring(0, i)] = until;
      }
    }
  }

  /// 加载白名单（默认 + 用户追加）
  Future<List<String>> loadExceptions() async {
    if (_loaded && _exceptions != null) return _exceptions!;
    final prefs = await SharedPreferences.getInstance();
    final user = prefs.getStringList(_exceptionsKey) ?? [];
    _exceptions = [...defaultExceptions, ...user];
    return _exceptions!;
  }

  /// 保存词表（增删改后调用）
  Future<void> saveWords(List<RiskWord> words) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _wordsKey,
      words.map((w) => jsonEncode(w.toJson())).toList(),
    );
    _words = List.of(words);
  }

  /// 追加白名单词组
  Future<void> addException(String phrase) async {
    final p = phrase.trim();
    if (p.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final user = prefs.getStringList(_exceptionsKey) ?? [];
    if (user.contains(p) || defaultExceptions.contains(p)) return;
    await prefs.setStringList(_exceptionsKey, [...user, p]);
    _exceptions = [...defaultExceptions, ...user, p];
  }

  /// 移除白名单词组
  Future<void> removeException(String phrase) async {
    if (defaultExceptions.contains(phrase)) return; // 默认白名单不可删
    final prefs = await SharedPreferences.getInstance();
    final user = prefs.getStringList(_exceptionsKey) ?? [];
    user.remove(phrase);
    await prefs.setStringList(_exceptionsKey, user);
    _exceptions = [...defaultExceptions, ...user];
  }

  /// 同步缓存（未加载时用默认表——供同步调用方如 buildMoodContext 使用）
  List<RiskWord> get cachedWords => _words ?? List.of(defaultRiskWordlist);

  List<String> get cachedExceptions => _exceptions ?? List.of(defaultExceptions);

  /// 用户偏好缓存（词 → 'block'；未加载时空）
  Map<String, String> get cachedUserPrefs => _userPrefs ?? const {};

  /// 临时豁免缓存（词 → 豁免截止时间；未加载时空）
  Map<String, DateTime> get cachedTempAllows => _tempAllows ?? const {};

  /// 用户明确说"屏蔽" → 记住偏好，以后该词直接屏蔽（不再问）
  Future<void> setUserPref(String word, String pref) async {
    _userPrefs ??= {};
    _userPrefs![word] = pref;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _userPrefsKey,
      _userPrefs!.entries.map((e) => '${e.key}:${e.value}').toList(),
    );
  }

  /// 用户选"这次不屏蔽" → 临时豁免（30 分钟内不再屏蔽该词）
  Future<void> tempAllow(String word) async {
    _tempAllows ??= {};
    _tempAllows![word] = DateTime.now().add(tempAllowDuration);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _tempAllowsKey,
      _tempAllows!.entries
          .map((e) => '${e.key}:${e.value.toIso8601String()}')
          .toList(),
    );
  }

  /// 清除已过期的临时豁免（返回是否清过）
  bool pruneTempAllows() {
    if (_tempAllows == null) return false;
    final now = DateTime.now();
    final before = _tempAllows!.length;
    _tempAllows!.removeWhere((_, until) => !until.isAfter(now));
    return _tempAllows!.length != before;
  }

  /// 强制重载（页面修改后同步）
  Future<void> reload() async {
    _loaded = false;
    _words = null;
    _exceptions = null;
    await loadWords();
    await loadExceptions();
  }
}
