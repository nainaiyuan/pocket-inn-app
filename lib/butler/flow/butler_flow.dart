library;

import '../../utils/debug_logger.dart';
import '../tools/butler_tool.dart';

/// 管家流程引擎 — 把管家操作抽象成"流程"
///
/// 一个流程 = 一组有序步骤。比如"聊天流程"：
///   ① 组合 Prompt → ② 发送男主 → ③ 等待回复 → ④ 还原假名 → ⑤ 记录情绪 → ⑥ 更新规律
///
/// 每个步骤记录：状态（进行中/成功/失败）、耗时、结果摘要、错误信息。
/// 日志页按流程树展示，能直观看到整个流程是否顺利进行、哪一步判定错误。
/// 之后管家可以直接调用这些流程（流程即服务，可复用可组合）。

/// 流程状态
enum ButlerFlowStatus { pending, running, success, failed, cancelled }

/// 步骤状态
enum ButlerFlowStepStatus { pending, running, success, failed, skipped }

/// 流程步骤定义
class ButlerFlowStep {
  final String id; // 'assemble_prompt'
  final String name; // '组合 Prompt'
  final Future<String?> Function()? action; // 执行函数，返回结果摘要；抛异常 = 失败

  ButlerFlowStepStatus status = ButlerFlowStepStatus.pending;
  String? result;
  String? error;
  int elapsedMs = 0;

  ButlerFlowStep({required this.id, required this.name, this.action});
}

/// 一个流程实例
class ButlerFlow {
  final String id; // 'chat_flow'
  final String name; // '聊天流程'
  final List<ButlerFlowStep> steps;

  /// 本流程中的工具调用链（技能执行时挂上来的，日志页展示）
  final List<ButlerToolCall> toolCalls = [];

  ButlerFlowStatus status = ButlerFlowStatus.pending;
  DateTime startedAt = DateTime.now();
  DateTime? finishedAt;

  ButlerFlow({required this.id, required this.name, required this.steps});

  int get totalElapsedMs =>
      finishedAt?.difference(startedAt).inMilliseconds ?? 0;

  bool get isSuccessful => status == ButlerFlowStatus.success;

  /// 顺序执行所有步骤：某步失败则中断（后续步骤标记 skipped）
  Future<void> run() async {
    status = ButlerFlowStatus.running;
    startedAt = DateTime.now();
    DebugLogger.log(
      '管家流程',
      '▶ 流程开始 [${steps.length}步] $name',
    );

    var failed = false;
    for (final step in steps) {
      if (failed) {
        step.status = ButlerFlowStepStatus.skipped;
        continue;
      }
      step.status = ButlerFlowStepStatus.running;
      final sw = Stopwatch()..start();
      DebugLogger.log('管家流程', '  └▶ $name › ${step.name}');
      try {
        final action = step.action;
        if (action == null) {
          step.result = '（无操作）';
          step.status = ButlerFlowStepStatus.success;
        } else {
          final summary = await action();
          step.result = summary;
          step.status = ButlerFlowStepStatus.success;
        }
      } catch (e) {
        step.error = '$e';
        step.status = ButlerFlowStepStatus.failed;
        failed = true;
        DebugLogger.log(
          '管家流程',
          '  └✖ $name › ${step.name} 判定失败: $e',
        );
      }
      sw.stop();
      step.elapsedMs = sw.elapsedMilliseconds;
      DebugLogger.log(
        '管家流程',
        '  └✔ $name › ${step.name} 完成（${sw.elapsedMilliseconds}ms）'
        '${step.result == null ? '' : ' › ${step.result}'}',
      );
    }

    finishedAt = DateTime.now();
    status = failed ? ButlerFlowStatus.failed : ButlerFlowStatus.success;
    DebugLogger.log(
      '管家流程',
      failed
          ? '■ 流程失败：$name（第 ${steps.indexWhere((s) => s.status == ButlerFlowStepStatus.failed) + 1} 步出错）'
          : '■ 流程完成 ✓：$name 共 ${totalElapsedMs}ms',
    );
  }
}

/// 流程运行器（单例）：运行流程 + 保留最近记录供日志页展示
class ButlerFlowRunner {
  ButlerFlowRunner._();

  static final ButlerFlowRunner instance = ButlerFlowRunner._();

  /// 最近完成的流程（日志页展示用，最多 20 个）
  final List<ButlerFlow> _history = [];
  List<ButlerFlow> get history => List.unmodifiable(_history);

  /// 当前正在运行的流程（无则 null）
  ButlerFlow? current;

  /// 运行一个流程
  Future<ButlerFlow> run(ButlerFlow flow) async {
    current = flow;
    try {
      await flow.run();
    } finally {
      current = null;
      _history.insert(0, flow);
      if (_history.length > 20) {
        _history.removeRange(20, _history.length);
      }
    }
    return flow;
  }

  /// 轻量模式：不提供 action，只记录步骤的开始/结束（供现有代码嵌入上报）
  ButlerFlow startRecording({
    required String id,
    required String name,
    required List<String> stepIds,
    required List<String> stepNames,
  }) {
    final flow = ButlerFlow(
      id: id,
      name: name,
      steps: [
        for (var i = 0; i < stepIds.length; i++)
          ButlerFlowStep(id: stepIds[i], name: stepNames[i]),
      ],
    );
    flow.status = ButlerFlowStatus.running;
    flow.startedAt = DateTime.now();
    current = flow;
    DebugLogger.log('管家流程', '▶ 流程开始 [${stepIds.length}步] $name');
    return flow;
  }

  /// 上报某步完成（轻量模式）
  void stepDone(String stepId, {String? result, String? error}) {
    final flow = current;
    if (flow == null) return;
    ButlerFlowStep? found;
    for (final s in flow.steps) {
      if (s.id == stepId) {
        found = s;
        break;
      }
    }
    final step = found;
    if (step == null) return;
    step.status = error == null
        ? ButlerFlowStepStatus.success
        : ButlerFlowStepStatus.failed;
    step.result = result;
    step.error = error;
    step.elapsedMs = DateTime.now().difference(flow.startedAt).inMilliseconds;
    DebugLogger.log(
      '管家流程',
      error == null
          ? '  └✔ ${flow.name} › ${step.name}${result == null ? '' : ' › $result'}'
          : '  └✖ ${flow.name} › ${step.name} 判定失败: $error',
    );
  }

  /// 结束当前流程（轻量模式）
  void finishRecording({bool failed = false}) {
    final flow = current;
    if (flow == null) return;
    flow.finishedAt = DateTime.now();
    flow.status = failed ? ButlerFlowStatus.failed : ButlerFlowStatus.success;
    // 未上报的步骤标记为跳过
    for (final step in flow.steps) {
      if (step.status == ButlerFlowStepStatus.pending) {
        step.status = ButlerFlowStepStatus.skipped;
      }
    }
    current = null;
    _history.insert(0, flow);
    if (_history.length > 20) {
      _history.removeRange(20, _history.length);
    }
    DebugLogger.log(
      '管家流程',
      failed ? '■ 流程失败：${flow.name}' : '■ 流程完成 ✓：${flow.name} 共 ${flow.totalElapsedMs}ms',
    );
  }

  /// 把一次工具调用挂到当前流程上（技能执行工具时自动调用）
  void attachToolCall(ButlerToolCall call) {
    final flow = current;
    if (flow == null) return;
    flow.toolCalls.add(call);
    DebugLogger.log(
      '管家工具',
      '🔧 ${call.toolName}(${call.argsSummary}) 开始',
    );
  }
}
