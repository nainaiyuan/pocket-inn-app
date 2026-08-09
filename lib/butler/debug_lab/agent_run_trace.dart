/// Agent Debug Lab —— 运行轨迹（AgentRunTrace）
///
/// 每次 AI 回复（一次用户消息 → 最终回复）记录一条完整轨迹，回答：
/// "男主到底缺什么？" —— 信息在哪一步丢的。
///
/// 轨迹内容（对应 GPT 方案 8-09 13:43）：
///   1. run_id + 用户输入
///   2. 发送给模型的完整 messages（第一次请求）
///   3. 模型输出（文本 + tool_calls + reasoning）
///   4. 工具执行结果（每个工具的入参/成败/结果文本）
///   5. 二次请求 messages（toolRound，含 tool 结果回传）
///   6. 最终回复
///   7. 写了哪些记忆（record_memory / save_summary 等）
///   8. 上下文快照（摘要区/话题原文/窗口/stateful 决策）
///
/// 纯 Dart，不依赖 Flutter。可 JSON 序列化（持久化 + 回放）。
library;

/// 工具调用（模型输出里的 tool_calls 条目）
class TraceToolCall {
  /// 原生调用 id（DeepSeek/OpenAI 给的，回传配对用）；文本协议无 id
  final String? id;
  final String name;
  final Map<String, dynamic> arguments;

