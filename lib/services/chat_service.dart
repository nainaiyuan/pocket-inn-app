import 'dart:async';

import '../ai_provider/ai_provider_manager.dart';
import '../ai_provider/models.dart';
import '../butler/butler.dart';
import '../butler/risk_word_store.dart' show RiskWordStore;
import '../butler/flow/butler_flow.dart';
import '../butler/modules/butler_module_hub.dart';
import '../butler/memory/emotion_arc.dart';
import '../butler/skills/butler_skill.dart';
import '../butler/skills/butler_skill_registry.dart';
import '../butler/skills/chat_skill.dart';
import '../butler/skills/memory_recall_skill.dart';
import '../butler/skills/mood_status_skill.dart';
import '../butler/skills/pattern_query_skill.dart';
import '../butler/tools/butler_tool_registry.dart';
import '../butler/tools/query_tools.dart';
import '../butler/tools/semantic_mood_tool.dart';
import '../butler/mood_analysis/mood_analyzer_keyword.dart';
import '../butler/mood_analysis/semantic_mood_analyzer.dart';
import '../butler/storage/storage_registry.dart';
import '../butler/task/task_manager.dart';
import '../data/mock_user_settings.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/male_lead.dart';
import '../models/preset.dart';
import '../models/prompt_assembly.dart';
import '../models/world_book.dart';
import '../utils/debug_logger.dart';
import 'chat_character_resolver.dart';
import 'character_service.dart';
import 'chat_database_service.dart';
import 'chat_memory_service.dart';
import 'chat_variable_service.dart';
import 'openai_compatible_api_service.dart';
import 'preset_service.dart';
import 'prompt_assembler.dart';
import 'world_book_service.dart';

class ChatSendResult {
  const ChatSendResult({
    required this.userNode,
    required this.assistantNode,
    required this.promptAssembly,
    required this.completion,
    this.blockedWords = const [],
    this.allowedWords = const [],
  });

  final ChatNode userNode;
  final ChatNode assistantNode;
  final PromptAssemblyResult promptAssembly;
  final ChatCompletionResult completion;

  /// 本次直接屏蔽的敏感词（供 UI 告知用户）
  final List<String> blockedWords;

  /// 本次用户选择不屏蔽的敏感词（临时豁免）
  final List<String> allowedWords;
}

class ChatService {
  ChatService._();

  static final ChatService instance = ChatService._();

  /// 管家实例（可选，由 APP 启动时初始化）
  Butler? butler;

  /// 初始化管家
  void initButler(Butler b) {
    butler = b;
    // 注入规律引擎：假面层据此生成"规律联动描述"
    // （男主发现提到某身份时情绪总是什么样 → 下次提到附上这条规律）
    b.maskEngine.patternEngine = ButlerModuleHub.instance.sharedPatternEngine;
    // 预热语义情绪模型（后台加载，不阻塞聊天）
    SemanticMoodAnalyzer.instance.warmUp();
    // 注册内置技能（幂等）
    ButlerSkillRegistry.instance
      ..registerAll([
        MoodStatusSkill(),
        MemoryRecallSkill(),
        PatternQuerySkill(),
        ChatSkill(),
      ]);
    // 注册内置工具（幂等）：管家模块 = 工具，技能通过工具干活
    ButlerToolRegistry.instance.registerAll([
      EmotionArcsQueryTool(),
      PatternQueryTool(),
      BaselineQueryTool(),
      SemanticMoodTool(),
      MemoryRecallTool(),
    ]);
  }

  // ========== 频率限制 ==========
  int _messageCount = 0;
  DateTime _rateLimitReset = DateTime.now();

  /// 检查是否超过频率限制
  /// 每秒最多 5 条消息
  bool _checkRateLimit() {
    final now = DateTime.now();
    if (now.difference(_rateLimitReset).inSeconds >= 1) {
      _messageCount = 0;
      _rateLimitReset = now;
    }
    _messageCount++;
    return _messageCount <= 5;
  }

