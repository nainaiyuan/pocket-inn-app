/// Agent Debug Lab —— 轨迹自动检查器（TraceAnalyzer）
///
/// 程序自己检查一条（或连续两条）AgentRunTrace，回答：
///   "信息在哪一步丢的？"
///
/// 检查三大块（对应 GPT 方案 8-09 13:43）：
///   1. 上下文完整性：system 人设 / current state / history / current user
///   2. 工具链完整性：assistant(tool_call) ↔ tool(result) 配对、结果进二次推理
///   3. Agent 状态：当前任务 / 已完成 / 刚执行工具 / 下一步（= Working Memory）
///
/// 输出：AgentHealthReport（记忆 ✅ / 工具 ⚠️ / 状态 ❌ + 建议列表）
/// 纯 Dart，不依赖 Flutter。
library;

import 'agent_run_trace.dart';

/// 单条检查结果
class TraceCheckResult {
  final String checkId;
  final String name;
  final bool passed;
  final String detail;

  const TraceCheckResult({
    required this.checkId,
    required this.name,
    required this.passed,
    this.detail = '',
  });

  String get icon => passed ? '✅' : '❌';
}

/// Agent 健康报告
class AgentHealthReport {
  final List<TraceCheckResult> checks;
  final String runId;
  final DateTime at;

  const AgentHealthReport({
    required this.checks,
    required this.runId,
    required this.at,
  });

  // ── 三大维度状态 ──

  /// 记忆：记忆工具执行是否成功、是否写入
  String get memoryStatus {
    final mem = checks.where((c) => c.checkId.startsWith('m'));
    if (mem.isEmpty) return '➖ 无记忆操作';
    return mem.every((c) => c.passed) ? '✅' : '⚠️';
  }

  /// 工具：工具链是否完整（结果有没有进二次推理）
  String get toolStatus {
    final tools = checks.where((c) => c.checkId.startsWith('t'));
    if (tools.isEmpty) return '➖ 无工具调用';
    return tools.every((c) => c.passed) ? '✅' : '⚠️';
  }

  /// 状态：Working Memory（当前任务/已完成/刚执行工具/下一步）
  String get stateStatus {
    final states = checks.where((c) => c.checkId.startsWith('s'));
    if (states.isEmpty) return '➖ 未检查';
    return states.every((c) => c.passed) ? '✅' : '❌';
  }

  /// 上下文完整性
  String get contextStatus {
    final ctx = checks.where((c) => c.checkId.startsWith('c'));
    if (ctx.isEmpty) return '➖ 未检查';
    return ctx.every((c) => c.passed) ? '✅' : '⚠️';
  }

  List<TraceCheckResult> get failed =>
      checks.where((c) => !c.passed).toList();

  /// 建议列表（按失败项生成）
  List<String> get suggestions {
    final out = <String>[];
    final failedIds = failed.map((c) => c.checkId).toSet();

    if (failedIds.contains('c1')) {
      out.add('system 人设缺失：检查 SystemTemplate.build 是否被跳过（轻量期?）');
    }
    if (failedIds.contains('c2')) {
      out.add('【当前情况】状态块缺失：男主不知道"自己在哪"');
    }
    if (failedIds.contains('c3')) {
      out.add('历史未注入：检查 buildHistoryMessages 返回空的原因');
    }
    if (failedIds.contains('c4')) {
      out.add('最后一条不是用户消息：模型可能分不清要回复哪条');
    }
    if (failedIds.contains('t2')) {
      out.add('原生 tool_calls 未回传 assistant 消息：检查 reasoning_content 是否为空导致降级文本协议');
    }
    if (failedIds.contains('t3')) {
      out.add('工具结果丢失：tool 消息未进二次请求 → 男主看不到自己调了什么 → 加 Working Memory');
    }
    if (failedIds.contains('t4')) {
      out.add('文本协议工具结果未注入二次请求');
    }
    if (failedIds.contains('t5')) {
      out.add('二次请求最后一条不是用户消息：模型可能回复错对象');
    }
    if (failedIds.contains('s1')) {
      out.add('工具轮缺少【当前情况】状态块');
    }
    if (failedIds.contains('s2')) {
      out.add('最终回复为空：工具执行了但男主没回应用户');
    }
    if (failedIds.contains('s3')) {
      out.add('下一轮没有【工具使用历史】：男主不知道自己刚调过什么 → 需要 Working Memory 或工具历史注入');
    }
    if (failedIds.contains('m1')) {
      out.add('记忆工具调用失败或未写入');
    }
    if (failedIds.contains('m2')) {
      out.add('摘要未写入：总结链路断');
    }
    if (failedIds.isEmpty) out.add('本轮链路完整，无需改动');
    return out;
  }

