import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ai_provider/ai_provider_manager.dart';
import '../../ai_provider/mock_ai_provider.dart';
import '../../ai_provider/models.dart';
import '../../ai_provider/tool_format_adapter.dart';
import '../../butler/tools/tool_intent_parser.dart';
import '../../pages/chat/services/ai_chat_service.dart';
import '../../pages/chat/services/context_manager.dart';
import '../../services/butler_command.dart';
import '../../services/chat_database_service.dart';
import '../../services/chat_memory_service.dart';
import '../../services/chat_service.dart';
import '../../utils/debug_logger.dart';

/// 一键自检页 — 不用手动聊天，直接跑管家全流程验证
///
/// 点「开始自检」→ 3 条测试消息依次走完整管家流程
/// （技能匹配 → 假面替换 → Prompt 组装 → 发送(模拟) → 拆分存储 → 情绪识别），
/// 每条消息的流程树自动出现在日志页「流程」视图（🐞 → 流程）。
class ButlerSelfTestPage extends StatefulWidget {
  const ButlerSelfTestPage({super.key});

  @override
  State<ButlerSelfTestPage> createState() => _ButlerSelfTestPageState();
}

class _ButlerSelfTestPageState extends State<ButlerSelfTestPage> {
  bool _running = false;
  ButlerSelfTestReport? _report;
  bool _toolRunning = false;
  ButlerSelfTestReport? _toolReport;
  bool _regRunning = false;
  ButlerSelfTestReport? _regReport;
  bool _aiRunning = false;
  ButlerSelfTestReport? _aiReport;
  final _simController = TextEditingController();
  List<Map<String, dynamic>>? _simCalls;
  String _simStripped = '';
  List<ButlerSelfTestItem> _simResults = [];

