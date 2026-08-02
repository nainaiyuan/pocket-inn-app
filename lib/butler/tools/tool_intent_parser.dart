import 'dart:convert';

/// 工具指令解析器（用户 8-03 05:31：要支持不同 AI 的多种指令格式）
///
/// 识别三种格式，统一转成 toolCalls：
/// 1. JSON 格式：
///    - 简化单对象：{"name":"record_memory","arguments":{"content":"..."}}
///    - 完整 tool_calls：{"id":"call_1","type":"function","function":{"name":"...","arguments":"..."}}
///    - tool_calls 数组：[{...},{...}]
/// 2. 中文文本格式："记住xxx" / "查一下xxx" / "写日记"（原意图词表恢复）
/// 3. 参数自动归一：arguments 可能是 Map 或 JSON 字符串，统一转 Map
///
/// 纯聊天文本（无任何指令）→ 返回 null → 零副作用照常显示。
class ToolIntentParser {
  /// 工具名 → 中文意图词（用户 8-03 03:56 扩充版 + 8-03 04:0x 备份恢复）
  static const Map<String, List<String>> chineseIntents = {
    'record_memory': ['记住', '记一下', '记下来', '记着', '别忘了', '你要记住'],
    'recall_memory': ['查记忆', '查一下记忆', '查看记忆', '查关于', '回忆', '回想', '查一下', '查查', '看看记忆', '记得吗', '想起来'],
    'save_identity_memory': ['记住代号', '保存代号'],
    'list_tools': ['有什么工具', '能做什么', '工具清单'],
    'write_diary': ['写日记', '写一下日记', '记日记'],
    'query_diary': ['查日记', '查一下日记', '翻日记', '看看日记', '之前聊过什么', '我说过什么'],
  };

  /// 统一入口：先 JSON 后中文，都识别不到返回 null
  static List<Map<String, dynamic>>? extract(String text) {
    if (text.trim().isEmpty) return null;
    final json = extractJsonToolCalls(text);
    if (json != null && json.isNotEmpty) return json;
    return extractChineseToolIntents(text);
  }

  /// 从文本里提取 JSON 工具调用指令
  /// 兼容：完整 tool_calls 数组 / 单对象 / function 包裹 / 混在自然语言里
  static List<Map<String, dynamic>>? extractJsonToolCalls(String text) {
    final results = <Map<String, dynamic>>[];
    // 先试整体解析（文本本身就是完整 JSON）
    _tryDecode(text, results);
    // 再逐个找 JSON 对象块（可能混在自然语言里）
    final blockRegex = RegExp(r'\{[^{}]*\}');
    for (final m in blockRegex.allMatches(text)) {
      _tryDecode(m.group(0)!, results);
    }
    return results.isEmpty ? null : results;
  }

  static void _tryDecode(String jsonText, List<Map<String, dynamic>> results) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return; // 不是合法 JSON，跳过
    }
    if (decoded is Map<String, dynamic>) {
      final call = _normalizeJsonCall(decoded);
      if (call != null) results.add(call);
    } else if (decoded is List) {
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final call = _normalizeJsonCall(item);
          if (call != null) results.add(call);
        }
      }
    }
  }

  /// 归一化单个 JSON 调用对象
  /// 支持：
  /// - {"name":"record_memory","arguments":{...}}          简化格式
  /// - {"function":{"name":"...","arguments":"..."}}       完整格式
  static Map<String, dynamic>? _normalizeJsonCall(Map<String, dynamic> obj) {
    String? name;
    Object? arguments;
    if (obj['name'] is String) {
      name = obj['name'] as String;
      arguments = obj['arguments'];
    } else if (obj['function'] is Map<String, dynamic>) {
      final fn = obj['function'] as Map<String, dynamic>;
      name = fn['name'] as String?;
      arguments = fn['arguments'];
    }
    if (name == null || name.isEmpty) return null;
    // arguments 归一：Map 直接用；JSON 字符串解析；缺失给空 Map
    Map<String, dynamic> args = {};
    if (arguments is Map<String, dynamic>) {
      args = arguments;
    } else if (arguments is String && arguments.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(arguments);
        if (decoded is Map<String, dynamic>) args = decoded;
      } catch (_) {}
    }
    return {'name': name, 'arguments': args};
  }

  /// 从文本里提取中文工具指令（原意图词表，参数粗提取）
  static List<Map<String, dynamic>>? extractChineseToolIntents(String text) {
    if (text.isEmpty) return null;
    final calls = <Map<String, dynamic>>[];
    chineseIntents.forEach((name, intents) {
      final hit = intents.any(text.contains);
      if (!hit) return;
      final args = <String, dynamic>{};
      // 粗提取参数：意图词后的内容（截到标点/换行，最长 30 字）
      final m = RegExp('(?:${intents.join('|')})[：:，,\\s]*(.+?)[。！？!?\\n]')
          .firstMatch(text);
      final argText = (m?.group(1) ?? '').trim();
      final arg = argText.length > 30 ? argText.substring(0, 30) : argText;
      switch (name) {
        case 'record_memory':
          args['content'] = arg;
          args['category'] = '';
        case 'recall_memory':
          args['query'] = arg;
          args['category'] = '';
        case 'save_identity_memory':
          args['code'] = arg;
          args['content'] = '';
        case 'write_diary':
          args['content'] = arg;
        case 'query_diary':
          args['keyword'] = arg;
      }
      calls.add({'name': name, 'arguments': args});
    });
    return calls.isEmpty ? null : calls;
  }
}
