/// Agent Debug Lab —— 剧本运行器（ScenarioRunner）
///
/// 跑固定剧本 → 收集轨迹 → 自动检查 → 出健康报告。
/// 发送函数注入（app 里接真实 AI 链路，测试里接 mock），
/// 所以本文件纯 Dart 可离线验证。
///
/// 用法（app 里一键跑）：
/// ```dart
/// final result = await ScenarioRunner.instance.run(
///   TestScenarios.byId('t1_tool')!,
///   send: (msg) => chatService.sendAndAwaitReply(msg), // 注入真实发送
/// );
/// print(result.render());
/// ```
library;

import 'agent_run_trace.dart';
import 'test_scenarios.dart';
import 'trace_analyzer.dart';
import 'trace_store.dart';

/// 单条剧本检查的结果
class ScenarioCheckResult {
  final ScenarioCheck check;
  final bool passed;
  final String detail;

  const ScenarioCheckResult({
    required this.check,
    required this.passed,
    required this.detail,
  });

  String get icon => passed ? '✅' : '❌';
}

/// 剧本运行结果
class ScenarioResult {
  final TestScenario scenario;
  final List<AgentRunTrace> runs;
  final List<ScenarioCheckResult> checkResults;
  final AgentHealthReport report;

  const ScenarioResult({
    required this.scenario,
    required this.runs,
    required this.checkResults,
    required this.report,
  });

  /// 渲染成报告文本
  String render() {
    final sb = StringBuffer();
    sb.writeln('🎬 剧本「${scenario.name}」—— ${scenario.description}');
    sb.writeln('  共 ${runs.length} 轮轨迹');
    for (final r in runs) {
      sb.writeln('  · ${r.userInput.isEmpty ? '(工具轮)' : r.userInput} '
          '→ 工具${r.toolExecutions.isEmpty ? '无' : r.toolExecutions.map((e) => e.name).join(',')} '
          '→ ${r.finalReply == null ? '' : '${r.finalReply!.length}字回复'}');
    }
    sb.writeln('  ── 剧本检查 ──');
    for (final c in checkResults) {
      sb.writeln('  ${c.icon} ${c.check.name} — ${c.detail}');
    }
    sb.writeln('  ── Agent 健康检查（最后一条轨迹）──');
    sb.writeln(report.render().split('\n').map((l) => '  $l').join('\n'));
    return sb.toString();
  }
}

/// 剧本运行器（单例）
class ScenarioRunner {
  ScenarioRunner._();

  static final ScenarioRunner instance = ScenarioRunner._();

  /// 运行剧本。
  /// [send] 发送一条用户消息并等待整轮完成（返回最终回复文本）。
  /// 每轮跑完，runner 从 TraceStore 取最新一条轨迹归档到 runs。
  Future<ScenarioResult> run(
    TestScenario scenario, {
    required Future<String> Function(String message) send,
    String personaId = 'debug_lab',
  }) async {
    final runs = <AgentRunTrace>[];
    for (final msg in scenario.script) {
      await send(msg);
      final recent = await TraceStore.instance.recent(personaId, limit: 3);
      // 取"刚产生的"新轨迹：优先找 userInput == msg 的那条
      AgentRunTrace? matched;
      for (final t in recent) {
        if (t.userInput == msg && !runs.any((r) => r.runId == t.runId)) {
          matched = t;
          break;
        }
      }
      matched ??= recent.isEmpty ? null : recent.first;
      if (matched != null && !runs.any((r) => r.runId == matched!.runId)) {
        runs.add(matched);
      }
    }

    // 剧本检查
    final checkResults = <ScenarioCheckResult>[];
    for (final check in scenario.checks) {
      final (ok, detail) = check.run(runs);
      checkResults.add(ScenarioCheckResult(
        check: check,
        passed: ok,
        detail: detail,
      ));
    }

    // Agent 健康检查（最后一条轨迹 + 上一条做跨轮检查）
    final report = runs.isEmpty
        ? _emptyReport()
        : const TraceAnalyzer().analyze(
            runs.last,
            previousTrace: runs.length >= 2 ? runs[runs.length - 2] : null,
          );

    return ScenarioResult(
      scenario: scenario,
      runs: runs,
      checkResults: checkResults,
      report: report,
    );
  }

  AgentHealthReport _emptyReport() => AgentHealthReport(
        checks: const [],
        runId: '-',
        at: DateTime.now(),
      );
}