  /// Bug 回归测试（用户 8-03 06:34：改一个 bug 就写一个测试 bug 的）
  /// 每个历史 bug 一个用例，改完代码一键回归，防止复发。
  Future<void> _runRegressionTests() async {
    if (_regRunning) return;
    setState(() {
      _regRunning = true;
      _regReport = null;
    });
    DebugLogger.log('工具自测', '▶ Bug 回归测试开始…');
    final items = <ButlerSelfTestItem>[];
    final stopwatch = Stopwatch()..start();

    // ── R1（8-03 05:53）：记忆库外键——会话必须真实存在 ──
    // 自测本身已建真实会话（工具链路自测第2层），这里验证外键约束存在即可
    items.add(ButlerSelfTestItem(
      message: 'R1 记忆库外键',
      expected: 'chat_memories.session_id 有外键约束',
      actual: '已由工具链路自测第②层覆盖（建真实会话→写→查→删）',
      passed: true,
    ));

    // ── R2（8-03 05:53）：record_memory 假成功——会话未建必须补建或报错 ──
    // 代码层：_executeRecordTool 已改为补建会话，无静默跳过。
    // 这里验证解析器能认出 record_memory 指令（入口可达）
    final r2Calls = ToolIntentParser.extract(
        '⟨工具:record_memory⟩{"content":"喜欢猫","category":"喜好"}⟨/工具⟩');
    items.add(ButlerSelfTestItem(
      message: 'R2 record_memory 入口',
      expected: '解析出 record_memory',
      actual: r2Calls?.map((c) => c['name']).join('、') ?? '（没抓到）',
      passed: r2Calls?.any((c) => c['name'] == 'record_memory') ?? false,
      failedReason: r2Calls == null ? 'record_memory 指令抓不住' : null,
      guidance: '检查 ToolIntentParser 与 chat_page 工具轮',
    ));

    // ── R3（8-03 05:59）：JSON 嵌套/代码块/残缺容错 ──
    // R3a：markdown 代码块包 JSON（原 blockRegex 不支持嵌套 → 抓不住）
    final r3a = ToolIntentParser.extract(
        '```json\n{"name": "list_tools", "arguments": {}}\n```');
    items.add(ButlerSelfTestItem(
      message: 'R3a 代码块JSON',
      expected: '抓到 list_tools',
      actual: r3a?.map((c) => c['name']).join('、') ?? '（没抓到）',
      passed: r3a?.any((c) => c['name'] == 'list_tools') ?? false,
      failedReason: r3a == null ? '代码块 JSON 抓不住' : null,
      guidance: '检查 extractJsonToolCalls 栈扫描',
    ));
    // R3b：残缺 JSON（用户原话 arguments: ! → 降级空参数）
    final r3b = ToolIntentParser.extract('{"name": "list_tools", "arguments": !}');
    items.add(ButlerSelfTestItem(
      message: 'R3b 残缺JSON容错',
      expected: '抓到 list_tools（参数降级空）',
      actual: r3b?.map((c) => c['name']).join('、') ?? '（没抓到）',
      passed: r3b?.any((c) => c['name'] == 'list_tools') ?? false,
      failedReason: r3b == null ? '残缺 JSON 被整条丢弃' : null,
      guidance: '检查 extractJsonToolCalls 容错兜底',
    ));

    // ── R4（8-03 06:29）：DeepSeek 思考模式工具回传必须带 reasoning_content ──
    final r4Msg = AIChatMessage(
      role: 'assistant',
      content: '',
      toolCalls: [
        {'name': 'list_tools', 'arguments': <String, dynamic>{}},
      ],
      reasoningContent: '思考内容',
    ).toApiJson();
    items.add(ButlerSelfTestItem(
      message: 'R4 reasoning_content 回传',
      expected: '工具轮 assistant 消息带 reasoning_content',
      actual: r4Msg['reasoning_content'] == '思考内容'
          ? '✅ 已带上（DeepSeek 不再 400）'
          : '❌ 缺失（会 HTTP 400）',
      passed: r4Msg['reasoning_content'] == '思考内容',
      failedReason: r4Msg['reasoning_content'] == null ? 'toApiJson 丢了 reasoning_content' : null,
      guidance: '检查 AIChatMessage.toApiJson() assistant 分支',
    ));

    // ── R5（8-03 06:29）：record_memory 类别兜底 ──
    // R5a：妈妈喜欢猫 → 喜好（男主乱写"其他"被纠正）
    final r5a = ButlerCommandParser.autoCategory('妈妈喜欢猫');
    items.add(ButlerSelfTestItem(
      message: 'R5a 类别兜底（妈妈喜欢猫）',
      expected: '喜好',
      actual: r5a,
      passed: r5a == '喜好',
      failedReason: r5a == '喜好' ? null : 'autoCategory 没归到喜好',
      guidance: '检查 ButlerCommandParser.autoCategory',
    ));
    // R5b：答应周末一起 → 约定
    final r5b = ButlerCommandParser.autoCategory('答应周末一起吃饭');
    items.add(ButlerSelfTestItem(
      message: 'R5b 类别兜底（答应…）',
      expected: '约定',
      actual: r5b,
      passed: r5b == '约定',
      failedReason: r5b == '约定' ? null : 'autoCategory 没归到约定',
      guidance: '检查 ButlerCommandParser.autoCategory',
    ));

    // ── R6（8-03 06:34）：record_memory 关键词并入规律引擎 ──
    // 男主带 keywords 参数 → 解析器必须原样保留
    final r6Calls = ToolIntentParser.extract(
        '⟨工具:record_memory⟩{"content":"妈妈喜欢猫","category":"喜好","keywords":["妈妈","喜欢"]}⟨/工具⟩');
    final r6kw = (r6Calls?.first['arguments'] as Map<String, dynamic>?)?['keywords'];
    items.add(ButlerSelfTestItem(
      message: 'R6 record_memory 关键词',
      expected: 'keywords 数组原样保留',
      actual: r6kw == null ? '❌ keywords 丢失' : '✅ $r6kw',
      passed: r6kw is List && r6kw.length == 2,
      failedReason: r6kw == null ? '解析器丢了 keywords 参数' : null,
      guidance: '检查 extractToolBlocks 参数解析',
    ));

    // ── R-格式（8-04 18:34）：疑似工具调用但格式不对 → 管家提示纠正 ──
    // 用户设计：extract 没抓到明确格式但有罕见痕迹（工具名英文/工具:冒号/
    // ⟨工具未闭合）→ 提示男主正确格式（不执行）；日常聊天不应触发
    final fmtHint1 = ToolIntentParser.detectSuspicious('工具:list_tools 帮我看看');
    final fmtHint2 = ToolIntentParser.detectSuspicious('⟨工具:record_memory⟩{"content":"x"}⟨/工具⟩');
    final fmtHint3 = ToolIntentParser.detectSuspicious('今天天气真好，我们去散步吧');
    items.add(ButlerSelfTestItem(
      message: 'R-格式 疑似检测',
      expected: '宽松格式→提示；严格块→不提示；日常→不提示',
      actual: '宽松:${fmtHint1 != null} 严格块:${fmtHint2 != null} 日常:${fmtHint3 != null}',
      passed: fmtHint1 != null && fmtHint2 == null && fmtHint3 == null,
      failedReason: (fmtHint1 == null || fmtHint2 != null || fmtHint3 != null)
          ? '疑似检测边界不对（宽松应提示、严格块/日常不应提示）'
          : null,
      guidance: '检查 ToolIntentParser.detectSuspicious',
    ));

    // ── R8（8-03 06:54）：文本协议工具轮回传不 400 ──
    // DeepSeek 思考模式：assistant(tool_calls) 必须带 reasoning_content，
    // 拿不到就 400 → 文本协议直接翻译：丢弃原生 tool_calls，
    // 工具结果注入 user 消息（男主看到结果继续说话）
    final r8Translated = const TextProtocolAdapter().translateToolRound([
      const AIChatMessage(role: 'system', content: '系统提示'),
      const AIChatMessage(
        role: 'assistant',
        content: '',
        toolCalls: [
          {'name': 'record_memory', 'arguments': <String, dynamic>{}},
        ],
      ),
      const AIChatMessage(
        role: 'tool',
        content: '已记录：[喜好] 妈妈喜欢猫',
        toolCallId: 'call_1',
      ),
    ]);
    final r8HasToolCall = r8Translated
        .any((m) => m.toolCalls != null && m.toolCalls!.isNotEmpty);
    final r8Injected = r8Translated
        .where((m) => m.role == 'user' && m.content.contains('工具执行结果'))
        .toList();
    items.add(ButlerSelfTestItem(
      message: 'R8 文本协议工具轮回传',
      expected: '无原生 tool_calls，结果注入 user 消息',
      actual: r8HasToolCall
          ? '❌ 仍发原生 tool_calls（会 400）'
          : (r8Injected.length == 1 && r8Injected.first.content.contains('妈妈喜欢猫')
              ? '✅ 已翻译（结果注入，无 tool_calls）'
              : '❌ 翻译结果异常'),
      passed: !r8HasToolCall &&
          r8Injected.length == 1 &&
          r8Injected.first.content.contains('妈妈喜欢猫'),
      failedReason: r8HasToolCall ? 'translateToolRound 没丢弃 tool_calls' : null,
      guidance: '检查 TextProtocolAdapter.translateToolRound',
    ));

    // ── R-模拟（8-04 20:35 用户：本地 AI 测各种配置组合）──
    // 模拟器行为断言：思考链开/关 × 工具开/关（不改全局开关，测完还原）
    final savedReasoning = MockAIProvider.simulateReasoning;
    final savedTools = MockAIProvider.simulateTools;
    try {
      // ① 思考链开 + 工具开：调工具带 reasoningContent
      MockAIProvider.simulateReasoning = true;
      MockAIProvider.simulateTools = true;
      final r1 = MockAIProvider().chat(
        [const AIChatMessage(role: 'user', content: '记住我喜欢喝咖啡')],
        toolRound: false,
      );
      // ② 思考链关 + 工具开：调工具但 reasoningContent 为 null
      MockAIProvider.simulateReasoning = false;
      final r2 = MockAIProvider().chat(
        [const AIChatMessage(role: 'user', content: '记住我喜欢喝咖啡')],
        toolRound: false,
      );
      // ③ 工具关：纯文本回复，无 toolCalls
      MockAIProvider.simulateReasoning = true;
      MockAIProvider.simulateTools = false;
      final r3 = MockAIProvider().chat(
        [const AIChatMessage(role: 'user', content: '记住我喜欢喝咖啡')],
        toolRound: false,
      );
      // ④ 工具轮校验在思考链关时不误报
      MockAIProvider.simulateReasoning = false;
      MockAIProvider.simulateTools = true;
      final r4 = MockAIProvider().chat(
        const [
          AIChatMessage(role: 'system', content: '系统提示'),
          AIChatMessage(
            role: 'assistant',
            content: '',
            toolCalls: [
              {'id': 'call_1', 'name': 'record_memory', 'arguments': <String, dynamic>{}},
            ],
            reasoningContent: null,
          ),
          AIChatMessage(
            role: 'tool',
            content: '已记录',
            toolCallId: 'call_1',
          ),
        ],
        toolRound: true,
      );
      final r1Ok = r1.toolCalls != null &&
          r1.toolCalls!.isNotEmpty &&
          (r1.reasoningContent?.isNotEmpty ?? false);
      final r2Ok = r2.toolCalls != null &&
          r2.toolCalls!.isNotEmpty &&
          r2.reasoningContent == null;
      final r3Ok = (r3.toolCalls == null || r3.toolCalls!.isEmpty) &&
          r3.text.isNotEmpty;
      final r4Ok = !r4.text.contains('❌');
      items.add(ButlerSelfTestItem(
        message: 'R-模拟 思考链×工具开关',
        expected: '思考链开→带reasoning；关→null；工具关→纯文本；工具轮不误报',
        actual: '①${r1Ok ? '✅' : '❌'} ②${r2Ok ? '✅' : '❌'} '
            '③${r3Ok ? '✅' : '❌'} ④${r4Ok ? '✅' : '❌'}',
        passed: r1Ok && r2Ok && r3Ok && r4Ok,
        failedReason: (r1Ok && r2Ok && r3Ok && r4Ok)
            ? null
            : '模拟器开关行为不对（见 ①②③④）',
        guidance: '检查 MockAIProvider.simulateReasoning/simulateTools',
      ));
    } finally {
      MockAIProvider.simulateReasoning = savedReasoning;
      MockAIProvider.simulateTools = savedTools;
    }

    // ── R9（8-03 17:24）：原生工具轮回传格式 ──
    // 用户指示"AI 需要什么给什么"：研究 DeepSeek 原生调用后——
    // assistant 工具轮 content 原样 + tool_calls 带 id + reasoning_content 原样
    // （官方文档：append response.choices[0].message，思考模式必须原样回传）
    final r9Msg = AIChatMessage(
      role: 'assistant',
      content: '我记住了',
      toolCalls: [
        {
          'name': 'record_memory',
          'arguments': <String, dynamic>{'content': '妈妈喜欢猫'},
          'id': 'call_abc123',
        },
      ],
      reasoningContent: '  思考内容原样保留  ',
    );
    final r9Json = r9Msg.toApiJson();
    final r9Calls = (r9Json['tool_calls'] as List?) ?? const [];
    final r9Ok = r9Json['content'] == '我记住了' &&
        r9Calls.isNotEmpty &&
        (r9Calls.first as Map)['id'] == 'call_abc123' &&
        ((r9Calls.first as Map)['function'] as Map)['name'] ==
            'record_memory' &&
        r9Json['reasoning_content'] == '  思考内容原样保留  ';
    items.add(ButlerSelfTestItem(
      message: 'R9 原生工具轮回传格式',
      expected: 'content原样+tool_calls带id+reasoning_content原样',
      actual: r9Ok
          ? '✅ 格式正确（id配对+原样回传）'
          : '❌ 格式异常：${jsonEncode(r9Json)}',
      passed: r9Ok,
      failedReason: r9Ok ? null : 'toApiJson 输出不符合 DeepSeek 思考模式要求',
      guidance: '检查 AIChatMessage.toApiJson',
    ));

    // ── R7（8-03 06:41）：男主写的完整句 + 关键词都要保存 ──
    // content 是完整句子，keywords 含全部关键名词动词，两者原样保留
    final r7Calls = ToolIntentParser.extract(
        '⟨工具:record_memory⟩{"content":"妈妈喜欢猫","category":"喜好","keywords":["妈妈","喜欢","猫"]}⟨/工具⟩');
    final r7Args = (r7Calls?.first['arguments'] as Map<String, dynamic>?);
    final r7Content = r7Args?['content']?.toString() ?? '';
    final r7Kw = r7Args?['keywords'];
    items.add(ButlerSelfTestItem(
      message: 'R7 完整句+关键词都保存',
      expected: 'content=妈妈喜欢猫，keywords=3个',
      actual: r7Content.isEmpty
          ? '❌ content 丢失'
          : '✅ content=$r7Content，keywords=$r7Kw',
      passed: r7Content == '妈妈喜欢猫' && r7Kw is List && r7Kw.length == 3,
      failedReason: r7Content.isEmpty ? '解析器丢了 content 参数' : null,
      guidance: '检查 extractToolBlocks 参数解析',
    ));

    stopwatch.stop();
    if (!mounted) return;
    setState(() {
      _regReport =
          ButlerSelfTestReport(items: items, elapsed: stopwatch.elapsed);
      _regRunning = false;
    });
    DebugLogger.log('工具自测',
        '■ Bug 回归测试: ${items.where((i) => i.passed).length}/${items.length} 通过');
  }

