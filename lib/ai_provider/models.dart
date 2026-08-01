/// AI Provider 模块的领域模型（纯 Dart，不依赖 Flutter / 管家）。
///
/// 一个「Provider」= 一个可调用的 AI 服务（云端厂商或本地模型），
/// 携带能力标签（chat / vision / stt / tts），v1 只启用 chat，
/// 其余能力字段预留，后续加识图、语音时不需要改结构。
library;

import 'dart:convert';

/// 能力标签。路由时按能力过滤：聊天请求只试带 chat 的 Provider。
enum AICapability {
  chat,
  vision,
  stt,
  tts,
}

/// Provider 类型：云端（需要网络+Key） / 本地（局域网或本机）。
enum ProviderType {
  cloud,
  local,
}

/// 运行健康状态。
enum ProviderHealth {
  /// 还没成功过 / 冷却已到期待重试
  unknown,

  /// 最近一次调用成功
  healthy,

  /// 连续失败，正在冷却期内，路由会跳过
  cooling,

  /// 用户手动禁用
  disabled,
}

/// 一个 AI Provider 的完整配置（可序列化）。
class AIProviderConfig {
  const AIProviderConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.baseUrl,
    this.apiKey = '',
    required this.model,
    this.capabilities = const {AICapability.chat},
    this.isCustom = false,
    this.enabled = true,
    this.priority = 100,
    this.note = '',
  });

  /// 稳定唯一 id，如 'preset-deepseek' / 'custom'
  final String id;

  /// 显示名，如 'DeepSeek'
  final String name;

  final ProviderType type;

  /// OpenAI 兼容端点，如 https://api.deepseek.com
  final String baseUrl;

  /// API Key（本地模型可为空）
  final String apiKey;

  /// 默认聊天模型名，如 deepseek-chat
  final String model;

  /// 支持的能力，默认仅聊天
  final Set<AICapability> capabilities;

  /// 是否自定义槽位（全项目只允许一个）
  final bool isCustom;

  /// 用户手动开关，关掉后路由直接跳过
  final bool enabled;

  /// 优先级，越小越靠前（用户手动排序后写回）
  final int priority;

  /// 给用户看的说明（如"glm-4-flash 免费"）
  final String note;

  bool get supportsChat => capabilities.contains(AICapability.chat);
  bool get supportsVision => capabilities.contains(AICapability.vision);

  /// 是否已填齐能发请求的字段
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  AIProviderConfig copyWith({
    String? id,
    String? name,
    ProviderType? type,
    String? baseUrl,
    String? apiKey,
    String? model,
    Set<AICapability>? capabilities,
    bool? isCustom,
    bool? enabled,
    int? priority,
    String? note,
  }) {
    return AIProviderConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      capabilities: capabilities ?? this.capabilities,
      isCustom: isCustom ?? this.isCustom,
      enabled: enabled ?? this.enabled,
      priority: priority ?? this.priority,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'capabilities': [for (final c in capabilities) c.name],
        'isCustom': isCustom,
        'enabled': enabled,
        'priority': priority,
        'note': note,
      };

  factory AIProviderConfig.fromJson(Map<String, dynamic> json) {
    return AIProviderConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名',
      type: ProviderType.values.asNameMap()[json['type']] ??
          ProviderType.cloud,
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      capabilities: {
        for (final item in (json['capabilities'] as List<dynamic>? ?? const []))
          if (AICapability.values.asNameMap()[item] != null)
            AICapability.values.asNameMap()[item]!,
      },
      isCustom: json['isCustom'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      priority: json['priority'] as int? ?? 100,
      note: json['note'] as String? ?? '',
    );
  }
}

/// 男主 → Provider 绑定。
/// [providerIds] 是该男主专用的「白名单 + 顺序」；
/// 为空表示跟随全局优先级。绑定内的 Provider 全挂时直接报错，
/// 不会偷偷回退到全局（用户选了什么就是什么）。
class PersonaAIBinding {
  const PersonaAIBinding({
    required this.personaId,
    this.providerIds = const [],
  });

  final String personaId;

  /// 该男主可用的 Provider id 列表（按用户选择的顺序）
  final List<String> providerIds;

  bool get followsGlobal => providerIds.isEmpty;

  PersonaAIBinding copyWith({List<String>? providerIds}) =>
      PersonaAIBinding(
        personaId: personaId,
        providerIds: providerIds ?? this.providerIds,
      );

  Map<String, dynamic> toJson() => {
        'personaId': personaId,
        'providerIds': providerIds,
      };

  factory PersonaAIBinding.fromJson(Map<String, dynamic> json) =>
      PersonaAIBinding(
        personaId: json['personaId'] as String? ?? '',
        providerIds: [
          for (final item in (json['providerIds'] as List<dynamic>? ?? const []))
            item.toString(),
        ],
      );
}

/// 每个男主的 AI 行为设置（持久化）。
/// key 用 personaId；空字符串 '' 表示「全局默认」。
/// 男主没单独设置时，自动切换 / 当前 Provider 都回落全局。
class PersonaAISettings {
  const PersonaAISettings({
    this.autoSwitch = true,
    this.lastProviderId,
  });

  /// 是否允许故障自动切换。
  /// false = 当前 AI 不可用时直接报错，弹窗让用户检查，不偷偷换人。
  final bool autoSwitch;

