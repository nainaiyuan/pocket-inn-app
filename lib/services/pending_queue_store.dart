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
      'status': 'pending', // pending=待回 | skipped=男主选择没回（放下）
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
    final pend = es.where((e) => e['status'] != 'skipped').toList();
    if (pend.isEmpty) return null;
    return pend
        .map((e) => '待#${e['id']} [${e['ts']}] ${e['text']}')
        .join('\n');
  }

  /// 已放下文本（注入用）：'待#3（你选择没回）[21:15] 内容'；空返回 null
  static String? skippedText(String personaId) {
    final es = _memCache[personaId];
    if (es == null || es.isEmpty) return null;
    final skip = es.where((e) => e['status'] == 'skipped').take(3).toList();
    if (skip.isEmpty) return null;
    return skip
        .map((e) => '待#${e['id']}（你选择没回）[${e['ts']}] ${e['text']}')
        .join('\n');
  }

  /// 按编号移除（男主 resolve_pending 工具：replied_ids → 真回了，消除）
  static Future<void> removeByIds(String personaId, List<int> ids) async {
    final es = [...(_memCache[personaId] ?? [])];
    if (es.isEmpty || ids.isEmpty) return;
    final remaining = es.where((e) => !ids.contains(e['id'])).toList();
    for (var i = 0; i < remaining.length; i++) {
      remaining[i]['id'] = i + 1;
    }
    await _save(personaId, remaining);
  }

  /// 标记放下（男主"不回待#N"→ 标 skipped，不消除——8-06 21:41 用户：
  /// 消除=处理完了，但放下≠回了；她问"为什么不回我"男主要能诚实回答）
  static Future<void> skip(String personaId, List<int> ids) async {
    final es = [...(_memCache[personaId] ?? [])];
    if (es.isEmpty) return;
    var changed = false;
    for (final e in es) {
      if (ids.contains(e['id']) && e['status'] != 'skipped') {
        e['status'] = 'skipped';
        changed = true;
      }
    }
    if (changed) await _save(personaId, es);
  }

  /// 男主回复后按标注处理（8-06 21:41 用户修正：不回的不消除）：
  /// - "回待#1、待#2" / "回复待#1" → 消除对应编号（真回了）
  /// - "不回待#3" / "放下待#3" → 标 skipped（选择没回，保留痕迹）
  /// - 没有任何编号标注 → 兜底：消最老一条（男主默认回最老的）
  /// 返回 (消除的编号, 放下的编号)
  static Future<(List<int>, List<int>)> resolve(
      String personaId, String reply) async {
    final es = [...(_memCache[personaId] ?? [])];
    if (es.isEmpty) return (const <int>[], const <int>[]);
    final removed = <int>[];
    final skipped = <int>[];
    final repliedIds = <int>{};
    final skipIds = <int>{};
    // "回待#N" / "回复待#N" → 回；"不回待#N" / "放下待#N" → 放下
    for (final m in RegExp(r'回(?:复)?\s*待#(\d+)').allMatches(reply)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1) repliedIds.add(n);
    }
    for (final m in RegExp(r'(?:不回|放下|不用回)\s*待#(\d+)')
        .allMatches(reply)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1) skipIds.add(n);
    }
    if (repliedIds.isEmpty && skipIds.isEmpty) {
      // 兜底：没标注 → 消最老一条（男主默认回最老的）
      removed.add(es.first['id'] as int);
    } else {
      for (final e in es) {
        if (repliedIds.contains(e['id'])) removed.add(e['id'] as int);
        if (skipIds.contains(e['id'])) skipped.add(e['id'] as int);
      }
    }
    final remaining = es
        .where((e) => !removed.contains(e['id']))
        .toList();
    for (final e in remaining) {
      if (skipped.contains(e['id'])) e['status'] = 'skipped';
    }
    for (var i = 0; i < remaining.length; i++) {
      remaining[i]['id'] = i + 1;
    }
    await _save(personaId, remaining);
    return (removed, skipped);
  }

  /// 预热缓存
  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    _memCache[personaId] = _parse(p.getString(_key(personaId)));
  }
}