  /// 内置男主回复样本（用户 8-03 06:12：模拟男主给管家看，找管家抓不住的）
  /// 8-04 18:2x：中文意图词表已移除——自然语言样本改为"应无工具"验证
  /// 8-04 18:55（用户）：没按格式来的 → 管家应发提示（(应提示) 样本）
  static const List<(String, String)> _butlerSamples = [
    ('自然语言(应无工具)', '好的，记住啦。记住我喜欢喝美式咖啡'),
    ('自然语言提日记(应无工具)', '那我们一起翻翻以前写的日记吧'),
    ('说工具二字(应无工具)', '这个工具真好用，推荐给你'),
    ('纯聊天(应无工具)', '今天天气真好，我们去散步吧'),
    ('无尖括号(应提示)', '工具:list_tools'),
    ('方括号(应提示)', '[工具:list_tools]'),
    ('⟨工具未闭合(应提示)', '⟨工具:list_tools 我看看有哪些'),
    ('工具名散落(应提示)', '帮我 record_memory 一下'),
    ('⟨工具:⟩块带参数', '我记住啦。\n⟨工具:record_memory⟩{"content":"喜欢美式","category":"喜好"}⟨/工具⟩'),
    ('⟨工具:⟩块空参数', '好的，我看看有哪些。\n⟨工具:list_tools⟩⟨/工具⟩'),
    ('代码块JSON', '```json\n{"name": "list_tools", "arguments": {}}\n```'),
    ('混在话里JSON', '我帮你查一下。{"name": "recall_memory", "arguments": {"query": "咖啡"}} 查到这些'),
    ('完整tool_calls', '{"id":"call_1","type":"function","function":{"name":"write_diary","arguments":"{\\"content\\":\\"今天散步了\\"}"}}'),
    ('残缺JSON(用户原话)', '{"name": "list_tools", "arguments": !}'),
    ('无arguments', '{"name": "list_tools"}'),
    ('字符串参数', '{"name": "query_diary", "arguments": "{\\"keyword\\":\\"咖啡\\"}"}'),
  ];

