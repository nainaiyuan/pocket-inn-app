import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/api_config.dart';
import '../services/openai_compatible_api_service.dart';

/// Anthropic 原生 transport（8-07 23:0x 用户：MCP 式统一适配——不管男主
/// 用什么格式，管家都实测识别 + 统一转换调用；不按 URL 名字猜格式）。
///
/// 支持：非流式 POST {baseUrl}/v1/messages；system 消息合并；
/// 工具轮 tool_use / tool_result 转换；响应 text + tool_use + thinking 解析。
/// 流式暂不做（男主对话全走非流式 chat()，流式 tool_calls 无消费方）。
///
/// 入参 messages 为 OpenAI 兼容 JSON 格式（AIChatMessage.toApiJson() 产物，
/// 含 role=tool / assistant tool_calls），这里统一转 Anthropic messages 格式。
Future<ChatCompletionResult> createAnthropicCompletion(
  ResolvedApiConfig config, {
  required List<Map<String, dynamic>> messages,
  Map<String, dynamic>? defaults,
  List<Map<String, dynamic>>? tools,
  ChatCompletionCancelToken? cancellationToken,
}) async {
  cancellationToken?.throwIfCancelled();

  final client = HttpClient();
  try {
    // ---- 消息转换：OpenAI 兼容 JSON → Anthropic messages ----
    final systemParts = <String>[];
    final anthropicMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final role = msg['role']?.toString() ?? 'user';
      final content = msg['content'];
      if (role == 'system') {
        if (content is String && content.trim().isNotEmpty) {
          systemParts.add(content.trim());
        }
        continue;
      }
      if (role == 'tool') {
        // 工具结果 → user 消息的 tool_result 块
        final toolCallId = msg['tool_call_id']?.toString() ?? '';
        final resultText = content?.toString() ?? '';
        anthropicMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              if (toolCallId.isNotEmpty) 'tool_use_id': toolCallId,
              'content': resultText,
            },
          ],
        });
        continue;
      }
      if (role == 'assistant') {
        final toolCallsRaw = msg['tool_calls'];
        if (toolCallsRaw is List && toolCallsRaw.isNotEmpty) {
          // 工具轮：text 块（若非空）+ tool_use 块原样回传
          final blocks = <Map<String, dynamic>>[
            if (content is String && content.trim().isNotEmpty)
              {'type': 'text', 'text': content},
            for (final call in toolCallsRaw)
              if (call is Map<String, dynamic>)
                () {
                  final fn = call['function'];
                  final fnMap = fn is Map<String, dynamic> ? fn : null;
                  final rawArgs = fnMap?['arguments']?.toString() ?? '{}';
                  Map<String, dynamic>? input;
                  try {
                    final decoded = jsonDecode(rawArgs);
                    if (decoded is Map<String, dynamic>) input = decoded;
                  } catch (_) {}
                  return {
                    'type': 'tool_use',
                    'id': call['id']?.toString() ?? 'call_unknown',
                    'name': fnMap?['name']?.toString() ?? 'unknown',
                    'input': input ?? <String, dynamic>{},
                  };
                }(),
          ];
          anthropicMessages.add({'role': 'assistant', 'content': blocks});
        } else {
          anthropicMessages.add({
            'role': 'assistant',
            'content': content?.toString() ?? '',
          });
        }
        continue;
      }
      // user（普通文本）
      anthropicMessages.add({
        'role': 'user',
        'content': content?.toString() ?? '',
      });
    }
    // Anthropic 要求最后一条是 user（或 tool_result）；若最后是 assistant，
    // 补一个空 user 消息
    if (anthropicMessages.isNotEmpty &&
        anthropicMessages.last['role'] == 'assistant') {
      anthropicMessages.add({'role': 'user', 'content': '（继续）'});
    }

    // ---- body ----
    final body = <String, dynamic>{
      'model': config.model,
      'max_tokens': (defaults?['max_tokens'] as num?)?.toInt() ?? 2048,
      if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
      'messages': anthropicMessages,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      if (defaults?['temperature'] != null)
        'temperature': (defaults!['temperature'] as num).toDouble(),
    };
    // customBody 合并（用户自定义参数）
    final custom = config.parseCustomBody();
    if (custom.isNotEmpty) {
      body.addAll(custom);
    }

    // ---- 请求 ----
    final endpoint = _buildAnthropicUri(config.baseUrl);
    final request = await client
        .openUrl('POST', endpoint)
        .timeout(const Duration(seconds: 30));
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.headers.set('x-api-key', config.apiKey);
    request.headers.set('anthropic-version', '2023-06-01');
    request.add(utf8.encode(jsonEncode(body)));

    cancellationToken?.throwIfCancelled();
    final response = await request.close().timeout(const Duration(seconds: 120));
    final responseBody = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final trimmed = responseBody.trim();
      throw HttpException(
        'Anthropic 请求失败，HTTP ${response.statusCode}'
        '${trimmed.isEmpty ? '' : ': ${trimmed.length > 300 ? trimmed.substring(0, 300) : trimmed}'}',
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Anthropic 响应不是 JSON 对象');
    }

    // ---- 解析：text + tool_use + thinking ----
    final textParts = <String>[];
    final thinkingParts = <String>[];
    final toolCalls = <Map<String, dynamic>>[];
    final contentBlocks = decoded['content'];
    if (contentBlocks is List) {
      for (final block in contentBlocks) {
        if (block is! Map<String, dynamic>) continue;
        switch (block['type']) {
          case 'text':
            final t = block['text']?.toString() ?? '';
            if (t.isNotEmpty) textParts.add(t);
          case 'thinking':
            final t = block['thinking']?.toString() ?? '';
            if (t.isNotEmpty) thinkingParts.add(t);
          case 'tool_use':
            toolCalls.add({
              'name': block['name']?.toString() ?? '',
              'arguments': (block['input'] as Map<String, dynamic>?) ?? {},
              if ((block['id']?.toString() ?? '').isNotEmpty)
                'id': block['id'].toString(),
            });
        }
      }
    }

    // usage 映射到 OpenAI 兼容结构（ChatCompletionResult 读 prompt_tokens 等）
    Map<String, dynamic>? usage;
    final usageRaw = decoded['usage'];
    if (usageRaw is Map<String, dynamic>) {
      usage = {
        'prompt_tokens': (usageRaw['input_tokens'] as num?)?.toInt() ?? 0,
        'completion_tokens': (usageRaw['output_tokens'] as num?)?.toInt() ?? 0,
        'total_tokens':
            ((usageRaw['input_tokens'] as num?)?.toInt() ?? 0) +
                ((usageRaw['output_tokens'] as num?)?.toInt() ?? 0),
      };
    }

    return ChatCompletionResult(
      text: textParts.join(''),
      thinkingChain: thinkingParts.isEmpty ? null : thinkingParts.join(''),
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      usage: usage,
    );
  } on HttpException catch (e) {
    final message = e.message.toLowerCase();
    final mentionsFormat = message.contains('tool') ||
        message.contains('function') ||
        message.contains('argument') ||
        message.contains('parameter') ||
        message.contains('unknown field') ||
        message.contains('unexpected') ||
        message.contains('invalid request');
    final badStatus = message.contains('400') || message.contains('422');
    if (mentionsFormat && badStatus) {
      // 复用能力探测的格式错误判定：触发降级链
      throw FormatException(e.message);
    }
    rethrow;
  } finally {
    client.close(force: true);
  }
}

Uri _buildAnthropicUri(String baseUrl) {
  final normalized = baseUrl.trim();
  if (normalized.isEmpty) {
    throw const FormatException('Base URL 不能为空');
  }
  final base = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  // 兼容用户填到 /v1 或 /anthropic 的情况
  if (base.endsWith('/v1')) return Uri.parse('$base/messages');
  if (base.endsWith('/anthropic')) return Uri.parse('$base/v1/messages');
  return Uri.parse('$base/v1/messages');
}
