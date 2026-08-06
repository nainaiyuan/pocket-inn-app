import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 📥 待回复队列（8-06 21:36 用户：不要系统自动算，男主自己带编号管理——
/// "回复待#几和几，然后就消除掉那个"）
///
/// - 用户消息 feed 时入队（自动，管家只做机械活）
/// - 男主回复时标注"（回待#1、待#2）"→ resolve() 按编号消除
/// - 男主决定不回的标"（不回待#3）"→ 也消除（放下）
/// - 消除的条目 + 男主的话 → 在上下文原文里自然配对（raw 自动记了双方）
/// - 兜底：男主没标编号 → 只消最老一条（默认他回最老的）；队列空则不动
class PendingQueueStore {
  PendingQueueStore._();

  static const _maxEntries = 30;

  static String _key(String personaId) => 'pending_queue_$personaId';

  static final Map<String, List<Map<String, dynamic>>> _memCache = {};

  static List<Map<String, dynamic>> _parse(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(String personaId, List<Map<String, dynamic>> es) async {
    _memCache[personaId] = es;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(personaId), jsonEncode(es));
  }

  /// 用户消息入队（自动，管家机械活）
  static Future<void> enqueue(String personaId, String text) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    final now = DateTime.now();
    final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final es = [...(_memCache[personaId] ?? [])];
    es.add({
      'id': es.length + 1, // 重新编号（消除后压缩）
      'ts': hhmm,
      'text': text.length > 120 ? '${text.substring(0, 120)}…' : text,
    });
    if (es.length > _maxEntries) {
      es.removeRange(0, es.length - _maxEntries);
    }
    // 压缩编号（消除后可能空洞）
    for (var i = 0; i < es.length; i++) {
      es[i]['id'] = i + 1;
    }
    await _save(personaId, es);
  }

  /// 待回复文本（注入用）：'待#1 [21:15] 内容'；空返回 null
  static String? pendingText(String personaId) {
    final es = _memCache[personaId];
    if (es == null || es.isEmpty) return null;
    return es.map((e) => '待#${e['id']} [${e['ts']}] ${e['text']}').join('\n');
  }

  /// 男主回复后按标注消除。规则：
  /// - "回待#1、待#2" / "回复待#1" → 消除对应编号
  /// - "不回待#3" → 消除对应编号（放下）
  /// - 没有任何编号标注 → 队列只有 1 条则消除它；多条则消最老一条（兜底）
  /// 返回消除的编号列表
  static Future<List<int>> resolve(String personaId, String reply) async {
    final es = [...(_memCache[personaId] ?? [])];
    if (es.isEmpty) return const [];
    final removed = <int>[];
    // 找所有 待#N 标注（回/不回都算消除）
    final ids = <int>{};
    final re = RegExp(r'(?:回|回复|不回|放下)?\s*待#(\d+)');
    for (final m in re.allMatches(reply)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1) ids.add(n);
    }
    if (ids.isNotEmpty) {
      for (final e in es) {
        if (ids.contains(e['id'])) removed.add(e['id'] as int);
      }
    } else {
      // 兜底：没标注 → 消最老一条（男主默认回最老的）
      removed.add(es.first['id'] as int);
    }
    if (removed.isEmpty) return const [];
    final remaining =
        es.where((e) => !removed.contains(e['id'])).toList();
    for (var i = 0; i < remaining.length; i++) {
      remaining[i]['id'] = i + 1;
    }
    await _save(personaId, remaining);
    return removed;
  }

  /// 预热缓存
  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    _memCache[personaId] = _parse(p.getString(_key(personaId)));
  }
}
