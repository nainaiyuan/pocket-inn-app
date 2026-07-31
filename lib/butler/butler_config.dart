/// 管家核心配置
/// 所有管家功能的开关和默认值
class ButlerConfig {
  // ========== 亲密安全设置 ==========
  bool keywordReplaceEnabled;   // 关键词替换模式 [PRIVACY_MARK]
  bool safeTranslateEnabled;    // 安全翻译模式

  // ========== 假面层设置 ==========
  bool maskLayerEnabled;        // 假面层总开关
  String defaultMaskLevel;      // 'core' | 'normal' | 'temp'

  // ========== 多男主共享 ==========
  bool allowCharacterChat;      // 允许男主互相交流
  bool allowCharacterNotify;    // 允许男主私聊用户

  // ========== 记忆 ==========
  bool autoExtractMemory;       // 自动提取记忆
  int autoExtractInterval;      // 每几轮提取一次

  // ========== 管家 AI ==========
  bool butlerAIEnabled;         // 管家 AI 总开关
  String butlerAIApiEndpoint;   // 管家专用 API 地址
  String butlerAIApiKey;        // 管家专用 API Key
  String butlerAIModel;         // 管家用的模型名

  ButlerConfig({
    this.keywordReplaceEnabled = false,
    this.safeTranslateEnabled = false,
    this.maskLayerEnabled = true,
    this.defaultMaskLevel = 'core',
    this.allowCharacterChat = true,
    this.allowCharacterNotify = true,
    this.autoExtractMemory = true,
    this.autoExtractInterval = 5,
    this.butlerAIEnabled = false,
    this.butlerAIApiEndpoint = '',
    this.butlerAIApiKey = '',
    this.butlerAIModel = 'gpt-4o-mini',
  });

  Map<String, dynamic> toJson() => {
    'keywordReplaceEnabled': keywordReplaceEnabled,
    'safeTranslateEnabled': safeTranslateEnabled,
    'maskLayerEnabled': maskLayerEnabled,
    'defaultMaskLevel': defaultMaskLevel,
    'allowCharacterChat': allowCharacterChat,
    'allowCharacterNotify': allowCharacterNotify,
    'autoExtractMemory': autoExtractMemory,
    'autoExtractInterval': autoExtractInterval,
    'butlerAIEnabled': butlerAIEnabled,
    'butlerAIApiEndpoint': butlerAIApiEndpoint,
    'butlerAIApiKey': butlerAIApiKey,
    'butlerAIModel': butlerAIModel,
  };

  factory ButlerConfig.fromJson(Map<String, dynamic> json) => ButlerConfig(
    keywordReplaceEnabled: json['keywordReplaceEnabled'] ?? false,
    safeTranslateEnabled: json['safeTranslateEnabled'] ?? false,
    maskLayerEnabled: json['maskLayerEnabled'] ?? true,
    defaultMaskLevel: json['defaultMaskLevel'] ?? 'core',
    allowCharacterChat: json['allowCharacterChat'] ?? true,
    allowCharacterNotify: json['allowCharacterNotify'] ?? true,
    autoExtractMemory: json['autoExtractMemory'] ?? true,
    autoExtractInterval: json['autoExtractInterval'] ?? 5,
    butlerAIEnabled: json['butlerAIEnabled'] ?? false,
    butlerAIApiEndpoint: json['butlerAIApiEndpoint'] ?? '',
    butlerAIApiKey: json['butlerAIApiKey'] ?? '',
    butlerAIModel: json['butlerAIModel'] ?? 'gpt-4o-mini',
  );
}