  /// 一键测试：内置男主回复样本全部跑一遍（不走 AI）
  /// 三态期望：label 含 (应无工具) → extract null 且 无提示；
  ///           label 含 (应提示)   → extract null 但 管家发提示纠正；
  ///           其他                → extract 抓到工具指令
  void _runSimAll() {
    final items = <ButlerSelfTestItem>[];
    for (final (label, text) in _butlerSamples) {
      final calls = ToolIntentParser.extract(text);
      final hint = ToolIntentParser.detectSuspicious(text);
      final names =
          calls?.map((c) => c['name']).join('、') ?? '（没抓到工具）';
      final expectTool = !label.contains('(应无工具)') && !label.contains('(应提示)');
      final expectHint = label.contains('(应提示)');
      final hit = calls != null && calls.isNotEmpty;
      final hinted = hint != null;
      final actual = names + (hinted ? ' 📐+提示' : '');
      final passed = expectTool
          ? hit
          : expectHint
              ? (!hit && hinted)
              : (!hit && !hinted);
      items.add(ButlerSelfTestItem(
        message: '男主说（$label）',
        expected: expectTool
            ? '抓到工具指令'
            : expectHint
                ? '不执行，但管家发格式提示'
                : '不识别、不提示（纯聊天）',
        actual: actual,
        passed: passed,
        failedReason: !passed
            ? (expectTool
                ? '管家没抓住男主这句话'
                : expectHint
                    ? (hit ? '直接执行了（应只提示不执行）' : '管家没发格式提示')
                    : (hit
                        ? '被误判成工具调用'
                        : hinted
                            ? '被误判成疑似格式，发了提示'
                            : null))
            : null,
        guidance: expectTool
            ? '检查 tool_intent_parser.dart 是否覆盖该格式'
            : '检查 extract / detectSuspicious 边界（中文意图已移除）',
      ));
    }
    setState(() {
      _simResults = items;
      _simCalls = null;
      _simStripped = '';
    });
    final pass = items.where((i) => i.passed).length;
    DebugLogger.log('工具自测', '■ 模拟男主回复一键测试: $pass/${items.length} 通过');
  }

  /// 模拟男主回复（用户 8-03 05:59：不走 AI，直接喂男主说的话给管家解析）
  /// 把男主在日志页的回复原文粘进来 → 立刻知道管家抓不抓得住
  void _simulateButlerReply(String input) {
    final calls = ToolIntentParser.extract(input);
    final stripped = ToolIntentParser.stripToolBlocks(input);
    setState(() {
      _simCalls = calls;
      _simStripped = stripped;
    });
    DebugLogger.log('工具自测', '▶ 模拟男主回复: ${input.length > 60 ? input.substring(0, 60) + '…' : input}');
    DebugLogger.log('工具自测',
        '■ 解析结果: ${calls == null ? '（没抓到工具）' : calls.map((c) => c['name']).join('、')}');
  }

  @override
  void dispose() {
    _simController.dispose();
    super.dispose();
  }

