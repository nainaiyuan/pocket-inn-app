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
    this.apiKeyHint = '',
    this.capabilities = const {AICapability.chat},
    this.note = '',
  });

  final String id;
  final String name;
  final ProviderType type;
  final String baseUrl;
  final String model;
  final String apiKeyHint;

  /// 预留：后续某些预设可带识图等能力
  final Set<AICapability> capabilities;
  final String note;
}

/// 开箱即用的预设厂商。
const List<AIProviderPreset> kAIProviderPresets = [
  AIProviderPreset(
    id: 'preset-deepseek',
    name: 'DeepSeek',
    type: ProviderType.cloud,
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-chat',
    apiKeyHint: 'sk-...',
    note: '便宜、推理强，官方直连',
  ),
  AIProviderPreset(
    id: 'preset-qwen',
    name: '通义千问',
    type: ProviderType.cloud,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen-plus',
    apiKeyHint: 'sk-...',
    note: '阿里云百炼，注册送免费额度',
  ),
  AIProviderPreset(
    id: 'preset-kimi',
    name: 'Kimi',
    type: ProviderType.cloud,
    baseUrl: 'https://api.moonshot.cn/v1',
    model: 'moonshot-v1-8k',
    apiKeyHint: 'sk-...',
    note: '月之暗面，长上下文',
  ),
  AIProviderPreset(
    id: 'preset-glm',
    name: '智谱 GLM',
    type: ProviderType.cloud,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    model: 'glm-4-flash',
    apiKeyHint: '填入智谱 API Key',
    note: 'glm-4-flash 免费档',
  ),
  AIProviderPreset(
    id: 'preset-doubao',
    name: '豆包（火山方舟）',
    type: ProviderType.cloud,
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-1-5-pro-32k-250115',
    apiKeyHint: '填入方舟 API Key',
    note: '模型 ID 以火山方舟控制台为准',
  ),
  AIProviderPreset(
    id: 'preset-siliconflow',
    name: '硅基流动',
    type: ProviderType.cloud,
    baseUrl: 'https://api.siliconflow.cn/v1',
    model: 'deepseek-ai/DeepSeek-V3',
    apiKeyHint: 'sk-...',
    note: '聚合开源模型，注册送额度',
  ),
  AIProviderPreset(
    id: 'preset-ollama',
    name: 'Ollama（本地）',
    type: ProviderType.local,
    baseUrl: 'http://127.0.0.1:11434/v1',
    model: 'qwen2.5:7b',
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