  Future<ChatSendResult> sendMessage({
    required ChatSession session,
    required ResolvedChatCharacter character,
    required List<ChatMessage> chatMessages,
    required String input,
    String? selectedPresetId,
    String? selectedUserSettingId,
    Set<String> selectedWorldBookIds = const <String>{},
    bool useStreaming = false,
    ChatCompletionCancelToken? cancellationToken,
    void Function(ChatCompletionProgress progress)? onStreamProgress,
    Future<ChatSession> Function()? persistSession,
    /// 提醒档敏感词确认回调（由 UI 层弹窗）：返回 true=屏蔽，false=不屏蔽，null=用户关闭
    Future<bool?> Function(List<String> askWords)? onAskBlock,
    /// 自检模式：不真实调用 AI（模拟回复），不写情绪落库，其余流程全跑。
    /// 用于"一键自检"——不手动聊天也能验证技能/工具/Prompt 组装等管家流程。
    bool selfTest = false,
  }) async {
    // 频率限制
    if (!_checkRateLimit()) {
      throw const FormatException('消息发送太快了，请稍后再试');
    }

    var normalizedInput = input.trim();
    if (normalizedInput.isEmpty) {
      throw const FormatException('消息不能为空');
    }

    // === 流程记录：聊天流程（技能触发 → 组合Prompt → 发送 → 等待 → 存储 → 记录情绪）===
    final sessionId = session.id;
    ButlerFlowRunner.instance.startRecording(
      id: 'chat_flow',
      name: '聊天流程',
      stepIds: const [
        'skill_trigger',
        'mask_replace',
        'assemble_prompt',
        'send_to_lead',
        'split_store',
        'record_mood',
      ],
      stepNames: const [
        '技能触发',
        '假面替换',
        '组合 Prompt',
        '发送男主并等待回复',
        '拆分存储多条',
        '记录情绪与规律',
      ],
    );

    // === 技能触发：匹配技能 → 执行 → 产出注入 Prompt ===
    String? skillInjection;
    try {
      final skill = ButlerSkillRegistry.instance.match(normalizedInput);
      if (skill != null && !skill.isFallback) {
        final result = await skill.execute(
          ButlerSkillContext(
            userText: normalizedInput,
            characterId: character.id,
            characterName: character.name,
            sessionId: sessionId,
          ),
        );
        skillInjection = result.promptInjection;
        ButlerFlowRunner.instance.stepDone(
          'skill_trigger',
          result: '触发技能【${skill.name}】'
              '${skillInjection == null ? '（无注入）' : '（已注入洞察）'}',
        );
      } else {
        ButlerFlowRunner.instance.stepDone(
          'skill_trigger',
          result: '无技能触发，走聊天流程',
        );
      }
    } catch (e) {
      ButlerFlowRunner.instance.stepDone(
        'skill_trigger',
        result: '技能触发失败: $e',
      );
    }

    // === 管家介入：假面层替换 ===
    if (butler != null && butler!.config.maskLayerEnabled) {
      final masked = await butler!.processOutgoing(
        text: normalizedInput,
        characterId: character.id,
        sessionId: sessionId,
      );
      if (masked.wasModified) {
        normalizedInput = masked.text;
        // 身份描述走 system 注入（男主认知层），不进 user 文本 → 不会念出来
        if (masked.maskHints.isNotEmpty) {
          final hints = masked.maskHints.join('；');
          // 告诉男主：以下是参考信息（情绪规律/身份描述），理解即可，不必在回复中提及
          final ref = '以下是关于用户身边人和情绪规律的参考信息，仅帮助你理解，'
              '不必在回复中提及：$hints';
          skillInjection = skillInjection == null
              ? '用户提到的身份代号：$ref'
              : '$skillInjection\n用户提到的身份代号：$ref';
        }
        ButlerFlowRunner.instance.stepDone(
          'mask_replace',
          result: '替换 ${masked.appliedMappings.length} 处敏感称呼',
        );
      } else {
        ButlerFlowRunner.instance.stepDone('mask_replace', result: '无敏感内容');
      }
    } else {
      ButlerFlowRunner.instance.stepDone('mask_replace', result: '假面层未开启');
    }

    if (!AIProviderManager.instance.hasUsable(character.id)) {
      throw StateError('当前没有可用的 AI Provider，请先在设置里配置 API');
    }

    final preset = await _resolvePreset(
      selectedPresetId ?? session.selectedPresetId,
    );
    final userSetting = _resolveUserSetting(
      selectedUserSettingId ?? session.selectedUserSettingId,
    );
    final worldBooks = await _loadSelectedWorldBooks(
      selectedWorldBookIds.isNotEmpty
          ? selectedWorldBookIds
          : session.selectedWorldBookIds.toSet(),
    );

    final memoryContext = await _buildMemoryContext(
      sessionId: session.id,
      chatMessages: chatMessages,
    );

    final promptAssembly = PromptAssembler.build(
      PromptAssemblyContext(
        characterName: character.name,
        characterCardData: character.cardJson,
        userName: userSetting.name,
        userSettingPrompt: userSetting.prompt,
        preset: preset,
        selectedWorldBooks: worldBooks,
        chatMessages: chatMessages,
        currentInput: normalizedInput,
        memoryContext: memoryContext,
        skillContext: skillInjection,
      ),
    );
    DebugLogger.log(
      '管家流程',
      '④ Prompt 组装完成：${promptAssembly.messages.length} 条消息（角色卡/预设/记忆/历史/世界书）',
    );
    ButlerFlowRunner.instance.stepDone(
      'assemble_prompt',
      result: '${promptAssembly.messages.length} 条消息',
    );
    cancellationToken?.throwIfCancelled();

    final activeSession = persistSession == null
        ? session
        : await persistSession();

    final userNode = await ChatDatabaseService.instance.appendUserMessage(
      sessionId: activeSession.id,
      parentMessageId: activeSession.currentLeafMessageId,
      text: normalizedInput,
    );

    try {
      final completion = selfTest
          ? ChatCompletionResult(
              text: '（自检模拟回复）我收到你说的话了：$normalizedInput',
            )
          : await _createCompletion(
              character.id,
              promptAssembly: promptAssembly,
              preset: preset,
              useStreaming: useStreaming,
              cancellationToken: cancellationToken,
              onStreamProgress: onStreamProgress,
            );
      ButlerFlowRunner.instance.stepDone(
        'send_to_lead',
        result: '收到回复 ${completion.text.length} 字'
            '${completion.usage == null ? '' : '（${completion.promptTokens}/${completion.totalTokens} tokens）'}',
      );

      // 男主连续多条：按 <split> 拆分成多条消息，链式存储（UI 显示为一组气泡）
      final segments = splitMultiMessages(completion.text);
      ChatNode? prevNode;
      for (final segment in segments) {
        prevNode = await ChatDatabaseService.instance.appendAssistantMessage(
          sessionId: activeSession.id,
          parentMessageId: (prevNode ?? userNode).id,
          text: segment,
          thinkingChain: prevNode == null ? completion.thinkingChain : null,
        );
      }
      final assistantNode = prevNode!;
      ButlerFlowRunner.instance.stepDone(
        'split_store',
        result: '拆成 ${segments.length} 条消息，已链式存储',
      );

      if (!selfTest) {
        unawaited(
          _tryAutoExtractMemories(
            sessionId: activeSession.id,
            branchLeafId: assistantNode.id,
            chatMessages: chatMessages,
            userMessage: ChatMessage(
              id: userNode.id,
              text: userNode.text,
              isMe: true,
            ),
            assistantMessage: ChatMessage(
              id: assistantNode.id,
              text: assistantNode.text,
              isMe: false,
            ),
            characterName: character.name,
            userName: userSetting.name,
          ),
        );
      }

      // 管家 AI：并行分析用户意图（如果启用）
      if (!selfTest && butler != null && butler!.config.butlerAIEnabled) {
        unawaited(_runButlerAI(input: input, userNode: userNode));
      }

      // 管家情绪闭环：记录情绪弧线 → 更新基线/规律 → 落库（情感基线视图数据源）
      if (selfTest) {
        // 自检模式：不落库（避免污染真实基线），只展示语义识别结果
        final dims = await SemanticMoodAnalyzer.instance
            .analyze(input, waitMs: 500);
        String moodStr = '无显著情绪';
        if (dims != null) {
          final sorted = dims.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          moodStr = sorted
              .take(3)
              .map((e) => '${e.key} ${e.value.round()}')
              .join('、');
        }
        ButlerFlowRunner.instance.stepDone(
          'record_mood',
          result: '语义识别：$moodStr（自检不落库）',
        );
      } else {
        _recordMoodData(characterId: character.id, userText: input);
        ButlerFlowRunner.instance.stepDone('record_mood', result: '情绪弧线已记录');
      }
      DebugLogger.log(
        '管家流程',
        '⑥ 男主回复完成：${segments.length} 条消息，已还原假名并存入会话',
      );

      // 记录 Token 用量到上下文缓存
      if (butler != null && completion.usage != null) {
        butler!.recordTokenUsage(completion.promptTokens, completion.totalTokens);
      }

      // 重新生成路径：无敏感词确认流程
      final blockedWords = <String>[];
      final allowedWords = <String>[];
      ButlerFlowRunner.instance.finishRecording();
      return ChatSendResult(
        userNode: userNode,
        assistantNode: assistantNode,
        promptAssembly: promptAssembly,
        completion: completion,
        blockedWords: blockedWords,
        allowedWords: allowedWords,
      );
    } on ChatCompletionCancelledException {
      ButlerFlowRunner.instance.finishRecording(failed: true);
      rethrow;
    } catch (error) {
      ButlerFlowRunner.instance.finishRecording(failed: true);
      throw StateError('发送聊天请求失败: $error');
    }
  }

