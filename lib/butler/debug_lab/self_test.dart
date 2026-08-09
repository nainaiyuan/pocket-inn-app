// ignore_for_file: avoid_print

/// Agent Debug Lab —— 离线自测（验证检查器真的能抓 bug）
///
/// 运行：dart run lib/butler/debug_lab/self_test.dart
/// 不依赖 Flutter、不依赖 AI、不联网。
///
/// 验证两件事：
///   1. 正常轨迹 → 报告全绿（不误报）
///   2. 工具结果丢失轨迹 → 报告报警 t3（真能抓到男主"不知道自己调过什么"）
library;

import 'agent_run_trace.dart';
import 'trace_analyzer.dart';
import 'trace_store.dart';
import 'trace_session.dart';

/// 构造一个正常轨迹：人设 + 状态块 + 历史 + 用户消息 + 工具调用 + 结果回传
AgentRunTrace buildHealthyTrace() {
  final toolCall = TraceToolCall(
    id: 'call_abc123',
    name: 'query_weather',
    arguments: {'city': '上海'},
  );
  return AgentRunTrace(
    runId: 'run_healthy_1',
    startedAt: DateTime.now(),
    personaId: 'test_persona',
    userInput: '帮我查一下今天天气怎么样',
    firstMessages: [
      const TraceMessage(
        role: 'system',
        content: '你是「沈星回」。人设：温柔疏离的恋人。',
      ),
      const TraceMessage(
        role: 'system',
        content: '【当前情况】（先看这个——你现在在哪，再决定怎么回）：\n状态：正常对话',
      ),
      const TraceMessage(
        role: 'system',
        content: '【男主摘要】你上次洗牌时总结的：她喜欢猫',
      ),
      const TraceMessage(role: 'user', content: '帮我查一下今天天气怎么样'),
    ],
    modelText: '',
    modelReasoning: '模拟思考：用户要查天气，我调工具。',
    modelToolCalls: [toolCall],
    toolExecutions: [
      TraceToolExecution(
        name: 'query_weather',
        args: {'city': '上海'},
        ok: true,
        resultText: '上海今天 28°C，多云。',
      ),
    ],
    secondMessages: [
      const TraceMessage(
        role: 'system',
        content: '【当前情况】（先看这个——你现在在哪，再决定怎么回）：\n状态：正常对话',
      ),
      TraceMessage(
        role: 'assistant',
        content: '',
        toolCalls: [toolCall],
        reasoningContent: '模拟思考：用户要查天气，我调工具。',
      ),
      TraceMessage(
        role: 'tool',
        content: '上海今天 28°C，多云。',
        toolCallId: 'call_abc123',
      ),
      const TraceMessage(
        role: 'user',
        content: '【用户当前消息】帮我查一下今天天气怎么样',
      ),
    ],
    finalReply: '上海今天 28°C 多云，出门不用带伞～',
    memoriesWritten: const [],
    contextSnapshot: const {'isFirstRun': false},
  );
}

/// 构造一个坏轨迹：工具执行了，但结果【没有】进二次请求
/// （模拟男主"不知道自己调过什么"的现场）
AgentRunTrace buildBrokenTrace() {
  final toolCall = TraceToolCall(
    id: 'call_xyz789',
    name: 'query_weather',
    arguments: {'city': '上海'},
  );
  return AgentRunTrace(
    runId: 'run_broken_1',
    startedAt: DateTime.now(),
    personaId: 'test_persona',
    userInput: '帮我查一下今天天气怎么样',
    firstMessages: [
      const TraceMessage(
        role: 'system',
        content: '你是「沈星回」。人设：温柔疏离的恋人。',
      ),
      const TraceMessage(
        role: 'system',
        content: '【当前情况】（先看这个——你现在在哪，再决定怎么回）：\n状态：正常对话',
      ),
      const TraceMessage(role: 'user', content: '帮我查一下今天天气怎么样'),
    ],
    modelText: '',
    modelReasoning: '模拟思考：用户要查天气，我调工具。',
    modelToolCalls: [toolCall],
    toolExecutions: [
      TraceToolExecution(
        name: 'query_weather',
        args: {'city': '上海'},
        ok: true,
        resultText: '上海今天 28°C，多云。',
      ),
    ],
    // ❌ 坏在这：二次请求只有 assistant(tool_calls)，没有 tool 结果！
    secondMessages: [
      TraceMessage(
        role: 'assistant',
        content: '',
        toolCalls: [toolCall],
        reasoningContent: '模拟思考：用户要查天气，我调工具。',
      ),
      // 缺少 [tool] 结果消息
      const TraceMessage(role: 'user', content: '帮我查一下今天天气怎么样'),
    ],
    finalReply: '好的，我看看～',
    memoriesWritten: const [],
    contextSnapshot: const {'isFirstRun': false},
  );
}

