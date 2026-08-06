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
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
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
    final es = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
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

  /// 全部待回复列表（8-06 23:55 停止按钮用：取收集的用户消息）
  static List<Map<String, dynamic>> list(String personaId) =>
      List<Map<String, dynamic>>.from(
          _memCache[personaId] ?? const <Map<String, dynamic>>[]);

  /// 待回复文本（注入用）：'待#1 [21:15] 内容'；空返回 null
  static String? pendingText(String personaId) {
    final es = _memCache[personaId];
    if (es == null || es.isEmpty) return null;
    return es
        .map((e) => '待#${e['id']} [${e['ts']}] ${e['text']}')
        .join('\n');
  }

  /// 按编号移除（男主 resolve_pending 工具 / 回复标注"回待#N" → 真回了，消除）
  static Future<void> removeByIds(String personaId, List<int> ids) async {
    final es = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    if (es.isEmpty || ids.isEmpty) return;
    final remaining = es.where((e) => !ids.contains(e['id'])).toList();
    for (var i = 0; i < remaining.length; i++) {
      remaining[i]['id'] = i + 1;
    }
    await _save(personaId, remaining);
  }

  /// 男主回复后按标注消除（8-06 21:43 用户定稿：**没有"不回"选项**——
  /// 没回的就留在待回复区挂着，男主赖不掉；给了"放下"他会当耳旁风
  /// 把不想回的全标上）：
  /// - "回待#1、待#2" / "回复待#1" → 消除对应编号（真回了）
  /// - 没有任何编号标注且队列只有 1 条 → 消除它（唯一候选，不算猜）
  /// - 没有任何编号标注且队列多条 → **不动**（系统不猜，没标=没回）
  /// 返回消除的编号列表
  static Future<List<int>> resolve(String personaId, String reply) async {
    final es = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    if (es.isEmpty) return const <int>[];
    final removed = <int>[];
    final repliedIds = <int>{};
    // "回待#N" / "回复待#N" → 回
    for (final m in RegExp(r'回(?:复)?\s*待#(\d+)').allMatches(reply)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1) repliedIds.add(n);
    }
    if (repliedIds.isNotEmpty) {
      for (final e in es) {
        if (repliedIds.contains(e['id'])) removed.add(e['id'] as int);
      }
    } else if (es.length == 1) {
      // 队列只有一条，男主回了话 → 必然是回它（唯一候选）
      removed.add(es.first['id'] as int);
    }
    // 多条且没标注 → 不动（没标=没回，挂着）
    if (removed.isEmpty) return const <int>[];
    final remaining = es.where((e) => !removed.contains(e['id'])).toList();
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
