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
  /// 8-07 21:52 用户：日志增强——纯 Dart 解析器用钩子（Flutter 侧注入 DebugLogger）
  static void Function(String tag, String msg)? logSink;

  /// 已知工具名集合（宽松格式/JSON容错只认这些，防误抓）
  /// 8-07 23:5x：扩展为全量 28 个——与 ai_chat_service.dart 工具列表
  /// 同步（新增工具时两边都要加）；句式暗号（工具:name）只认这些，
  /// 日常聊天"工具:还不错"（无已知名）永不触发
  static final Set<String> _knownToolNames = {
    'add_record',
    'continue_speaking',
    'countdown_card',
    'list_tools',
    'manage_flow',
    'manage_frequent_tools',
    'manage_pad',
    'manage_record_tree',
    'manage_task',
    'notify_user',
    'query_diary',
    'query_logs',
    'query_record',
    'query_setting_history',
    'query_tool_formats',
    'recall_memory',
    'record_memory',
    'record_relation',
    'report_bug',
    'request_permission',
    'request_text_block',
    'resolve_pending',
    'save_identity_memory',
    'save_summary',
    'update_setting',
    'write_diary',
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
    if (blocks != null && blocks.isNotEmpty) {
      logSink?.call('工具意图',
          '🔧 识别 ${blocks.length} 个工具块（${blocks.map((b) => b['name']).join('、')}）');
      return blocks;
    }
    final json = extractJsonToolCalls(text);
    if (json != null && json.isNotEmpty) {
      logSink?.call('工具意图',
          '🔧 识别 ${json.length} 个 JSON 工具调用（${json.map((b) => b['name']).join('、')}）');
      return json;
    }
    // 8-07 23:5x（用户建议"写一句话对暗号"）：句式暗号第三通道——
    // "工具:manage_flow 动作=next" 一句话调工具；精确工具名才识别
    final sentence = extractSentenceCalls(text);
    if (sentence != null && sentence.isNotEmpty) {
      logSink?.call('工具意图',
          '🔧 识别 ${sentence.length} 个句式暗号（${sentence.map((b) => b['name']).join('、')}）');
      return sentence;
    }
    logSink?.call('工具意图', '❓ 无明确工具格式（文本含工具痕迹但识别不到）');
    return null;
  }

  /// 疑似工具调用检测（8-04 18:34 用户设计）：
  /// extract 没抓到明确格式，但文本里有"疑似想调工具"的罕见痕迹 →
  /// 管家不执行，而是提示男主正确格式（注入下轮，男主下次用对）。
  /// 特征全选**罕见**的（日常聊天不会出现），误判也只是提示，无害：
  /// ① 已知工具名英文（record_memory 等）散落在文本里
  /// ② "工具:" / "工具：" 冒号格式（宽松变体痕迹）
  /// ③ ⟨工具:xxx⟩ 写了开头没闭合
  /// 合法格式（extract 能抓到）→ 返回 null（不提示，走正常执行）
  static String? detectSuspicious(String text) {
    if (text.trim().isEmpty) return null;
    // 8-04 18:55：合法格式不提示（严格块/JSON 里也含工具名英文，
    // 必须先排除——否则严格块也被判成"格式不对"）
    if (extract(text) != null) return null;
    const knownNames = [
      'record_memory', 'recall_memory', 'save_identity_memory',
      'list_tools', 'write_diary', 'query_diary',
    ];
    final hasToolName = knownNames.any(text.contains);
    final hasToolColon = RegExp(r'工具\s*[:：]').hasMatch(text);
    final hasUnclosed = RegExp(r'⟨工具:[a-zA-Z_]+').hasMatch(text) &&
        !text.contains('⟨/工具⟩');
    if (!hasToolName && !hasToolColon && !hasUnclosed) return null;
    return '你刚才提到工具调用，但格式不对，管家没有执行。'
        '正确格式：⟨工具:工具名⟩{"参数":"值"}⟨/工具⟩'
        '（参数可省略；或用原生工具调用）。下次按这个格式写。';
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

  /// 一句话工具暗号（8-07 23:5x 用户建议）：
  /// "工具:工具名 参数名=值 参数名=值"——模型写原生 tool_calls 写岔时的
  /// 简单兜底（简单到几乎不会写错）；精确工具名 + 键=值 结构，防误触发。
  /// 例：工具:manage_flow 动作=next → manage_flow{action:next}
  ///    工具:list_tools               → list_tools{}
  /// 8-08 22:2x（自检"男主说(方括号/⟨未闭合/工具名散落)应提示 却执行"）：
  /// 收紧边界——① 前面不能被 [ ⟨ 【 或字母数字包着（[工具:list_tools] 是
  /// 宽松变体痕迹，不是暗号）② 工具名后只吃 键=值 序列，残留自然话
  /// （'工具:list_tools 帮我看看'）整体不匹配 → 走 detectSuspicious 提示
  static final RegExp _sentenceRe = RegExp(
      r'(?<![a-zA-Z0-9_⟨\[【])工具\s*[:：]\s*([a-zA-Z_]+)'
      r'((?:\s+\S+?=\S+)*\s*)(?=工具\s*[:：]|$)');
  /// 8-08 18:4x（修复验证中心 ⑤ 失败）：剥离用收紧版——
  /// 只匹配"工具:名 [键=值]*"调用本身（含调用后空白），不吞后面的自然话
  /// （旧 _sentenceRe 的 group2 懒匹配到句尾，把"我们继续"也吞了）。
  static final RegExp _sentenceCallRe = RegExp(
      r'(?<![a-zA-Z0-9_⟨\[【])工具\s*[:：]\s*([a-zA-Z_]+)((?:\s+\S+?=\S+)*\s*)');
  static final RegExp _kvRe = RegExp(r'(\S+?)=(\S+)');

  /// 中文参数键 → 工具参数名（男主是中文模型，写"动作=next"很自然；
  /// 映射后 manage_flow 能收到 action=next，不用男主记英文键）
  static const Map<String, String> _cnKeyMap = {
    '动作': 'action', '内容': 'content', '类别': 'category',
    '目标': 'goal', '步骤': 'steps', '关键词': 'keywords',
    '名称': 'name', '标题': 'title', '文本': 'text', '提醒': 'text',
    'id': 'id', '编号': 'id', '时间': 'time', '日期': 'date',
    '参数': 'arguments', '数量': 'count', '路径': 'path',
  };

  static List<Map<String, dynamic>>? extractSentenceCalls(String text) {
    final results = <Map<String, dynamic>>[];
    for (final m in _sentenceRe.allMatches(text)) {
      final name = m.group(1) ?? '';
      if (!_knownToolNames.contains(name)) continue; // 防误触发
      final rest = (m.group(2) ?? '').trim();
      final args = <String, dynamic>{};
      for (final kv in _kvRe.allMatches(rest)) {
        final key = kv.group(1)!;
        args[_cnKeyMap[key] ?? key] = kv.group(2)!;
      }
      results.add({'name': name, 'arguments': args});
    }
    return results.isEmpty ? null : results;
  }

  /// 从回复文本里剥离 ⟨工具:…⟩ 块 + 一句话暗号（用户只看到男主自然的话）
  static String stripToolBlocks(String text) {
    var t = text.replaceAll(_toolBlock, '').trim();
    // 剥句式暗号：只剥已知工具名的"工具:名 [键=值]*"调用部分，
    // 调用后面的自然话保留（8-08 18:4x：旧实现把"我们继续"也吞了）。
    // 用游标重建，避免 replaceRange 后偏移失效。
    final sb = StringBuffer();
    var cursor = 0;
    for (final m in _sentenceCallRe.allMatches(t)) {
      final name = m.group(1) ?? '';
      if (!_knownToolNames.contains(name)) continue; // 防误触发
      sb.write(t.substring(cursor, m.start));
      cursor = m.end;
    }
    sb.write(t.substring(cursor));
    return sb.toString().trim();
  }

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
