import 'dart:convert';

/// 工具指令解析器（用户 8-03 05:31：要支持不同 AI 的多种指令格式）
///
/// 识别两种明确格式，统一转成 toolCalls：
/// 1. ⟨工具:name⟩{json}⟨/工具⟩ 文本协议块（含宽松变体 [工具:name] / 工具:name）
/// 2. JSON 格式：
///    - 简化单对象：{"name":"record_memory","arguments":{"content":"..."}}
///    - 完整 tool_calls：{"id":"call_1","type":"function","function":{"name":"...","arguments":"..."}}
///    - tool_calls 数组：[{...},{...}]
/// 3. 参数自动归一：arguments 可能是 Map 或 JSON 字符串，统一转 Map
///
/// ⚠️ 8-04 18:2x（用户明确要求）：**移除中文意图词表**——
/// 男主正常说话（"翻翻以前写的日记"）会被模糊 contains 误判成工具意图，
/// 管家就弹窗调工具。DeepSeek 用原生 tool_calls 不需要它；
/// 文本协议 AI 用 ⟨工具:⟩ 明确块即可（男主按格式写，不与对话冲突）。
/// 纯聊天文本（无明确指令格式）→ 返回 null → 零副作用照常显示。
class ToolIntentParser {
  /// 已知工具名集合（宽松格式/JSON容错只认这些，防误抓）
  static final Set<String> _knownToolNames = {
    'record_memory',
    'recall_memory',
    'save_identity_memory',
    'list_tools',
    'write_diary',
    'query_diary',
  };

  /// ⟨工具:name⟩{json}⟨/工具⟩ 文本协议块（37批 TextProtocolAdapter 同款格式）
  /// 8-04 18:2x（用户明确要求）：格式必须**罕见**，日常对话不会出现——
  /// 只认严格块 ⟨工具:name⟩{json}⟨/工具⟩（⟨⟩ 全角尖括号聊天里几乎不出现）。
  /// ⚠️ 8-03 06:12 加的宽松变体（[工具:name] / 【工具:name】 / 工具:name
  /// 无括号）已删除——"工具:xxx"、"【工具】"这类字样日常对话会出现，
  /// 就是误触发源（用户 18:28："你认为 #A# 不常见不会误触发吗？
  /// 文本格式也要找一个少见的格式"）。
  static final RegExp _toolBlock =
      RegExp(r'⟨工具:([a-zA-Z_]+)⟩(.*?)⟨/工具⟩', dotAll: true);

  /// 统一入口：⟨工具:⟩块 → JSON，都识别不到返回 null
  /// （8-04 18:2x：不再走中文意图词表——自然语言会误触发）
  static List<Map<String, dynamic>>? extract(String text) {
    if (text.trim().isEmpty) return null;
    final blocks = extractToolBlocks(text);
    if (blocks != null && blocks.isNotEmpty) return blocks;
    return extractJsonToolCalls(text);
  }

  /// 解析 ⟨工具:name⟩{json}⟨/工具⟩ 文本协议块（仅严格块）
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
    // 8-03 19:2x（用户反馈"deepseek骗人"根因）：AI 念 JSON 时工具名拼错
    // （如 list_toos → list_tools）→ 模糊匹配纠正，别让拼写错误吞掉工具调用
    final nameRegex = RegExp(r'"name"\s*:\s*"([a-zA-Z_]+)"');
    for (final m in nameRegex.allMatches(text)) {
      final raw = m.group(1) ?? '';
      if (raw.isEmpty) continue;
      final name = _fuzzyMatchToolName(raw) ?? raw;
      if (!_knownToolNames.contains(name)) continue;
      if (results.any((r) => r['name'] == name)) continue;
      results.add({'name': name, 'arguments': <String, dynamic>{}});
    }
    return results.isEmpty ? null : results;
  }

  /// 工具名模糊纠正（8-03 19:2x）：
  /// AI 在文本里念工具调用时容易拼错（list_toos / recrd_memory / recall_memry），
  /// 编辑距离 ≤ 1 直接纠正；距离 2 且长度接近也纠正（防乱匹配）。
  /// 返回纠正后的已知工具名；匹配不上返回 null。
  static String? _fuzzyMatchToolName(String name) {
    if (_knownToolNames.contains(name)) return name;
    String? best;
    var bestDist = 3;
    for (final known in _knownToolNames) {
      final d = _levenshtein(name, known);
      if (d < bestDist) {
        bestDist = d;
        best = known;
      }
    }
    if (best == null) return null;
    if (bestDist <= 1) return best;
    if (bestDist == 2 && (name.length - best.length).abs() <= 1) return best;
    return null;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final dp =
        List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
    for (var i = 0; i <= a.length; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      dp[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        ].reduce((x, y) => x < y ? x : y);
      }
    }
    return dp[a.length][b.length];
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
    // 8-03 19:2x：拼错工具名 → 模糊纠正（list_toos → list_tools）
    final corrected = _fuzzyMatchToolName(name);
    if (corrected == null) return null; // 未知工具（且不像任何已知）→ 忽略
    name = corrected;
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
}
