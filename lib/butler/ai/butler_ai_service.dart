/// 管家 AI 服务
///
/// 职责：
/// 1. 接收用户脱敏后的文本
/// 2. 发给管家专用 AI（通过 AIProviderManager 路由，personaId 固定为 'butler'）
/// 3. AI 返回结构化 JSON（指令 + 回复 + 情绪）
/// 4. 管家执行指令，显示回复
///
/// 和男主 AI 的区别：
/// - 走同一个 AIProviderManager，但 personaId 不同，可单独绑定 Provider
/// - Prompt 固定，不参与角色扮演
/// - 输出强制 JSON 格式
///
/// 未来微调方向：
/// - 训练数据：用户吐槽+指令 → 结构化意图
/// - 不需要角色扮演能力，只需要理解能力
/// - 目标是让模型知道：自己是管家，不是男主
library;

import 'dart:convert';

import '../../ai_provider/ai_provider_manager.dart';
import '../../ai_provider/models.dart';
import '../../utils/debug_logger.dart';

class ButlerAIService {
  /// 管家在 AIProviderManager 里的固定 personaId。
  /// 用户可以在设置里给管家单独绑定 Provider。
  static const String butlerPersonaId = 'butler';

  // 兼容旧配置字段（保留，实际调用走 AIProviderManager）
  final String apiEndpoint;
  final String apiKey;
  final String model;

  /// 管家 AI 的 Prompt（固定不变）
  /// 告诉 AI：你是谁、你的任务、输出格式
  static const String systemPrompt = '''
你是一个私人管家 AI，名字叫"管家"。
你的职责是帮助用户管理手机里的私人助理 APP。

【你的身份】
- 你不是男/女朋友 AI
- 你是用户的私人管家
- 语气温和、专业、贴心，但保持距离感
- 用户烦躁时可以安抚，不要调情

【你的任务】
用户会对你说各种话——吐槽、指令、抱怨、情绪宣泄。
你需要做三件事：
1. 理解用户意图，提取结构化指令
2. 如果用户情绪不好，用管家身份安抚
3. 必须输出以下 JSON 格式

【输出格式】
{
  "reply": "你对用户的回复（如果没有需要说的，留空字符串）",
  "intents": [
    {
      "type": "指令类型",
      "params": {
        "key": "value"
      }
    }
  ],
  "mood": "用户当前情绪",
  "needs_comfort": true/false
}

【指令类型说明】
- "save_note": 记笔记（params: { "content": "笔记内容", "category": "纪念日/喜好/感受/随便记" }）
- "set_config": 修改管家设置（params: { "key": "配置名", "value": "值" }）
- "lock_vault": 锁定保险箱（params: {}）
- "call_character": 叫男主出来（params: { "name": "男主名字" }）
- "query_memory": 查询记忆（params: { "topic": "主题" }）
- "set_trigger": 设触发条件（params: { "trigger": "触发条件", "action": "触发后的动作", "content": "附加内容" }）
- "analyze_image": 分析图片（params: { "description": "图片的文字描述" }，不保存图片本身）

【情绪词列表】
开心, 平静, 烦躁, 伤心, 生气, 焦虑, 满足, 疲惫, 害怕, 害羞, 期待, 惊讶, 无奈

【注意事项】
- 如果用户只是吐槽，没有具体指令 → intents 返回空数组
- 如果用户明显需要安抚 → needs_comfort: true, 写一段温和的回复
- 如果用户骂你 → 道歉、问清楚要什么，不要顶嘴
- 不要代替男主 AI 和用户谈恋爱
''';

  ButlerAIService({
    this.apiEndpoint = '',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
  });

