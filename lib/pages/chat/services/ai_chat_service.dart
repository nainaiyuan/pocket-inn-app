import '../../../ai_provider/ai_provider_manager.dart';
import '../../../ai_provider/models.dart';
import '../../../butler/context/context_tracker.dart';
import '../../../services/chat_service.dart';
import '../../../utils/debug_logger.dart';

/// 聊天页的 AI 门面 —— 走 AIProviderManager（男主级路由 + 故障切换）。
///
/// 不再返回模拟句子；未配置 / 全部失败时会抛异常，由聊天页弹窗提示。
class AiChatService {
  static final AiChatService _instance = AiChatService._();
  factory AiChatService() => _instance;
  AiChatService._();

  /// 最近一次组装好的完整 prompt（📄 按钮查看：男主"知道什么"一目了然）
  String? lastPromptText;

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
    final needsWindow = !ContextTracker.instance.windowConfirmed(personaId);
    final systemPrompt = '你是「$personaName」，一个正在和用户聊天的角色。'
        '请始终以这个身份自然、温柔地回复，保持人设与说话风格，'
        '不要说"作为AI"之类的话，也不要提及模型或技术细节。'
        '回复要口语化、有情绪、有代入感，一般不超过 200 字。'
        // 能力引导（男主可见，管家处理，用户看不到指令本身）
        '【你的能力】你可以主动做这些事，管家会执行（用户看不到指令）：'
        '用户提到喜欢、讨厌、习惯、个人信息、约定的事 → 直接 #记录 类别：内容#'
        '（类别：喜好/约定/日常/事实/其他，比如 #记录 喜好：她喜欢下雨天#）；'
        '想确认以前的事、用户提过的事 → 直接 #查记忆 关键词#'
        '（比如 #查记忆 她喜欢什么#）。'
        '【重要】不要问用户"要不要我记住"——需要记就直接调用 #记录，'
        '用户确认由管家负责。调用后指令执行完，你再自然地继续和用户说话。'
        '${needsWindow ? '【必答】开始对话时，请先回复 #model 你的模型名 上下文Token数（例如：#model deepseek-chat 65536），只需回复这一次。' : ''}'
        '${skillContext == null ? '' : '\n\n以下是管家刚刚实时检索到的用户状态（本次对话前的最新信息），自然地回应，不要提及"管家"或"检索"：\n$skillContext'}';
    // 透明化：保存完整 prompt 供 📄 按钮查看
    lastPromptText = '【System】\n$systemPrompt\n\n【User】\n$message';
    DebugLogger.log('Prompt', '本次组装完成（${lastPromptText!.length} 字，可点 📄 查看）');
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
    // token 追踪：API 精确 usage → 管家累计 + 记得清单更新
    try {
      final butler = ChatService.instance.butler;
      final usage = result.usage;
      if (butler != null && usage != null) {
        final promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
        final totalTokens = (usage['total_tokens'] as num?)?.toInt() ?? 0;
        if (promptTokens > 0) {
          butler.recordTokenUsage(promptTokens, totalTokens);
          ContextTracker.instance.recordCall(personaId, promptTokens);
          DebugLogger.log('上下文', '📈 $personaName 本轮 ${promptTokens}token（累计 ${butler.totalPromptTokens}）');
        }
      }
    } catch (_) {}
    // 男主回复里的 #model → 确认窗口长度
    if (!ContextTracker.instance.windowConfirmed(personaId)) {
      final m = RegExp(r'#model\s+(\S+)\s+(\d+)', caseSensitive: false)
          .firstMatch(result.text);
      if (m != null) {
        final w = int.tryParse(m.group(2)!);
        if (w != null && w >= 4096 && w <= 1048576) {
          ContextTracker.instance.setWindow(personaId, w);
          DebugLogger.log('上下文', '🎯 男主自报: ${m.group(1)} 窗口 $w token');
        } else {
          DebugLogger.log('上下文', '⚠️ 男主 #model 值不合理，忽略: ${m.group(0)}');
        }
      } else {
        // 兜底：男主没报 → 按模型名查内置窗口表（deepseek-chat 等）
        final w = ContextTracker.instance.windowByModelHint(
          _currentModelName(personaId),
        );
        if (w > 0) {
          ContextTracker.instance.setWindow(personaId, w);
          DebugLogger.log('上下文', '🔎 男主未报 #model，查表兜底: '
              '${_currentModelName(personaId)} → $w token');
        }
      }
    }
    return result;
  }

  /// 当前生效的模型名（候选列表第一个 = 当前生效）
  String _currentModelName(String personaId) {
    try {
      final candidates =
          AIProviderManager.instance.candidatesFor(personaId);
      return candidates.isNotEmpty ? candidates.first.model : '';
    } catch (_) {
      return '';
    }
  }
}
