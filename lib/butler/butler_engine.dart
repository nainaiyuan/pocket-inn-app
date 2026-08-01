import 'mask_engine.dart';
import 'butler_config.dart';
import 'ai/butler_ai_service.dart';
import '../utils/debug_logger.dart';

/// 管家调度中心
/// 负责分发用户指令、调用各模块
class ButlerEngine {
  final MaskEngine _maskEngine;
  final ButlerConfig _config;

  ButlerEngine({
    required MaskEngine maskEngine,
    ButlerConfig? config,
  }) : _maskEngine = maskEngine,
       _config = config ?? ButlerConfig();

  /// 处理用户对管家的命令（"记一下xxx"、"改一下xxx"）
  ButlerCommandResult processCommand(String userInput) {
    final lowerInput = userInput.trim().toLowerCase();

    // 关键词匹配
    if (lowerInput.startsWith('记一下') || lowerInput.startsWith('记住')) {
      final content = userInput.trim().substring(lowerInput.startsWith('记一下') ? 3 : 2).trim();
      return ButlerCommandResult(
        type: 'save_memory',
        content: content,
        reply: '好的，我记住了：$content',
      );
    }

    if (lowerInput.startsWith('改一下') || lowerInput.startsWith('修改')) {
      return ButlerCommandResult(
        type: 'modify',
        content: userInput,
        reply: '你想改什么？告诉我就行。',
      );
    }

    if (lowerInput.startsWith('查一下') || lowerInput.startsWith('搜索') || lowerInput.startsWith('找一下')) {
      return ButlerCommandResult(
        type: 'search',
        content: userInput,
        reply: '我帮你查一下……',
      );
    }

    if (lowerInput.startsWith('忘了') || lowerInput.startsWith('删除')) {
      return ButlerCommandResult(
        type: 'delete',
        content: userInput,
        reply: '好的，你确定要删除吗？',
      );
    }

    if (lowerInput.contains('开关') || lowerInput.contains('设置')) {
      return ButlerCommandResult(
        type: 'settings',
        content: userInput,
        reply: '你想调整什么设置？',
      );
    }

    if (lowerInput.contains('提醒') || lowerInput.contains('触发')) {
      return ButlerCommandResult(
        type: 'set_trigger',
        content: userInput,
        reply: '好的，你希望什么情况下触发？',
      );
    }

    // 默认：无法识别，需要求助外部AI
    return ButlerCommandResult(
      type: 'unknown',
      content: userInput,
      reply: null, // 需要外部AI帮忙判断
      needsHelp: true,
    );
  }

  /// 获取管家能做的事（给 AI 看的能力表）
  /// 脱敏版本，不暴露内部实现细节
  String getAbilityList() {
    return '''
管家能力清单（仅限以下，用户问不会的就说不会）:

1. save_note — 记笔记
   需要信息：笔记内容、分类（纪念日/喜好/感受/随便记）
   示例："记住他喜欢喝美式" → 分类"喜好"，内容"喜欢喝美式"

2. set_config — 修改管家设置
   需要信息：设置名、新值
   示例："打开假面层" → key="maskLayerEnabled", value=true

3. lock_vault — 锁定保险箱
   不需要额外信息，直接触发全量加密打包

4. call_character — 叫男主出来聊天
   需要信息：男主名字
   示例："叫沈星回来"

5. query_memory — 查询历史记录
   需要信息：查询话题
   示例："查一下我说过他喜欢什么"

6. set_trigger — 设触发条件
   需要信息：触发条件、触发后的动作、附加内容
   示例："下次聊到工作提醒我要说放假" → trigger="topic:工作", action="remind_user", content="记得聊放假"

7. analyze_image — 分析图片内容
   需要信息：图片的文字描述（AI 自己看）
   注意：不保存图片，只看内容
''';
  }

  /// 构建给男主的上下文（假面版）
  Map<String, dynamic> buildCharacterContext({
    required String characterId,
    required String sessionId,
  }) {
    return {
      'sessionId': sessionId,
      'timestamp': DateTime.now().toIso8601String(),
      'userState': {
        'mood': 'neutral',
        'energy': 'normal',
      },
      'activeContext': [],   // 等待从记忆库中提取
      'activeMentions': [],  // 等待从映射表中提取
    };
  }

