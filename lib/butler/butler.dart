import 'mask_engine.dart';
import 'storage/identity_store.dart' show IdentityEntry;
import 'butler_engine.dart';
import 'butler_config.dart';
import 'butler_database.dart';
import 'insight/insight_engine.dart';
import 'ai/butler_ai_service.dart';

/// 管家总入口
/// 提供给 APP 调用的统一接口
class Butler {
  late final MaskEngine maskEngine;
  late final ButlerEngine butlerEngine;
  late final ButlerConfig config;
  late final InsightEngine insightEngine;

  /// Token 用量缓存
  int _totalPromptTokens = 0;
  int _lastPromptTokens = 0;

  Butler({MaskEngine? sharedMaskEngine}) {
    // 必须用 ButlerModuleHub 的共享引擎（身份词/规律在这里加载），
    // 否则假面层页面配置的身份词与聊天时用的引擎不是同一份 → 替换不生效
    maskEngine = sharedMaskEngine ?? MaskEngine();
    config = ButlerConfig();
    butlerEngine = ButlerEngine(maskEngine: maskEngine, config: config);
    insightEngine = InsightEngine(db: ButlerDatabase.instance);
    _initDefaultIdentities();
  }

  /// 初始化一些默认身份映射
  void _initDefaultIdentities() {
    // 这些只是示例，用户可以在 APP 里自行添加
  }

  /// 注册身份
  void registerIdentity(IdentityEntry entry) {
    maskEngine.registerIdentity(entry);
  }

  /// 处理用户输入（判断是跟管家说还是跟男主说）
  ButlerIntent analyzeIntent(String text) {
    final trimmed = text.trim().toLowerCase();

    // 以管家称呼开头
    if (trimmed.startsWith('管家') || trimmed.startsWith('小管家')) {
      final content = trimmed.startsWith('管家')
          ? text.substring(2).trim()
          : text.substring(3).trim();
      return ButlerIntent(target: 'butler', content: content);
    }

    return ButlerIntent(target: 'character', content: text);
  }

  /// 处理发给男主的消息（经过假面层）
  ProcessResult processOutgoing({
    required String text,
    required String characterId,
    required String sessionId,
  }) {
    return butlerEngine.processOutgoingMessage(
      userText: text,
      characterId: characterId,
      sessionId: sessionId,
    );
  }

  /// 处理男主回复（还原假名）
  String processIncoming({
    required String text,
    required String sessionId,
  }) {
    return butlerEngine.processIncomingMessage(
      characterReply: text,
      sessionId: sessionId,
    );
  }

  /// 处理管家命令
  ButlerCommandResult processCommand(String text) {
    final intent = analyzeIntent(text);
    if (intent.target == 'butler') {
      return butlerEngine.processCommand(intent.content);
    }
    // 用户没有叫管家，但管家也可以尝试理解
    return butlerEngine.processCommand(text);
  }

  /// 获取配置
  ButlerConfig getConfig() => config;

  /// 获取心情标签上下文（给 PromptAssembler 用）
  /// 只检测敏感词触发了才返回，没有触发返回空字符串
  String getMoodContext(String text) {
    return butlerEngine.buildMoodContext(text);
  }

  /// 调用管家 AI 分析用户意图
  /// 用户的文本先经过假面层脱敏，再发给管家专用 AI
  Future<ButlerAIResult> analyzeWithAI(String userText, {bool maskBeforeSend = true}) async {
    final maskedText = maskBeforeSend
        ? _applyMaskLayer(userText)
        : userText;
    return butlerEngine.analyzeWithAI(userText, maskedText);
  }

  /// 对文本应用假面层替换（不修改原始文本，只生成脱敏版本）
  String _applyMaskLayer(String text) {
    // 这个方法被废弃，改用 replaceSensitive
    return text;
  }

  /// 更新配置
  void updateConfig(ButlerConfig newConfig) {
    config = newConfig;
  }

  /// 记录本次请求消耗的 Token（从 API 返回的 usage 获取）
  void recordTokenUsage(int promptTokens, int totalTokens) {
    _totalPromptTokens += promptTokens;
    _lastPromptTokens = promptTokens;
  }

  /// 获取累计消耗的 prompt_tokens
  int get totalPromptTokens => _totalPromptTokens;

  /// 获取上次请求消耗的 prompt_tokens
  int get lastPromptTokens => _lastPromptTokens;

  /// 重置 Token 计数（换模型时调用）
  void resetTokenCount() {
    _totalPromptTokens = 0;
    _lastPromptTokens = 0;
  }

  /// 当前心情分数（用于 TTS 引擎语音调配）
  /// 范围 0.0–1.0，默认 0.5 表示中性
  double get currentMood => 0.5; // TODO: 接入真实情绪分析
}

/// 意图判断结果
class ButlerIntent {
  final String target;  // 'butler' | 'character'
  final String content;

  ButlerIntent({required this.target, required this.content});
}
