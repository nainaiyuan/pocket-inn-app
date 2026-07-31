/// 预设厂商列表（纯 Dart）。
///
/// 用户不用记地址：勾选预设 → 只填 API Key 就能用。
/// 所有端点均为 OpenAI 兼容格式（/chat/completions）。
/// 自定义槽位（id 固定为 'custom'）由 [AIProviderManager] 单独管理，
/// 这里只放「开箱即用」的预设。
library;

import 'models.dart';

/// 一个预设条目。
class AIProviderPreset {
  const AIProviderPreset({
    required this.id,
    required this.name,
    required this.type,
    required this.baseUrl,
    required this.model,
    this.models = const [],
    this.apiKeyHint = '',
    this.capabilities = const {AICapability.chat},
    this.note = '',
  });

  final String id;
  final String name;
  final ProviderType type;
  final String baseUrl;

  /// 默认模型名（列表里的第一个）。
  final String model;

  /// 该厂商常用的模型名列表（添加/编辑时下拉可选，也可手填）。
  final List<String> models;

  final String apiKeyHint;

  /// 预留：后续某些预设可带识图等能力
  final Set<AICapability> capabilities;
  final String note;
}

/// 开箱即用的预设厂商。
/// 注意：模型名会随厂商更新变化，这里只列「当前常用」，
/// 添加/编辑时用户可下拉选择，也可直接手填最新模型名。
const List<AIProviderPreset> kAIProviderPresets = [
  AIProviderPreset(
    id: 'preset-deepseek',
    name: 'DeepSeek',
    type: ProviderType.cloud,
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-v4-flash',
    models: [
      'deepseek-v4-flash', // 对话，快且便宜（deepseek-chat 已于 2026-07-24 停用）
      'deepseek-v4-pro', // 推理，更强（deepseek-reasoner 已于 2026-07-24 停用）
    ],
    apiKeyHint: 'sk-...',
    note: '官方直连，v4 系列（旧 deepseek-chat/reasoner 已停用）',
  ),
  AIProviderPreset(
    id: 'preset-qwen',
    name: '通义千问',
    type: ProviderType.cloud,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen-plus',
    models: [
      'qwen-plus',
      'qwen-max',
      'qwen-turbo',
      'qwen-flash',
      'qwen-long',
    ],
    apiKeyHint: 'sk-...',
    note: '阿里云百炼，注册送免费额度',
  ),
  AIProviderPreset(
    id: 'preset-kimi',
    name: 'Kimi',
    type: ProviderType.cloud,
    baseUrl: 'https://api.moonshot.cn/v1',
    model: 'moonshot-v1-8k',
    models: [
      'moonshot-v1-8k',
      'moonshot-v1-32k',
      'moonshot-v1-128k',
      'kimi-k2-0711-preview',
    ],
    apiKeyHint: 'sk-...',
    note: '月之暗面，长上下文',
  ),
  AIProviderPreset(
    id: 'preset-glm',
    name: '智谱 GLM',
    type: ProviderType.cloud,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    model: 'glm-4-flash',
    models: [
      'glm-4-flash', // 免费档
      'glm-4-plus',
      'glm-4-air',
      'glm-4-long',
      'glm-4-0520',
    ],
    apiKeyHint: '填入智谱 API Key',
    note: 'glm-4-flash 免费档',
  ),
  AIProviderPreset(
    id: 'preset-doubao',
    name: '豆包（火山方舟）',
    type: ProviderType.cloud,
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-1-5-pro-32k-250115',
    models: [
      'doubao-1-5-pro-32k-250115',
      'doubao-1-5-lite-32k-250115',
      'doubao-seed-1-6-250615',
      'doubao-seed-1-6-thinking-250615',
    ],
    apiKeyHint: '填入方舟 API Key',
    note: '模型 ID 以火山方舟控制台为准',
  ),
  AIProviderPreset(
    id: 'preset-siliconflow',
    name: '硅基流动',
    type: ProviderType.cloud,
    baseUrl: 'https://api.siliconflow.cn/v1',
    model: 'deepseek-ai/DeepSeek-V3',
    models: [
      'deepseek-ai/DeepSeek-V3',
      'deepseek-ai/DeepSeek-R1',
      'Qwen/Qwen2.5-72B-Instruct',
      'Qwen/Qwen2.5-7B-Instruct',
      'THUDM/GLM-4-9B-Chat',
      'meta-llama/Llama-3.3-70B-Instruct',
    ],
    apiKeyHint: 'sk-...',
    note: '聚合开源模型，注册送额度',
  ),
  AIProviderPreset(
    id: 'preset-ollama',
    name: 'Ollama（本地）',
    type: ProviderType.local,
    baseUrl: 'http://127.0.0.1:11434/v1',
    model: 'qwen2.5:7b',
    models: [
      'qwen2.5:7b',
      'qwen2.5:14b',
      'qwen2.5:32b',
      'llama3.1:8b',
      'gemma2:9b',
      'deepseek-r1:7b',
    ],
    apiKeyHint: '本地无需 Key',
    note: '电脑/平板装 Ollama 后可用',
  ),
  AIProviderPreset(
    id: 'preset-llamacpp',
    name: 'llama.cpp（本地）',
    type: ProviderType.local,
    baseUrl: 'http://127.0.0.1:8080/v1',
    model: '',
    apiKeyHint: '本地无需 Key',
    note: '自己起的 llama-server，模型名需自填',
  ),
];

/// 预设 → 可用的 Provider 配置。
AIProviderConfig presetToConfig(
  AIProviderPreset preset, {
  int priority = 100,
  bool enabled = true,
}) {
  return AIProviderConfig(
    id: preset.id,
    name: preset.name,
    type: preset.type,
    baseUrl: preset.baseUrl,
    model: preset.model,
    capabilities: preset.capabilities,
    enabled: enabled,
    priority: priority,
    note: preset.note,
  );
}

/// 首次启动的默认配置：全部预设按列表顺序开启。
List<AIProviderConfig> defaultProviderConfigs() {
  return [
    for (var i = 0; i < kAIProviderPresets.length; i++)
      presetToConfig(kAIProviderPresets[i], priority: i),
  ];
}
