library;

import 'dart:convert';

import 'models.dart';

/// 工具格式翻译层（用户 19:29/19:34 设计）
///
/// 核心思想：底层调用、参数、执行逻辑**不变**，只有"工具声明/返回格式"
/// 随 AI 厂商不同（A 格式 / B 格式 / C 格式…）。未来接新 AI 只需
/// 新增一个 [ToolFormatAdapter] 实现，拼接逻辑复用。
///
/// 内部统一格式（所有 adapter 的翻译目标）：
/// - 工具声明：`[{type: function, function: {name, description, parameters}}]`
///   （即 OpenAI 兼容格式，chat_page 的 butlerTools 就是这个）
/// - 工具调用：`[{name, arguments: {…}}]`
///
/// 各厂商原生格式：
/// - OpenAI 兼容（DeepSeek/通义/智谱/本地…）：与内部格式一致 → 直通
/// - Anthropic：tools 声明 `[{name, input_schema, description}]`，
///   返回 `content[]` 里 `type: tool_use` 块
/// - Gemini：tools 声明 `[{functionDeclarations: [...]}]`，
///   返回 `functionCall` 对象
/// - 本地/不支持工具：不声明工具（返回 null）

/// 工具格式适配器：内部统一格式 ↔ 各厂商原生格式 的双向翻译
///
/// 子类用 `extends` 继承默认实现（buildToolHint / parseToolCallsFromText /
/// stripToolBlocks 默认空实现），只需覆盖自己支持的翻译方法。
abstract class ToolFormatAdapter {
  const ToolFormatAdapter();

  /// 格式标识（'openai' / 'anthropic' / 'gemini' / 'text' / 'none'）
  String get formatId;

  /// 发给 AI 前：内部工具声明 → 该厂商原生 tools 参数
  /// 返回 null = 不传 tools（该厂商/模型不支持原生工具）
  List<Map<String, dynamic>>? translateTools(List<Map<String, dynamic>> tools);

  /// AI 返回后：该厂商原生响应体 → 内部统一工具调用列表
  /// 返回 [] = 没有工具调用
  List<Map<String, dynamic>> parseToolCalls(Map<String, dynamic> response);

  /// 文本协议：生成注入 system 的工具说明文字（默认空 = 不需要）
  String buildToolHint(List<Map<String, dynamic>> tools) => '';

  /// 文本协议：从回复文本解析工具调用（默认空 = 不支持文本协议）
  List<Map<String, dynamic>> parseToolCallsFromText(String text) => const [];

  /// 文本协议：从回复文本剥掉工具块（默认原样返回）
  String stripToolBlocks(String text) => text;

  /// 工具轮消息翻译（默认原样返回；文本协议覆盖为丢弃原生
  /// tool_calls + 工具结果注入 user 消息，8-03 06:54）
  List<AIChatMessage> translateToolRound(List<AIChatMessage> messages) =>
      messages;

  /// 8-08 22:1x（自检：嵌套 JSON 被非贪婪正则截断到第一个 `}`）：
  /// 从文本提取"包含 startNeedle 的完整括号平衡 JSON 对象"。
  /// 例：{"type":"tool_use","input":{"a":1}} —— 非贪婪正则会在
  /// 内层 "a":1} 处截断导致 jsonDecode 失败；本函数扫到括号归零为止。
  static List<String> extractBalancedJsonObjects(
      String text, String startNeedle) {
    final result = <String>[];
    var idx = 0;
    while (true) {
      final hit = text.indexOf(startNeedle, idx);
      if (hit < 0) break;
      // 从 needle 往前找包裹它的 {
      var braceStart = hit;
      while (braceStart > 0 && text[braceStart] != '{') {
        braceStart--;
      }
      if (text[braceStart] != '{') {
        idx = hit + 1;
        continue;
      }
      var depth = 0;
      var i = braceStart;
      var inStr = false;
      var esc = false;
      var closed = false;
      for (; i < text.length; i++) {
        final ch = text[i];
        if (inStr) {
          if (esc) {
            esc = false;
          } else if (ch == r'\') {
            esc = true;
          } else if (ch == '"') {
            inStr = false;
          }
          continue;
        }
        if (ch == '"') {
          inStr = true;
        } else if (ch == '{') {
          depth++;
        } else if (ch == '}') {
          depth--;
          if (depth == 0) {
            result.add(text.substring(braceStart, i + 1));
            closed = true;
            break;
          }
        }
      }
      idx = (closed ? i : hit) + 1;
    }
    return result;
  }
}