  Future<ChatSendResult> regenerateAssistantResponse({
    required ChatSession session,
    required ResolvedChatCharacter character,
    required List<ChatMessage> historyBeforeUserMessage,
    required ChatMessage userMessage,
    String? selectedPresetId,
    String? selectedUserSettingId,
    Set<String> selectedWorldBookIds = const <String>{},
    bool useStreaming = false,
    ChatCompletionCancelToken? cancellationToken,
    void Function(ChatCompletionProgress progress)? onStreamProgress,
  }) async {
    if (userMessage.id == null) {
      throw StateError('用户消息缺少 ID，无法重新生成');
    }
    if (!userMessage.isMe) {
      throw StateError('只能基于用户消息重新生成回复');
    }

    if (!AIProviderManager.instance.hasUsable(character.id)) {
      throw StateError('当前没有可用的 AI Provider，请先在设置里配置 API');
    }

    final preset = await _resolvePreset(
      selectedPresetId ?? session.selectedPresetId,
    );
    final userSetting = _resolveUserSetting(
      selectedUserSettingId ?? session.selectedUserSettingId,
    );
    final worldBooks = await _loadSelectedWorldBooks(
      selectedWorldBookIds.isNotEmpty
          ? selectedWorldBookIds
          : session.selectedWorldBookIds.toSet(),
    );

    final memoryContext = await _buildMemoryContext(
      sessionId: session.id,
      chatMessages: historyBeforeUserMessage,
    );

    final promptAssembly = PromptAssembler.build(
      PromptAssemblyContext(
        characterName: character.name,
        characterCardData: character.cardJson,
        userName: userSetting.name,
        userSettingPrompt: userSetting.prompt,
        preset: preset,
        selectedWorldBooks: worldBooks,
        chatMessages: historyBeforeUserMessage,
        currentInput: userMessage.text,
        memoryContext: memoryContext,
      ),
    );
    cancellationToken?.throwIfCancelled();

    try {
      final completion = await _createCompletion(
        character.id,
        promptAssembly: promptAssembly,
        preset: preset,
        useStreaming: useStreaming,
        cancellationToken: cancellationToken,
        onStreamProgress: onStreamProgress,
      );

      // 男主连续多条：按 <split> 拆分链式存储
      final segments = splitMultiMessages(completion.text);
      String? prevId = userMessage.id;
      ChatNode? lastNode;
      for (final segment in segments) {
        lastNode = await ChatDatabaseService.instance.appendAssistantMessage(
          sessionId: session.id,
          parentMessageId: prevId,
          text: segment,
          thinkingChain: lastNode == null ? completion.thinkingChain : null,
        );
        prevId = lastNode.id;
      }
      final assistantNode = lastNode!;

      unawaited(
        _tryAutoExtractMemories(
          sessionId: session.id,
          branchLeafId: assistantNode.id,
          chatMessages: historyBeforeUserMessage,
          userMessage: ChatMessage(
            id: userMessage.id,
            text: userMessage.text,
            isMe: true,
          ),
          assistantMessage: ChatMessage(
            id: assistantNode.id,
            text: assistantNode.text,
            isMe: false,
          ),
          characterName: character.name,
          userName: userSetting.name,
        ),
      );

      return ChatSendResult(
        userNode: ChatNode(
          id: userMessage.id!,
          sessionId: userMessage.sessionId ?? session.id,
          parentId: userMessage.parentId,
          role: ChatNodeRole.user,
          text: userMessage.text,
          createdAt: DateTime.now(),
          siblingOrder: userMessage.index - 1,
        ),
        assistantNode: assistantNode,
        promptAssembly: promptAssembly,
        completion: completion,
      );
    } on ChatCompletionCancelledException {
      rethrow;
    } catch (error) {
      throw StateError('重新生成聊天回复失败: $error');
    }
  }

  /// 继续推进：基于最后一条角色消息生成新的角色消息。
  /// 使用预设中的 `continue_nudge_prompt` 作为继续提示。
  Future<ChatCompletionResult> continueAssistantResponse({
    required ChatSession session,
    required ResolvedChatCharacter character,
    required List<ChatMessage> chatMessages,
    String? selectedPresetId,
    String? selectedUserSettingId,
    Set<String> selectedWorldBookIds = const <String>{},
    bool useStreaming = false,
    ChatCompletionCancelToken? cancellationToken,
    void Function(ChatCompletionProgress progress)? onStreamProgress,
  }) async {
    if (chatMessages.isEmpty) {
      throw StateError('没有可继续的消息');
    }
    final lastMessage = chatMessages.last;
    if (lastMessage.isMe) {
      throw StateError('只能继续角色消息');
    }
    final lastMessageId = lastMessage.id;
    if (lastMessageId == null) {
      throw StateError('角色消息缺少 ID，无法继续');
    }

    if (!AIProviderManager.instance.hasUsable(character.id)) {
      throw StateError('当前没有可用的 AI Provider，请先在设置里配置 API');
    }

    final preset = await _resolvePreset(
      selectedPresetId ?? session.selectedPresetId,
    );
    final userSetting = _resolveUserSetting(
      selectedUserSettingId ?? session.selectedUserSettingId,
    );
    final worldBooks = await _loadSelectedWorldBooks(
      selectedWorldBookIds.isNotEmpty
          ? selectedWorldBookIds
          : session.selectedWorldBookIds.toSet(),
    );

    final memoryContext = await _buildMemoryContext(
      sessionId: session.id,
      chatMessages: chatMessages,
    );

    final promptAssembly = PromptAssembler.build(
      PromptAssemblyContext(
        characterName: character.name,
        characterCardData: character.cardJson,
        userName: userSetting.name,
        userSettingPrompt: userSetting.prompt,
        preset: preset,
        selectedWorldBooks: worldBooks,
        chatMessages: chatMessages,
        currentInput: '',
        memoryContext: memoryContext,
      ),
    );
    cancellationToken?.throwIfCancelled();

    final continueNudge = ChatVariableService.replacePlaceholders(
      preset.extra['continue_nudge_prompt'] as String? ??
          '[Continue your last message without repeating its original content.]',
      characterName: character.name,
      userName: userSetting.name,
    ).trim();

    final fixedRole = preset.extra['fixed_prompts_role'] as String? ?? 'system';

    final requestMessages = <Map<String, dynamic>>[
      for (final message in promptAssembly.messages)
        {'role': message.role, 'content': message.content},
      if (continueNudge.isNotEmpty)
        {'role': fixedRole, 'content': continueNudge},
    ];

    try {
      final completion = await _createCompletionFromMessages(
        character.id,
        messages: requestMessages,
        preset: preset,
        useStreaming: useStreaming,
        cancellationToken: cancellationToken,
        onStreamProgress: onStreamProgress,
      );

      // 男主连续多条：按 <split> 拆分链式存储
      final segments = splitMultiMessages(completion.text);
      String? prevId = lastMessageId;
      ChatNode? lastNode;
      for (final segment in segments) {
        lastNode = await ChatDatabaseService.instance.appendAssistantMessage(
          sessionId: session.id,
          parentMessageId: prevId,
          text: segment,
          thinkingChain: lastNode == null ? completion.thinkingChain : null,
        );
        prevId = lastNode.id;
      }

      return completion;
    } on ChatCompletionCancelledException {
      rethrow;
    } catch (error) {
      throw StateError('继续推进失败: $error');
    }
  }

