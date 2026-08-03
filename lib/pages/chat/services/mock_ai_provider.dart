import 'dart:convert';

import '../../../ai_provider/models.dart';
import '../../../utils/debug_logger.dart';

/// 🧪 模拟 AI（找bug工具，用户 8-03 20:3x 要求）：
/// 代替 DeepSeek 走完整聊天链路（feed→组装→工具轮→回传→回复），
/// 不联网、不花 token、行为脚本化。
///
/// 核心价值：**校验程序回传格式**——DeepSeek 原生 function calling 要求：
/// ① assistant 工具轮消息整条原样回传（tool_calls 带 id + reasoning_content
///    思考模式必须原样带回，否则 HTTP 400）
/// ② 工具结果 {role: tool, tool_call_id: 模型给的 id, content} 配对
/// 模拟 AI 在工具轮逐项检查，格式不对直接报出来 → 用户立刻知道
/// 是程序 bug 还是 AI 行为。
class MockAIProvider {
  /// 上次返回的 assistant 消息摘要（工具轮校验对照用）
  Map<String, dynamic>? _lastAssistant;

  /// 非工具轮：根据最后一条 user 消息内容决定行为（脚本化）
  AIProviderResult chat(
    List<AIChatMessage> messages, {
    required bool toolRound,
  }) {
    DebugLogger.log('模拟AI', '🤖 模拟AI 收到 ${messages.length} 条消息：');
    for (final m in messages) {
      final extra = (m.toolCalls != null && m.toolCalls!.isNotEmpty)
          ? ' tool_calls=${m.toolCalls!.map((c) => c['name']).join('、')}'
          : (m.toolCallId != null ? ' tool_call_id=${m.toolCallId}' : '');
      final content = m.content.length > 50
          ? m.content.substring(0, 50) + '…'
          : m.content;
      DebugLogger.log('模拟AI', '  [${m.role}] $content$extra');
    }

    // 结构检查：发给模型的 user 消息应该只有 1 条（当前消息）
    // 上下文参考必须是 system 消息——如果混进 user/assistant 对话流就是 bug
    if (!toolRound) {
      final userMsgs = messages.where((m) => m.role == 'user').length;
      if (userMsgs > 1) {
        DebugLogger.log(
            '模拟AI',
            '⚠️ 检测到 $userMsgs 条 user 消息（应该只有 1 条当前消息）——'
            '上下文参考混进对话流了，男主会分不清哪条要回复！');
      }
      final history = messages
          .where((m) => m.role == 'system' && m.content.contains('上下文参考'))
          .toList();
      if (history.isNotEmpty) {
        // 检查上下文参考里有没有男主消息（用户 20:03 反馈"男主对话被抛弃"）
        // 注意：buildHistoryMessages 输出格式是 [user]/[assistant] 前缀
        // （8-03 21:25 修：原来数"用户：/男主："永远 0 条，误报"男主消息丢失"）
        final raw = history.first.content;
        final userCount = RegExp(r'\[user\]').allMatches(raw).length;
        final aiCount = RegExp(r'\[assistant\]').allMatches(raw).length;
        DebugLogger.log(
            '模拟AI',
            '📊 上下文参考里 用户 $userCount 条 / 男主 $aiCount 条'
            '${aiCount >= userCount - 1 ? ' ✅ 男主消息在' : ' ❌ 男主消息丢失！'}');
      }
    }

    if (toolRound) {
      return _handleToolRound(messages);
    }

    // 非工具轮：按最后一条 user 消息内容触发脚本
    String lastUser = '';
    for (final m in messages.reversed) {
      if (m.role == 'user') {
        lastUser = m.content;
        break;
      }
    }
    if (lastUser.contains('记住') || lastUser.contains('喜欢喝')) {
      // 8-03 22:3x（用户确认设计）：男主记录的是【男主总结的话】，
      // 不是用户原话——"用户说的乱七八糟 → 男主总结出精炼句"
      // 原实现直接存 lastUser（用户原话"记住我喜欢喝咖啡"）→ 不符合
      final summary = _summarizePreference(lastUser);
      return _toolCall('record_memory', {
        'content': summary,
        // 模拟男主提取"关键动词+名词"（设计：a+b+c 组合找规律用）
        'keywords': ['喜欢', '咖啡'],
      }, '模拟思考：用户想让我记住这个偏好，我总结成一句话用 record_memory 存进记忆库。');
    }
    if (lastUser.contains('之前说过') || lastUser.contains('查一下') ||
        lastUser.contains('记得')) {
      return _toolCall('recall_memory', {'query': lastUser},
          '模拟思考：用户问我之前说过什么，我用 recall_memory 查记忆库。');
    }
    if (lastUser.contains('工具')) {
      return _toolCall('list_tools', {},
          '模拟思考：用户想知道我能做什么，我调用 list_tools 列出来。');
    }
    if (lastUser.contains('日记')) {
      return _toolCall('write_diary', {'content': '模拟日记内容'},
          '模拟思考：用户要写日记，我调用 write_diary 存档。');
    }
    return AIProviderResult(
      text: '（模拟AI）好的呢，我在听。',
      reasoningContent: '模拟思考：普通聊天，直接自然回复就好。',
      providerName: '模拟AI',
    );
  }

