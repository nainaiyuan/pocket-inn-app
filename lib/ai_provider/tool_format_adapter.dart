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
    ToolFormatEntry(
      match: (url) => url.contains('anthropic'),
      adapter: const AnthropicAdapter(),
    ),
    ToolFormatEntry(
      match: (url) =>
          url.contains('generativelanguage') || url.contains('gemini'),
      adapter: const GeminiAdapter(),
    ),
    // DeepSeek：OpenAI 兼容直通（原生 function calling + 思考模式工具调用，
    // V3.2 起支持；工具轮 id 配对 + reasoning_content 原样回传由 chat_page
    // 双通道处理——8-03 17:24 用户指示研究原生调用，不再绕文本协议）
    ToolFormatEntry(
      match: (url) => url.contains('deepseek'),
      adapter: const OpenAICompatAdapter(),
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