  /// 分析用户意图
  /// [userText] 用户的原始输入（已脱敏）
  /// 返回结构化结果
  Future<ButlerAIResult> analyze(String userText) async {
    final manager = AIProviderManager.instance;

    if (!manager.hasUsable(butlerPersonaId)) {
      DebugLogger.log(
        '管家AI',
        '没有可用的 AI Provider，跳过意图分析（请先在设置里配置 API）',
      );
      return ButlerAIResult(
        reply: '',
        intents: [],
        mood: '平静',
        needsComfort: false,
      );
    }

    try {
      final result = await manager.chat(
        butlerPersonaId,
        [
          const AIChatMessage(role: 'system', content: systemPrompt),
          AIChatMessage(role: 'user', content: userText),
        ],
        defaults: const {
          'response_format': {'type': 'json_object'},
          'temperature': 0.2,
          'max_tokens': 800,
        },
      );

      final decoded = jsonDecode(result.text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('管家 AI 返回的不是 JSON 对象');
      }
      final butlerResult = ButlerAIResult.fromJson(decoded);
      DebugLogger.log(
        '管家AI',
        '分析完成: mood=${butlerResult.mood} '
        'intents=${butlerResult.intents.length} '
        'needsComfort=${butlerResult.needsComfort} '
        '(provider: ${result.providerName})',
      );
      return butlerResult;
    } on Object catch (error) {
      DebugLogger.log('管家AI', '分析失败: $error');
      return ButlerAIResult(
        reply: '',
        intents: [],
        mood: '平静',
        needsComfort: false,
      );
    }
  }

  /// 批量分析（考虑后续合并多条短消息）
  Future<List<ButlerAIResult>> analyzeBatch(List<String> texts) async {
    final results = <ButlerAIResult>[];
    for (final text in texts) {
      results.add(await analyze(text));
    }
    return results;
  }
}

/// 管家 AI 分析结果
class ButlerAIResult {
  /// 管家对用户的回复（空字符串 = 不需要回复）
  final String reply;

  /// 提取的结构化指令列表
  final List<ButlerIntent> intents;

  /// 用户情绪
  final String mood;

  /// 是否需要安抚
  final bool needsComfort;

  ButlerAIResult({
    required this.reply,
    required this.intents,
    required this.mood,
    this.needsComfort = false,
  });

  /// 是否有需要执行的指令
  bool get hasIntents => intents.isNotEmpty;

  /// 是否需要回复用户
  bool get shouldReply => reply.isNotEmpty;

  factory ButlerAIResult.fromJson(Map<String, dynamic> json) {
    final intentsList = (json['intents'] as List? ?? [])
        .map((e) => ButlerIntent.fromJson(e as Map<String, dynamic>))
        .toList();

    return ButlerAIResult(
      reply: json['reply'] as String? ?? '',
      intents: intentsList,
      mood: json['mood'] as String? ?? '平静',
      needsComfort: json['needs_comfort'] as bool? ?? false,
    );
  }
}

/// 管家指令
class ButlerIntent {
  /// 指令类型
  /// save_note / set_config / lock_vault / call_character / query_memory / set_trigger / analyze_image
  final String type;

  /// 指令参数
  final Map<String, dynamic> params;

  ButlerIntent({
    required this.type,
    this.params = const {},
  });

  factory ButlerIntent.fromJson(Map<String, dynamic> json) {
    return ButlerIntent(
      type: json['type'] as String,
      params: json['params'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'params': params,
  };
}

/// 触发条件
/// 当某种条件满足时，管家自动执行动作
class ButlerTrigger {
  /// 触发条件类型: topic / mood / time / keyword
  final String triggerType;

  /// 匹配值（如话题名、情绪名、关键词）
  final String matchValue;

  /// 触发后的动作: notify_character / remind_user / adjust_config
  final String action;

  /// 附加内容
  final String content;

  /// 是否启用
  bool enabled;

  ButlerTrigger({
    required this.triggerType,
    required this.matchValue,
    required this.action,
    this.content = '',
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'triggerType': triggerType,
    'matchValue': matchValue,
    'action': action,
    'content': content,
    'enabled': enabled,
  };

  factory ButlerTrigger.fromJson(Map<String, dynamic> json) => ButlerTrigger(
    triggerType: json['triggerType'] as String,
    matchValue: json['matchValue'] as String,
    action: json['action'] as String,
    content: json['content'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
  );
}