  /// 助手帮答：基于当前对话生成一条用户回复，填入输入框。
  /// 使用预设中的 `impersonation_prompt` 作为扮演提示。不写入数据库。
  Future<String> generateUserReply({
    required ChatSession session,
    required ResolvedChatCharacter character,
    required List<ChatMessage> chatMessages,
    String? selectedPresetId,
    String? selectedUserSettingId,
    Set<String> selectedWorldBookIds = const <String>{},
    bool useStreaming = false,
    ChatCompletionCancelToken? cancellationToken,
    void Function(ChatCompletionProgress progress)? onStreamProgress,
  }) async {
    if (!AIProviderManager.instance.hasUsable(character.id)) {
      throw StateError('当前没有可用的 AI Provider，请先在设置里配置 API');
    }

    final preset = await _resolvePreset(
      selectedPresetId ?? session.selectedPresetId,
    );
    final userSetting = _resolveUserSetting(
      selectedUserSettingId ?? session.selectedUserSettingId,
    );
    final worldBooks = await _loadSelectedWorldBooks(
      selectedWorldBookIds.isNotEmpty
          ? selectedWorldBookIds
          : session.selectedWorldBookIds.toSet(),
    );

    final memoryContext = await _buildMemoryContext(
      sessionId: session.id,
      chatMessages: chatMessages,
    );

    final promptAssembly = PromptAssembler.build(
      PromptAssemblyContext(
        characterName: character.name,
        characterCardData: character.cardJson,
        userName: userSetting.name,
        userSettingPrompt: userSetting.prompt,
        preset: preset,
        selectedWorldBooks: worldBooks,
        chatMessages: chatMessages,
        currentInput: '',
        memoryContext: memoryContext,
      ),
    );
    cancellationToken?.throwIfCancelled();

    final impersonationPrompt = ChatVariableService.replacePlaceholders(
      preset.extra['impersonation_prompt'] as String? ??
          '[Write your next reply from the point of view of {{user}}, using the chat history so far as a guideline for the writing style of {{user}}. Don\'t write as {{char}} or system. Don\'t describe actions of {{char}}.]',
      characterName: character.name,
      userName: userSetting.name,
    ).trim();

    final fixedRole = preset.extra['fixed_prompts_role'] as String? ?? 'system';

    final requestMessages = <Map<String, dynamic>>[
      for (final message in promptAssembly.messages)
        {'role': message.role, 'content': message.content},
      if (impersonationPrompt.isNotEmpty)
        {'role': fixedRole, 'content': impersonationPrompt},
    ];

    try {
      final completion = await _createCompletionFromMessages(
        character.id,
        messages: requestMessages,
        preset: preset,
        useStreaming: useStreaming,
        cancellationToken: cancellationToken,
        onStreamProgress: onStreamProgress,
      );
      return completion.text;
    } on ChatCompletionCancelledException {
      rethrow;
    } catch (error) {
      throw StateError('助手帮答失败: $error');
    }
  }

  Future<Preset> _resolvePreset(String? presetId) async {
    if (presetId != null && presetId.trim().isNotEmpty) {
      final preset = await PresetService.instance.loadById(presetId);
      if (preset != null) {
        return preset;
      }
    }

    final fallback = await PresetService.instance.loadDefaultPreset();
    if (fallback != null) {
      return fallback;
    }
    throw StateError('未找到可用预设');
  }

  UserSetting _resolveUserSetting(String? userSettingId) {
    final settings = userSettingsNotifier.value;
    if (settings.isEmpty) {
      return defaultUserSettings.first;
    }

    if (userSettingId != null) {
      for (final item in settings) {
        if (item.id == userSettingId) {
          return item;
        }
      }
    }

    return settings.first;
  }

  Future<List<WorldBook>> _loadSelectedWorldBooks(Set<String> ids) async {
    if (ids.isEmpty) {
      return const [];
    }

    final books = <WorldBook>[];
    for (final id in ids) {
      final book = await WorldBookService.instance.loadById(id);
      if (book != null) {
        books.add(book);
      }
    }
    return books;
  }

  Future<ChatCompletionResult> _createCompletion(
    String personaId, {
    required PromptAssemblyResult promptAssembly,
    required Preset preset,
    required bool useStreaming,
    ChatCompletionCancelToken? cancellationToken,
    void Function(ChatCompletionProgress progress)? onStreamProgress,
  }) async {
    final requestMessages = [
      for (final message in promptAssembly.messages)
        {'role': message.role, 'content': message.content},
    ];

    return _createCompletionFromMessages(
      personaId,
      messages: requestMessages,
      preset: preset,
      useStreaming: useStreaming,
      cancellationToken: cancellationToken,
      onStreamProgress: onStreamProgress,
    );
  }

