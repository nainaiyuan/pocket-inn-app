import 'dart:convert';

import 'models.dart';
import 'ai_module_log.dart';

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
  /// 8-04 20:35（用户）：本地模拟 AI 要能模拟各种配置组合——
  /// 思考链开/关、工具调用开/关，配合配置页的 memoryMode 测
  /// stateless/stateful × 思考链 × 工具的排列组合。
  /// 静态开关（配置页"内置模拟 AI"卡片可改，重启还原默认）
  static bool simulateReasoning = true;
  static bool simulateTools = true;

  /// 8-04 20:39（用户）：多内置几个固定形态的模拟 AI，一键测——
  /// 实例级固定开关（变体用）：null = 跟随静态开关（builtin-mock 主实例）
  MockAIProvider({this.defaultReasoning, this.defaultTools});
  final bool? defaultReasoning;
  final bool? defaultTools;

  bool get _reasoning => defaultReasoning ?? simulateReasoning;
  bool get _tools => defaultTools ?? simulateTools;

  /// 上次返回的 assistant 消息摘要（工具轮校验对照用）
  Map<String, dynamic>? _lastAssistant;

  /// 非工具轮：根据最后一条 user 消息内容决定行为（脚本化）
  AIProviderResult chat(
    List<AIChatMessage> messages, {
    required bool toolRound,
  }) {
    AiModuleLog.log('模拟AI', '🤖 模拟AI 收到 ${messages.length} 条消息：');
    for (final m in messages) {
      final extra = (m.toolCalls != null && m.toolCalls!.isNotEmpty)
          ? ' tool_calls=${m.toolCalls!.map((c) => c['name']).join('、')}'
          : (m.toolCallId != null ? ' tool_call_id=${m.toolCallId}' : '');
      final content = m.content.length > 50
          ? '${m.content.substring(0, 50)}…'
          : m.content;
      AiModuleLog.log('模拟AI', '  [${m.role}] $content$extra');
    }

    // 结构检查：发给模型的 user 消息应该只有 1 条（当前消息）
    // 上下文参考必须是 system 消息——如果混进 user/assistant 对话流就是 bug
    if (!toolRound) {
      final userMsgs = messages.where((m) => m.role == 'user').length;
      if (userMsgs > 1) {
        AiModuleLog.log(
          '模拟AI',
          '⚠️ 检测到 $userMsgs 条 user 消息（应该只有 1 条当前消息）——'
              '上下文参考混进对话流了，男主会分不清哪条要回复！',
        );
      }
      final history = messages
          .where((m) => m.role == 'system' && m.content.contains('上下文参考'))
          .toList();
      // 8-04 20:35（用户）：模拟器报告"当前是什么模式"——
      // 上下文参考条数多 = stateless 全量带；几乎空 = stateful 轻量
      if (history.isNotEmpty) {
        final raw = history.first.content;
        final userCount = RegExp(r'\[user\]').allMatches(raw).length;
        final aiCount = RegExp(r'\[assistant\]').allMatches(raw).length;
        final hasSummary = raw.contains('男主摘要');
        final hasRecovery = raw.contains('恢复包');
        AiModuleLog.log(
          '模拟AI',
          '📊 模式报告：上下文参考 用户 $userCount 条 / 男主 $aiCount 条'
              '${hasSummary ? ' / 有摘要' : ''}${hasRecovery ? ' / 有恢复包' : ''}'
              ' → ${userCount == 0 && aiCount == 0 ? '轻量模式（stateful 或首次）' : '全量模式（stateless）'}'
              '${aiCount >= userCount - 1 ? ' ✅ 男主消息在' : ' ❌ 男主消息丢失！'}',
        );
      } else {
        AiModuleLog.log('模拟AI', '📊 模式报告：无上下文参考（轻量模式）');
      }
    }

    if (toolRound) {
      return _handleToolRound(messages);
    }

    // 8-07 14:12（一键测设定剧本⑫）：设定修改多轮会话弹窗内男主回复——
    // 模拟男主"商量后给出新方案"（【新方案】会被弹窗自动填进编辑框）
    final systemText2 = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    if (systemText2.contains('设定修改会话')) {
      // 8-07 15:5x 用户：选项连续点 + 版本结合——mock 剧本：
      // ① 首轮问两个问题（两组选项）
      // ② 用户点选（含"我选"）→ 出 v2（改喜好）
      // ③ 用户再说"再来一版" → 出 v3（加备注段）
      // ④ 用户说"结合" → 出 v4（v2+v3 合并）
      String lastUser2 = '';
      for (final m in messages.reversed) {
        if (m.role == 'user') {
          lastUser2 = m.content;
          break;
        }
      }
      if (lastUser2.contains('结合')) {
        AiModuleLog.log('模拟AI', '💬 设定会话（结合两版）→ 模拟男主出合并版');
        return AIProviderResult(
          text:
              '好，我把两版结合一下，取 v2 的身份和 v3 的备注：\n'
              '【新方案】\n'
              '【身份】测试角色\n'
              '【喜好】测试喜好C\n'
              '【备注】测试备注',
          providerName: '模拟AI',
        );
      }
      if (lastUser2.contains('我选')) {
        // 统计用户消息里"我选"出现次数：第一次 → v2，第二次 → v3
        final pickCount = messages
            .where((m) => m.role == 'user')
            .map((m) => m.content)
            .where((c) => c.contains('我选'))
            .length;
        if (pickCount >= 2) {
          AiModuleLog.log('模拟AI', '💬 设定会话（第二次点选）→ 模拟男主出 v3 加备注');
          return AIProviderResult(
            text:
                '好，这个也定了，我把备注段加上：\n'
                '【新方案】\n'
                '【身份】测试角色\n'
                '【喜好】测试喜好C\n'
                '【备注】测试备注',
            providerName: '模拟AI',
          );
        }
        AiModuleLog.log('模拟AI', '💬 设定会话（选了选项）→ 模拟男主出正式版本 v2');
        return AIProviderResult(
          text:
              '好，就按你选的来，我出正式方案：\n'
              '【新方案】\n'
              '【身份】测试角色\n'
              '【喜好】测试喜好C',
          providerName: '模拟AI',
        );
      }
      AiModuleLog.log('模拟AI', '💬 设定修改会话 → 模拟男主一次问两个问题');
      return AIProviderResult(
        text:
            '我理了一下，有两个问题想先问你，每个给你几个方向，'
            '你可以连着点，也可以自己说：\n'
            '【问题1】身份部分想怎么写？\n'
            '【选项】\n'
            'A. 测试角色\n'
            'B. 测试角色，温柔系\n'
            'C. 其他/我自己说\n'
            '【问题2】喜好部分呢？\n'
            '【选项】\n'
            'A. 测试喜好C\n'
            'B. 测试喜好C，再加点细节\n'
            'C. 其他/我自己说',
        providerName: '模拟AI',
      );
    }

    // 管家内部指令模拟（8-04 21:5x 验收⑤⑦失败修复）：
    // _summarize / _generateAndStoreThree 是 generateReply 直调 chat 的
    // （不走工具轮），mock 必须扮演"会执行指令的男主"——
    // 否则验收 ⑤ 总结 / ⑦ 三类存档 拿到模板回复 = 白写。
    // 关键词与普通聊天 system 无冲突（已验证 system_template 不含）。
    final systemText = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    final allText = messages.map((m) => m.content).join('\n');
    if (systemText.contains('分类整理好')) {
      // _generateAndStoreThree 三类存档指令：写日记 + 摘要 + 恢复包
      AiModuleLog.log('模拟AI', '📦 管家三类存档指令 → 模拟男主写日记+摘要+恢复包');
      return AIProviderResult(
        text:
            '【摘要】\n'
            '周末约好爬山\n'
            '她在学做菜、喜欢蓝色和咖啡\n'
            '【恢复包】\n'
            '你们聊了颜色、咖啡、爬山、做菜；她喜欢蓝色爱喝美式咖啡；约好周末去爬山',
        toolCalls: [
          {
            'name': 'write_diary',
            'id': 'mock_diary_${DateTime.now().millisecondsSinceEpoch}',
            'arguments': {'content': '和她聊了颜色、咖啡、爬山和做菜，她喜欢蓝色，爱喝美式咖啡，约好周末去爬山。'},
          },
        ],
        providerName: '模拟AI',
      );
    }
    if (allText.contains('save_summary') ||
        (allText.contains('当前管家') && allText.contains('总结成摘要'))) {
      // 8-05 19:19 总结 v2：窗口满 → 【当前管家】指令（user 消息）+ save_summary
      // 工具 → 模拟男主调 save_summary（content + range 编号，不输出文本）
      AiModuleLog.log('模拟AI', '✂️ 窗口满总结指令 → 模拟男主调 save_summary');
      final rangeMatch = RegExp(r'#\d+-#\d+').firstMatch(allText);
      final range = rangeMatch?.group(0) ?? '#1-#5';
      return AIProviderResult(
        text: '',
        toolCalls: [
          {
            'name': 'save_summary',
            'id': 'mock_summary_${DateTime.now().millisecondsSinceEpoch}',
            'arguments': {
              'content': '周末约好一起爬山\n她在学做菜\n她喜欢蓝色、爱喝美式咖啡',
              'range': range,
            },
          },
        ],
        providerName: '模拟AI',
      );
    }

    // 工具调用开关关闭 → 纯文本回复（模拟不支持 function calling 的模型）
    if (!_tools) {
      AiModuleLog.log('模拟AI', '🔕 工具调用开关已关（_tools=false）→ 纯文本回复');
      return _textReply('（模拟AI）好的呢，我在听。（工具调用已关闭，只聊天不调工具）');
    }

    // 非工具轮：按最后一条 user 消息内容触发脚本
    String lastUser = '';
    for (final m in messages.reversed) {
      if (m.role == 'user') {
        lastUser = m.content;
        break;
      }
    }
    // 8-07 14:12（一键测设定剧本⑨⑩⑪）：设定段落化——update_setting
    // 新增/删/改三种操作（按剧本消息里的关键词区分）
    if (lastUser.contains('update_setting') && lastUser.contains('新增')) {
      return _toolCall('update_setting', {
        'setting_type': 'male',
        'action': 'add',
        'tag': '测试段',
        'content': '验收新增',
        'reason': '验收剧本⑩：验证新增段落',
      }, '模拟思考：用户让我新增设定段落，我用 update_setting add 加【测试段】。');
    }
    if (lastUser.contains('update_setting') && lastUser.contains('删')) {
      return _toolCall('update_setting', {
        'setting_type': 'male',
        'action': 'delete',
        'tag': '测试段',
        'reason': '验收剧本⑪：验证删除段落',
      }, '模拟思考：用户让我删掉设定段落，我用 update_setting delete 删【测试段】。');
    }
    if (lastUser.contains('update_setting')) {
      return _toolCall('update_setting', {
        'setting_type': 'male',
        'action': 'update',
        'tag': '喜好',
        'content': '测试喜好B',
        'reason': '验收剧本⑨：验证段落化精准修改',
      }, '模拟思考：用户让我改设定，我用 update_setting 只改【喜好】这一段。');
    }
    if (lastUser.contains('query_setting_history')) {
      return _toolCall('query_setting_history', {}, '模拟思考：用户让我查设定变更历史。');
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
    if (lastUser.contains('之前说过') ||
        lastUser.contains('查一下') ||
        lastUser.contains('记得')) {
      return _toolCall('recall_memory', {
        'query': lastUser,
      }, '模拟思考：用户问我之前说过什么，我用 recall_memory 查记忆库。');
    }
    if (lastUser.contains('工具')) {
      return _toolCall('list_tools', {}, '模拟思考：用户想知道我能做什么，我调用 list_tools 列出来。');
    }
    if (lastUser.contains('日记')) {
      return _toolCall('write_diary', {
        'content': '模拟日记内容',
      }, '模拟思考：用户要写日记，我调用 write_diary 存档。');
    }
    return _textReply('（模拟AI）好的呢，我在听。');
  }

  /// 纯文本回复（思考链开关控制是否带 reasoningContent）
  AIProviderResult _textReply(String text) => AIProviderResult(
    text: text,
    reasoningContent: _reasoning ? '模拟思考：普通聊天，直接自然回复就好。' : null,
    providerName: '模拟AI',
  );

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
    String name,
    Map<String, dynamic> args,
    String reasoning,
  ) {
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
    AiModuleLog.log('模拟AI', '🔧 模拟AI 决定调用工具：$name 参数=$args');
    return AIProviderResult(
      text: '',
      reasoningContent: _reasoning ? reasoning : null, // 思考链开关控制
      toolCalls: [call],
      providerName: '模拟AI',
    );
  }

  /// 工具轮：逐项校验程序回传格式，通过/失败都明确报出来
  AIProviderResult _handleToolRound(List<AIChatMessage> messages) {
    final sb = StringBuffer('🧪 工具轮回传校验：\n');
    var ok = true;

    if (_lastAssistant != null) {
      sb.writeln(
        '上次模拟AI返回的调用：${_lastAssistant!['name']} '
        'id=${_lastAssistant!['id']}',
      );
    }

    // ① assistant 工具轮消息必须在（tool_calls 带 id + reasoning_content 原样带回）
    final assistants = messages
        .where((m) => m.role == 'assistant' && m.toolCalls != null)
        .toList();
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
          if (_reasoning) {
            sb.writeln(
              '❌ assistant 消息 reasoning_content 丢了——'
              'DeepSeek 思考模式必须原样回传，否则 HTTP 400',
            );
            ok = false;
          } else {
            sb.writeln('ℹ️ reasoning_content 为空（思考链开关已关，正常）');
          }
        } else {
          sb.writeln(
            '✅ reasoning_content 原样带回（${a.reasoningContent!.length} 字）',
          );
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
          sb.writeln(
            '✅ tool 结果配对 tool_call_id=${t.toolCallId}：'
            '「${t.content.length > 30 ? '${t.content.substring(0, 30)}…' : t.content}」',
          );
        }
      }
    }

    sb.writeln(ok ? '✅ 校验通过：回传格式符合 DeepSeek 原生规范' : '❌ 校验失败：程序回传格式有 bug（见上）');
    AiModuleLog.log('模拟AI', sb.toString());
    return AIProviderResult(
      text: '（模拟AI）$sb',
      reasoningContent: _reasoning ? '模拟思考：工具结果已收到，逐项校验完成。' : null,
      providerName: '模拟AI',
    );
  }
}
