import '../../../ai_provider/ai_provider_manager.dart';
import '../../../ai_provider/models.dart';
import '../../../utils/debug_logger.dart';

/// 聊天页的 AI 门面 —— 走 AIProviderManager（男主级路由 + 故障切换）。
///
/// 不再返回模拟句子；未配置 / 全部失败时会抛异常，由聊天页弹窗提示。
class AiChatService {
  static final AiChatService _instance = AiChatService._();
  factory AiChatService() => _instance;
  AiChatService._();

  /// 真实 AI 回复。
  ///
  /// [personaId] 决定用哪个男主的 Provider 绑定与自动切换设置；
  /// [personaName] 用于组装人设提示词；
  /// [skillContext] 管家技能注入（如情绪洞察），拼入 system 让男主自然接住。
  /// 返回完整结果（含实际用的 Provider 与切换痕迹，供 UI 展示）。
  Future<AIProviderResult> generateReply(
    String message,
    String personaId, {
    String personaName = '角色',
    String? skillContext,
  }) async {
    final manager = AIProviderManager.instance;
    if (!manager.hasUsable(personaId)) {
      DebugLogger.log(
        'AI路由',
        '❌ 发送前检查：$personaId 没有可用 Provider',
      );
      throw const AIAllProvidersFailedException();
    }
    final systemPrompt = '你是「$personaName」，一个正在和用户聊天的角色。'
        '请始终以这个身份自然、温柔地回复，保持人设与说话风格，'
        '不要说"作为AI"之类的话，也不要提及模型或技术细节。'
        '回复要口语化、有情绪、有代入感，一般不超过 200 字。'
        '${skillContext == null ? '' : '\n\n以下是管家刚刚实时检索到的用户状态（本次对话前的最新信息），自然地回应，不要提及"管家"或"检索"：\n$skillContext'}';
    final result = await manager.chat(
      personaId,
      [
        AIChatMessage(role: 'system', content: systemPrompt),
        AIChatMessage(role: 'user', content: message),
      ],
    );
    if (result.text.trim().isEmpty) {
      throw const FormatException('AI 返回了空回复');
    }
    return result;
  }
}
