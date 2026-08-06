import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 📋 男主便签 / 当前任务模块（8-06 21:12 用户设计）
///
/// 男主自己维护的"工作区"：工具调用结果、查到的东西、干到一半的事，
/// 都写在这里。每轮 prompt 注入，男主下一句就知道"还有什么没干"。
///
/// 规则（写进模块说明，男主自己判断）：
/// - 干活中还要用的 → 留着；干完活 → 删
/// - 和正文（对话上下文）重复的 → 删（上下文已有的优先）
/// - 不设限额，男主自己说"第几行到第几行删"
/// - 写摘要（上下文压缩）时自己清理
///
/// 存储：行列表（Line 编号从 1 开始，男主用行号管理），per-persona。
class WorkingPadStore {
  WorkingPadStore._();

  static const _maxLines = 60; // 物理上限防无限膨胀（男主正常用不到）

  static String _key(String personaId) => 'working_pad_$personaId';

  static final Map<String, List<String>> _memCache = {};

  static List<String> _parse(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  /// 同步读（prompt 注入用；没 warm 过返回空）
  static List<String> lines(String personaId) {
    if (personaId.isEmpty) return const [];
    return _memCache[personaId] ?? const [];
  }

  /// 便签文本（注入用）：行号+内容，空返回 null
  static String? text(String personaId) {
    final ls = lines(personaId);
    if (ls.isEmpty) return null;
    final buf = StringBuffer();
    for (var i = 0; i < ls.length; i++) {
      buf.writeln('${i + 1}. ${ls[i]}');
    }
    return buf.toString().trim();
  }

  static Future<void> _save(String personaId, List<String> lines) async {
    _memCache[personaId] = lines;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(personaId), jsonEncode(lines));
  }

  /// 全量设置（男主自己整理好后重写）
  static Future<void> setAll(String personaId, List<String> lines) async {
    final cleaned =
        lines.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (cleaned.length > _maxLines) {
      cleaned.removeRange(_maxLines, cleaned.length);
    }
    await _save(personaId, cleaned);
  }

  /// 追加一行
  static Future<void> append(String personaId, String line) async {
    final ls = [...(_memCache[personaId] ?? [])];
    ls.add(line.trim());
    if (ls.length > _maxLines) ls.removeRange(_maxLines, ls.length);
    await _save(personaId, ls);
  }

  /// 删第 from 行到第 to 行（1 起；to 可省略=只删 from）
  static Future<int> remove(String personaId, int from, int? to) async {
    final ls = [...(_memCache[personaId] ?? [])];
    if (ls.isEmpty) return 0;
    final end = (to == null || to < from) ? from : to;
    if (from < 1 || from > ls.length) return 0;
    final realEnd = end > ls.length ? ls.length : end;
    ls.removeRange(from - 1, realEnd);
    await _save(personaId, ls);
    return realEnd - from + 1;
  }

  /// 预热缓存（发消息起点调）
  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    _memCache[personaId] = _parse(p.getString(_key(personaId)));
  }
}