  /// 统一入口：所有聊天请求都走 AIProviderManager（按男主路由 + 故障切换）。
  /// [personaId] = 男主 id（character.id），用于男主级 Provider 绑定。
  Future<ChatCompletionResult> _createCompletionFromMessages(
    String personaId, {
    required List<Map<String, dynamic>> messages,
    required Preset preset,
    required bool useStreaming,
    ChatCompletionCancelToken? cancellationToken,
    void Function(ChatCompletionProgress progress)? onStreamProgress,
  }) async {
    final manager = AIProviderManager.instance;
    final aiMessages = [
      for (final message in messages)
        AIChatMessage(
          role: (message['role'] as String?) ?? 'user',
          content: (message['content'] as String?) ?? '',
        ),
    ];

    if (!useStreaming) {
      final result = await manager.chat(
        personaId,
        aiMessages,
        defaults: _buildCompletionDefaults(preset, useStreaming: false),
        cancellationToken: cancellationToken,
      );
      final text = result.text.trim();
      if (text.isEmpty) {
        throw const FormatException('聊天接口返回了空回复');
      }
      final thinking = result.thinking.trim();
      return ChatCompletionResult(
        text: text,
        thinkingChain: thinking.isEmpty ? null : thinking,
        usage: result.usage,
      );
    }

    final textBuffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    try {
      await for (final chunk in manager.chatStream(
        personaId,
        aiMessages,
        defaults: _buildCompletionDefaults(preset, useStreaming: true),
        cancellationToken: cancellationToken,
      )) {
        if (chunk.text.isNotEmpty) {
          textBuffer.write(chunk.text);
        }
        if (chunk.thinking.isNotEmpty) {
          thinkingBuffer.write(chunk.thinking);
        }
        onStreamProgress?.call(
          ChatCompletionProgress(
            textDelta: chunk.text,
            thinkingDelta: chunk.thinking,
            done: chunk.done,
          ),
        );
      }
    } on ChatCompletionCancelledException {
      final partialText = textBuffer.toString().trim();
      if (partialText.isEmpty) {
        rethrow;
      }
      final partialThinking = thinkingBuffer.toString().trim();
      return ChatCompletionResult(
        text: partialText,
        thinkingChain: partialThinking.isEmpty ? null : partialThinking,
      );
    }

    final text = textBuffer.toString().trim();
    if (text.isEmpty) {
      throw const FormatException('聊天接口返回了空回复');
    }
    final thinking = thinkingBuffer.toString().trim();
    return ChatCompletionResult(
      text: text,
      thinkingChain: thinking.isEmpty ? null : thinking,
    );
  }

  Future<List<String>> _buildMemoryContext({
    required String sessionId,
    required List<ChatMessage> chatMessages,
  }) async {
    final memoryConfig = memoryExtractionNotifier.value;
    if (!memoryConfig.enabled) return const [];

    final pathIds = chatMessages
        .where((m) => m.id != null)
        .map((m) => m.id!)
        .toList();
    if (pathIds.isEmpty) return const [];

    final memories = await ChatMemoryService.instance.getRecentBranchMemories(
      sessionId: sessionId,
      pathMessageIds: pathIds,
      count: memoryConfig.recallCount,
    );
    return memories.map((m) => m.content).toList();
  }

  Future<void> _tryAutoExtractMemories({
    required String sessionId,
    required String branchLeafId,
    required List<ChatMessage> chatMessages,
    required ChatMessage userMessage,
    required ChatMessage assistantMessage,
    required String characterName,
    required String userName,
  }) async {
    final memoryConfig = memoryExtractionNotifier.value;
    if (!memoryConfig.enabled) return;
    if (memoryConfig.interval <= 0) return;

    final allMessages = [...chatMessages, userMessage, assistantMessage];
    final pathIds = chatMessages
        .where((m) => m.id != null)
        .map((m) => m.id!)
        .toList();
    final newAssistantCount = await _countNewAssistantSinceLastExtraction(
      sessionId: sessionId,
      allMessages: allMessages,
      pathIds: pathIds,
    );
    if (newAssistantCount < memoryConfig.interval) return;

    await ChatMemoryService.instance.tryExtractAndSave(
      sessionId: sessionId,
      branchLeafId: branchLeafId,
      messages: allMessages,
      characterName: characterName,
      userName: userName,
    );
  }

  Future<int> _countNewAssistantSinceLastExtraction({
    required String sessionId,
    required List<ChatMessage> allMessages,
    required List<String> pathIds,
  }) async {
    final memories = await ChatMemoryService.instance.getBranchMemories(
      sessionId: sessionId,
      pathMessageIds: pathIds,
    );
    if (memories.isEmpty) {
      return allMessages.where((m) => !m.isMe).length;
    }
    final processedIds = memories.first.sourceMessageIds.toSet();
    return allMessages
        .where((m) => !m.isMe && m.id != null && !processedIds.contains(m.id))
        .length;
  }

  Map<String, dynamic> _buildCompletionDefaults(
    Preset preset, {
    required bool useStreaming,
  }) {
    return {
      'stream': useStreaming,
      'temperature': preset.temperature,
      'top_p': preset.topP,
      if (preset.openaiMaxTokens > 0) 'max_tokens': preset.openaiMaxTokens,
      if (preset.extra['enable_reasoning'] == true) ...{
        'reasoning_effort': preset.extra['reasoning_effort'] ?? 'medium',
      },
    };
  }

  /// 管家：还原 AI 回复中的假名
  /// 用之前发送消息时建立的会话映射还原真实名称
  String restoreButlerMask(String text, String sessionId) {
    if (butler == null || !butler!.config.maskLayerEnabled) return text;
    return butler!.processIncoming(text: text, sessionId: sessionId);
  }

  /// 男主连续多条：把回复按 <split> 拆成多条消息
  /// - 没有 <split> → 原样单条
  /// - 有 → 拆分、trim、过滤空段；全空时回退单条
  static List<String> splitMultiMessages(String text) {
    final trimmed = text.trim();
    if (!trimmed.contains('<split>')) {
      return [trimmed];
    }
    final segments = trimmed
        .split('<split>')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return segments.isEmpty ? [trimmed] : segments;
  }