  /// 模拟男主总结：用户原话（可能啰嗦/带指令）→ 精炼的总结句
  /// "记住我喜欢喝咖啡" → "用户喜欢喝咖啡"
  /// "帮我记住我讨厌下雨天" → "用户讨厌下雨天"
  String _summarizePreference(String raw) {
    var s = raw;
    for (final p in ['请你记住', '帮我记住', '请记住', '记住']) {
      if (s.startsWith(p)) {
        s = s.substring(p.length);
        break;
      }
    }
    s = s.trim();
    // 人称统一成男主口中的"用户"（真实 DeepSeek 也会这样总结）
    s = s.replaceFirst(RegExp(r'^(我|人家)'), '用户');
    return s;
  }

  AIProviderResult _toolCall(
      String name, Map<String, dynamic> args, String reasoning) {
    final call = <String, dynamic>{
      'id': 'call_mock_${DateTime.now().millisecondsSinceEpoch}',
      'name': name,
      'arguments': args,
      // argumentsJson：DeepSeek 原生要求 arguments 是 JSON 字符串
      'argumentsJson': jsonEncode(args),
    };
    _lastAssistant = {
      'id': call['id'],
      'name': name,
      'reasoning': reasoning,
      'content': '',
    };
    DebugLogger.log('模拟AI', '🔧 模拟AI 决定调用工具：$name 参数=$args');
    return AIProviderResult(
      text: '',
      reasoningContent: reasoning,
      toolCalls: [call],
      providerName: '模拟AI',
    );
  }

  /// 工具轮：逐项校验程序回传格式，通过/失败都明确报出来
  AIProviderResult _handleToolRound(List<AIChatMessage> messages) {
    final sb = StringBuffer('🧪 工具轮回传校验：\n');
    var ok = true;

    if (_lastAssistant != null) {
      sb.writeln('上次模拟AI返回的调用：${_lastAssistant!['name']} '
          'id=${_lastAssistant!['id']}');
    }

    // ① assistant 工具轮消息必须在（tool_calls 带 id + reasoning_content 原样带回）
    final assistants =
        messages.where((m) => m.role == 'assistant' && m.toolCalls != null).toList();
    if (assistants.isEmpty) {
      sb.writeln('❌ 没找到 assistant 工具轮消息（tool_calls 整条丢了？）');
      ok = false;
    } else {
      for (final a in assistants) {
        for (final c in a.toolCalls!) {
          final id = c['id']?.toString() ?? '';
          if (id.isEmpty) {
            sb.writeln('❌ tool_calls 缺 id：$c');
            ok = false;
          } else {
            sb.writeln('✅ assistant 工具轮带 id：$id');
          }
        }
        if (a.reasoningContent == null || a.reasoningContent!.isEmpty) {
          sb.writeln('❌ assistant 消息 reasoning_content 丢了——'
              'DeepSeek 思考模式必须原样回传，否则 HTTP 400');
          ok = false;
        } else {
          sb.writeln('✅ reasoning_content 原样带回（${a.reasoningContent!.length} 字）');
        }
      }
    }

    // ② tool 结果消息必须 tool_call_id 配对
    final tools = messages.where((m) => m.role == 'tool').toList();
    if (tools.isEmpty) {
      sb.writeln('❌ 没有 tool 结果消息（管家没把工具结果回传男主？）');
      ok = false;
    } else {
      for (final t in tools) {
        if (t.toolCallId == null || t.toolCallId!.isEmpty) {
          sb.writeln('❌ tool 消息缺 tool_call_id：「${t.content}」');
          ok = false;
        } else {
          sb.writeln('✅ tool 结果配对 tool_call_id=${t.toolCallId}：'
              '「${t.content.length > 30 ? t.content.substring(0, 30) + '…' : t.content}」');
        }
      }
    }

    sb.writeln(ok
        ? '✅ 校验通过：回传格式符合 DeepSeek 原生规范'
        : '❌ 校验失败：程序回传格式有 bug（见上）');
    DebugLogger.log('模拟AI', sb.toString());
    return AIProviderResult(
      text: '（模拟AI）$sb',
      reasoningContent: '模拟思考：工具结果已收到，逐项校验完成。',
      providerName: '模拟AI',
    );
  }
}