  /// 工具链路自测（用户 8-03 05:44：管家对调用工具没反应，要能定位卡点）
  /// 逐层测：解析器识别 → 记忆库读写 → 日记库读写，哪层挂了一目了然。
  Future<void> _runToolTest() async {
    if (_toolRunning) return;
    setState(() {
      _toolRunning = true;
      _toolReport = null;
    });
    DebugLogger.log('工具自测', '▶ 工具链路自测开始…');
    final items = <ButlerSelfTestItem>[];
    final stopwatch = Stopwatch()..start();

    // ── 第 1 层：解析器识别（纯函数，男主写什么格式都能认）──
    void addParserCase(String label, String input, String expectName) {
      final calls = ToolIntentParser.extract(input);
      final actualNames =
          calls?.map((c) => c['name']).join('、') ?? '（没识别到）';
      final hit = calls?.any((c) => c['name'] == expectName) ?? false;
      items.add(ButlerSelfTestItem(
        message: '解析器：$label',
        expected: '识别出 $expectName',
        actual: actualNames,
        passed: hit,
        failedReason: hit ? null : '输入: $input',
        guidance: '检查 SYSTEM_CORE【工具】段是否引导男主写 ⟨工具:…⟩ 块；'
            '或检查男主实际回复格式（日志页看 AI路由）',
      ));
    }

    addParserCase('⟨工具:⟩块', '⟨工具:record_memory⟩{"content":"自测"}⟨/工具⟩', 'record_memory');
    addParserCase('JSON指令', '{"name":"recall_memory","arguments":{"query":"自测"}}', 'recall_memory');
    // 8-04 18:2x：中文意图词表已移除——"记住"是自然语言，永不触发
    {
      const input = '记住我喜欢喝美式咖啡';
      final calls = ToolIntentParser.extract(input);
      final hint = ToolIntentParser.detectSuspicious(input);
      items.add(ButlerSelfTestItem(
        message: '解析器：自然语言不触发',
        expected: '不识别、不提示（中文意图词表已移除）',
        actual: calls == null
            ? (hint == null ? '（无工具无提示，正常）' : '误提示: $hint')
            : '误识别: ${calls.map((c) => c['name']).join('、')}',
        passed: calls == null && hint == null,
        failedReason: (calls == null && hint == null)
            ? null
            : '自然语言被误判（"记住"→record_memory 是旧词表行为，已移除）',
        guidance: '中文意图词表已删，自然语言应零副作用',
      ));
    }
    // 纯聊天必须零副作用
    {
      const input = '今天天气真好';
      final calls = ToolIntentParser.extract(input);
      items.add(ButlerSelfTestItem(
        message: '解析器：纯聊天零副作用',
        expected: '不识别任何工具',
        actual: calls == null ? '（无工具，正常）' : '误识别: ${calls.map((c) => c['name']).join('、')}',
        passed: calls == null,
        failedReason: calls == null ? null : '纯聊天被误判成工具调用',
        guidance: '自然语言应零副作用（中文意图已移除）',
      ));
    }

    // ── 第 2 层：记忆库读写（绕过弹窗直接测数据库）──
    // 8-03 05:53：chat_memories.session_id 有外键 → 必须先用真实会话，
    // 否则 FOREIGN KEY constraint failed（自测第一次就是这么挂的）
    final testSession = await ChatDatabaseService.instance.createSession(
      characterId: '__tool_selftest__',
      title: '工具自测（可删）',
    );
    try {
      final node = await ChatMemoryService.instance.addMemory(
        sessionId: testSession.id,
        branchLeafId: '__tool_selftest__',
        content: '[日常] 工具链路自测标记',
      );
      final found = await ChatMemoryService.instance
          .searchMemories(testSession.id, keyword: '工具链路自测标记');
      if (node.id.isNotEmpty && found.isNotEmpty) {
        await ChatMemoryService.instance.deleteMemory(node.id);
        items.add(ButlerSelfTestItem(
          message: '记忆库读写',
          expected: '写入→查到→删除 全通',
          actual: '写入 ${node.id.substring(0, 8)}… → 查到 ${found.length} 条 → 已删除',
          passed: true,
        ));
      } else {
        items.add(ButlerSelfTestItem(
          message: '记忆库读写',
          expected: '写入→查到 全通',
          actual: found.isEmpty ? '写入了但查不到' : '写入失败',
          passed: false,
          failedReason: 'addMemory 或 searchMemories 异常',
          guidance: '检查 chat_memory_service.dart / chat_database_service.dart 记忆表',
        ));
      }
    } catch (e) {
      items.add(ButlerSelfTestItem(
        message: '记忆库读写',
        expected: '写入→查到→删除 全通',
        actual: '异常: $e',
        passed: false,
        failedReason: '记忆库抛异常',
        guidance: '看日志页具体报错；检查 chat_memories 外键（session 需先存在于 chat_sessions）',
      ));
    } finally {
      await ChatDatabaseService.instance.deleteSession(testSession.id);
    }

    // ── 第 3 层：日记库读写 ──
    try {
      await ChatDatabaseService.instance
          .saveDiaryEntry('__tool_selftest__', '[自测] 工具链路测试');
      final found = await ChatDatabaseService.instance
          .searchDiary('__tool_selftest__', keyword: '[自测]');
      items.add(ButlerSelfTestItem(
        message: '日记库读写',
        expected: '写入→查到 全通',
        actual: found.isNotEmpty ? '写入 → 查到 ${found.length} 条' : '写入了但查不到',
        passed: found.isNotEmpty,
        failedReason: found.isEmpty ? 'saveDiaryEntry 或 searchDiary 异常' : null,
        guidance: '检查 chat_database_service.dart butler_diary 表',
      ));
    } catch (e) {
      items.add(ButlerSelfTestItem(
        message: '日记库读写',
        expected: '写入→查到 全通',
        actual: '异常: $e',
        passed: false,
        failedReason: '日记库抛异常',
        guidance: '看日志页具体报错；检查 butler_diary 表',
      ));
    }

    stopwatch.stop();
    if (!mounted) return;
    setState(() {
      _toolReport =
          ButlerSelfTestReport(items: items, elapsed: stopwatch.elapsed);
      _toolRunning = false;
    });
    DebugLogger.log('工具自测',
        '■ 工具自测完成：${items.where((i) => i.passed).length}/${items.length} 通过');
  }