  /// 管家情绪闭环：分析用户消息情绪 → 情绪弧线 → 更新基线/规律 → 落库
  ///
  /// 情感基线视图（情绪分析页）的数据就来自这里：
  /// - arcs 落库（按时间/按男主聚合 → 趋势 + 各男主基线）
  /// - 规律引擎（关键词组合 → 情绪偏移 = 触发因素）
  void _recordMoodData({
    required String characterId,
    required String userText,
  }) {
    try {
      final patternEngine = ButlerModuleHub.instance.sharedPatternEngine;
      if (patternEngine == null) return;

      // 情绪分析：先关键词兜底（同步、即时）；模型就绪后由
      // _recordSemanticMood 异步补录语义级弧线（覆盖关键词结果）
      final result = KeywordMoodAnalyzer().analyze(userText);
      final dimensions = result.dimensions;
      final isAnomaly = result.isAnomaly;
      const analyzerName = '关键词';
      final keywords = KeywordMoodAnalyzer.matchKeywords(userText);
      // 追加命中的身份称呼（如"妈妈""老板"）→ 规律引擎会长出
      // "妈妈+烦 → 烦躁上升"这类组合，假面层据此生成规律联动描述
      try {
        final labels =
            butler?.maskEngine.allIdentities.map((e) => e.realLabel).toList() ??
                const <String>[];
        for (final label in labels) {
          if (userText.contains(label) && !keywords.contains(label)) {
            keywords.add(label);
          }
        }
      } catch (_) {}
      if (dimensions.isEmpty) return;

      // 合并男主推测关键词（#keywords 暂存队列）→ 规律引擎据此积累
      if (ButlerPipelineResult.pendingKeywords.isNotEmpty) {
        for (final k in ButlerPipelineResult.pendingKeywords) {
          if (!keywords.contains(k)) keywords.add(k);
        }
        DebugLogger.log(
          '管家流程',
          '🎯 男主推测关键词已并入弧线: '
          '${ButlerPipelineResult.pendingKeywords.join('、')}',
        );
        ButlerPipelineResult.pendingKeywords.clear();
      }

      final now = DateTime.now();
      final arc = EmotionArc(
        id: 'arc_${now.millisecondsSinceEpoch}',
        time: now,
        characterId: characterId,
        triggerKeywords: keywords,
        startMood: patternEngine.baseline.allValues,
        peakMood: dimensions,
        endMood: dimensions,
        returnedToBaseline: !isAnomaly,
        durationMinutes: 1,
      );

      // 更新基线 + 规律统计（关键词组合 → 情绪偏移）
      patternEngine.addArc(arc);
      // 落库：情感基线视图的数据源
      StorageRegistry.instance.emotionArcs.save(arc);

      final moodStr = dimensions.entries
          .map((e) => '${e.key} ${e.value.round()}')
          .join(' ');
      DebugLogger.log(
        '管家情绪',
        '[$analyzerName]弧线已记录：关键词[${keywords.isEmpty ? '无' : keywords.join('、')}] → $moodStr',
      );

      // 语义级分析（模型就绪后异步补录，覆盖关键词结果）
      unawaited(_recordSemanticMood(characterId: characterId, userText: userText));
    } catch (e) {
      DebugLogger.log('管家情绪', '情绪记录失败: $e');
    }
  }

  /// 语义级情绪补录：模型就绪后分析原文，覆盖关键词弧线
  Future<void> _recordSemanticMood({
    required String characterId,
    required String userText,
  }) async {
    try {
      final patternEngine = ButlerModuleHub.instance.sharedPatternEngine;
      if (patternEngine == null) return;
      final dimensions = await SemanticMoodAnalyzer.instance.analyze(
        userText,
        waitMs: 2000, // 首次等模型加载，之后秒回
      );
      if (dimensions == null) return;

      final keywords = KeywordMoodAnalyzer.matchKeywords(userText);
      final now = DateTime.now();
      final arc = EmotionArc(
        id: 'arc_sem_${now.millisecondsSinceEpoch}',
        time: now,
        characterId: characterId,
        triggerKeywords: keywords,
        startMood: patternEngine.baseline.allValues,
        peakMood: dimensions,
        endMood: dimensions,
        returnedToBaseline: true,
        durationMinutes: 1,
      );
      patternEngine.addArc(arc);
      StorageRegistry.instance.emotionArcs.save(arc);

      final moodStr = dimensions.entries
          .map((e) => '${e.key} ${e.value.round()}')
          .join(' ');
      DebugLogger.log('管家情绪', '[语义模型]弧线已记录 → $moodStr');
    } catch (e) {
      DebugLogger.log('管家情绪', '语义补录失败: $e');
    }
  }

  /// 管家 AI：异步分析用户意图并管理任务
  Future<void> _runButlerAI({
    required String input,
    required dynamic userNode,
  }) async {
    try {
      final result = await butler!.analyzeWithAI(input);
      if (result.hasIntents) {
        // 创建任务
        final tasks = TaskManager.instance.createTasks(result.intents);

        // 自动执行（只自动执行简单任务，复杂任务等用户确认）
        for (final task in tasks) {
          if (_canAutoExecute(task.type)) {
            final taskResult = await TaskManager.instance.execute(task.id);
            if (taskResult.success) {
              // 执行成功，通知用户
              DebugLogger.log('管家', '任务 #${task.id} 已完成: ${task.description}');
            } else {
              // 执行失败，记录错误
              DebugLogger.log('管家', '任务 #${task.id} 失败: ${taskResult.error}');
            }
          } else {
            // 需要用户确认的任务
            DebugLogger.log('管家', '新任务 #${task.id}: ${task.description}');
          }
        }
      } else if (result.shouldReply) {
        // 纯安慰/回复，显示在聊天界面
        DebugLogger.log('管家', '回复: ${result.reply}');
      }
    } catch (e) {
      // 管家 AI 失败不影响主流程
      DebugLogger.log('管家', 'AI 分析失败: $e');
    }
  }

  /// 判断任务类型是否可以自动执行
  /// 自动执行：不需要用户额外确认的简单任务
  /// 需确认：可能影响用户数据的操作
  bool _canAutoExecute(String taskType) {
    switch (taskType) {
      case 'save_note':
        return true;
      case 'set_config':
        return true;
      case 'lock_vault':
        return false; // 需要用户确认
      case 'call_character':
        return true;
      case 'query_memory':
        return true;
      case 'set_trigger':
        return true;
      case 'analyze_image':
        return true;
      default:
        return false;
    }
  }
}

