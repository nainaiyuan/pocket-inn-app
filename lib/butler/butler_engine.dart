import 'mask_engine.dart';
import 'mood_analysis/mood_analyzer_keyword.dart' show KeywordMoodAnalyzer;
import 'risk_filter_wordlist.dart' show RiskWord, privacyMark;
import 'risk_word_store.dart' show RiskWordStore;
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
  Future<ProcessResult> processOutgoingMessage({
    required String userText,
    required String characterId,
    required String sessionId,
  }) async {
    // 确保敏感词表已加载（用户配置；首次启动写入默认表）
    await RiskWordStore.instance.loadWords();
    // 管家规则校验
    var text = userText;
    String? moodContext;

    // 1. 假面层替换（统一替换，不因"跟我念"等指令放行——用户 17:57：
    //    不能一个一个词放行。男主把代号当普通内容，念代号 → 还原层还原成真实称呼）
    //    37批：代号会话级轮换（每次新对话重新分配），男主无法把代号绑定到具体人
    if (_config.maskLayerEnabled) {
      final maskResult = await _maskEngine.replaceSensitive(
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

    // 2. 关键词替换（PRIVACY_MARK）——三档：直接屏蔽 / 提醒（弹窗问用户）/ 放行
    //    每男主开关：本地 AI 男主可关闭（固定格式检测不受影响）
    var askWords = <String>[];
    var blockedWords = <String>[];
    String? maskLayerText; // 敏感词挖空前（假面层已替换）——用户选"不屏蔽"时用
    final riskEnabled = RiskWordStore.instance.cachedEnabled &&
        !RiskWordStore.instance.isCharacterDisabled(characterId);
    if (_config.keywordReplaceEnabled && riskEnabled) {
      final verdict = _detectSensitiveWords(text);
      // 提醒档：先挖空，用户选"不屏蔽"时用 maskLayerText 恢复
      final sensitiveWords = [...verdict.block, ...verdict.ask];
      if (verdict.block.isNotEmpty) {
        blockedWords = verdict.block.map((w) => w.word).toList();
      }
      if (verdict.ask.isNotEmpty) {
        askWords = verdict.ask.map((w) => w.word).toList();
      }
      if (sensitiveWords.isNotEmpty) {
        maskLayerText = text; // 挖空前存档（假面层已替换）
        final privacyResult = _maskEngine.applyPrivacyMark(
          text: text,
          sensitiveWords: sensitiveWords,
        );
        text = privacyResult.text;
        DebugLogger.log(
          '管家流程',
          '② 隐私标记：检测到 ${sensitiveWords.length} 类敏感词，已加标记'
          '（${sensitiveWords.map((w) => w.word).join('/')}）'
          '${verdict.ask.isNotEmpty ? '（其中 ${verdict.ask.map((w) => w.word).join('/')} 为提醒档，待用户确认）' : ''}',
        );

        // 记录触发时间（持续时间因子：持续聊同一话题 → 强度 +1）
        for (final w in sensitiveWords) {
          _lastTriggerTime[w.word] = DateTime.now();
        }
        DebugLogger.log(
          '管家流程',
          '已记录触发时间：${sensitiveWords.map((w) => w.word).join('/')} '
          '（持续窗口 ${sensitiveWords.map((w) => '${w.coolDownMinutes}分钟').join('/')}）',
        );

        // 3. 有替换时 → 生成心情标签助理解读
        moodContext = _maskEngine.buildMoodContextString(userText);
        DebugLogger.log('管家流程', '③ 心情标签已生成，附给男主辅助理解');

        // 4. 全挖空兜底：替换后文本没有可读内容 → 用情绪标签生成 fallback，
        //    男主依然能理解意图（设计：全挖空 → fallback 文本）
        final stripped = text.replaceAll(privacyMark, '').trim();
        if (stripped.isEmpty && moodContext != null) {
          text = '$privacyMark（$moodContext）';
          DebugLogger.log('管家流程', '④ 全挖空 → 用情绪标签生成 fallback 文本');
        }
      }

    }

    // 5. 固定格式敏感信息屏蔽（身份证/手机号/银行卡/邮箱…）
    //    独立于敏感词开关：任何男主都检测（本地 AI 也要），每次命中都弹窗确认
    var formatMatched = <String>[];
    String? formatLayerText;
    final (fmtText, fmtMatchedList) = _maskEngine.applyFormatMask(text);
    if (fmtMatchedList.isNotEmpty) {
      formatMatched = fmtMatchedList;
      formatLayerText = text; // 挖空前存档（敏感词已处理）
      text = fmtText;
      DebugLogger.log(
        '管家流程',
        '⑤ 固定格式检测：${fmtMatchedList.join('/')} → 已标记，待用户确认是否发送',
      );
      // 敏感词没触发时也附情绪标签（男主理解意图）
      moodContext ??= _maskEngine.buildMoodContextString(userText);
    }

    return ProcessResult(
      text: text,
      wasModified: text != userText || moodContext != null,
      appliedMappings: text != userText
          ? {'privacy_mark': '敏感词已替换/挖空'}
          : const {},
      moodContext: moodContext,
      askWords: askWords,
      blockedWords: blockedWords,
      maskLayerText: maskLayerText,
      formatMatched: formatMatched,
      formatLayerText: formatLayerText,
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

  /// 风险词检测（用户词表 + 白名单 + 冷却 + 分级搭配）
  ///
  /// 判定规则（"不是所有时候都是敏感的"）：
  /// 1. 词表 = 用户配置（默认预置：爸爸/妈妈等测试词 + 动作/身体词）
  /// 2. 白名单覆盖：命中词在例外词组内（亲爱的/进口…）→ 不触发
  /// 3. 冷却：该词触发后 coolDownMinutes 分钟内不重复挖空（持续时间维度）
  /// 4. 分级：hard 单独触发；soft 需搭配 hard 或 soft 命中 ≥2
  /// 求知意图：用户在了解敏感词（问意思/感觉/解释）→ 不屏蔽，让男主解释
  static const List<String> _curiosityWords = [
    '什么是', '是什么', '啥是', '啥叫', '解释', '讲讲', '说说',
    '介绍一下', '介绍下', '什么感觉', '什么体验', '科普', '含义',
    '告诉我', '知道吗', '了解吗', '怎么写', '怎么读',
  ];

  bool _isCuriosityIntent(String text) {
    // 常见求知句式直接命中（无问号也算）
    if (text.contains('是什么意思') || text.contains('啥意思')) return true;
    if (!_curiosityWords.any(text.contains)) return false;
    // 有问号，或疑问语气词（吗/么/呀/啊/呢）
    return text.contains('？') ||
        text.contains('?') ||
        text.contains('吗') ||
        text.contains('么') ||
        text.contains('呀') ||
        text.contains('啊') ||
        text.contains('呢');
  }

  _Verdict _detectSensitiveWords(String text) {
    final words = RiskWordStore.instance.cachedWords;
    final exceptions = RiskWordStore.instance.cachedExceptions;
    final now = DateTime.now();
    final hits = <RiskWord>[];
    for (final w in words) {
      if (!text.contains(w.word)) continue;
      // 白名单覆盖 → 该词在此场景不敏感
      if (exceptions.any(
        (e) => text.contains(e) && e.contains(w.word),
      )) {
        continue;
      }
      hits.add(w);
    }
    if (hits.isEmpty) return const _Verdict(block: [], ask: []);

    // 临时豁免：用户选过"这次不屏蔽" → 30 分钟内/情感区间内放行
    RiskWordStore.instance.pruneTempAllows();
    final tempAllows = RiskWordStore.instance.cachedTempAllows;
    final exempted = hits.where((w) {
      final until = tempAllows[w.word];
      return until != null && until.isAfter(DateTime.now());
    }).toList();
    if (exempted.isNotEmpty) {
      DebugLogger.log(
        '管家流程',
        '临时豁免：${exempted.map((w) => w.word).join('/')} 在豁免期内（用户选过不屏蔽）→ 放行',
      );
      hits.removeWhere((w) => exempted.contains(w));
      if (hits.isEmpty) return const _Verdict(block: [], ask: []);
    }

    // 用户已确认过"屏蔽"的词 → 直接屏蔽（不再问）
    final prefs = RiskWordStore.instance.cachedUserPrefs;
    final confirmed = hits.where((w) => prefs[w.word] == RiskWordStore.prefBlock).toList();
    if (confirmed.isNotEmpty) {
      DebugLogger.log(
        '管家流程',
        '用户已确认屏蔽：${confirmed.map((w) => w.word).join('/')} → 直接屏蔽',
      );
      return _Verdict(block: confirmed, ask: const []);
    }

    // 最高敏词（severe，如"做爱"）：任何场景直接屏蔽，求知也不豁免
    // 用户 16:32："做爱是什么感觉？"必须屏蔽，不能让男主展开解释
    final severes = hits.where((h) => h.isSevere).toList();
    if (severes.isNotEmpty) {
      DebugLogger.log(
        '管家流程',
        '最高敏词 ${severes.map((w) => w.word).join('/')} 命中 → 直接屏蔽（求知不豁免）',
      );
      return _Verdict(block: hits, ask: const []);
    }

    // 综合公式判定（用户 16:37：各种信号一起辅助，不是一触发就没了）：
    // score = Σ词基础分（hard +2 / soft +1）
    //       + 情感浓度分（真实 high +2 / medium +1；无情绪信号 +1）
    //       + 基线偏离分（当前 vs 基线差 ≥20 → +1）
    //       + 持续时间分（距上次触发 < 持续窗口 → +1）
    //       + 话题浓度分（命中 ≥2 词 +1；≥3 词 +2）
    //       - 求知减分（求知意图 → -1）
    // score ≥ 3 → 屏蔽
    // 求知只是减分因子，不是一票放行；hard 单词 + 求知 → 2 分不屏蔽（可解释）
    // - A词+B词（≥2 命中）更敏感 → 强度 ≥1 就挖空
    // - 单词（hard）没那么敏感 → 需强度 ≥2 才挖空
    // - soft 单词 → 不挖空
    // 强度分 = 情感浓度 + 基线偏离 + 持续时间（聊到敏感话题持续多久）
    final analyzer = KeywordMoodAnalyzer();
    final mood = analyzer.analyze(text);
    var score = 0;
    final parts = <String>[];

    // ① 词基础分：hard +2 / soft +1（每个命中词累加）
    final wordScore = hits.fold<int>(
      0,
      (a, w) => a + (w.isHard ? 2 : 1),
    );
    score += wordScore;
    parts.add('词${hits.map((w) => '${w.word}${w.isHard ? "(硬)" : "(软)"}').join('/')}+$wordScore');

    // ② 情感浓度分：真实情绪 high +2 / medium +1；无情绪信号（平静兜底）+1
    final cv = mood.concentrationValue;
    final isPureFallback = mood.dimensions.length <= 2 &&
        mood.dimensions.containsKey('平静');
    int concScore;
    if (isPureFallback) {
      concScore = 1; // 无情绪信号 → 中性分（敏感词命中本身说明话题浓度）
    } else if (cv >= 60) {
      concScore = 2;
    } else if (cv >= 30) {
      concScore = 1;
    } else {
      concScore = 0;
    }
    score += concScore;
    parts.add('浓度${isPureFallback ? "平静兜底" : cv.round()}+$concScore');

    // ③ 情感基线偏离：当前情绪 vs 基线差 ≥20 → +1
    final baseline = analyzer.getBaseline();
    var baseScore = 0;
    if (baseline.isNotEmpty) {
      for (final e in mood.dimensions.entries) {
        final b = baseline[e.key];
        if (b != null && (e.value - b).abs() >= 20) {
          baseScore = 1;
          break;
        }
      }
    }
    score += baseScore;
    parts.add('基线$baseScore');

    // ④ 持续时间：距上次触发 < 持续窗口 → 持续中 +1
    final anyRecent = hits.any((w) {
      final last = _lastTriggerTime[w.word];
      return last != null &&
          now.difference(last).inMinutes < w.coolDownMinutes;
    });
    final durScore = anyRecent ? 1 : 0;
    score += durScore;
    parts.add('持续$durScore');

    // ⑤ 话题浓度：命中 ≥2 词 +1；≥3 词 +2（A+B 搭配更敏感）
    final topicScore = hits.length >= 3 ? 2 : (hits.length >= 2 ? 1 : 0);
    score += topicScore;
    parts.add('话题${hits.length}词+$topicScore');

    // ⑥ 求知减分：用户在了解 → -1（只是减分，不是一票放行）
    final curiosity = _isCuriosityIntent(text);
    if (curiosity) {
      score -= 1;
      parts.add('求知-1');
    }

    if (score >= 5) {
      DebugLogger.log(
        '管家流程',
        '屏蔽判定：${hits.map((w) => w.word).join('/')} '
        '（${parts.join('，')} = $score ≥ 5）→ 直接屏蔽',
      );
      return _Verdict(block: hits, ask: const []);
    }
    if (score >= 3) {
      DebugLogger.log(
        '管家流程',
        '提醒判定：${hits.map((w) => w.word).join('/')} '
        '（${parts.join('，')} = $score，3 ≤ score < 5）→ 弹窗问用户',
      );
      return _Verdict(block: const [], ask: hits);
    }
    DebugLogger.log(
      '管家流程',
      '屏蔽判定：${hits.map((w) => w.word).join('/')} '
      '（${parts.join('，')} = $score < 3）→ 放行',
    );
    return _Verdict(block: const [], ask: const []);
  }

  /// 检测降温话题
  /// 这些话题不触发 PRIVACY_MARK，但触发"需要降温"提示
  /// 敏感词最近触发时间：词 → 上次触发（持续时间因子：
  /// 距上次触发 < 持续窗口 → 算"持续聊这个话题"，强度 +1）
  final Map<String, DateTime> _lastTriggerTime = {};

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

    final verdict = _detectSensitiveWords(text);
    if (verdict.block.isNotEmpty || verdict.ask.isNotEmpty) {
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

/// 敏感词判定结果：直接屏蔽档 + 提醒档（放行=两者都空）
class _Verdict {
  final List<RiskWord> block;
  final List<RiskWord> ask;

  const _Verdict({required this.block, required this.ask});
}