/// 8-07 21:2x 用户实测：男主在文本里写 Anthropic 新版工具调用
/// `<invoke name="X"><parameter name="Y">V</parameter></invoke>`（流式带
/// `<|IDSMLI|>` 增量标记）。这是通用兜底：任何格式的模型都可能双写残留，
/// 或把 invoke XML 当唯一调用方式。库级函数，所有 adapter 都能用。
///
/// 先剥 `<|IDSMLI|>` 等流式标记（变体容忍空格），再解析 invoke 块：
/// `<invoke name="manage_flow"><parameter name="action">next</parameter></invoke>`
/// 参数值支持 JSON 自动解码（数字/布尔/对象）。
final RegExp _invokeRe = RegExp(
    r'<invoke\s+name="([a-zA-Z_]+)"[^>]*>([\s\S]*?)</invoke>',
    caseSensitive: false);

final RegExp _invokeParamRe = RegExp(
    r'<parameter\s+name="([^"]+)"[^>]*>([\s\S]*?)</parameter>',
    caseSensitive: false);

/// 清洗层（8-07 21:36 用户实测贴出的男主真实输出）：模型模仿 Anthropic
/// 流式格式时，<|IDSMLI|> 增量标记会被切碎污染——I/l/| 混用、空格错位、
/// string="true" 属性混进 parameter、_name 下划线变体、闭合标签错乱。
/// 先按标签名锚点把污染还原成干净 XML，再剥残留标记。
String _sanitizeInvokeText(String text) {
  var t = text;
  // 闭合标签污染：</|I DSMLIl invoke> → </invoke>
  t = t.replaceAll(
      RegExp(r'</[^>]*?invoke', caseSensitive: false), '</invoke');
  t = t.replaceAll(
      RegExp(r'</[^>]*?parameter', caseSensitive: false), '</parameter');
  t = t.replaceAll(
      RegExp(r'</[^>]*?tool_calls', caseSensitive: false), '</tool_calls');
  // 开标签污染：<|I DSMLIl invoke name=...> → <invoke name=...>
  t = t.replaceAll(
      RegExp(r'<[^/][^>]*?invoke', caseSensitive: false), '<invoke');
  t = t.replaceAll(
      RegExp(r'<[^/][^>]*?parameter', caseSensitive: false), '<parameter');
  t = t.replaceAll(
      RegExp(r'<[^/][^>]*?tool_calls', caseSensitive: false), '<tool_calls');
  // 参数名下划线变体：_name= → name=
  t = t.replaceAll('_name=', 'name=');
  // 剥剩余独立流式标记（含 DSML 的标签，如 <|IDSMLI|> 完整/碎片）
  t = t.replaceAll(
      RegExp(r'<[^>]*DSML[^>]*>', caseSensitive: false), '');
  return t;
}

/// 剥掉所有流式标记 + 工具调用区域（tool_calls…</tool_calls> 或裸 invoke 块）
String stripAnthropicInvokeBlocks(String text) {
  final t = _sanitizeInvokeText(text);
  var r = t
      // 8-11 06:0x（用户：气泡残留 "<"）：<|tool_calls|> 开标签被
      // _sanitizeInvokeText 清洗成 <tool_calls|> 后，旧正则从 tool_calls
      // 开始剥 → 前面的 "<" 单独残留 → 气泡显示 "…忘了。<"。
      // 改成从 "<" 起整块剥（覆盖 <|tool_calls|> / <tool_calls|> / <tool_calls>）。
      .replaceAll(
          RegExp(r'<[^>]*tool_calls[\s\S]*?</tool_calls>', caseSensitive: false),
          '')
      .replaceAll(_invokeRe, '')
      .trim();
  // 模型只写 `<|tool_calls|>` 开头 + invoke 块、没写 `</tool_calls>` 闭合时，
  // 剥完 invoke 会剩开标签壳（`<tool_calls|>` / `<|tool_calls|>`）→ 清掉。
  // 带尖括号才匹配，正文里的 "tool_calls" 单词不受影响。
  r = r
      .replaceAll(
          RegExp(r'<\s*\|?\s*tool_calls\s*\|?\s*>?', caseSensitive: false), '')
      .trim();
  return r;
}