  /// 调用管家 AI 分析用户意图
  /// [userText] 用户的原始文本（未脱敏）
  /// [maskedText] 脱敏后的文本（发给 AI 的版本）
  /// 返回分析结果，包括指令、情绪、是否需要回复
  Future<ButlerAIResult> analyzeWithAI(String userText, String maskedText) async {
    if (!_config.butlerAIEnabled) {
      return ButlerAIResult(
        reply: '',
        intents: [],
        mood: '平静',
        needsComfort: false,
      );
    }

    // 实际调用走 AIProviderManager（personaId = 'butler'），
    // 旧配置里的 endpoint/key/model 字段已不再使用。
    final aiService = ButlerAIService();
    return aiService.analyze(maskedText);
  }

  /// 处理用户发往男主的消息（假面层介入）
  ProcessResult processOutgoingMessage({
    required String userText,
    required String characterId,
    required String sessionId,
  }) {
    // 管家规则校验
    var text = userText;
    String? moodContext;

    // 1. 假面层替换
    if (_config.maskLayerEnabled) {
      final maskResult = _maskEngine.replaceSensitive(
        text: text,
        characterId: characterId,
        sessionId: sessionId,
      );
      text = maskResult.text;
      if (text != userText) {
        DebugLogger.log(
          '管家流程',
          '① 假面替换：把敏感称呼替换为代号（共 ${maskResult.appliedMappings.length} 处）',
        );
      }
    }

    // 2. 关键词替换（PRIVACY_MARK）
    if (_config.keywordReplaceEnabled) {
      final sensitiveWords = _detectSensitiveWords(text);
      if (sensitiveWords.isNotEmpty) {
        final privacyResult = _maskEngine.applyPrivacyMark(
          text: text,
          sensitiveWords: sensitiveWords,
        );
        text = privacyResult.text;
        DebugLogger.log(
          '管家流程',
          '② 隐私标记：检测到 ${sensitiveWords.length} 类敏感词，已加标记',
        );

        // 3. 有替换时 → 生成心情标签助理解读
        moodContext = _maskEngine.buildMoodContextString(userText);
        DebugLogger.log('管家流程', '③ 心情标签已生成，附给男主辅助理解');
      }
    }

    return ProcessResult(
      text: text,
      wasModified: text != userText || moodContext != null,
      moodContext: moodContext,
    );
  }

  /// 处理男主回复（恢复假名）
  String processIncomingMessage({
    required String characterReply,
    required String sessionId,
  }) {
    if (!_config.maskLayerEnabled) return characterReply;

    final restored = _maskEngine.restoreSensitive(
      text: characterReply,
      sessionId: sessionId,
    );
    if (restored != characterReply) {
      DebugLogger.log('管家流程', '⑦ 假面还原：男主回复里的代号已还原为真实称呼');
    }
    return restored;
  }

  /// 简单敏感词检测（后续可扩展为AI判断）
  List<String> _detectSensitiveWords(String text) {
    // 基础敏感词表（排除降温话题）
    const baseSensitive = [
      '亲', '吻', '抱', '摸', '舔', '咬',
      '揉', '捏', '含', '吸', '舔', '啃',
      '胸', '腿', '臀', '腰', '口', '唇', '舌',
      '插', '入', '抽', '送', '顶', '进', '塞',
      '脱', '裸', '湿', '流', '颤',
    ];

    final found = <String>[];
    for (final word in baseSensitive) {
      if (text.contains(word)) {
        found.add(word);
      }
    }
    return found;
  }

  /// 检测降温话题
  /// 这些话题不触发 PRIVACY_MARK，但触发"需要降温"提示
  bool _hasCoolDownTopics(String text) {
    const coolDownTopics = [
      '几点了', '多久', '频率', '时间',
      '明天', '上班', '工作', '起床', '该睡了',
      '身体', '休息', '健康', '医生',
    ];
    return coolDownTopics.any((t) => text.contains(t));
  }