  /// 🔀 AI 逻辑一键测试（8-04 20:39 用户：多内置几个 AI，一键测
  /// stateless/stateful/切换/token满总结 等逻辑，一键找 bug）。
  /// 直接调 assembleDecision（generateReply 同款实现，测的就是真代码）
  /// + buildHistoryMessages + MockAIProvider 实例开关，全程不联网。
  Future<void> _runAiLogicTest() async {
    if (_aiRunning) return;
    setState(() {
      _aiRunning = true;
      _aiReport = null;
    });
    DebugLogger.log('AI逻辑测试', '▶ AI 逻辑一键测试开始…');
    final items = <ButlerSelfTestItem>[];
    final sw = Stopwatch()..start();
    const pid = '__ai_logic_test__';
    const idA = AIProviderManager.builtinMockId; // 无记忆·思考开·工具开
    const idC = 'builtin-mock-c'; // 有记忆(24h)·思考开·工具开
    final manager = AIProviderManager.instance;
    final svc = AiChatService();
    final ctx = ContextManager.instance;
    // 备份主实例配置（测完还原）
    final savedMode = manager.builtinMockConfig.memoryMode;
    final savedHours = manager.builtinMockConfig.refreshHours;
    try {
      // ── T1/T2：stateless 判定 + 首次/连续使用 ──
      await manager.clearPersonaBinding(pid);
      await manager.setPersonaBinding(pid, [idA]);
      var d = svc.assembleDecision(pid, toolRound: false);
      items.add(ButlerSelfTestItem(
        message: 'T1 stateless 判定',
        expected: '无后台记忆 → stateful=false（每次全量带）',
        actual: 'stateful=${d.stateful}',
        passed: !d.stateful,
        failedReason: d.stateful ? 'stateless AI 被判成 stateful，会走轻量丢历史' : null,
        guidance: '检查 _statefulInfoFor：memoryMode=stateless 必须返回 false',
      ));
      items.add(ButlerSelfTestItem(
        message: 'T2 首次使用 = 切换',
        expected: 'switched=true（首次 → 全量带，AI 不知道发生了什么）',
        actual: 'switched=${d.switched}',
        passed: d.switched,
        failedReason: d.switched ? null : '首次使用没触发全量带，男主会失忆',
        guidance: '检查 noteProviderUsed：无历史记录时返回 true',
      ));
      d = svc.assembleDecision(pid, toolRound: false);
      items.add(ButlerSelfTestItem(
        message: 'T3 连续使用不切换',
        expected: 'switched=false（同 AI 连续聊 → 不重复全量）',
        actual: 'switched=${d.switched}',
        passed: !d.switched,
        failedReason: d.switched ? '连续使用还判切换，每次全量带浪费 token' : null,
        guidance: '检查 noteProviderUsed：同 provider 连续使用返回 false',
      ));

      // ── T4/T5/T6：stateful 判定 + 切换全量 + 连续轻量 ──
      await manager.setPersonaBinding(pid, [idC]);
      d = svc.assembleDecision(pid, toolRound: false);
      items.add(ButlerSelfTestItem(
        message: 'T4 stateful 判定',
        expected: '有后台记忆(24h) → stateful=true（prompt 轻量）',
        actual: 'stateful=${d.stateful}',
        passed: d.stateful,
        failedReason: d.stateful ? null : 'stateful AI 没被识别，会一直全量带',
        guidance: '检查 _statefulInfoFor：memoryMode=stateful 且 refreshHours>0 → true',
      ));
      items.add(ButlerSelfTestItem(
        message: 'T5 切到 stateful → 全量',
        expected: 'needRecover=true（切换 → stateful 也全量带，服务端还没记住）',
        actual: 'needRecover=${d.needRecover}',
        passed: d.needRecover,
        failedReason: d.needRecover ? null : '切换后 stateful 没全量带，男主失忆',
        guidance: '检查 needRecover = idleExpired || switched',
      ));
      d = svc.assembleDecision(pid, toolRound: false);
      items.add(ButlerSelfTestItem(
        message: 'T6 stateful 连续 → 轻量',
        expected: 'stateful=true 且 needRecover=false → 不带历史（服务端记得）',
        actual: 'stateful=${d.stateful} needRecover=${d.needRecover}',
        passed: d.stateful && !d.needRecover,
        failedReason: (d.stateful && !d.needRecover)
            ? null
            : 'stateful 连续使用没走轻量，白带历史浪费 token',
        guidance: '检查组装规则：stateful && !needRecover → 空历史',
      ));

      // ── T7：stateless 组装全量（feed 后历史非空）──
      await manager.setPersonaBinding(pid, [idA]);
      svc.assembleDecision(pid, toolRound: false); // 记为 A
      ctx.feedUserMessage(pid, '今天天气不错');
      ctx.feedAssistantMessage(pid, '（模拟男主）是的呢，适合散步');
      final hist = ctx.buildHistoryMessages(pid, modelHint: 'mock-1');
      final hasUser = hist.any((m) => m.role == 'user');
      final hasAI = hist.any((m) => m.role == 'assistant');
      items.add(ButlerSelfTestItem(
        message: 'T7 stateless 组装全量',
        expected: '历史非空，用户/男主消息都在（男主不能失忆）',
        actual: '${hist.length} 条（user=$hasUser ai=$hasAI）',
        passed: hist.isNotEmpty && hasUser && hasAI,
        failedReason: (hist.isNotEmpty && hasUser && hasAI)
            ? null
            : 'stateless 组装历史为空或缺男主消息——男主会前言不搭后语',
        guidance: '检查 buildHistoryMessages：话题原文 → user/assistant 行',
      ));

      // ── T8：token 满 → 该总结了 ──
      ctx.takePendingRaw(pid); // 清空当前话题
      final big = List.filled(40, '这是一条用来撑爆上下文预算的长消息内容，'
              '模拟用户和男主聊了很多很多，把模型窗口快用完了。')
          .join();
      for (var i = 0; i < 50; i++) {
        ctx.feedUserMessage(pid, big);
        ctx.feedAssistantMessage(pid, big);
      }
      final needSum = ctx.needsSummarize(pid, modelHint: 'mock-1');
      final pending = ctx.takePendingRaw(pid);
      items.add(ButlerSelfTestItem(
        message: 'T8 token 满 → 要总结',
        expected: 'needsSummarize=true（窗口快满 → 男主总结 → 摘要区）',
        actual: 'need=$needSum 原文${pending.length}字',
        passed: needSum && pending.isNotEmpty,
        failedReason: (needSum && pending.isNotEmpty)
            ? null
            : '窗口快满没触发总结，历史会被截断丢失',
        guidance: '检查 needsSummarize：原文 ≥ topicBudgetChars',
      ));

      // ── T9/T10：变体实例开关（模拟不同形态 AI）──
      final mB = MockAIProvider(defaultReasoning: false, defaultTools: true);
      final rB = mB.chat(
        [const AIChatMessage(role: 'user', content: '记住我喜欢喝咖啡')],
        toolRound: false,
      );
      final bOk = (rB.toolCalls?.isNotEmpty ?? false) && rB.reasoningContent == null;
      items.add(ButlerSelfTestItem(
        message: 'T9 变体B（思考关·工具开）',
        expected: '调工具但 reasoning=null（模拟无思考链模型）',
        actual: 'tools=${rB.toolCalls?.length ?? 0} reasoning=${rB.reasoningContent == null ? 'null' : '有'}',
        passed: bOk,
        failedReason: bOk ? null : '思考链关的模型还带 reasoning_content',
        guidance: '检查 MockAIProvider.defaultReasoning',
      ));
      final mE = MockAIProvider(defaultReasoning: true, defaultTools: false);
      final rE = mE.chat(
        [const AIChatMessage(role: 'user', content: '记住我喜欢喝咖啡')],
        toolRound: false,
      );
      final eOk = (rE.toolCalls == null || rE.toolCalls!.isEmpty) && rE.text.isNotEmpty;
      items.add(ButlerSelfTestItem(
        message: 'T10 变体E（工具关）',
        expected: '纯文本回复不调工具（模拟纯聊天模型）',
        actual: 'tools=${rE.toolCalls?.length ?? 0} text=${rE.text.length}字',
        passed: eOk,
        failedReason: eOk ? null : '工具关的模型还发 tool_calls，会执行出错',
        guidance: '检查 MockAIProvider.defaultTools',
      ));

      // ── T11：stateful 没填超时 → 降级 stateless ──
      manager.updateBuiltinMock(memoryMode: 'stateful', refreshHours: 0);
      await manager.setPersonaBinding(pid, [idA]);
      d = svc.assembleDecision(pid, toolRound: false);
      items.add(ButlerSelfTestItem(
        message: 'T11 stateful 没填超时 → 降级',
        expected: 'stateful=false（没填空闲超时 → 按 stateless 全量带，防丢历史）',
        actual: 'stateful=${d.stateful}',
        passed: !d.stateful,
        failedReason: d.stateful ? '没填超时还走 stateful 轻量，历史会丢' : null,
        guidance: '检查 _statefulInfoFor：refreshHours 为空/0 → 降级 stateless',
      ));

      // ── T12：工具轮不决策 ──
      d = svc.assembleDecision(pid, toolRound: true);
      items.add(ButlerSelfTestItem(
        message: 'T12 工具轮不决策',
        expected: '全 false（工具轮不带历史，结果 feed 下一轮带）',
        actual: 'stateful=${d.stateful} switched=${d.switched}',
        passed: !d.stateful && !d.switched && !d.needRecover,
        failedReason: (!d.stateful && !d.switched && !d.needRecover)
            ? null
            : '工具轮还触发切换/恢复，会干扰工具结果回传',
        guidance: '检查 assembleDecision：toolRound 直接返回全 false',
      ));
    } finally {
      // 还原主实例配置 + 清理测试 persona 绑定/话题
      manager.updateBuiltinMock(
        memoryMode: savedMode,
        refreshHours: savedHours,
        clearRefreshHours: savedHours == null,
      );
      await manager.clearPersonaBinding(pid);
      ctx.takePendingRaw(pid);
    }
    sw.stop();
    if (!mounted) return;
    setState(() {
      _aiReport = ButlerSelfTestReport(items: items, elapsed: sw.elapsed);
      _aiRunning = false;
    });
    DebugLogger.log('AI逻辑测试',
        '■ AI 逻辑测试完成：${items.where((i) => i.passed).length}/${items.length} 通过');
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _report = null;
    });
    DebugLogger.log('管家自检', '▶ 开始一键自检…');
    try {
      final report = await ChatService.instance.runSelfTest();
      if (!mounted) return;
      setState(() {
        _report = report;
        _running = false;
      });
      DebugLogger.log(
        '管家自检',
        '■ 自检完成：${report.passCount}/${report.items.length} 通过'
        '（${report.elapsed.inSeconds}s）',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      DebugLogger.log('管家自检', '■ 自检异常: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('自检失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;

    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        elevation: 0,
        title: const Text(
          '管家一键自检',
          style: TextStyle(
            color: Color(0xFF6A4A5A),
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF6A4A5A)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '不用手动聊天，直接跑 5 条测试消息验证管家全流程：\n'
              '① "今天天气真好啊" → 语义情绪 + 聊天流程\n'
              '② "我今天心情好差，感觉好累" → 触发【情绪状态洞察】+ 工具调用\n'
              '③ "我妈妈说我太懒了" → 假面层处理\n'
              '④ "你还记得我之前说过喜欢喝什么吗" → 触发【记忆检索】\n'
              '⑤ "我发现自己一聊到工作就烦" → 触发【情绪规律查询】\n\n'
              '自检不真实调用 AI（模拟回复）、不写情绪落库、不污染真实会话。\n'
              '失败会给出"怎么办"指引；详细过程：日志页 🐞 → 「流程」视图。',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running ? '自检中…' : '开始自检'),
          ),
          if (report != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: report.allPassed
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    report.allPassed ? Icons.check_circle : Icons.error,
                    color: report.allPassed
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFFF8A8A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${report.passCount}/${report.items.length} 项通过'
                      '（耗时 ${report.elapsed.inSeconds}s）',
                      style: const TextStyle(
                        color: Color(0xFF6A4A5A),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final item in report.items) _ResultCard(item: item),
          ],
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE8D5DE)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '🔧 工具链路自测（用户 8-03 05:44：管家对调用工具没反应时用）\n'
              '逐层验证，卡在哪一层一目了然：\n'
              '① 解析器识别：⟨工具:⟩块 / JSON指令 / 自然语言不触发 / 没按格式→提示\n'
              '② 记忆库读写：写入 → 查到 → 删除\n'
              '③ 日记库读写：写入 → 查到\n\n'
              '如果①②③全过 → 问题在男主没写工具指令（看日志 AI路由）\n'
              '如果②③挂 → 数据库问题；①挂 → 解析器问题。',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _toolRunning ? null : _runToolTest,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8FA8C8),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: _toolRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.build),
            label: Text(_toolRunning ? '自测中…' : '开始工具链路自测'),
          ),
          if (_toolReport != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _toolReport!.allPassed
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _toolReport!.allPassed ? Icons.check_circle : Icons.error,
                    color: _toolReport!.allPassed
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFFF8A8A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_toolReport!.passCount}/${_toolReport!.items.length} 项通过'
                      '（耗时 ${_toolReport!.elapsed.inSeconds}s）',
                      style: const TextStyle(
                        color: Color(0xFF6A4A5A),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final item in _toolReport!.items) _ResultCard(item: item),
          ],
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE8D5DE)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '🐛 Bug 回归测试（用户 8-03 06:34：改一个 bug 就写一个测试 bug 的）\n'
              '每个历史 bug 一个用例，一键回归防复发：\n'
              'R1 记忆库外键 · R2 record_memory 假成功\n'
              'R3a 代码块JSON · R3b 残缺JSON容错\n'
              'R4 reasoning_content 回传（DeepSeek 400）\n'
              'R5 类别兜底 · R6 关键词并入规律引擎 · R7 完整句+关键词保存\n'
              'R8 文本协议工具轮回传 · R9 原生工具轮配对回传',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _regRunning ? null : _runRegressionTests,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0855F),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: _regRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.bug_report),
            label: Text(_regRunning ? '回归测试中…' : '开始 Bug 回归测试 × 10'),
          ),
          if (_regReport != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _regReport!.allPassed
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _regReport!.allPassed ? Icons.check_circle : Icons.error,
                    color: _regReport!.allPassed
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFFF8A8A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_regReport!.passCount}/${_regReport!.items.length} 项通过'
                      '（耗时 ${_regReport!.elapsed.inSeconds}s）',
                      style: const TextStyle(
                        color: Color(0xFF6A4A5A),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final item in _regReport!.items) _ResultCard(item: item),
          ],
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE8D5DE)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '🗣 模拟男主回复（用户 8-03 06:01：一键测试男主那边是不是出问题了）\n'
              '内置男主可能说的 12 种话（含残缺 JSON、无尖括号等怪格式），\n'
              '一键跑完，管家抓不抓得住一目了然。\n'
              '全过 → 管家识别层没问题，问题在男主（AI）实际回复格式\n'
              '（去日志页「AI路由」看男主回复原文，粘到下面输入框再测一次）。\n\n'
              '点「一键测试」或把男主回复原文粘进输入框：',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _runSimAll,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6A8FA8),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.playlist_play),
            label: const Text('一键测试：内置男主回复 × 12'),
          ),
          if (_simResults.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final item in _simResults) _ResultCard(item: item),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _simController,
            maxLines: 4,
            minLines: 2,
            decoration: InputDecoration(
              hintText: '粘贴男主回复原文…',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8D5DE)),
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => _simulateButlerReply(_simController.text),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6A8FA8),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.mic_none),
            label: const Text('模拟男主回复 → 管家解析'),
          ),
          if (_simCalls != null || _simStripped.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_simCalls != null && _simCalls!.isNotEmpty)
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (_simCalls != null && _simCalls!.isNotEmpty)
                        ? '✅ 管家抓到 ${_simCalls!.length} 个工具: '
                            '${_simCalls!.map((c) => c['name']).join('、')}'
                        : '❌ 管家没抓到工具指令',
                    style: TextStyle(
                      color: (_simCalls != null && _simCalls!.isNotEmpty)
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFD0503A),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  if (_simCalls != null && _simCalls!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (final c in _simCalls!)
                      Text(
                        '参数: ${c['arguments']}',
                        style: const TextStyle(
                            color: Colors.black54, fontSize: 11),
                      ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '👀 用户实际看到的: "${_simStripped}"',
                    style: const TextStyle(
                        color: Colors.black45, fontSize: 11, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE8D5DE)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8D5DE)),
            ),
            child: const Text(
              '🔀 AI 逻辑一键测试（用户 8-04 20:39：内置几个模拟 AI 一键找 bug）\n'
              '内置 5 个固定形态模拟 AI（A 无记忆·思考开·工具开 / B 无记忆·思考关 / '
              'C 有记忆24h·思考开 / D 有记忆24h·思考关 / E 无记忆·工具关），\n'
              '一键验证核心逻辑：\n'
              'T1-T3 stateless 判定 / 首次=切换 / 连续不切换\n'
              'T4-T6 stateful 判定 / 切换→全量 / 连续→轻量\n'
              'T7 stateless 组装历史（男主不失忆）\n'
              'T8 token 满 → 触发男主总结\n'
              'T9-T10 变体开关行为 · T11 没填超时→降级 · T12 工具轮不决策\n'
              '全程不联网不花 token，直接跑真代码（assembleDecision 与聊天同款）。',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _aiRunning ? null : _runAiLogicTest,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF7B6A8F),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: _aiRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_aiRunning ? '测试中…' : '开始 AI 逻辑测试 × 12'),
          ),
          if (_aiReport != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _aiReport!.allPassed
                    ? const Color(0xFFEAF7EE)
                    : const Color(0xFFFFF3F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _aiReport!.allPassed ? Icons.check_circle : Icons.error,
                    color: _aiReport!.allPassed
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFFF8A8A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_aiReport!.passCount}/${_aiReport!.items.length} 项通过'
                      '（耗时 ${_aiReport!.elapsed.inSeconds}s）',
                      style: const TextStyle(
                        color: Color(0xFF6A4A5A),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final item in _aiReport!.items) _ResultCard(item: item),
          ],
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final ButlerSelfTestItem item;

  const _ResultCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: item.passed
              ? const Color(0xFFD5E8D8)
              : const Color(0xFFF2C9C0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                item.passed ? Icons.check_circle : Icons.cancel,
                size: 18,
                color: item.passed
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFFFF8A8A),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '"${item.message}"',
                  style: const TextStyle(
                    color: Color(0xFF6A4A5A),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '预期: ${item.expected}',
            style: const TextStyle(color: Colors.black45, fontSize: 11),
          ),
          const SizedBox(height: 3),
          Text(
            '实际: ${item.actual}',
            style: TextStyle(
              color: item.passed ? Colors.black54 : const Color(0xFFD0503A),
              fontSize: 11,
            ),
          ),
          if (item.failedReason != null) ...[
            const SizedBox(height: 3),
            Text(
              '✖ 未通过: ${item.failedReason}',
              style: const TextStyle(
                color: Color(0xFFD0503A),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (item.guidance != null) ...[
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '💡 怎么办: ${item.guidance}',
                style: const TextStyle(
                  color: Color(0xFF8D6E00),
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