  /// 渲染成报告文本（可直接展示/发给用户）
  String render() {
    final sb = StringBuffer();
    sb.writeln('📋 Agent 健康报告（run $runId · ${at.toIso8601String()}）');
    sb.writeln('  记忆: $memoryStatus  工具: $toolStatus  '
        '状态: $stateStatus  上下文: $contextStatus');
    sb.writeln('  检查 ${checks.length} 项，'
        '通过 ${checks.length - failed.length}，失败 ${failed.length}');
    for (final c in checks) {
      sb.writeln('  ${c.icon} ${c.name}'
          '${c.detail.isNotEmpty ? ' — ${c.detail}' : ''}');
    }
    sb.writeln('  💡 建议:');
    for (final s in suggestions) {
      sb.writeln('    - $s');
    }
    return sb.toString();
  }
}

/// 轨迹自动检查器
class TraceAnalyzer {
  const TraceAnalyzer();

  /// 分析一条轨迹。
  /// [previousTrace] 上一轮轨迹（跨 run 检查：下一轮有没有工具使用历史）
  AgentHealthReport analyze(
    AgentRunTrace trace, {
    AgentRunTrace? previousTrace,
  }) {
    final checks = <TraceCheckResult>[
      ..._checkContext(trace),
      ..._checkToolchain(trace),
      ..._checkState(trace, previousTrace: previousTrace),
      ..._checkMemory(trace),
    ];
    return AgentHealthReport(
      checks: checks,
      runId: trace.runId,
      at: DateTime.now(),
    );
  }

  // ── 1. 上下文完整性 ──

  List<TraceCheckResult> _checkContext(AgentRunTrace trace) {
    final msgs = trace.firstMessages;
    final out = <TraceCheckResult>[];

    // c1: system 人设
    final hasSystem = msgs.any((m) =>
        m.isSystem &&
        (m.content.contains('人设') ||
            m.content.contains('你叫') ||
            m.content.contains('你是') ||
            m.content.contains('SYSTEM')));
    out.add(TraceCheckResult(
      checkId: 'c1',
      name: '上下文·system 人设',
      passed: hasSystem || trace.isToolRound,
      detail: hasSystem
          ? '有'
          : (trace.isToolRound ? '工具轮豁免' : '缺失（轻量期?）'),
    ));

    // c2: 当前状态块
    final hasState = msgs.any((m) =>
        m.isSystem && m.content.contains('【当前情况】'));
    out.add(TraceCheckResult(
      checkId: 'c2',
      name: '上下文·【当前情况】状态块',
      passed: hasState,
      detail: hasState ? '有' : '缺失：男主不知道"自己在哪"',
    ));

    // c3: 历史（非首轮非工具轮）
    final isFirstRun =
        trace.contextSnapshot['isFirstRun'] == true ||
            trace.userInput.isEmpty == false &&
                msgs.where((m) => m.isUser).length <= 1 &&
                msgs.where((m) => m.isAssistant).isEmpty;
    final hasHistory = msgs.any((m) =>
        m.isSystem &&
        (m.content.contains('【男主摘要】') ||
            m.content.contains('【聊天历史') ||
            m.content.contains('【工具使用历史】') ||
            m.content.contains('【上下文参考】')));
    out.add(TraceCheckResult(
      checkId: 'c3',
      name: '上下文·历史注入',
      passed: trace.isToolRound || hasHistory || isFirstRun,
      detail: trace.isToolRound
          ? '工具轮豁免'
          : (hasHistory
              ? '有'
              : (isFirstRun ? '首轮无历史正常' : '缺失')),
    ));

    // c4: 最后一条是 user（current user）
    final last = msgs.isEmpty ? null : msgs.last;
    out.add(TraceCheckResult(
      checkId: 'c4',
      name: '上下文·最后一条=当前用户消息',
      passed: last != null && last.isUser,
      detail: last == null
          ? 'messages 为空'
          : '最后一条是 ${last.role}（${last.summary(30)}）',
    ));

    return out;
  }