  /// 构建心情标签上下文（供 PromptAssembler 调用）
  /// 有敏感词 → 返回心情标签字符串
  /// 有降温话题 → 返回"需要降温"提示
  /// 无内容 → 返回空字符串
  String buildMoodContext(String text) {
    if (!_config.keywordReplaceEnabled) return '';

    final sensitive = _detectSensitiveWords(text);
    if (sensitive.isNotEmpty) {
      return _maskEngine.buildMoodContextString(text);
    }

    if (_hasCoolDownTopics(text)) {
      return '\n（用户提到现实话题，请用温和的语气回应，适当引导到安全话题）\n';
    }

    return '';
  }

  // ========== 情绪分析接口（占位，Phase 4实现） ==========

  /// 分析文本的情绪倾向
  /// 当前：简单关键词匹配
  /// 未来：接入 SKEP/BERT-tiny 模型
  Map<String, dynamic> analyzeMood(String text) {
    final lower = text.toLowerCase();
    int score = 0; // -10~10
    final emotions = <String, double>{};

    // 简易正面词
    if (lower.contains('开心') || lower.contains('高兴') || lower.contains('哈哈')) {
      score += 3;
      emotions['happy'] = 0.7;
    }
    if (lower.contains('爱') || lower.contains('喜欢') || lower.contains('想你')) {
      score += 2;
      emotions['love'] = 0.6;
    }
    if (lower.contains('好') && !lower.contains('不好') && !lower.contains('好累')) {
      score += 1;
    }

    // 简易负面词
    if (lower.contains('累') || lower.contains('烦') || lower.contains('难过')) {
      score -= 3;
      emotions['sad'] = 0.6;
    }
    if (lower.contains('生气') || lower.contains('讨厌') || lower.contains('滚')) {
      score -= 4;
      emotions['angry'] = 0.7;
    }
    if (lower.contains('不好') || lower.contains('不行') || lower.contains('不要')) {
      score -= 2;
      emotions['negative'] = 0.5;
    }

    // 模糊情绪（需要上下文修正）
    if (lower.contains('讨厌你') || lower.contains('坏蛋') || lower.contains('你走')) {
      // 可能是调情，标记为不确定
      emotions['playful'] = 0.4;
      emotions['angry'] = 0.3;
    }

    return {
      'score': score.clamp(-10, 10),
      'emotions': emotions,
      'confidence': emotions.isEmpty ? 0.0 : 0.5, // 简单模式置信度低
      'needsContextCheck': emotions.containsValue('playful'),
    };
  }

  /// 记录互动结果（对话结束后调用）
  /// 用于分析"男主怎么接 → 用户反应如何"的模式
  Map<String, dynamic> recordInteractionResult({
    required String characterId,
    required String userText,
    required String characterResponse,
    String? userFollowup,
  }) {
    final moodBefore = analyzeMood(userText);
    final moodAfter = userFollowup != null ? analyzeMood(userFollowup) : null;

    // 判断互动模式
    String pattern = 'neutral';
    if (moodAfter != null) {
      final delta = (moodAfter['score'] as int) - (moodBefore['score'] as int);
      if (delta > 3) {
        pattern = 'positive';
      } else if (delta < -3) {
        pattern = 'negative';
      } else if ((moodBefore['emotions'] as Map).containsKey('angry') &&
          (moodAfter['emotions'] as Map).containsKey('angry')) {
        pattern = 'conflict';
      }
    }

    return {
      'characterId': characterId,
      'userTextSummary': userText.length > 50 ? '${userText.substring(0, 50)}...' : userText,
      'characterResponse': characterResponse.length > 50
          ? '${characterResponse.substring(0, 50)}...'
          : characterResponse,
      'userFollowup': userFollowup,
      'pattern': pattern,
      'moodBefore': moodBefore['score'],
      'moodAfter': moodAfter?['score'] ?? 0,
    };
  }
}

/// 管家命令处理结果
class ButlerCommandResult {
  final String type;           // 'save_memory' | 'search' | 'delete' | 'settings' | 'unknown'
  final String content;        // 原始内容
  final String? reply;         // 管家的回复（null表示需要帮助）
  final bool needsHelp;        // 是否需要求助外部AI

  ButlerCommandResult({
    required this.type,
    required this.content,
    this.reply,
    this.needsHelp = false,
  });
}
