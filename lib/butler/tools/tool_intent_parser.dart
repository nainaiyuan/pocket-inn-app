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

  /// ⟨工具:name⟩{json}⟨/工具⟩ 文本协议块（37批 TextProtocolAdapter 同款格式）
  /// 8-03 06:12：再加宽松变体 —— [工具:name] / 【工具:name】 / 工具:name（无括号）
  static final RegExp _toolBlock =
      RegExp(r'⟨工具:([a-zA-Z_]+)⟩(.*?)⟨/工具⟩', dotAll: true);
  static final RegExp _toolBlockLoose = RegExp(
      r'[⟨\[【]?\s*工具\s*[:：]\s*([a-zA-Z_]+)\s*[⟩\]】]?',
      dotAll: true);

  /// 已知工具名集合（宽松格式/JSON容错只认这些，防误抓）
  static final Set<String> _knownToolNames = chineseIntents.keys.toSet();

  /// 统一入口：⟨工具:⟩块 → JSON → 中文，都识别不到返回 null
  /// （用户 8-03 05:42：不默认 AI 走哪个通道，管家认所有格式，
  ///   不同命令格式，同一个底层执行）
  static List<Map<String, dynamic>>? extract(String text) {
    if (text.trim().isEmpty) return null;
    final blocks = extractToolBlocks(text);
    if (blocks != null && blocks.isNotEmpty) return blocks;
    final json = extractJsonToolCalls(text);
    if (json != null && json.isNotEmpty) return json;
    return extractChineseToolIntents(text);
  }

  /// 解析 ⟨工具:name⟩{json}⟨/工具⟩ 文本协议块（含宽松变体）
  static List<Map<String, dynamic>>? extractToolBlocks(String text) {
    final results = <Map<String, dynamic>>[];
    // 严格块：⟨工具:name⟩…⟨/工具⟩（name 任意，参数 JSON 解析失败给空）
    for (final m in _toolBlock.allMatches(text)) {
      final name = m.group(1) ?? '';
      final jsonStr = m.group(2) ?? '';
      Map<String, dynamic> args = {};
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) args = decoded;
      } catch (_) {}
      if (name.isNotEmpty) {
        results.add({'name': name, 'arguments': args});
      }
    }
    // 宽松块：[工具:name] / 【工具:name】 / 工具:name（无括号）
    // 只认已知工具名；跳过已被严格块覆盖的位置（用 lastIndex 简单去重）
    for (final m in _toolBlockLoose.allMatches(text)) {
      final name = m.group(1) ?? '';
      if (name.isEmpty || !_knownToolNames.contains(name)) continue;
      if (results.any((r) => r['name'] == name)) continue;
      results.add({'name': name, 'arguments': <String, dynamic>{}});
    }
    return results.isEmpty ? null : results;
  }

  /// 从回复文本里剥离 ⟨工具:…⟩ 块（用户只看到男主自然的话）
  static String stripToolBlocks(String text) =>
      text.replaceAll(_toolBlock, '').trim();

  /// 从文本里提取 JSON 工具调用指令
  /// 兼容：完整 tool_calls 数组 / 单对象 / function 包裹 / 混在自然语言里 /
  /// markdown 代码块包裹 / arguments 嵌套花括号 / 参数残缺（如 arguments: !）
  /// 用户 8-03 05:59：原 blockRegex `\{[^{}]*\}` 不支持嵌套 → 改栈扫描找平衡块
  /// 用户 8-03 06:12：JSON 残缺（name 在、arguments 非法）→ 降级空参数执行，
  /// 不再整条丢弃（男主写 {"name":"list_tools","arguments":!} 也要能抓）
  static List<Map<String, dynamic>>? extractJsonToolCalls(String text) {
    final results = <Map<String, dynamic>>[];
    // 先试整体解析（文本本身就是完整 JSON）
    _tryDecode(text, results);
    if (results.isNotEmpty) return results;
    // 栈扫描：找所有平衡的 {…} 块（支持嵌套花括号）
    final stack = <int>[];
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '{') {
        stack.add(i);
      } else if (ch == '}') {
        if (stack.isNotEmpty) {
          final start = stack.removeLast();
          if (stack.isEmpty) {
            _tryDecode(text.substring(start, i + 1), results);
          }
        }
      }
    }
    if (results.isNotEmpty) return results;
    // 容错兜底：JSON 解析失败但能提取到已知工具名 → 降级空参数
    // （覆盖 {"name":"list_tools","arguments":!} 这类残缺 JSON）
    final nameRegex = RegExp(r'"name"\s*:\s*"([a-zA-Z_]+)"');
    for (final m in nameRegex.allMatches(text)) {
      final name = m.group(1) ?? '';
      if (name.isEmpty || !_knownToolNames.contains(name)) continue;
      if (results.any((r) => r['name'] == name)) continue;
      results.add({'name': name, 'arguments': <String, dynamic>{}});
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