  // ── 2. 工具链完整性 ──

  List<TraceCheckResult> _checkToolchain(AgentRunTrace trace) {
    final out = <TraceCheckResult>[];
    if (!trace.hasToolCalls && trace.toolExecutions.isEmpty) {
      out.add(const TraceCheckResult(
        checkId: 't0',
        name: '工具链·本轮无工具调用',
        passed: true,
        detail: '纯聊天轮，跳过工具检查',
      ));
      return out;
    }

    // t1: 每个 toolCall 都有执行记录
    final executedNames =
        trace.toolExecutions.map((e) => e.name).toSet();
    final unexecuted = trace.modelToolCalls
        .where((c) => !executedNames.contains(c.name))
        .toList();
    out.add(TraceCheckResult(
      checkId: 't1',
      name: '工具链·模型请求的工具都执行了',
      passed: unexecuted.isEmpty,
      detail: unexecuted.isEmpty
          ? '执行 ${trace.toolExecutions.length} 个'
          : '未执行: ${unexecuted.map((c) => c.name).join(',')}',
    ));

    // t2: 原生通道 assistant(tool_calls) 回传
    final hasNative =
        trace.modelToolCalls.any((c) => (c.id ?? '').isNotEmpty);
    final hasAssistantCall = trace.secondMessages.any(
        (m) => m.isAssistant && m.toolCalls.isNotEmpty);
    out.add(TraceCheckResult(
      checkId: 't2',
      name: '工具链·assistant(tool_calls) 回传',
      passed: !hasNative || hasAssistantCall,
      detail: !hasNative
          ? '无原生调用（文本协议）'
          : (hasAssistantCall ? '已回传' : '缺失：可能被降级文本协议'),
    ));

    // t3: tool 结果消息配对（原生通道）
    final nativeIds =
        trace.modelToolCalls.map((c) => c.id).whereType<String>().toSet();
    final toolResultIds = trace.secondMessages
        .where((m) => m.isTool && m.toolCallId != null)
        .map((m) => m.toolCallId!)
        .toSet();
    final missingResults =
        nativeIds.where((id) => !toolResultIds.contains(id)).toList();
    out.add(TraceCheckResult(
      checkId: 't3',
      name: '工具链·tool 结果进二次请求',
      passed: nativeIds.isEmpty || missingResults.isEmpty,
      detail: nativeIds.isEmpty
          ? '无原生调用'
          : (missingResults.isEmpty
              ? '全部配对（${toolResultIds.length} 条）'
              : '丢失: $missingResults → 男主看不到自己调过什么'),
    ));

    // t4: 文本协议结果注入（无原生 id 时）
    final textOnly = !hasNative && trace.toolExecutions.isNotEmpty;
    // 8-09 14:5x（真实轨迹 t4 误报）：多轮工具时 secondMessages 只留最后一轮，
    // 用 injectedToolResults（chat_page 每轮实际注入的块）兜底对照
    final injectedText = [
      ...trace.secondMessages.map((m) => m.content),
      ...trace.injectedToolResults,
    ].join('\n');
    final textInjected = trace.toolExecutions.every((e) =>
        injectedText.contains(e.name) ||
        (e.resultText.isNotEmpty && injectedText.contains(
            e.resultText.length > 20
                ? e.resultText.substring(0, 20)
                : e.resultText)));
    out.add(TraceCheckResult(
      checkId: 't4',
      name: '工具链·文本协议结果注入二次请求',
      passed: !textOnly || textInjected,
      detail: !textOnly
          ? '原生通道'
          : (textInjected ? '已注入' : '丢失'),
    ));

    // t5: 二次请求最后一条是 user
    final last = trace.secondMessages.isEmpty
        ? null
        : trace.secondMessages.last;
    out.add(TraceCheckResult(
      checkId: 't5',
      name: '工具链·二次请求最后一条=用户消息',
      passed: last != null && last.isUser,
      detail: last == null
          ? '无二次请求'
          : '最后一条是 ${last.role}（${last.summary(30)}）',
    ));

    // t6: 工具结果语义——ok:false 但文本像"查询无结果"（不是真失败）
    // 8-09 16:0x（用户：查记忆无结果被男主说成"用户拒绝查"）：
    // 查询无结果 ≠ 执行失败，男主可能误读 ❌ 为拒绝/失败
    final noResultLike = RegExp(r'没有找到|无结果|不存在|查不到|未找到|暂时没有|没查到');
    final suspiciousFails = trace.toolExecutions
        .where((e) => !e.ok && e.resultText.contains(noResultLike))
        .toList();
    out.add(TraceCheckResult(
      checkId: 't6',
      name: '工具链·查询无结果被标失败（语义检查）',
      passed: suspiciousFails.isEmpty,
      detail: suspiciousFails.isEmpty
          ? '无 ok:false 但文本像"查询无结果"的记录'
          : '${suspiciousFails.length} 次查询无结果被标 ok:false：'
              '${suspiciousFails.map((e) => '${e.name}「${e.resultText}」').join('；')}'
              '——查询完成≠失败，应 ok:true（已修复，旧数据仍会显示）',
    ));

    // t7: 工具选型——查记忆/找信息却用了非 recall_memory 工具
    // 8-09 16:0x（观察项：男主用 manage_tool_cache 找记忆 → 选型混乱症状）
    final recallLike = RegExp(r'回忆|记忆|记得|查到|找.*记忆|recall');
    final memoryLookupTools = <String>{'recall_memory', 'query_memory'};
    final oddTools = trace.toolExecutions
        .where((e) =>
            e.resultText.contains(recallLike) &&
            !memoryLookupTools.contains(e.name))
        .toList();
    out.add(TraceCheckResult(
      checkId: 't7',
      name: '工具链·查记忆用了非 recall_memory（选型观察）',
      passed: oddTools.isEmpty,
      detail: oddTools.isEmpty
          ? '查记忆类需求都用 recall_memory'
          : '男主用 ${oddTools.map((e) => '${e.name}（${e.resultText}）').join('；')} '
              '找记忆——选型可疑，考虑工具手册/提示优化',
    ));

    return out;
  }