/// 一键自检：不手动聊天，直接跑管家全流程验证
///
/// 用法：ChatService.instance.runSelfTest()（需先 initButler）
/// 3 条测试消息依次走完整流程（技能匹配→假面→Prompt 组装→发送(模拟)→存储→情绪识别），
/// 每条消息的流程树会出现在日志页「流程」视图，这里汇总检查点 ✔/✖。
class ButlerSelfTestReport {
  final List<ButlerSelfTestItem> items;
  final Duration elapsed;
  final int passCount;

  ButlerSelfTestReport({
    required this.items,
    required this.elapsed,
  }) : passCount = items.where((i) => i.passed).length;

  bool get allPassed => passCount == items.length;
}

class ButlerSelfTestItem {
  final String message; // 测试消息原文
  final String expected; // 预期
  final String actual; // 实际
  final bool passed;
  final String? failedReason;

  /// 失败时的解决建议（自检页展示："怎么办"）
  final String? guidance;

  ButlerSelfTestItem({
    required this.message,
    required this.expected,
    required this.actual,
    required this.passed,
    this.failedReason,
    this.guidance,
  });
}

/// 轻量管家管线结果（新版聊天页用）
class ButlerPipelineResult {
  /// 假面层替换后的文本（无替换时 = 原文）
  final String maskedText;

  /// 男主推测关键词暂存队列（#keywords 解析后，下轮情绪记录时并入弧线）
  static final List<String> pendingKeywords = [];

  /// 从男主回复中解析 #keywords 并剥离（仅管家可见，不显示给用户）
  /// 返回剥离命令后的显示文本；解析到的关键词进暂存队列
  static String extractKeywordsFromReply(String reply) {
    final m = RegExp(r'#keywords\s+([^\n#]+)').firstMatch(reply);
    if (m == null) return reply;
    final words = m
        .group(1)!
        .split(RegExp(r'[,，、\s]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isNotEmpty) {
      pendingKeywords.addAll(words);
      DebugLogger.log('管家流程', '🎯 男主推测关键词: ${words.join('、')}（已暂存，下轮并入弧线）');
    }
    return reply.replaceRange(m.start, m.end, '').trim();
  }
  /// 技能注入内容（塞进 AI prompt；无技能/无注入 = null）
  final String? skillInjection;

  /// 温控询问指令（情绪超基线 → 让男主在回复末尾附 #keywords，仅管家可见）
  final String? keywordAsk;

  const ButlerPipelineResult({
    required this.maskedText,
    this.skillInjection,
    this.keywordAsk,
  });
}

/// 自检入口（ChatService 扩展）
extension ButlerSelfTest on ChatService {
  /// 轻量管家管线（新版聊天页用）：
  /// 技能触发 → 假面替换 → 情绪记录，全程流程树可见。
  /// 返回替换后的文本 + 技能注入；不落库聊天消息（新版聊天页不持久化会话）。
  Future<ButlerPipelineResult> runButlerPipeline({
    required String userText,
    required String characterId,
    required String characterName,
    String? sessionId,
  }) async {
    ButlerFlowRunner.instance.startRecording(
      id: 'chat_flow',
      name: '聊天流程',
      stepIds: const ['skill_trigger', 'mask_replace', 'record_mood', 'keyword_ask'],
      stepNames: const ['技能触发', '假面替换', '记录情绪与规律', '温控询问'],
    );

    var text = userText.trim();
    String? skillInjection;

    // 1. 技能触发：匹配 → 执行（内部调工具）→ 产出注入
    try {
      final skill = ButlerSkillRegistry.instance.match(text);
      if (skill != null && !skill.isFallback) {
        final result = await skill.execute(
          ButlerSkillContext(
            userText: text,
            characterId: characterId,
            characterName: characterName,
            sessionId: sessionId ?? 'chat_page',
          ),
        );
        skillInjection = result.promptInjection;
        ButlerFlowRunner.instance.stepDone(
          'skill_trigger',
          result: '触发技能【${skill.name}】'
              '${skillInjection == null ? '（无注入）' : '（已注入洞察）'}',
        );
      } else {
        ButlerFlowRunner.instance.stepDone(
          'skill_trigger',
          result: '无技能触发，走聊天流程',
        );
      }
    } catch (e) {
      ButlerFlowRunner.instance.stepDone('skill_trigger', result: '技能触发失败: $e');
    }

    // 2. 假面层：敏感称呼替换
    if (butler != null && butler!.config.maskLayerEnabled) {
      final masked = await butler!.processOutgoing(
        text: text,
        characterId: characterId,
        sessionId: sessionId ?? 'chat_page',
      );
      if (masked.wasModified) {
        text = masked.text;
        ButlerFlowRunner.instance.stepDone(
          'mask_replace',
          result: '替换 ${masked.appliedMappings.length} 处敏感称呼',
        );
      } else {
        ButlerFlowRunner.instance.stepDone('mask_replace', result: '无敏感内容');
      }
    } else {
      ButlerFlowRunner.instance.stepDone('mask_replace', result: '假面层未开启');
    }

    // 3. 情绪记录：关键词 → 弧线 → 规律 → 落库（真实收集）
    _recordMoodData(characterId: characterId, userText: userText);
    ButlerFlowRunner.instance.stepDone('record_mood', result: '情绪弧线已记录');

    // 4. 温控询问：情绪超基线 → 让男主在回复末尾附 #keywords（仅管家可见）
    //    基线空/样本少时也触发 → 一开始就快速积累关键词找规律
    String? keywordAsk;
    try {
      final pe = ButlerModuleHub.instance.sharedPatternEngine;
      if (pe != null && butler != null && butler!.config.maskLayerEnabled) {
        final mood = KeywordMoodAnalyzer().analyze(userText);
        final base = pe.baseline;
        final dims = mood.dimensions;
        final exceeds = !base.isReliable ||
            dims.entries.any((e) =>
                (e.value - (base.allValues[e.key] ?? 0)).abs() > 20);
        if (exceeds && dims.isNotEmpty) {
          final top = dims.entries
              .reduce((a, b) => a.value >= b.value ? a : b);
          keywordAsk =
              '（管家观察：用户情绪「${top.key} ${top.value.round()}」超出当前基线。'
              '请在回复末尾附一行 #keywords 关键词1,关键词2 —— 你推测导致用户'
              '情绪变化的关键词；这一行仅管家可见，不要告诉用户）';
          ButlerFlowRunner.instance.stepDone(
            'keyword_ask',
            result: '情绪超基线（${top.key}+${top.value.round()}）→ 请男主附关键词',
          );
        }
      }
    } catch (_) {}
    ButlerFlowRunner.instance.finishRecording();

    return ButlerPipelineResult(
      maskedText: text,
      skillInjection: skillInjection,
      keywordAsk: keywordAsk,
    );
  }

