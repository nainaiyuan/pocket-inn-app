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

  List<RiskWord>? _words;
  List<String>? _exceptions;
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
    _loaded = true;
    return _words!;
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

  /// 强制重载（页面修改后同步）
  Future<void> reload() async {
    _loaded = false;
    _words = null;
    _exceptions = null;
    await loadWords();
    await loadExceptions();
  }
}
