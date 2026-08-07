import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// ToolCacheStore —— 男主工具工作缓存（8-08 02:1x 用户定稿）
///
/// 用户："他记忆就是一点不记，要么留个位置给他工具使用的缓存，
/// 太多了就让他写进他的管记忆的地方让他整理。"
///
/// 男主干活时把工具查到的中间数据放这里（工作记忆，短命），
/// 干完活把要长期用的整理进记录（record_memory）或便签（manage_pad），
/// 然后 clear 清空。避免"查完就丢、每次醒来重新查"。
///
/// 男主自管（免审批），管家只做存储，不做任何判断。
/// 上限：10 条 / 注入时截断 800 字并提示整理。
class ToolCacheStore {
  /// 8-07 21:48 用户：日志增强（男主 query_logs 自查）。纯 Dart 库不直接
  /// 依赖 DebugLogger（Flutter），用可注入钩子。
  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) => logSink?.call(tag, msg);

  ToolCacheStore._();

  static const String _prefix = 'tool_cache_';
  static const int maxEntries = 10;

  static List<String>? _memCache;

  static String _key(String personaId) => '$_prefix$personaId';

  /// 单例缓存读（warm 后同步读，避免每轮 await）
  static void warm(String personaId) {
    if (personaId.isEmpty) return;
    _load(personaId);
  }

  static Future<void> _load(String personaId) async {
    if (personaId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(personaId));
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        _memCache = decoded is List
            ? decoded.map((e) => e.toString()).toList()
            : <String>[];
      } else {
        _memCache = <String>[];
      }
    } catch (e) {
      _memCache = <String>[];
    }
  }

  static Future<List<String>> _read(String personaId) async {
    if (personaId.isEmpty) return <String>[];
    await _load(personaId);
    return _memCache ?? <String>[];
  }

  static Future<void> _write(String personaId, List<String> entries) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    if (entries.isEmpty) {
      await p.remove(_key(personaId));
      _memCache = <String>[];
    } else {
      await p.setString(_key(personaId), jsonEncode(entries));
      _memCache = entries;
    }
  }

  /// 追加一条缓存（自动截断到 maxEntries，丢最旧的）
  static Future<String> add(String personaId, String content) async {
    final entries = await _read(personaId);
    final text = content.trim();
    if (text.isEmpty) return '缓存内容为空，没记';
    entries.add(text);
    if (entries.length > maxEntries) {
      final dropped = entries.length - maxEntries;
      entries.removeRange(0, dropped);
      _log('工具缓存', '🧹 缓存超 $maxEntries 条，丢了最旧 $dropped 条');
    }
    await _write(personaId, entries);
    _log('工具缓存', '📥 缓存 +1（现有 ${entries.length} 条）');
    return '已记入工具缓存（现有 ${entries.length} 条）';
  }

  /// 清空缓存
  static Future<String> clear(String personaId) async {
    final n = (await _read(personaId)).length;
    await _write(personaId, <String>[]);
    _log('工具缓存', '🗑️ 缓存清空（$n 条）');
    return n > 0 ? '工具缓存已清空（$n 条）' : '工具缓存本来就是空的';
  }

  /// 注入文本（男主上下文用）：带预算截断 + 超限提示整理
  static String text(String personaId) {
    final entries = _memCache ?? <String>[];
    if (entries.isEmpty) return '';
    final sb = StringBuffer();
    var budget = 800;
    for (var i = 0; i < entries.length; i++) {
      final line = '· ${entries[i]}';
      if (line.length > budget) {
        sb.writeln('· ${line.substring(0, budget)}…（截断）');
        budget = 0;
        break;
      }
      sb.writeln(line);
      budget -= line.length;
    }
    final overflow = entries.length > maxEntries ? '（超出上限，整理后清空）' : '';
    return '${sb.toString().trim()}\n'
        '——工具缓存 ${entries.length} 条$overflow：干完活把要长期用的整理进'
        '记录（record_memory）或便签（manage_pad），然后 clear 清空';
  }

  /// 当前条数（工具 status 用）
  static Future<int> count(String personaId) async =>
      (await _read(personaId)).length;
}