  const TraceToolCall({
    this.id,
    required this.name,
    this.arguments = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'arguments': arguments,
      };

  factory TraceToolCall.fromJson(Map<String, dynamic> json) => TraceToolCall(
        id: json['id']?.toString(),
        name: json['name']?.toString() ?? '',
        arguments:
            (json['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// 一条消息（发给模型/模型返回的 messages 元素）
class TraceMessage {
  final String role; // system | user | assistant | tool
  final String content;
  final List<TraceToolCall> toolCalls; // assistant 消息的 tool_calls
  final String? toolCallId; // tool 消息配对用
  final String? reasoningContent; // assistant 思考链

  const TraceMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const [],
    this.toolCallId,
    this.reasoningContent,
  });

  bool get isSystem => role == 'system';
  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isTool => role == 'tool';

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'toolCalls': toolCalls.map((t) => t.toJson()).toList(),
        'toolCallId': toolCallId,
        'reasoningContent': reasoningContent,
      };

  factory TraceMessage.fromJson(Map<String, dynamic> json) => TraceMessage(
        role: json['role']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        toolCalls: ((json['toolCalls'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => TraceToolCall.fromJson(m.cast<String, dynamic>()))
            .toList(),
        toolCallId: json['toolCallId']?.toString(),
        reasoningContent: json['reasoningContent']?.toString(),
      );

  /// 摘要（调试/报告用，截断）
  String summary([int maxLen = 60]) {
    final buf = StringBuffer('[$role]');
    if (toolCalls.isNotEmpty) {
      buf.write(' tool_calls:${toolCalls.map((t) => t.name).join(',')}');
    }
    if (content.isNotEmpty) {
      buf.write(' ${content.length > maxLen ? '${content.substring(0, maxLen)}…' : content}');
    }
    return buf.toString();
  }
}

/// 一次工具执行记录
class TraceToolExecution {
  final String name;
  final Map<String, dynamic> args;
  final bool ok;
  final String resultText; // 给模型看的工具结果
  final bool userApproved; // 是否经过用户确认（null=无需确认）
  final int durationMs;

  const TraceToolExecution({
    required this.name,
    this.args = const {},
    required this.ok,
    this.resultText = '',
    this.userApproved = true,
    this.durationMs = 0,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'args': args,
        'ok': ok,
        'resultText': resultText,
        'userApproved': userApproved,
        'durationMs': durationMs,
      };

  factory TraceToolExecution.fromJson(Map<String, dynamic> json) =>
      TraceToolExecution(
        name: json['name']?.toString() ?? '',
        args: (json['args'] as Map?)?.cast<String, dynamic>() ?? const {},
        ok: json['ok'] as bool? ?? false,
        resultText: json['resultText']?.toString() ?? '',
        userApproved: json['userApproved'] as bool? ?? true,
        durationMs: json['durationMs'] as int? ?? 0,
      );
}

/// 一条完整运行轨迹
class AgentRunTrace {
  /// 唯一 id（时间戳 + 随机）
  final String runId;

  final DateTime startedAt;
  DateTime? finishedAt;

  final String personaId;

  /// 用户输入（工具轮=空串）
  final String userInput;

  /// 是否工具轮（二次请求）
  final bool isToolRound;

  /// 第一次请求：发送给模型的完整 messages
  final List<TraceMessage> firstMessages;

  // ── 模型输出 ──
  final String? modelText;
  final String? modelReasoning;
  final List<TraceToolCall> modelToolCalls;

  // ── 工具执行 ──
  final List<TraceToolExecution> toolExecutions;

  /// 二次请求 messages（工具轮）
  final List<TraceMessage> secondMessages;

  /// 最终回复（男主对用户说的话）
  final String? finalReply;

  /// 这次对话写了哪些记忆（record_memory/record_relation/save_summary 等）
  final List<String> memoriesWritten;

  /// 上下文快照
  final Map<String, dynamic> contextSnapshot;

  /// 构造（不用 const：finishedAt 需运行后设置）
  AgentRunTrace({
    required this.runId,
    required this.startedAt,
    this.finishedAt,
    required this.personaId,
    this.userInput = '',
    this.isToolRound = false,
    this.firstMessages = const [],
    this.modelText,
    this.modelReasoning,
    this.modelToolCalls = const [],
    this.toolExecutions = const [],
    this.secondMessages = const [],
    this.finalReply,
    this.memoriesWritten = const [],
    this.contextSnapshot = const {},
  });

  /// 总耗时
  int get durationMs =>
      (finishedAt?.difference(startedAt).inMilliseconds ?? 0);

  bool get hasToolCalls => modelToolCalls.isNotEmpty;

  /// 快照读取辅助
  String snap(String key, [String fallback = '']) =>
      contextSnapshot[key]?.toString() ?? fallback;

  Map<String, dynamic> toJson() => {
        'runId': runId,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'personaId': personaId,
        'userInput': userInput,
        'isToolRound': isToolRound,
        'firstMessages': firstMessages.map((m) => m.toJson()).toList(),
        'modelText': modelText,
        'modelReasoning': modelReasoning,
        'modelToolCalls': modelToolCalls.map((t) => t.toJson()).toList(),
        'toolExecutions': toolExecutions.map((t) => t.toJson()).toList(),
        'secondMessages': secondMessages.map((m) => m.toJson()).toList(),
        'finalReply': finalReply,
        'memoriesWritten': memoriesWritten,
        'contextSnapshot': contextSnapshot,
      };

  factory AgentRunTrace.fromJson(Map<String, dynamic> json) => AgentRunTrace(
        runId: json['runId']?.toString() ?? '',
        startedAt:
            DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        finishedAt: DateTime.tryParse(json['finishedAt']?.toString() ?? ''),
        personaId: json['personaId']?.toString() ?? '',
        userInput: json['userInput']?.toString() ?? '',
        isToolRound: json['isToolRound'] as bool? ?? false,
        firstMessages: _msgs(json['firstMessages']),
        modelText: json['modelText']?.toString(),
        modelReasoning: json['modelReasoning']?.toString(),
        modelToolCalls: _calls(json['modelToolCalls']),
        toolExecutions: ((json['toolExecutions'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) =>
                TraceToolExecution.fromJson(m.cast<String, dynamic>()))
            .toList(),
        secondMessages: _msgs(json['secondMessages']),
        finalReply: json['finalReply']?.toString(),
        memoriesWritten:
            ((json['memoriesWritten'] as List?) ?? const [])
                .whereType<String>()
                .toList(),
        contextSnapshot:
            (json['contextSnapshot'] as Map?)?.cast<String, dynamic>() ??
                const {},
      );

  static List<TraceMessage> _msgs(dynamic raw) =>
      ((raw as List?) ?? const [])
          .whereType<Map>()
          .map((m) => TraceMessage.fromJson(m.cast<String, dynamic>()))
          .toList();

  static List<TraceToolCall> _calls(dynamic raw) =>
      ((raw as List?) ?? const [])
          .whereType<Map>()
          .map((m) => TraceToolCall.fromJson(m.cast<String, dynamic>()))
          .toList();
}
