/// Agent Debug Lab —— 自动测试剧本（TestScenario）
///
/// 不要人工聊天。固定剧本跑完 → 自动检查 → 出健康报告。
/// 每次改 MCP / 工具 / 记忆 / 人设 / 多角色，都能跑同一套剧本回归。
///
/// 剧本（对应 GPT 方案 8-09 13:43）：
///   测试1 工具：男主第二轮必须知道"我刚查过天气"
///   测试2 多步骤：收集信息→整理→输出，不能中途忘
///   测试3 压缩：聊天 100 轮触发 compact，继续问"计划做到哪了"不丢
///
/// 纯 Dart，不依赖 Flutter。
library;

import 'agent_run_trace.dart';

/// 剧本检查项
class ScenarioCheck {
  final String name;

  /// 最终回复必须包含的关键词（任一命中即过）
  final List<String> mustContainInReply;

  /// 最终回复绝不能包含的关键词（命中即失败）
  final List<String> mustNotContainInReply;

  /// 自定义检查（拿到全部 run 的轨迹）
  final bool Function(List<AgentRunTrace> runs)? custom;

  const ScenarioCheck({
    required this.name,
    this.mustContainInReply = const [],
    this.mustNotContainInReply = const [],
    this.custom,
  });

  /// 执行检查，返回 (通过, 详情)
  (bool, String) run(List<AgentRunTrace> runs) {
    if (custom != null) {
      final ok = custom!(runs);
      return (ok, ok ? '自定义检查通过' : '自定义检查失败');
    }
    if (runs.isEmpty) return (false, '没有轨迹数据');
    final lastReply = runs.last.finalReply ?? '';
    if (mustContainInReply.isNotEmpty) {
      final hit = mustContainInReply.firstWhere(
        (k) => lastReply.contains(k),
        orElse: () => '',
      );
      if (hit.isEmpty) {
        return (false, '回复里找不到「${mustContainInReply.join(' / ')}」');
      }
      return (true, '命中「$hit」');
    }
    if (mustNotContainInReply.isNotEmpty) {
      final hit = mustNotContainInReply.firstWhere(
        (k) => lastReply.contains(k),
        orElse: () => '',
      );
      if (hit.isNotEmpty) {
        return (false, '回复里出现了「$hit」');
      }
      return (true, '无禁用词');
    }
    return (true, '无检查条件');
  }
}

/// 一个测试剧本
class TestScenario {
  final String id;
  final String name;
  final String description;

  /// 依次发送的用户消息（自动跑，不用人工）
  final List<String> script;

  /// 跑完后自动检查
  final List<ScenarioCheck> checks;

  const TestScenario({
    required this.id,
    required this.name,
    required this.description,
    required this.script,
    this.checks = const [],
  });
}

/// 内置剧本
class TestScenarios {
  static final List<TestScenario> all = [
    // ── 测试1：工具 ──
    TestScenario(
      id: 't1_tool',
      name: '测试1：工具调用',
      description: '男主调工具后，第二轮必须知道"我刚查过天气"（工具结果进二次推理 + 工具历史注入）',
      script: ['帮我查一下今天天气怎么样'],
      checks: [
        ScenarioCheck(
          name: '男主调用了工具',
          custom: (runs) =>
              runs.isNotEmpty && runs.first.toolExecutions.isNotEmpty,
        ),
        ScenarioCheck(
          name: '工具结果进了二次推理（tool 消息存在）',
          custom: (runs) =>
              runs.length >= 2 &&
              runs[1].secondMessages.any((m) => m.isTool) ||
              runs.length >= 2 &&
                  runs[1].firstMessages.any((m) => m.isTool),
        ),
        ScenarioCheck(
          name: '男主最终回复了用户',
          custom: (runs) =>
              (runs.last.finalReply?.trim().isNotEmpty ?? false),
        ),
      ],
    ),

    // ── 测试2：多步骤 ──
    TestScenario(
      id: 't2_multistep',
      name: '测试2：多步骤任务',
      description: '收集信息→整理→输出，中途不能忘（走 manage_flow 流程）',
      script: [
        '帮我制定一个三天旅行计划',
        '第一天想去海边，第二天去古镇，第三天随便',
      ],
      checks: [
        ScenarioCheck(
          name: '最终回复提到旅行计划（没中途忘）',
          mustContainInReply: ['旅行', '计划', '海边', '古镇', '三天'],
        ),
        ScenarioCheck(
          name: '第二轮回复没忘第一轮信息',
          custom: (runs) {
            if (runs.length < 2) return false;
            final second = runs[1].finalReply ?? '';
            return second.contains('海边') || second.contains('古镇');
          },
        ),
      ],
    ),

    // ── 测试3：压缩 ──
    TestScenario(
      id: 't3_compact',
      name: '测试3：上下文压缩后不丢',
      description: '多轮对话触发 compact/summarize 后，继续问"计划做到哪了"不能丢',
      script: [
        '我们来玩一个角色扮演：我是船长，你是大副，我们要去南极',
        '好的船长，我们的船叫破冰号',
        '破冰号上有一只企鹅，它叫波波',
        '波波负责掌舵',
        '波波会唱歌，每天早上唱一首',
        '我们这次去南极是要找一块叫"永恒之冰"的宝物',
        '永恒之冰藏在一个冰洞里，冰洞在企鹅村的北边',
        '企鹅村的村长是一只老海象，他叫胡子爷爷',
        '胡子爷爷知道冰洞的位置，但他说只有唱歌最好听的企鹅才能进去',
        '波波为了进去，每天都在练习新歌',
        '刚刚那个计划做到哪了？我们为什么要去南极？',
      ],
      checks: [
        ScenarioCheck(
          name: '记得任务目标（永恒之冰）',
          mustContainInReply: ['永恒之冰', '南极', '宝物'],
        ),
        ScenarioCheck(
          name: '记得关键角色（波波/胡子爷爷）',
          mustContainInReply: ['波波', '胡子爷爷', '企鹅'],
        ),
      ],
    ),
  ];

  static TestScenario? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }
}
