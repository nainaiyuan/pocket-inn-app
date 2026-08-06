import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// ⏰ 定时任务计划（8-06 21:26 用户：定时跟当前任务模块（便签）分开——
/// 便签=正在干的活，定时=计划，到点触发）
///
/// 男主设的"几点提醒/几点唤醒"都记这里（持久化，重启不丢），
/// 每轮 prompt 注入【定时任务】区，男主知道有什么计划在等触发。
/// 触发完（管家执行唤醒/提醒后）自动移除或标记已触发。
///
/// 条目：{time: '21:30', desc: '唤醒男主（她 20 分钟没回来）', status: 'waiting|done'}
class TimerPlanStore {
  TimerPlanStore._();

  static const _maxEntries = 20;

  static String _key(String personaId) => 'timer_plans_$personaId';

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

  /// 新增一个计划（自动带当前时间 HH:MM）
  static Future<void> add(String personaId, String desc) async {
    if (personaId.isEmpty) return;
    final now = DateTime.now();
    final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final entries = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    entries.insert(0, {
      'time': hhmm,
      'desc': desc.length > 80 ? '${desc.substring(0, 80)}…' : desc,
      'status': 'waiting',
    });
    if (entries.length > _maxEntries) {
      entries.removeRange(_maxEntries, entries.length);
    }
    _memCache[personaId] = entries;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(personaId), jsonEncode(entries));
  }

  /// 等待中的计划文本（注入用）：'⏰ 21:30 唤醒男主（…）'；无返回 null
  static String? waitingText(String personaId) {
    final entries = _memCache[personaId];
    if (entries == null || entries.isEmpty) return null;
    final waiting = entries
        .where((e) => e['status'] == 'waiting')
        .take(5)
        .toList();
    if (waiting.isEmpty) return null;
    return waiting
        .map((e) => '⏰ ${e['time']} ${e['desc']}')
        .join('\n');
  }

  /// 标记某条已触发（按 desc 匹配第一条 waiting）；没有匹配就静默
  static Future<void> markDone(String personaId, String desc) async {
    final entries = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    for (var i = 0; i < entries.length; i++) {
      final d = entries[i]['desc']?.toString() ?? '';
      if (entries[i]['status'] == 'waiting' && d.contains(desc)) {
        entries[i]['status'] = 'done';
        _memCache[personaId] = entries;
        final p = await SharedPreferences.getInstance();
        await p.setString(_key(personaId), jsonEncode(entries));
        return;
      }
    }
  }

  /// 预热缓存（发消息起点调）
  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    _memCache[personaId] = _parse(p.getString(_key(personaId)));
  }
}