/// 从文本解析 Anthropic invoke 工具调用（清洗污染后匹配）
List<Map<String, dynamic>> parseAnthropicInvokeCalls(String text) {
  final clean = _sanitizeInvokeText(text);
  final result = <Map<String, dynamic>>[];
  for (final m in _invokeRe.allMatches(clean)) {
    final name = m.group(1) ?? '';
    if (name.isEmpty) continue;
    final body = m.group(2) ?? '';
    final args = <String, dynamic>{};
    for (final p in _invokeParamRe.allMatches(body)) {
      final raw = (p.group(2) ?? '').trim();
      args[p.group(1) ?? ''] = _tryJsonValue(raw) ?? raw;
    }
    result.add({'name': name, 'arguments': args});
  }
  return result;
}

dynamic _tryJsonValue(String raw) {
  if (raw.isEmpty) return raw;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// OpenAI 兼容格式：内部格式即原生格式，直通
class OpenAICompatAdapter extends ToolFormatAdapter {
  const OpenAICompatAdapter();

  @override
  String get formatId => 'openai';

  @override
  List<Map<String, dynamic>>? translateTools(List<Map<String, dynamic>> tools) =>
      tools.isEmpty ? null : tools;

  @override
  List<Map<String, dynamic>> parseToolCalls(Map<String, dynamic> response) {
    final result = <Map<String, dynamic>>[];
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) return result;
    final message = (choices.first as Map<String, dynamic>?)?['message'];
    if (message is! Map<String, dynamic>) return result;
    final rawCalls = message['tool_calls'];
    if (rawCalls is! List) return result;
    for (final raw in rawCalls) {
      if (raw is! Map) continue;
      final fn = raw['function'];
      if (fn is! Map) continue;
      final name = fn['name']?.toString() ?? '';
      final id = raw['id']?.toString() ?? '';
      final argsRaw = fn['arguments']?.toString() ?? '{}';
      Map<String, dynamic> args = {};
      try {
        final decoded = jsonDecode(argsRaw);
        if (decoded is Map<String, dynamic>) args = decoded;
      } catch (_) {}
      result.add({
        'name': name,
        'arguments': args,
        if (id.isNotEmpty) 'id': id,
      });
    }
    return result;
  }

  /// 8-08 22:1x（自检"openai JSON 文本 ✗"）：OpenAI 兼容模型在文本里写
  /// `{"name":"xxx","arguments":{...}}`（JSON 文本化工具调用）也认——
  /// 统一适配 = 多格式都识别执行，不按名字猜格式。排除 type=tool_use
  /// （那是 Anthropic 格式，归 AnthropicAdapter 管，避免双识别）。
  @override
  List<Map<String, dynamic>> parseToolCallsFromText(String text) {
    final result = <Map<String, dynamic>>[];
    for (final jsonStr
        in ToolFormatAdapter.extractBalancedJsonObjects(text, '"name"')) {
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is! Map<String, dynamic>) continue;
        if (decoded['type'] == 'tool_use') continue;
        final name = decoded['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final args = decoded['arguments'];
        result.add({
          'name': name,
          'arguments':
              args is Map<String, dynamic> ? args : <String, dynamic>{},
        });
      } catch (_) {}
    }
    return result;
  }
}

/// Anthropic 原生格式（未来接 Claude 原生 API 用）
///
/// 声明：`[{name, description, input_schema: {type: object, properties, required}}]`
/// 返回：`content: [{type: 'tool_use', id, name, input: {…}}]`
class AnthropicAdapter extends ToolFormatAdapter {
  const AnthropicAdapter();

  @override
  String get formatId => 'anthropic';

  @override
  List<Map<String, dynamic>>? translateTools(List<Map<String, dynamic>> tools) {
    if (tools.isEmpty) return null;
    return [
      for (final t in tools)
        if (t['function'] is Map<String, dynamic>)
          () {
            final fn = t['function'] as Map<String, dynamic>;
            final params = (fn['parameters'] as Map<String, dynamic>?) ?? {};
            return {
              'name': fn['name'] ?? '',
              'description': fn['description'] ?? '',
              'input_schema': {
                'type': 'object',
                'properties': params['properties'] ?? {},
                'required': params['required'] ?? <String>[],
              },
            };
          }(),
    ];
  }

