import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// ToolManualStore —— 工具使用手册（8-08 15:2x，设计文档四，GPT 10 问 2）
///
/// 分工（重要，防混用）：
/// - ToolManualStore = 工具**怎么用**（格式/示例/坑）→ 解决"不会用"
/// - FlowStore = 当前**为什么用工具、做到哪一步**（目标/步骤/进度/完成条件）
/// - ToolCacheStore = 工具**查到什么**（短期工作缓存）
/// ❌ 不能用工具手册替代任务状态：男主查了手册 ≠ 任务推进了，进度只看 FlowStore。
///
/// 男主自管（manage_tool_manual，免审批），管家只做存储。
/// 预算策略（GPT 13:20 定案：按上下文预算不按数量）：
/// - 注入时带预算截断（默认 600 字），超了提示按需 get
/// - 男主第一次不知道 → 查手册秒懂 → 用完顺手记 → 下次不再重学
class ToolManualStore {
  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) => logSink?.call(tag, msg);

  ToolManualStore._();

  static const String _prefix = 'tool_manual_';

  static Map<String, dynamic>? _memCache;

  static String _key(String personaId) => '$_prefix$personaId';

  /// 单例缓存读（warm 后同步读）
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
        _memCache = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
      } else {
        _memCache = <String, dynamic>{};
      }
    } catch (e) {
      _memCache = <String, dynamic>{};
    }
  }

  static Future<Map<String, dynamic>> _read(String personaId) async {
    if (personaId.isEmpty) return <String, dynamic>{};
    await _load(personaId);
    return _memCache ?? <String, dynamic>{};
  }

  static Future<void> _write(
      String personaId, Map<String, dynamic> entries) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    if (entries.isEmpty) {
      await p.remove(_key(personaId));
      _memCache = <String, dynamic>{};
    } else {
      await p.setString(_key(personaId), jsonEncode(entries));
      _memCache = entries;
    }
  }

  /// 记一条手册（add/update 同路径：有则覆盖，无则新增）
  /// [toolName] 工具英文名；[usage] 用途；[format] 格式；[example] 示例；
  /// [note] 注意/坑
  static Future<String> save(String personaId, String toolName,
      {String? usage, String? format, String? example, String? note}) async {
    if (personaId.isEmpty || toolName.trim().isEmpty) return 'tool 不能为空';
    final entries = await _read(personaId);
    final name = toolName.trim();
    final prev = (entries[name] as Map?) ?? <String, dynamic>{};
    final entry = Map<String, dynamic>.from(prev);
    if (usage != null && usage.trim().isNotEmpty) entry['用途'] = usage.trim();
    if (format != null && format.trim().isNotEmpty) entry['格式'] = format.trim();
    if (example != null && example.trim().isNotEmpty) entry['示例'] = example.trim();
    if (note != null && note.trim().isNotEmpty) entry['注意'] = note.trim();
    entry['updatedAt'] = DateTime.now().toIso8601String();
    entries[name] = entry;
    await _write(personaId, entries);
    _log('工具手册', '📖 手册 $name 已记录（共 ${entries.length} 条）');
    return '工具手册已记录 $name（共 ${entries.length} 条）。下次直接查手册，不用重新试格式。';
  }

  /// 查单条（完整条目，按需读取）
  static Future<String> get(String personaId, String toolName) async {
    final entries = await _read(personaId);
    final entry = entries[toolName.trim()];
    if (entry == null || entry is! Map) {
      return '手册里没有 $toolName 的记录。可 manage_tool_manual add 记一条'
          '（工具名用英文）。';
    }
    final sb = StringBuffer('📖 $toolName：');
    final keys = ['用途', '格式', '示例', '注意'];
    for (final k in keys) {
      final v = entry[k]?.toString().trim() ?? '';
      if (v.isNotEmpty) sb.writeln('$k：$v');
    }
    return sb.toString().trim();
  }

  /// 列表（名称 + 用途，注入用）
  static Future<String> list(String personaId) async {
    final entries = await _read(personaId);
    if (entries.isEmpty) return '工具手册还是空的（男主用 manage_tool_manual add 记录格式/坑）';
    final sb = StringBuffer('📖 工具手册 ${entries.length} 条：');
    entries.forEach((name, v) {
      final usage = v is Map ? (v['用途']?.toString() ?? '') : '';
      sb.writeln('· $name${usage.isNotEmpty ? '：$usage' : ''}');
    });
    return sb.toString().trim();
  }

  /// 删除一条
  static Future<String> remove(String personaId, String toolName) async {
    final entries = await _read(personaId);
    final name = toolName.trim();
    if (!entries.containsKey(name)) return '手册里没有 $name';
    entries.remove(name);
    await _write(personaId, entries);
    _log('工具手册', '🗑️ 手册 $name 已删除（剩 ${entries.length} 条）');
    return '手册条目 $name 已删除';
  }

  /// 注入文本（上下文预算：默认 600 字，超了截断提示按需 get）
  /// [relatedTools] 当前任务相关工具名（优先注入这些的精简条目）
  static String text(String personaId, {List<String>? relatedTools}) {
    final entries = _memCache ?? <String, dynamic>{};
    if (entries.isEmpty) return '';
    final sb = StringBuffer();
    var budget = 600;
    final names = <String>[];
    // 先注入相关工具
    if (relatedTools != null) {
      for (final t in relatedTools) {
        final e = entries[t];
        if (e is Map && !names.contains(t)) {
          names.add(t);
          final format = (e['格式'] ?? '').toString().trim();
          final note = (e['注意'] ?? '').toString().trim();
          final line = '$t 格式：${format.isNotEmpty ? format : '（未记格式）'}'
              '${note.isNotEmpty ? '；注意：$note' : ''}';
          if (line.length <= budget) {
            sb.writeln(line);
            budget -= line.length;
          }
        }
      }
    }
    // 剩余预算给其他条目（一行摘要）
    for (final e in entries.entries) {
      if (names.contains(e.key)) continue;
      final v = e.value;
      if (v is! Map) continue;
      final format = (v['格式'] ?? '').toString().trim();
      if (format.isEmpty) continue;
      final line = '${e.key} 格式：$format';
      if (line.length <= budget) {
        sb.writeln(line);
        budget -= line.length;
        names.add(e.key);
      }
    }
    if (sb.isEmpty) return '';
    final more = entries.length - names.length;
    return '${sb.toString().trim()}\n'
        '——工具手册 ${entries.length} 条（${more > 0 ? '还有 $more 条，' : ''}'
        '完整条目 manage_tool_manual get 按需读；格式坑记进手册，别反复试）';
  }
}