void main() async {
  print('═══ Agent Debug Lab 离线自测 ═══');
  print('');
  final analyzer = TraceAnalyzer();

  // ── 测试 1：正常轨迹不该误报 ──
  print('【测试1】正常轨迹 → 期望全绿');
  final healthy = analyzer.analyze(buildHealthyTrace());
  print(healthy.render());
  final healthyFails = healthy.failed.length;
  print(healthyFails == 0 ? '✅ 正常轨迹 0 报警' : '❌ 误报了 $healthyFails 项');

  print('');
  print('─────────────────────────────');
  print('');

  // ── 测试 2：坏轨迹必须报警 t3（工具结果丢失）──
  print('【测试2】工具结果丢失轨迹 → 期望报警 t3');
  final broken = analyzer.analyze(buildBrokenTrace());
  print(broken.render());
  final hasT3 = broken.checks.any(
      (c) => c.checkId == 't3' && !c.passed);
  final hasT5 = broken.checks.any(
      (c) => c.checkId == 't5' && !c.passed);
  print(hasT3
      ? '✅ 抓到 t3：工具结果丢失 → 男主不知道自己调过什么'
      : '❌ 漏报 t3');
  print(hasT5
      ? '✅ 抓到 t5：二次请求最后一条不是用户消息'
      : 'ℹ️ t5 未触发（视消息结构）');

  print('');
  print('─────────────────────────────');
  print('');

  // ── 测试 3：存储往返 ──
  print('【测试3】TraceStore 存取往返');
  TraceStore.configure(MemoryTraceStorage());
  final trace = buildHealthyTrace();
  await TraceStore.instance.save(trace);
  final loaded = await TraceStore.instance.load('test_persona', trace.runId);
  final roundTripOk = loaded != null && loaded.finalReply == trace.finalReply;
  print(roundTripOk ? '✅ 存取一致' : '❌ 存取不一致');

  print('');
  print('─────────────────────────────');
  print('');

  // ── 测试 4：TraceSession 全流程（begin→记录→工具轮续接→finish）──
  print('【测试4】TraceSession 埋点全流程');
  TraceStore.configure(MemoryTraceStorage());
  final sess = TraceSession.instance;
  sess.begin('test_persona', '帮我查一下天气');
  sess.recordFirstMessages([
    TraceMessage.summarized(role: 'system', content: '你是「沈星回」。人设：温柔疏离。'),
    TraceMessage.summarized(role: 'user', content: '帮我查一下天气'),
  ]);
  sess.recordModelOutput(
    text: '',
    reasoning: '模拟思考：调天气工具',
    toolCalls: [
      TraceToolCall(id: 'call_1', name: 'query_weather', arguments: const {'city': '上海'}),
    ],
  );
  sess.recordToolExecution(const TraceToolExecution(
    name: 'query_weather', args: {'city': '上海'}, ok: true, resultText: '28°C 多云',
  ));
  // 工具轮续接
  sess.begin('test_persona', '', toolRound: true);
  sess.recordFirstMessages([
    TraceMessage.summarized(role: 'system', content: '【当前情况】状态：正常对话'),
    TraceMessage.summarized(
      role: 'assistant',
      toolCalls: [TraceToolCall(id: 'call_1', name: 'query_weather')],
    ),
    TraceMessage.summarized(role: 'tool', content: '28°C 多云', toolCallId: 'call_1'),
    TraceMessage.summarized(role: 'user', content: '【用户当前消息】帮我查一下天气'),
  ]);
  sess.recordChange('窗口校准: 65536→68000');
  sess.recordMemoryWritten('喜好-奶茶（测试）');
  await sess.finish('上海今天 28°C 多云，出门不用带伞～');
  final saved = await TraceStore.instance.recent('test_persona', limit: 1);
  final sessionOk = saved.isNotEmpty &&
      saved.first.hasToolCalls &&
      saved.first.toolExecutions.length == 1 &&
      saved.first.secondMessages.any((m) => m.isTool) &&
      saved.first.changes.isNotEmpty &&
      saved.first.memoriesWritten.isNotEmpty;
  print(sessionOk
      ? '✅ 会话完整（工具调用+结果回传+变化+记忆都记录了）'
      : '❌ 会话不完整');

  print('');
  final ok = healthyFails == 0 && hasT3 && roundTripOk && sessionOk;
  print(ok
      ? '═══ 全部通过：检查器能抓 bug，可以进入埋点阶段 ═══'
      : '═══ 有失败项，先修再埋点 ═══');
}