  @override
  List<Map<String, dynamic>> parseToolCalls(Map<String, dynamic> response) {
    final result = <Map<String, dynamic>>[];
    final content = response['content'];
    if (content is! List) return result;
    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] != 'tool_use') continue;
      result.add({
        'name': block['name']?.toString() ?? '',
        'arguments': (block['input'] as Map<String, dynamic>?) ?? {},
        if ((block['id']?.toString() ?? '').isNotEmpty) 'id': block['id'].toString(),
      });
    }
    return result;
  }

  /// 文本解析（8-07 19:15 用户：允许 AI 在文本里写其他家原生格式，管家识别执行）：
  /// 识别 `{"type":"tool_use","name":...,"input":{...}}` JSON 或 `<tool_use>…</tool_use>` 块
  /// 8-08 22:1x（自检"tool_use JSON ✗"）：JSON 分支从非贪婪正则改成
  /// 括号平衡提取——嵌套 input 对象不再被截断到第一个 `}`
  static final RegExp _toolUseBlockRe =
      RegExp(r'<tool_use>([\s\S]*?)</tool_use>', caseSensitive: false);

  @override
  List<Map<String, dynamic>> parseToolCallsFromText(String text) {
    final result = <Map<String, dynamic>>[];
    for (final m in _toolUseBlockRe.allMatches(text)) {
      final raw = (m.group(1) ?? '').trim();
      Map<String, dynamic>? obj;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) obj = decoded;
      } catch (_) {}
      // 也兼容 <tool_use> 里直接写 {"name":...,"input":...}（无 type 字段）
      if (obj == null) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) obj = decoded;
        } catch (_) {}
      }
      final name = obj?['name']?.toString() ?? '';
      final input = obj?['input'];
      if (name.isEmpty) continue;
      result.add({
        'name': name,
        'arguments': input is Map<String, dynamic> ? input : <String, dynamic>{},
      });
    }
    // JSON 形态：括号平衡提取（支持嵌套 input）
    for (final jsonStr
        in ToolFormatAdapter.extractBalancedJsonObjects(text, '"tool_use"')) {
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is! Map<String, dynamic>) continue;
        final name = decoded['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final input = decoded['input'];
        result.add({
          'name': name,
          'arguments':
              input is Map<String, dynamic> ? input : <String, dynamic>{},
        });
      } catch (_) {}
    }
    // 8-07 21:2x：也认 invoke XML 格式（男主实测会写）
    result.addAll(parseAnthropicInvokeCalls(text));
    return result;
  }

  @override
  String stripToolBlocks(String text) =>
      stripAnthropicInvokeBlocks(text.replaceAll(_toolUseBlockRe, ''));
}

/// Gemini 原生格式（未来接 Gemini API 用）
///
/// 声明：`[{functionDeclarations: [{name, description, parameters}]}]`
/// 返回：`functionCall: {name, args: {…}}`
class GeminiAdapter extends ToolFormatAdapter {
  const GeminiAdapter();

  @override
  String get formatId => 'gemini';

  @override
  List<Map<String, dynamic>>? translateTools(List<Map<String, dynamic>> tools) {
    if (tools.isEmpty) return null;
    return [
      {
        'functionDeclarations': [
          for (final t in tools)
            if (t['function'] is Map<String, dynamic>) t['function'],
        ],
      },
    ];
  }

  @override
  List<Map<String, dynamic>> parseToolCalls(Map<String, dynamic> response) {
    final result = <Map<String, dynamic>>[];
    final candidates = response['candidates'];
    if (candidates is! List || candidates.isEmpty) return result;
    final content = (candidates.first as Map<String, dynamic>?)?['content'];
    if (content is! Map<String, dynamic>) return result;
    final parts = content['parts'];
    if (parts is! List) return result;
    for (final part in parts) {
      if (part is! Map) continue;
      final fc = part['functionCall'];
      if (fc is! Map<String, dynamic>) continue;
      result.add({
        'name': fc['name']?.toString() ?? '',
        'arguments': (fc['args'] as Map<String, dynamic>?) ?? {},
      });
    }
    return result;
  }

  /// 文本解析（8-07 19:15 用户：允许 AI 在文本里写 Gemini 原生格式，管家识别执行）：
  /// 识别 `{"functionCall":{"name":...,"args":{...}}}` JSON
  /// 8-08 22:1x（自检）：括号平衡提取，防嵌套 args 截断
  @override
  List<Map<String, dynamic>> parseToolCallsFromText(String text) {
    final result = <Map<String, dynamic>>[];
    for (final jsonStr
        in ToolFormatAdapter.extractBalancedJsonObjects(text, '"functionCall"')) {
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is! Map<String, dynamic>) continue;
        final fc = decoded['functionCall'];
        if (fc is! Map<String, dynamic>) continue;
        final name = fc['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        result.add({
          'name': name,
          'arguments': (fc['args'] as Map<String, dynamic>?) ?? {},
        });
      } catch (_) {}
    }
    return result;
  }

  @override
  String stripToolBlocks(String text) =>
      text.replaceAll(RegExp(r'\{"functionCall"[\s\S]*?\}\}'), '').trim();
}

