import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 🧠 工具结果记忆（8-06 21:00 用户：管家只记"成功/失败"不记内容，
/// 男主查了也白查 → 记结果的实际内容，男主看记忆=直接看到上次查到的东西）
///
/// 每次工具调用存一条 {time, tool, result}，滚动保留最近 20 条。
/// prompt 注入最近 5 条（每条截断 ~100 字），token 恒定不随工具数量涨。
class ToolResultStore {
  ToolResultStore._();

  static const _maxEntries = 20;

  static String _key(String personaId) => 'tool_results_$personaId';

  /// 内存缓存（prompt 注入是同步读，靠 warm()/add() 维护）
  static final Map<String, List<Map<String, dynamic>>> _memCache = {};

  static List<Map<String, dynamic>> _parse(String? raw) {
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// 记录一次工具结果（result 是内容摘要，不是"成功/失败"）
  static Future<void> add(String personaId, String tool, String result) async {
    if (personaId.isEmpty) return;
    final now = DateTime.now();
    final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final entry = {
      'time': hhmm,
      'tool': tool,
      'result': result.length > 100 ? '${result.substring(0, 100)}…' : result,
    };
    final entries = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    entries.insert(0, entry);
    if (entries.length > _maxEntries) {
      entries.removeRange(_maxEntries, entries.length);
    }
    _memCache[personaId] = entries;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(personaId), jsonEncode(entries));
  }

  /// 最近 n 条（同步读，prompt 注入用；没 warm 过返回空）
  static List<Map<String, dynamic>> recent(String personaId, {int n = 5}) {
    if (personaId.isEmpty) return const [];
    final cached = _memCache[personaId];
    if (cached == null) return const [];
    return cached.take(n).toList();
  }

  /// 预热缓存（进入聊天页时调一次）
  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    _memCache[personaId] = _parse(p.getString(_key(personaId)));
  }
}