  /// 最近一次成功使用的 Provider id（用于"当前 AI"展示）。
  final String? lastProviderId;

  PersonaAISettings copyWith({
    bool? autoSwitch,
    String? lastProviderId,
    bool clearLastProvider = false,
  }) =>
      PersonaAISettings(
        autoSwitch: autoSwitch ?? this.autoSwitch,
        lastProviderId: clearLastProvider
            ? null
            : (lastProviderId ?? this.lastProviderId),
      );

  Map<String, dynamic> toJson() => {
        'autoSwitch': autoSwitch,
        if (lastProviderId != null) 'lastProviderId': lastProviderId,
      };

  factory PersonaAISettings.fromJson(Map<String, dynamic> json) =>
      PersonaAISettings(
        autoSwitch: json['autoSwitch'] as bool? ?? true,
        lastProviderId: json['lastProviderId'] as String?,
      );
}

/// 自动切换被关闭时，某个 Provider 调用失败抛出。
/// UI 用它弹窗："当前 AI（xxx）不可用：原因"。
class AIProviderUnavailableException implements Exception {
  const AIProviderUnavailableException({
    required this.providerName,
    required this.cause,
  });

  /// 失败的那个 Provider 显示名
  final String providerName;
  final Object cause;

  @override
  String toString() => '当前 AI（$providerName）不可用：$cause';
}

/// 聊天消息（OpenAI 兼容格式）。
/// [imageBase64] 预留：带图请求时自动组装成多模态 content。
class AIChatMessage {
  const AIChatMessage({
    required this.role,
    required this.content,
    this.imageBase64,
    this.toolCallId,
    this.toolCalls,
  });

  /// system / user / assistant / tool
  final String role;

  /// 消息内容（tool 消息时为工具执行结果；assistant 工具轮可为空字符串）
  final String content;
  final String? imageBase64;

  /// tool 消息的调用 ID（关联 assistant 的 tool_calls）
  final String? toolCallId;

  /// assistant 消息请求的工具调用（function calling）
  final List<Map<String, dynamic>>? toolCalls;

  Map<String, dynamic> toApiJson() {
    // 工具结果消息：{role: tool, tool_call_id, content}
    if (role == 'tool' && toolCallId != null) {
      return {'role': 'tool', 'tool_call_id': toolCallId, 'content': content};
    }
    // assistant 工具轮：{role: assistant, content: null, tool_calls}
    if (toolCalls != null && toolCalls!.isNotEmpty) {
      return {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          for (final call in toolCalls!)
            {
              'id': call['id'] ?? 'call_${call['name'] ?? 'fn'}',
              'type': 'function',
              'function': {
                'name': call['name'],
                'arguments': call['argumentsJson'] ??
                    _encodeArguments(call['arguments']),
              },
            },
        ],
      };
    }
    if (imageBase64 == null || imageBase64!.isEmpty) {
      return {'role': role, 'content': content};
    }
    return {
      'role': role,
      'content': [
        {'type': 'text', 'text': content},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'},
        },
      ],
    };
  }

  static String _encodeArguments(Object? args) {
    if (args == null) return '{}';
    if (args is String) return args;
    try {
      return jsonEncode(args);
    } catch (_) {
      return '{}';
    }
  }
}

/// 一次 AI 调用的结果。
/// 流式场景下 [text] / [thinking] 是增量片段，[done] 标记流结束。
class AIProviderResult {
  const AIProviderResult({
    this.text = '',
    this.thinking = '',
    this.providerId,
    this.providerName,
    this.usage,
    this.toolCalls,
    this.failedProviders = const [],
    this.done = false,
  });

  final String text;

  /// 思考链（reasoning）。流式时是增量，非流式是完整内容。
  final String thinking;

  final String? providerId;
  final String? providerName;

  /// API 返回的 token 用量（非流式才有）
  final Map<String, dynamic>? usage;

  /// 模型请求的工具调用（function calling）：[{name, arguments}]
  final List<Map<String, dynamic>>? toolCalls;

  /// 本次调用中尝试过但失败了的 Provider 名（故障切换痕迹）
  final List<String> failedProviders;

  final bool done;

  AIProviderResult copyWith({
    String? text,
    String? thinking,
    String? providerId,
    String? providerName,
    Map<String, dynamic>? usage,
    List<String>? failedProviders,
    bool? done,
  }) {
    return AIProviderResult(
      text: text ?? this.text,
      thinking: thinking ?? this.thinking,
      providerId: providerId ?? this.providerId,
      providerName: providerName ?? this.providerName,
      usage: usage ?? this.usage,
      failedProviders: failedProviders ?? this.failedProviders,
      done: done ?? this.done,
    );
  }
}

/// 所有 Provider 都失败时抛出。
class AIAllProvidersFailedException implements Exception {
  const AIAllProvidersFailedException({this.tried = const [], this.lastError});

  /// 尝试过的 Provider 显示名
  final List<String> tried;
  final Object? lastError;

  @override
  String toString() {
    if (tried.isEmpty) {
      return '没有可用的 AI Provider（可能全部被禁用或在冷却中）';
    }
    return '所有 AI Provider 都失败了：$tried';
  }
}