/// 文本协议兜底（本地不支持原生 function calling 的模型，用户 19:42 确认）
///
/// 思路：不传原生 tools，但把工具说明写成 system 文字；模型要用工具时
/// 在回复里写结构化块 `⟨工具:name⟩{json 参数}⟨/工具⟩`，管家解析执行。
///
/// 为什么用 ⟨工具:…⟩JSON⟨/工具⟩：
/// - 现代模型训练数据里 JSON/标签结构到处都是，照模板抄即可，比 #A# 可靠
/// - 不调用 = 纯聊天，零副作用（工具只是可选项，不强制）
/// - 结构化 JSON 参数 → 解析成内部统一格式，执行/存储/待确认区全不变
class TextProtocolAdapter extends ToolFormatAdapter {
  const TextProtocolAdapter();

  static final RegExp _toolBlock =
      RegExp(r'⟨工具:([a-zA-Z_]+)⟩(.*?)⟨/工具⟩', dotAll: true);

  @override
  String get formatId => 'text';

  @override
  List<Map<String, dynamic>>? translateTools(List<Map<String, dynamic>> tools) =>
      null;

  @override
  List<Map<String, dynamic>> parseToolCalls(Map<String, dynamic> response) =>
      const [];

  @override
  String buildToolHint(List<Map<String, dynamic>> tools) {
    if (tools.isEmpty) return '';
    final lines = <String>[];
    for (final t in tools) {
      final fn = t['function'];
      if (fn is! Map<String, dynamic>) continue;
      final name = fn['name'] ?? '';
      final desc = fn['description'] ?? '';
      final params =
          ((fn['parameters'] as Map<String, dynamic>?)?['properties']
                  as Map<String, dynamic>?) ??
              {};
      final paramNames = params.keys.join(', ');
      lines.add('- $name($paramNames)：$desc');
    }
    if (lines.isEmpty) return '';
    return '【工具】你可以使用以下工具（需要时才用，不需要就正常聊天，'
        '不要提"工具"这两个字）：\n${lines.join('\n')}\n'
        '要用某个工具时，在回复中单独写一行：\n'
        '⟨工具:工具名⟩{"参数名":"参数值"}⟨/工具⟩\n'
        '例如：⟨工具:record_memory⟩{"category":"喜好","content":"她喜欢小猫"}⟨/工具⟩\n'
        '写完工具块后，继续正常说话。';
  }

  @override
  List<Map<String, dynamic>> parseToolCallsFromText(String text) {
    final result = <Map<String, dynamic>>[];
    for (final m in _toolBlock.allMatches(text)) {
      final name = m.group(1) ?? '';
      final jsonStr = m.group(2) ?? '';
      Map<String, dynamic> args = {};
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) args = decoded;
      } catch (_) {}
      if (name.isNotEmpty) {
        result.add({'name': name, 'arguments': args});
      }
    }
    return result;
  }

  @override
  String stripToolBlocks(String text) =>
      text.replaceAll(_toolBlock, '').trim();

  /// 8-03 06:54：文本协议下工具轮回传翻译。
  ///
  /// DeepSeek 思考模式要求「带 tool_calls 的 assistant 消息」必须原样
  /// 回传 reasoning_content，响应里拿不到（或解析不出）就 HTTP 400：
  /// "The 'reasoning_content' in the thinking mode must be passed back"。
  /// 文本协议干脆不发原生 tool_calls：丢弃 assistant(tool_calls) 与
  /// tool 消息，把工具结果合并成一条 user 消息注入，男主看到结果继续说话。
  /// 非工具轮消息（无 tool/assistant(tool_calls)）原样返回，零副作用。
  @override
  List<AIChatMessage> translateToolRound(List<AIChatMessage> messages) {
    final toolResults = <String>[];
    final filtered = <AIChatMessage>[];
    for (final m in messages) {
      if (m.role == 'tool') {
        if (m.content.trim().isNotEmpty) toolResults.add(m.content.trim());
      } else if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
        // 丢弃 assistant(tool_calls)——思考模式回传要求太高，文本协议不需要
      } else {
        filtered.add(m);
      }
    }
    if (toolResults.isNotEmpty) {
      filtered.add(AIChatMessage(
        role: 'user',
        content: '【工具执行结果】\n${toolResults.join('\n')}\n\n'
            '基于结果自然地回复用户，不要再调用工具。',
      ));
    }
    return filtered;
  }
}