  /// 跑一遍管家全流程自检。返回汇总报告；详细过程见日志页流程树。
  Future<ButlerSelfTestReport> runSelfTest() async {
    final items = <ButlerSelfTestItem>[];
    final sw = Stopwatch()..start();

    // ── 准备：找第一个角色（没有就用占位角色）──
    MaleLead? lead;
    try {
      final leads = await CharacterService.instance.loadAllSummaries();
      if (leads.isNotEmpty) lead = leads.first;
    } catch (_) {}
    final character = ResolvedChatCharacter(
      id: lead?.id ?? 'self_test_character',
      name: lead?.name ?? '测试男主',
      description: '',
      cardJson: const {},
    );

    // ── 建独立测试会话（测完删除，不污染真实会话）──
    ChatSession? testSession;
    try {
      testSession = await ChatDatabaseService.instance.createSession(
        characterId: character.id,
        title: '⚙ 自检会话（可删除）',
      );
    } catch (e) {
      items.add(ButlerSelfTestItem(
        message: '（环境）',
        expected: '创建测试会话',
        actual: '失败: $e',
        passed: false,
        failedReason: '无法创建测试会话，后续步骤跳过',
      ));
      return ButlerSelfTestReport(items: items, elapsed: sw.elapsed);
    }

    // ── 环境检查：假面层是否配置了身份词 ──
    final identities = butler?.maskEngine.allIdentities ?? const <dynamic>[];
    items.add(ButlerSelfTestItem(
      message: '（环境）假面层身份词',
      expected: '已配置 ≥1 个身份词（如"妈妈"→[家人1]）',
      actual: identities.isEmpty
          ? '未配置任何身份词'
          : '已配置 ${identities.length} 个：${identities.map((e) => (e as dynamic).realLabel).take(4).join('、')}',
      passed: identities.isNotEmpty,
      failedReason: identities.isEmpty ? '假面层没有替换词，替换功能无法生效' : null,
      guidance: identities.isEmpty
          ? '打开右侧栏 → 假面层 → 添加身份词（如"妈妈""老板"），或点"让管家生成"自动生成'
          : null,
    ));

    // ── 依次跑 5 条测试消息 ──
    final testCases = [
      (
        text: '今天天气真好啊',
        expect: '无技能触发，走聊天流程 + 语义情绪识别',
        keyStep: 'skill_trigger',
        keyResult: '无技能触发',
      ),
      (
        text: '我今天心情好差，感觉好累',
        expect: '触发【情绪状态洞察】+ 3 个工具调用',
        keyStep: 'skill_trigger',
        keyResult: '情绪状态洞察',
      ),
      (
        text: '我妈妈说我太懒了',
        expect: '假面层处理（有配置则替换敏感称呼）',
        keyStep: 'mask_replace',
        keyResult: '',
      ),
      (
        text: '你还记得我之前说过喜欢喝什么吗',
        expect: '触发【记忆检索】+ 工具调用',
        keyStep: 'skill_trigger',
        keyResult: '记忆检索',
      ),
      (
        text: '我发现自己一聊到工作就烦',
        expect: '触发【情绪规律查询】+ 工具调用',
        keyStep: 'skill_trigger',
        keyResult: '情绪规律查询',
      ),
    ];

    for (final tc in testCases) {
      final flowBefore = ButlerFlowRunner.instance.history.length;
      String actual = '';
      bool passed = true;
      String? reason;

      try {
        await sendMessage(
          session: testSession!,
          character: character,
          chatMessages: const [],
          input: tc.text,
          selfTest: true,
        );
        // 从流程树读取结果（和用户看到的一致）
        final newFlows = ButlerFlowRunner.instance.history
            .take(ButlerFlowRunner.instance.history.length - flowBefore)
            .toList();
        final flow = newFlows.isNotEmpty ? newFlows.first : null;
        if (flow == null) {
          actual = '流程树没有新增记录';
          passed = false;
          reason = 'sendMessage 未产生流程记录';
        } else {
          final step = flow.steps
              .where((s) => s.id == tc.keyStep)
              .toList()
              .firstOrNull;
          final stepResult = step?.result ?? '';
          if (tc.keyResult.isNotEmpty &&
              !stepResult.contains(tc.keyResult)) {
            passed = false;
            reason = '步骤「${step?.name ?? tc.keyStep}」结果不符: $stepResult';
          }
          final toolCount = flow.toolCalls.length;
          final moodStep = flow.steps
              .where((s) => s.id == 'record_mood')
              .toList()
              .firstOrNull;
          actual = '流程${flow.isSuccessful ? '成功' : '失败'}'
              '（$toolCount 个工具调用）'
              ' › ${stepResult.isNotEmpty ? stepResult : '无关键结果'}'
              ' › ${moodStep?.result ?? ''}';
          if (!flow.isSuccessful) {
            passed = false;
            reason ??= '流程未成功完成';
          }
        }
      } catch (e) {
        passed = false;
        actual = '异常: $e';
        reason = '发送消息抛异常';
      }

      items.add(ButlerSelfTestItem(
        message: tc.text,
        expected: tc.expect,
        actual: actual,
        passed: passed,
        failedReason: reason,
        guidance: reason != null ? _guidanceFor(tc.text, reason) : null,
      ));
    }

    // ── 清理测试会话 ──
    try {
      await ChatDatabaseService.instance.deleteSession(testSession.id);
    } catch (_) {}

    return ButlerSelfTestReport(items: items, elapsed: sw.elapsed);
  }

  /// 根据失败原因给出解决建议（测试期"有 bug 明显一点，告诉用户怎么了、怎么办"）
  String _guidanceFor(String text, String reason) {
    if (text.contains('心情') || text.contains('情绪')) {
      return '检查：规律引擎是否就绪（initButler 后自动创建）。'
          '还不行就重启 APP 再试。';
    }
    if (text.contains('还记得') || text.contains('记得')) {
      return '记忆为空是正常的：先和男主聊几句让管家总结记忆，'
          '或在「记忆管理」里手动添加一条，再来自检。';
    }
    if (text.contains('一聊到') || text.contains('规律')) {
      return '规律需要积累：多聊几次相关话题（至少2次确认）后才会出现。'
          '先用第2条用例验证情绪洞察技能是否正常。';
    }
    return '参考日志页 🐞 → 流程视图，看哪一步标红；把截图发给龙虾。';
  }
}
