import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 📥 待回复队列（8-06 21:36 用户：不要系统自动算，男主自己带编号管理——
/// "回复待#几和几，然后就消除掉那个"）
///
/// - 用户消息 feed 时入队（自动，管家只做机械活）
/// - 8-07 19:5x 用户：双类型队列——
///   - type='user'：主对话她说的（id=数字 #1 #2…，显示在【待回复】<user> 块）
///   - type='butler'：管家/系统提醒（id=字母 #A #B…，显示在【系统消息】<sys> 块）
/// - 男主回复时标注 <reply>回#1、#A</reply> → resolve() 按编号消除（数字/字母都认）
/// - 男主决定不回的标"（不回待#3）"→ 也消除（放下）
/// - 消除的条目 + 男主的话 → 在上下文原文里自然配对（raw 自动记了双方）
/// - 兜底：男主没标编号 → 只消最老一条（默认他回最老的）；队列空则不动
class PendingQueueStore {
  /// 8-07 21:48 用户：日志增强（男主 query_logs 自查待回复问题）。
  /// 纯 Dart 库用可注入钩子，Flutter 侧注入 DebugLogger。
  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) => logSink?.call(tag, msg);

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

  /// 消息入队（自动，管家机械活）
  /// [type] = 'user'（主对话她说的，数字编号 #1 #2…）| 'butler'（管家提醒，字母编号 #A #B…）
  static Future<void> enqueue(String personaId, String text,
      {String type = 'user'}) async {
    if (personaId.isEmpty || text.trim().isEmpty) return;
    final now = DateTime.now();
    final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final es = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    final isButler = type == 'butler';
    // 编号：user=数字（1,2,3…），butler=字母（A,B,C…），各自独立连续
    final id = isButler ? _nextButlerId(es) : _nextUserId(es);
    es.add({
      'id': id,
      'ts': hhmm,
      'text': text.length > 120 ? '${text.substring(0, 120)}…' : text,
      'type': type,
    });
    _log('待回复',
        '📥 入队 #$id [${isButler ? '系统' : '她'}] $hhmm：${text.length > 60 ? text.substring(0, 60) + '…' : text}');
    if (es.length > _maxEntries) {
      es.removeRange(0, es.length - _maxEntries);
    }
    // 压缩编号（消除后可能空洞）
    _renumber(es);
    await _save(personaId, es);
  }

  static int _nextUserId(List<Map<String, dynamic>> es) {
    var max = 0;
    for (final e in es) {
      final v = e['id'];
      if (v is int && v > max) max = v;
    }
    return max + 1;
  }

  static String _nextButlerId(List<Map<String, dynamic>> es) {
    var max = 0;
    for (final e in es) {
      final v = e['id'];
      if (v is String && v.length == 1 && v.toUpperCase().codeUnitAt(0) >= 65) {
        final n = v.toUpperCase().codeUnitAt(0) - 64;
        if (n > max) max = n;
      }
    }
    return String.fromCharCode(64 + max + 1);
  }

  /// 压缩编号：user 条目按顺序 1,2,3…，butler 条目按顺序 A,B,C…
  static void _renumber(List<Map<String, dynamic>> es) {
    var u = 0;
    var b = 0;
    for (final e in es) {
      if (e['type'] == 'butler') {
        b++;
        e['id'] = String.fromCharCode(64 + b);
      } else {
        u++;
        e['id'] = u;
      }
    }
  }

  /// 全部待回复列表（8-06 23:55 停止按钮用：取收集的用户消息）
  static List<Map<String, dynamic>> list(String personaId) =>
      List<Map<String, dynamic>>.from(
          _memCache[personaId] ?? const <Map<String, dynamic>>[]);

  /// 用户待回复文本（注入【待回复】<user> 块用）：'<user>#1 [21:15] 她：内容</user>'；空返回 null
  static String? pendingUserText(String personaId) {
    final es = _memCache[personaId];
    if (es == null || es.isEmpty) return null;
    final lines = es
        .where((e) => e['type'] != 'butler')
        .map((e) => '<user>#${e['id']} [${e['ts']}] 她：${e['text']}</user>')
        .toList();
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// 管家/系统提醒文本（注入【系统消息】<sys> 块用）：'<sys>#A [21:16] 提醒：内容</sys>'；空返回 null
  static String? pendingButlerText(String personaId) {
    final es = _memCache[personaId];
    if (es == null || es.isEmpty) return null;
    final lines = es
        .where((e) => e['type'] == 'butler')
        .map((e) => '<sys>#${e['id']} [${e['ts']}] 提醒：${e['text']}</sys>')
        .toList();
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// 待回复文本（旧接口兼容，注入用）：'待#1 [21:15] 内容'；空返回 null
  static String? pendingText(String personaId) {
    final es = _memCache[personaId];
    if (es == null || es.isEmpty) return null;
    return es
        .map((e) => '待#${e['id']} [${e['ts']}] ${e['text']}')
        .join('\n');
  }

  /// 按编号移除（男主 resolve_pending 工具 / 回复标注"回待#N" → 真回了，消除）
  static Future<void> removeByIds(String personaId, List<String> ids) async {
    final es = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    if (es.isEmpty || ids.isEmpty) return;
    final remaining = es.where((e) => !ids.contains(e['id'].toString())).toList();
    _renumber(remaining);
    _log('待回复', '🗑 消队 ${ids.join('、')}（剩 ${remaining.length} 条）');
    await _save(personaId, remaining);
  }

  /// 男主回复后按标注消除（8-06 21:43 用户定稿：**没有"不回"选项**——
  /// 没回的就留在待回复区挂着，男主赖不掉；给了"放下"他会当耳旁风
  /// 把不想回的全标上）：
  /// - "<reply>回#1、#A</reply>"（8-07 19:15 新格式，数字/字母都认）
  /// - "回待#1" / "回复待#1"（旧格式兼容）
  /// - 没有任何编号标注且队列只有 1 条 → 消除它（唯一候选，不算猜）
  /// - 没有任何编号标注且队列多条 → **不动**（系统不猜，没标=没回）
  /// 返回消除的编号列表
  static Future<List<String>> resolve(String personaId, String reply) async {
    final es = List<Map<String, dynamic>>.from(_memCache[personaId] ?? const <Map<String, dynamic>>[]);
    if (es.isEmpty) return const <String>[];
    final removed = <String>[];
    final repliedIds = <String>{};
    // 8-07 19:15 新格式：<reply>回#1、#A</reply>（男主回复标注，必带）
    for (final m
        in RegExp(r'<reply>([\s\S]*?)</reply>', caseSensitive: false)
            .allMatches(reply)) {
      for (final n in RegExp(r'#(\d+|[A-Za-z])').allMatches(m.group(1) ?? '')) {
        final v = n.group(1)!;
        repliedIds.add(v.toUpperCase());
      }
    }
    // 旧格式兼容："回待#N" / "回复待#N" → 回
    for (final m in RegExp(r'回(?:复)?\s*待#(\d+|[A-Za-z])').allMatches(reply)) {
      repliedIds.add(m.group(1)!.toUpperCase());
    }
    if (repliedIds.isNotEmpty) {
      for (final e in es) {
        if (repliedIds.contains(e['id'].toString().toUpperCase())) {
          removed.add(e['id'].toString());
        }
      }
    } else if (es.length == 1) {
      // 队列只有一条，男主回了话 → 必然是回它（唯一候选）
      removed.add(es.first['id'].toString());
    }
    // 多条且没标注 → 不动（没标=没回，挂着）
    if (removed.isEmpty) return const <String>[];
    final remaining = es.where((e) => !removed.contains(e['id'].toString())).toList();
    _renumber(remaining);
    await _save(personaId, remaining);
    _log('待回复', '✔ resolve 消除 ${removed.join('、')}');
    return removed;
  }

  /// 预热缓存
  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    _memCache[personaId] = _parse(p.getString(_key(personaId)));
  }
}