/// 完全不用工具的模型：不声明工具、不解析调用（纯聊天，不假装有工具）
class NoToolAdapter extends ToolFormatAdapter {
  const NoToolAdapter();

  @override
  String get formatId => 'none';

  @override
  List<Map<String, dynamic>>? translateTools(List<Map<String, dynamic>> tools) =>
      null;

  @override
  List<Map<String, dynamic>> parseToolCalls(Map<String, dynamic> response) =>
      const [];
}

/// 按 baseUrl / 厂商特征选择适配器。
///
/// 工具格式注册表（8-03 17:36 用户需求：未来任何厂商新格式都能
/// "一下子匹配上"，核心代码不动）。
///
/// 接新 AI 的最小动作：
/// ① 有 OpenAI 兼容端点（90% 厂商都有，含 Claude 走 OpenRouter、
///    Gemini 走官方 OpenAI 兼容端点）→ **零改动**，兜底自动匹配
/// ② 只有自家原生端点 → 写一个 [ToolFormatAdapter] 子类（或复用现有），
///    在 [_entries] 注册一行匹配规则
/// ③ 用户配置里也可直接指定 [AIProviderConfig.toolFormat]，显式选择
///    格式（openai/anthropic/gemini/text/none），不依赖 URL 识别
class ToolFormatRegistry {
  ToolFormatRegistry._();

  /// 注册表：按顺序匹配，先到先得；最后一条是 OpenAI 兼容兜底
  static final List<ToolFormatEntry> _entries = [
    // DeepSeek：OpenAI 兼容直通（原生 function calling + 思考模式工具调用，
    // V3.2 起支持；工具轮 id 配对 + reasoning_content 原样回传由 chat_page
    // 双通道处理——8-03 17:24 用户指示研究原生调用，不再绕文本协议）。
    // ⚠️ 8-07 23:0x 用户："先适配 DeepSeek 原生"——DeepSeek 的 Anthropic
    // 兼容端点（api.deepseek.com/anthropic）曾被 anthropic 规则（旧第一条）
    // 抢先匹配 → 降级 text 协议 → invoke XML 污染。deepseek 规则必须最前。
    ToolFormatEntry(
      match: (url) => url.contains('deepseek'),
      adapter: const OpenAICompatAdapter(),
    ),
    ToolFormatEntry(
      match: (url) =>
          url.contains('anthropic') && !url.contains('deepseek'),
      adapter: const AnthropicAdapter(),
    ),
    ToolFormatEntry(
      match: (url) =>
          url.contains('generativelanguage') || url.contains('gemini'),
      adapter: const GeminiAdapter(),
    ),
    // 兜底：OpenAI 兼容（通义/智谱/Kimi/豆包/火山/硅基/Groq/Ollama/
    // LM Studio/vLLM… 国内外绝大多数 API 与本地推理框架）
    ToolFormatEntry(
      match: (_) => true,
      adapter: const OpenAICompatAdapter(),
    ),
  ];

  /// 解析：用户显式指定优先（toolFormat），否则注册表按 baseUrl 匹配
  static ToolFormatAdapter resolve(
    String baseUrl, {
    String? toolFormatOverride,
  }) {
    switch (toolFormatOverride) {
      case 'text':
        return const TextProtocolAdapter();
      case 'none':
        return const NoToolAdapter();
      case 'anthropic':
        return const AnthropicAdapter();
      case 'gemini':
        return const GeminiAdapter();
      case 'openai':
        return const OpenAICompatAdapter();
    }
    final url = baseUrl.toLowerCase();
    for (final entry in _entries) {
      if (entry.match(url)) return entry.adapter;
    }
    return const OpenAICompatAdapter();
  }
}

/// 注册表条目：URL 匹配规则 + 对应的适配器
class ToolFormatEntry {
  const ToolFormatEntry({required this.match, required this.adapter});

  final bool Function(String url) match;
  final ToolFormatAdapter adapter;
}

/// [toolFormatOverride] 来自 AIProviderConfig.toolFormat（用户可手动指定），
/// 优先于 baseUrl 识别：'text' = 本地模型文本协议兜底，
/// 'none' = 纯聊天不用工具，'anthropic'/'gemini'/'openai' = 显式指定，
/// 其余按 baseUrl 自动识别（注册表）。
ToolFormatAdapter resolveToolFormat(
  String baseUrl, {
  String? toolFormatOverride,
}) =>
    ToolFormatRegistry.resolve(baseUrl,
        toolFormatOverride: toolFormatOverride);