  // ── 3. Agent 状态（Working Memory）──

  List<TraceCheckResult> _checkState(
    AgentRunTrace trace, {
    AgentRunTrace? previousTrace,
  }) {
    final out = <TraceCheckResult>[];

    // s1: 工具轮有【当前情况】状态块
    final hasState = trace.secondMessages.any(
        (m) => m.isSystem && m.content.contains('【当前情况】'));
    out.add(TraceCheckResult(
      checkId: 's1',
      name: '状态·工具轮含【当前情况】',
      passed: !trace.hasToolCalls || hasState,
      detail: hasState ? '有' : '缺失（工具轮也要知道自己在哪）',
    ));

    // s2: 最终回复存在（男主回应了用户）
    final hasReply = (trace.finalReply?.trim().isNotEmpty ?? false) ||
        trace.toolExecutions.isNotEmpty;
    out.add(TraceCheckResult(
      checkId: 's2',
      name: '状态·男主有最终回复',
      passed: hasReply,
      detail: hasReply
          ? (trace.finalReply?.trim().isNotEmpty ?? false
              ? '${trace.finalReply!.length} 字'
              : '无文本但执行了工具（气泡已反馈）')
          : '空回复',
    ));

    // s3: 跨 run —— 下一轮能看到"刚执行过工具"（工具使用历史）
    if (previousTrace != null &&
        previousTrace.toolExecutions.isNotEmpty) {
      final prevNames =
          previousTrace.toolExecutions.map((e) => e.name).toSet();
      final firstText =
          trace.firstMessages.map((m) => m.content).join('\n');
      final seen = prevNames.every((n) => firstText.contains(n));
      out.add(TraceCheckResult(
        checkId: 's3',
        name: '状态·下一轮知道刚调过 ${prevNames.join('/')}',
        passed: seen,
        detail: seen
            ? '工具历史已注入'
            : '看不到 → 缺 Working Memory / 工具历史注入',
      ));
    } else {
      out.add(const TraceCheckResult(
        checkId: 's3',
        name: '状态·跨轮工具记忆',
        passed: true,
        detail: '无上一轮工具调用，跳过',
      ));
    }

    // s4: provider 切换频率——switchedProvider 频繁出现 = 稳定性隐患
    // 8-09 16:0x（观察项：【6】JSON contextSnapshot 显示 switchedProvider:true,
    // needRecover:true, isFirstRun:true——正常 failover，但频率值得盯）
    final switched = trace.contextSnapshot['switchedProvider'] == true;
    final needRecover = trace.contextSnapshot['needRecover'] == true;
    out.add(TraceCheckResult(
      checkId: 's4',
      name: '状态·本轮发生 provider 切换/恢复',
      passed: !switched && !needRecover,
      detail: !switched && !needRecover
          ? '无切换（switchedProvider=false）'
          : '⚠️ 本轮 ${[
              if (switched) 'provider 切换',
              if (needRecover) '上下文恢复',
            ].join('+')}——failover 正常，但频繁出现要查 provider 稳定性',
    ));

    return out;
  }

  // ── 4. 记忆写入 ──

  List<TraceCheckResult> _checkMemory(AgentRunTrace trace) {
    final out = <TraceCheckResult>[];
    final memTools = trace.toolExecutions
        .where((e) =>
            e.name == 'record_memory' ||
            e.name == 'record_relation' ||
            e.name == 'save_summary')
        .toList();

    if (memTools.isEmpty) {
      out.add(const TraceCheckResult(
        checkId: 'm0',
        name: '记忆·本轮无记忆操作',
        passed: true,
        detail: '跳过',
      ));
      return out;
    }

    final failedMem = memTools.where((e) => !e.ok).toList();
    out.add(TraceCheckResult(
      checkId: 'm1',
      name: '记忆·记忆工具执行成功',
      passed: failedMem.isEmpty,
      detail: failedMem.isEmpty
          ? '${memTools.length} 个成功'
          : '失败: ${failedMem.map((e) => '${e.name}(${e.resultText})').join(',')}',
    ));

    final hasRecord = trace.memoriesWritten.isNotEmpty;
    out.add(TraceCheckResult(
      checkId: 'm2',
      name: '记忆·写入记录存在',
      passed: !memTools.any((e) => e.name != 'save_summary') || hasRecord,
      detail: hasRecord
          ? '${trace.memoriesWritten.length} 条'
          : '工具成功但 memoriesWritten 为空（埋点缺失?）',
    ));

    return out;
  }
}
