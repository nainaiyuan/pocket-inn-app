/// Agent Debug Lab —— 轨迹会话（TraceSession）
///
/// 埋点入口：旁路记录器，**只记录、不改任何现有行为**。
///
/// 用法（埋点方调用，分散在 generateReply / chat_page 工具循环）：
/// ```dart
/// TraceSession.instance.begin(personaId, userInput);      // 用户消息轮：开新 run
/// TraceSession.instance.begin(personaId, '', toolRound: true); // 工具轮：续接当前 run
/// TraceSession.instance.recordFirstMessages(msgs);        // 组装后、发送前
/// TraceSession.instance.recordModelOutput(result);        // 模型返回后
/// TraceSession.instance.recordToolExecution(...);         // 每个工具执行后（chat_page）
/// TraceSession.instance.recordChange('新增摘要: ...');     // 增量变化（ContextManager）
/// TraceSession.instance.finish(finalReply);               // 最终回复 → 存 TraceStore
/// ```
///
/// 纯 Dart，不依赖 Flutter / ai_provider（埋点方负责类型转换）。
library;

import 'agent_run_trace.dart';
import 'trace_store.dart';

/// 轨迹会话（单例）
class TraceSession {
  TraceSession._();

  static final TraceSession instance = TraceSession._();

  /// 全局开关（Debug Lab 页面可关）
  bool enabled = true;

  AgentRunTrace? _current;
  bool _finished = false;

  /// 工具轮续接模式：续接后 recordFirstMessages 写 secondMessages
  bool _toolRoundMode = false;

  /// 当前 run（null = 没有进行中的会话）
  AgentRunTrace? get current => _current;

  bool get isActive => _current != null && !_finished;

  /// 开始/续接一次会话。
  /// [toolRound] true = 工具轮，续接当前 run（无当前 run 时也会新建）；
  /// false = 用户消息轮，开新 run（丢弃未 finish 的旧 run）。
  void begin(
    String personaId,
    String userInput, {
    bool toolRound = false,
    Map<String, dynamic>? contextSnapshot,
  }) {
    if (!enabled) return;
    _toolRoundMode = toolRound;
    if (!toolRound) {
      _current = AgentRunTrace(
        runId: _newRunId(),
        startedAt: DateTime.now(),
        personaId: personaId,
        userInput: userInput,
        contextSnapshot: contextSnapshot ?? const {},
      );
      _finished = false;
    } else {
      // 工具轮续接；没有进行中的会话就新建一个（防御）
      _current ??= AgentRunTrace(
        runId: _newRunId(),
        startedAt: DateTime.now(),
        personaId: personaId,
        isToolRound: true,
        contextSnapshot: contextSnapshot ?? const {},
      );
      _finished = false;
    }
  }

  /// 记录第一次请求 messages（组装后、发送前 = 男主真实看到的）
  void recordFirstMessages(List<TraceMessage> messages) {
    final t = _current;
    if (t == null || _finished) return;
    if (_toolRoundMode || t.isToolRound) {
      _current = _copy(t, secondMessages: messages);
    } else {
      _current = _copy(t, firstMessages: messages);
    }
  }

  /// 记录模型输出
  void recordModelOutput({
    String? text,
    String? reasoning,
    List<TraceToolCall> toolCalls = const [],
  }) {
    final t = _current;
    if (t == null || _finished) return;
    _current = _copy(
      t,
      modelText: text,
      modelReasoning: reasoning,
      modelToolCalls: toolCalls,
    );
  }

  /// 记录一次工具执行（chat_page 工具循环里调用）
  void recordToolExecution(TraceToolExecution execution) {
    final t = _current;
    if (t == null || _finished) return;
    _current = _copy(
      t,
      toolExecutions: [...t.toolExecutions, execution],
    );
  }

  /// 记录记忆写入（ContextManager / 工具执行后）
  void recordMemoryWritten(String memory) {
    final t = _current;
    if (t == null || _finished) return;
    _current = _copy(
      t,
      memoriesWritten: [...t.memoriesWritten, memory],
    );
  }

  /// 记录增量变化（如：新增摘要 / 窗口校准 / 话题切换）
  void recordChange(String change) {
    final t = _current;
    if (t == null || _finished) return;
    _current = _copy(t, changes: [...t.changes, change]);
  }

  /// 记录工具轮实际注入二次请求的结果块（chat_page 组装 toolMessages 后调用）。
  /// 多轮工具时 secondMessages 会被最后一轮覆盖，这里保留每轮的注入内容。
  void recordInjectedToolResults(List<String> blocks) {
    final t = _current;
    if (t == null || _finished || blocks.isEmpty) return;
    _current = _copy(
      t,
      injectedToolResults: [...t.injectedToolResults, ...blocks],
    );
  }

  /// 结束会话并保存（非工具轮的最终回复时调用）
  Future<void> finish(String? finalReply) async {
    final t = _current;
    if (t == null || _finished) return;
    _current = _copy(
      t,
      finalReply: finalReply,
      finishedAt: DateTime.now(),
    );
    _finished = true;
    if (t.isToolRound) {
      // 工具轮 finish 不单独存（等主 run 一起存）——但保留内容
      return;
    }
    await TraceStore.instance.save(_current!);
    _current = null;
  }

  /// 丢弃当前会话（异常路径）
  void abort() {
    _current = null;
    _finished = true;
  }

  static String _newRunId() {
    final now = DateTime.now();
    final micro = now.microsecondsSinceEpoch;
    return '${now.millisecondsSinceEpoch}_${micro % 100000}';
  }

  static AgentRunTrace _copy(
    AgentRunTrace t, {
    DateTime? finishedAt,
    String? modelText,
    String? modelReasoning,
    List<TraceToolCall>? modelToolCalls,
    List<TraceToolExecution>? toolExecutions,
    List<TraceMessage>? firstMessages,
    List<TraceMessage>? secondMessages,
    List<String>? injectedToolResults,
    String? finalReply,
    List<String>? memoriesWritten,
    List<String>? changes,
  }) =>
      AgentRunTrace(
        runId: t.runId,
        startedAt: t.startedAt,
        finishedAt: finishedAt,
        personaId: t.personaId,
        userInput: t.userInput,
        isToolRound: t.isToolRound,
        firstMessages: firstMessages ?? t.firstMessages,
        modelText: modelText ?? t.modelText,
        modelReasoning: modelReasoning ?? t.modelReasoning,
        modelToolCalls: modelToolCalls ?? t.modelToolCalls,
        toolExecutions: toolExecutions ?? t.toolExecutions,
        secondMessages: secondMessages ?? t.secondMessages,
        injectedToolResults: injectedToolResults ?? t.injectedToolResults,
        finalReply: finalReply ?? t.finalReply,
        memoriesWritten: memoriesWritten ?? t.memoriesWritten,
        changes: changes ?? t.changes,
        contextSnapshot: t.contextSnapshot,
      );
}
