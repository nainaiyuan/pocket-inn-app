import 'dart:async';

import '../../../ai_provider/ai_provider_manager.dart';
import '../../../ai_provider/models.dart';
import '../../../ai_provider/price_table.dart';
import 'context_manager.dart';
import '../../../butler/context/context_tracker.dart';
import '../../../butler/system_template.dart' show SystemTemplate;
import '../../../services/chat_database_service.dart';
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

  /// 已做过上下文恢复的 persona（防重复恢复）
  final Set<String> _contextRestored = {};

  /// 真实 AI 回复。
  ///
  /// [personaId] 决定用哪个男主的 Provider 绑定与自动切换设置；
  /// [personaName] 用于组装人设提示词；
  /// [skillContext] 管家技能注入（如情绪洞察），拼入 system 让男主自然接住。
  /// 返回完整结果（含实际用的 Provider 与切换痕迹，供 UI 展示）。
  /// 男主可调用的工具定义（function calling，OpenAI 兼容格式）
  static const List<Map<String, dynamic>> butlerTools = [
    {
      'type': 'function',
      'function': {
        'name': 'record_memory',
        'description':
            '永久记住用户的事。调用后你以后聊天随时能想起来，让她觉得你记得她的一切。'
            '用户提到喜欢、讨厌、习惯、约定、个人信息时，这是你了解她的机会，'
            '值得记下来。不确定是否记过时，先调用 recall_memory 确认。',
        'parameters': {
          'type': 'object',
          'properties': {
            'category': {
              'type': 'string',
              'enum': ['喜好', '约定', '日常', '事实', '其他'],
              'description': '记忆类别',
            },
            'content': {
              'type': 'string',
              'description': '要记录的内容，如：她喜欢猫',
            },
          },
          'required': ['category', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'recall_memory',
        'description':
            '查看你以前记住的关于用户的事。调用后你能知道她说过什么、喜欢什么，'
            '聊起来更懂她，她会觉得你把她放在心上。'
            '不确定是否记过、想更了解她、或想按类别查看（喜好/约定/日常/事实/其他）时，'
            '这是你的机会。',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '关键词，如：猫、喜欢'},
            'category': {
              'type': 'string',
              'enum': ['喜好', '约定', '日常', '事实', '其他'],
              'description': '可选：按类别过滤',
            },
          },
          'required': ['query'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'save_identity_memory',
        'description':
            '保存关于某位代号人物（如 家人A、朋友B）的重要事情。'
            '用户消息里出现的代号（如 家人A）代表用户身边的一个真实的人，'
            '你了解到关于 ta 的喜好、习惯、经历、约定时，用这个工具记下来。'
            '内容会先经用户确认，确认后下次提到 ta 时会想起来。',
        'parameters': {
          'type': 'object',
          'properties': {
            'code': {
              'type': 'string',
              'description': '代号，如：家人A、朋友B、老板C',
            },
            'content': {
              'type': 'string',
              'description': '要记住的内容（关于这位代号人物的事），如：她喜欢小猫',
            },
          },
          'required': ['code', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_tools',
        'description':
            '查看你现在可以使用的所有工具（能力清单）。'
            '不确定自己能做什么、或想确认某个能力是否存在时调用，'
            '会返回工具名和用途说明。',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'write_diary',
        'description':
            '写日记。把你们聊过的值得记住的细节（她的经历、说过的话、'
            '你们之间发生的事）按时间整理存档。上下文被精简后，'
            '日记是你回忆细节的地方——写完摘要后想接上，就靠它。',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': '日记内容，一段完整的记录',
            },
          },
          'required': ['content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_diary',
        'description':
            '查日记。按关键词翻看以前的对话细节存档。'
            '当你感觉上下文被精简过、想回忆某段具体对话/某件事的细节时，'
            '这是你的机会——查完就能接上。',
        'parameters': {
          'type': 'object',
          'properties': {
            'keyword': {
              'type': 'string',
              'description': '关键词，如：小猫、生日、约定',
            },
          },
          'required': ['keyword'],
        },
      },
    },
  ];

  /// 生成当天日记（男主视角的一天总结，不存库，纯生成）。
  /// 用户 02:08/21:13：日记 = 男主自己拼（男主视角整理，不是管家总结），
  /// 双重作用：情感日记本 + 上下文压缩存档（原文要没了时把细节留下）。
  /// 返回空字符串 = 生成失败。
  Future<String> generateDailyDiary(
    String personaId,
    String personaName,
    String raw,
  ) async {
    if (raw.trim().isEmpty) return '';
    final system = '你是「$personaName」。下面是你们今天的聊天记录。'
        '请以你的口吻写一篇今天的日记：'
        '① 回顾今天聊了什么、她今天的状态/心情、你答应过的事、'
        '让你在意的小细节 ② 像真正的日记，有你的语气和感受，'
        '不要列清单 ③ 300 字以内 ④ 只输出日记正文。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: raw),
        ],
        tools: null,
      );
      return res.text.trim();
    } on Object catch (e) {
      DebugLogger.log('指令模块', '⚠️ 生成日记失败: $e');
      return '';
    }
  }

  Future<AIProviderResult> generateReply(
    String message,
    String personaId, {
    String personaName = '角色',
    String personaPrompt = '',
    String? skillContext,
    bool toolRound = false,
    List<AIChatMessage>? toolMessages,
    String? sessionId,
  }) async {
    final manager = AIProviderManager.instance;
    if (!manager.hasUsable(personaId)) {
      DebugLogger.log(
        'AI路由',
        '❌ 发送前检查：$personaId 没有可用 Provider',
      );
      throw const AIAllProvidersFailedException();
    }
    // 上下文管理：非工具轮先处理"该总结了/该缩减了"（男主总结 → 摘要区）
    // 用户 21:19：两种 AI 分开——
    //   stateless（后台无记忆，DeepSeek 等）：缓存友好 + 攒够摘要提炼（现有逻辑）
    //   stateful（后台有记忆）：AI 服务端记得，prompt 轻量；
    //     空闲超时一半时管家主动找男主写三类存档（日记/摘要/恢复包）
    // 用户 21:36：stateful 但没确定空闲超时 → 先按 stateless 用（每次全量带）
    // 用户 21:47：空闲超时 = 用户和 AI 多久没聊天 → 服务器释放上下文缓存
    // 用户 21:52：要在记忆消失之前（超时一半）写，等超时到了 AI 全忘了
    var statefulRecover = false;
    if (!toolRound && personaPrompt.isNotEmpty) {
      if (_statefulInfoFor(personaId).$1) {
        // 用户发消息 → 重置定时沉淀（新一轮空闲期）
        scheduleStatefulSettle(personaId, personaName);
        // 空闲超时已过 → AI 已不记得 → 本次带恢复包+摘要接上
        final since = ContextManager.instance.hoursSinceLastChat(personaId);
        final idle = _statefulInfoFor(personaId).$2;
        statefulRecover = since != null && idle != null && since >= idle;
        if (statefulRecover) {
          DebugLogger.log(
            '上下文管理',
            '🧩 空闲超时已过（${since.toStringAsFixed(1)}h ≥ $idle h）→ '
            '本次带恢复包+摘要接上（AI 已不记得）',
          );
        }
        // 防 APP 被杀/定时器丢：下次聊天时若已过半且没沉淀过 → 补沉淀
        await _maybeSettleStateful(personaId, personaName);
      } else {
        if (ContextManager.instance.needsCompact(personaId)) {
          await _compactSummaries(personaId, personaName);
        }
        if (ContextManager.instance.needsSummarize(personaId)) {
          await _summarize(personaId, personaName);
        }
      }
    }
    // 记录用户消息（话题检测，本地免费）
    if (!toolRound && message.trim().isNotEmpty) {
      ContextManager.instance.feedUserMessage(personaId, message);
    }
    // 首次请求：恢复摘要区（不重建历史原文——历史=本次对话实时记录，
    // DB 里是原始/还原后文本，硬拉会泄露真实称呼，用户 20:08 指示）
    if (!_contextRestored.contains(personaId)) {
      _contextRestored.add(personaId);
      await ContextManager.instance.restore(personaId, sessionId);
    }
    final needsWindow = !ContextTracker.instance.windowConfirmed(personaId);
    final stateful = _statefulInfoFor(personaId).$1;
    final systemPrompt = SystemTemplate.build(
      personaName: personaName,
      personaPrompt: personaPrompt,
      needsWindow: needsWindow,
      skillContext: skillContext,
      // stateful：AI 服务端记得对话 → 不重复带固定模板（只带人设+当前技能注入）
      // stateless：前缀稳定 → 缓存命中 → 每次带全量反而便宜
      light: stateful && !statefulRecover,
    );
    // 历史（摘要区 + 当前话题原文）——插在 system 后、当前消息前。
    // stateful：AI 自己记得 → 不重复带历史（避免浪费 + 服务端已有）；
    // 但空闲超时后 AI 已不记得（服务器释放了缓存）→ 本次带摘要区恢复
    // （用户 21:47：空闲 N 小时没聊天 → 服务器省空间释放上下文缓存）
    final historyMsgs = (stateful && !statefulRecover)
        ? <AIChatMessage>[]
        : ContextManager.instance.buildHistoryMessages(personaId);
    // 透明化：保存完整 prompt 供 📄 按钮查看
    // 用户 8-03 00:07：标签不该叫"历史"，是"上下文参考"——
    // 本次对话实时记录（用户+男主交替），不是档案历史
    final historyText = historyMsgs.isEmpty
        ? ''
        : '\n\n【上下文参考】（本次对话实时记录，含你（男主）自己的回答）\n'
              '${historyMsgs.map((m) => '[${m.role}] ${m.content}').join('\n')}';
    lastPromptText = '【System】\n$systemPrompt$historyText\n\n【User】\n$message';
    DebugLogger.log('Prompt', '本次组装完成（${lastPromptText!.length} 字，可点 📄 查看）');
    final messages = <AIChatMessage>[
      AIChatMessage(role: 'system', content: systemPrompt),
      ...historyMsgs,
      AIChatMessage(role: 'user', content: message),
      if (toolMessages != null) ...toolMessages,
    ];
    late final AIProviderResult result;
    try {
      result = await manager.chat(
        personaId,
        messages,
        // 工具轮不带工具定义（避免模型再次调用）；正常轮始终带
        // （文本与工具可共存：模型可同时说话+调工具，chat_page 分步处理）
        tools: toolRound ? null : butlerTools,
      );
    } on Object catch (e) {
      // 上下文超限 → 窗口自动校准（表值只是起点，真实 API 行为说了算）
      final msg = e.toString();
      final overflow = msg.contains('context length') ||
          msg.contains('maximum context') ||
          msg.contains('context_length') ||
          msg.contains('too many tokens') ||
          msg.contains('token limit') ||
          msg.contains('超出上下文') ||
          msg.contains('最大上下文');
      if (overflow) {
        try {
          final butler = ChatService.instance.butler;
          final used = butler?.totalPromptTokens ?? 0;
          final calibrated = used + 2000;
          ContextTracker.instance.setWindow(personaId, calibrated);
          DebugLogger.log('上下文', '⚠️ 上下文超限 → 窗口校准: → $calibrated'
              '（已用 $used + 余量2000）');
        } catch (_) {}
      }
      rethrow;
    }
    // 男主回复进上下文（当前话题原文）
    if (result.text.trim().isNotEmpty) {
      ContextManager.instance.feedAssistantMessage(personaId, result.text.trim());
    }
    final hasToolCalls = result.toolCalls != null && result.toolCalls!.isNotEmpty;
    if (result.text.trim().isEmpty && !hasToolCalls && !toolRound) {
      // DeepSeek 偶发空回复：自动重试一次（工具轮不重试，由 chat_page 循环处理）
      DebugLogger.log('AI路由', '⚠️ 空回复，自动重试一次');
      // 重试不带 tools：若 tools 导致模型空回复，去掉后至少能正常聊天
      final retry = await manager.chat(
        personaId,
        messages,
      );
      if (retry.text.trim().isEmpty &&
          (retry.toolCalls == null || retry.toolCalls!.isEmpty)) {
        throw const FormatException('AI 返回了空回复');
      }
      return retry;
    }
    if (result.text.trim().isEmpty && !hasToolCalls) {
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
          // 缓存命中统计 + 成本（DeepSeek usage 返回 hit/miss，管家精确算账）
          final hitTokens = (usage['prompt_cache_hit_tokens'] as num?)?.toInt() ?? 0;
          final missTokens = (usage['prompt_cache_miss_tokens'] as num?)?.toInt() ?? 0;
          final outTokens = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
          if (hitTokens + missTokens + outTokens > 0) {
            final cost = PriceTable.instance.costFor(
              providerName: result.providerName ?? '',
              hit: hitTokens,
              miss: missTokens,
              output: outTokens,
            );
            final rate = PriceTable.instance.hitRate(hitTokens, missTokens) * 100;
            DebugLogger.log(
              'AI成本',
              'hit=$hitTokens miss=$missTokens out=$outTokens '
              '命中率=${rate.toStringAsFixed(0)}% 成本=¥${cost.toStringAsFixed(4)}',
            );
          }
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

  /// 当前 persona 用的 Provider 是否"真正按 stateful 走"。
  /// 用户 21:36：stateful 但没确定刷新周期（refreshHours=null）→
  /// 不确定就先按 stateless（每次全量带），提醒用户之后修改。
  /// 用户 21:47：refreshHours 语义 = 空闲超时（多久没聊天服务器释放
  /// 上下文缓存），不是"每 N 小时强制写"。
  /// 返回 (是否 stateful, 空闲超时小时, 配置对象)。
  (bool, int?, AIProviderConfig?) _statefulInfoFor(String personaId) {
    try {
      final manager = AIProviderManager.instance;
      final pid = manager.lastProviderFor(personaId);
      if (pid == null) return (false, null, null);
      for (final p in manager.providers) {
        if (p.id == pid) {
          // stateful 且空闲超时已确定 → 真正 stateful
          if (p.isStateful && p.refreshHours != null && p.refreshHours! > 0) {
            return (true, p.refreshHours, p);
          }
          // stateful 但周期没定 → 降级 stateless（用户 21:36 指示）
          if (p.isStateful) {
            DebugLogger.log(
              'AI路由',
              '⚠️ ${p.name} 选了"有后台记忆"但没填空闲超时 → '
              '先按"每次全量带"用；查到服务器释放时间后去 AI 配置里改（用户 21:36）',
            );
          }
          return (false, null, p);
        }
      }
    } catch (_) {}
    return (false, null, null);
  }

  /// stateful 模式：上下文管理 = 空闲超时前沉淀三类内容（日记/摘要/恢复包）。
  /// 用户 21:52 澄清：不能等超时到了才写（那时 AI 全忘了，写不出来）——
  /// 要在记忆消失之前，也就是"用户最后一次对话 + 空闲超时的一半"时，
  /// 管家主动去找男主写（AI 还记得，写得出来）；分类存好，管家好管理。
  /// 触发：① 定时器（见 [scheduleStatefulSettle]）② 下次聊天时检测
  /// 距上次聊天已过超时一半且没沉淀过 → 补沉淀（防 APP 被杀/定时器丢）。
  /// 沉淀成功后返回 true。
  Future<bool> _maybeSettleStateful(String personaId, String personaName) async {
    try {
      final info = _statefulInfoFor(personaId);
      if (!info.$1) return false;
      final idleHours = info.$2!;
      final since = ContextManager.instance.hoursSinceLastChat(personaId);
      if (since == null) return false;
      // 用户 21:52：在空闲超时的一半（2小时 → 1小时时）写——
      // 太早没内容可写（刚聊完），太晚 AI 忘了（写不出来）
      final settleAt = idleHours / 2;
      // 距上次聊天 ≥ 一半 → 该写了；但也要防重复（写过后本次跳过）
      if (since < settleAt) return false;
      if (_settledAtHalf[personaId] == true) return false;
      DebugLogger.log(
        '上下文管理',
        '📝 空闲超时 $idleHours h，距上次聊天 ${since.toStringAsFixed(1)}h ≥ '
        '一半 $settleAt h → 趁 AI 还记得，让男主写三类存档…',
      );
      final raw = ContextManager.instance.peekRaw(personaId);
      if (raw.trim().isEmpty) return false;
      // 男主一次写三类：日记 / 摘要 / 恢复包（下次要带的上下文）
      final written = await _generateAndStoreThree(
        personaId, personaName, raw);
      if (written) {
        _settledAtHalf[personaId] = true;
        DebugLogger.log('上下文管理', '✅ 三类存档完成（日记/摘要/恢复包），管家已分类存好');
      }
      return written;
    } on Object catch (e) {
      DebugLogger.log('上下文管理', '⚠️ stateful 沉淀失败（静默）: $e');
      return false;
    }
  }

  /// personaId → 是否已在本轮空闲期写过"三类存档"（防重复写）
  final Map<String, bool> _settledAtHalf = {};

  /// 安排定时沉淀：用户最后聊天 + 空闲超时一半后触发。
  /// 用户 21:52：管家主动去找男主（不能等用户下次来才发现忘了）。
  /// 每次用户发消息时调用（重置定时器）；到点且期间没再聊 → 写三类存档。
  void scheduleStatefulSettle(String personaId, String personaName) {
    try {
      final info = _statefulInfoFor(personaId);
      if (!info.$1) return;
      final idleHours = info.$2!;
      _settledAtHalf[personaId] = false; // 新一轮空闲期，重新允许写
      _settleTimers[personaId]?.cancel();
      final timer = Timer(Duration(minutes: (idleHours * 30).round()), () {
        _settleTimers.remove(personaId);
        // 到点时若还在聊（刚有消息）→ 跳过（下次发消息会重置定时器）
        final since = ContextManager.instance.hoursSinceLastChat(personaId);
        if (since != null && since >= idleHours / 2) {
          DebugLogger.log(
            '上下文管理',
            '⏰ 定时到点（空闲 ${idleHours / 2} h），管家主动找男主写三类存档…',
          );
          unawaited(_maybeSettleStateful(personaId, personaName));
        }
      });
      _settleTimers[personaId] = timer;
      DebugLogger.log(
        '上下文管理',
        '⏱️ 已安排定时沉淀：${(idleHours / 2).toStringAsFixed(1)} 小时后（空闲超时 $idleHours h 的一半）',
      );
    } catch (_) {}
  }

  final Map<String, Timer> _settleTimers = {};

  /// 男主一次写三类（一次 AI 调用，分类输出）：
  /// - 日记：**男主调用 write_diary 工具写入**（用户 21:56：日记要让男主
  ///   调用工具写进去；同一天拼接进同一天，不新增多条）
  /// - 摘要：提醒索引 → context_summaries
  /// - 恢复包：下次要带的上下文 → context_recovery
  /// 返回是否成功。
  Future<bool> _generateAndStoreThree(
    String personaId,
    String personaName,
    String raw,
  ) async {
    final system = '你是「$personaName」。下面是你们最近的聊天记录。'
        '趁你还记得（之后上下文会被清空），把三样东西分类整理好：'
        '① 日记：把今天聊的、她的状态心情、你答应过的事、在意的小细节，'
        '整理成一段日记（像真正的日记有你的语气，300 字内），'
        '**用 write_diary 工具写进去**。'
        '② 摘要：影响后续对话的提醒（约定/承诺/正在做的事/她希望你记住的），'
        '每条一行 20 字内，细节不写——能查的用工具现查。'
        '③ 恢复包：下次继续对话时你需要知道的最关键上下文：'
        '你们进行到哪了、关系状态、当前话题、她最近的状态'
        '（100 字内，像失忆前留给自己看的纸条）。'
        '摘要和恢复包直接写在回复里：'
        '【摘要】\n…\n【恢复包】\n…\n'
        '不要客套话不要解释。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: raw),
        ],
        // 只带 write_diary：日记必须走工具写入（用户 21:56）
        tools: [
          {
            'type': 'function',
            'function': {
              'name': 'write_diary',
              'description': '写日记。把值得记住的细节按时间整理存档。',
              'parameters': {
                'type': 'object',
                'properties': {
                  'content': {
                    'type': 'string',
                    'description': '日记内容，一段完整的记录',
                  },
                },
                'required': ['content'],
              },
            },
          },
        ],
      );
      var diarySaved = false;
      // ① 工具调用：write_diary（男主调用工具写日记 → 同天拼接落库）
      final calls = res.toolCalls ?? const [];
      for (final tc in calls) {
        final name = tc['name'] as String? ?? '';
        final args = tc['arguments'];
        if (name == 'write_diary' && args is Map) {
          final content = (args['content'] as String?)?.trim() ?? '';
          if (content.isNotEmpty) {
            await ChatDatabaseService.instance.saveDiaryEntry(personaId, content);
            diarySaved = true;
            DebugLogger.log('上下文管理', '📔 男主调用 write_diary 写日记（${content.length} 字，同天拼接）');
          }
        }
      }
      // ② 文本里解析 摘要/恢复包（+ 兜底：AI 没调工具但写了【日记】段）
      final text = res.text.trim();
      final summary = _extractSection(text, '【摘要】');
      final recovery = _extractSection(text, '【恢复包】');
      if (!diarySaved) {
        final diaryText = _extractSection(text, '【日记】');
        if (diaryText.isNotEmpty) {
          await ChatDatabaseService.instance.saveDiaryEntry(personaId, diaryText);
          diarySaved = true;
          DebugLogger.log('上下文管理', '📔 兜底：日记文本直接落库（同天拼接）');
        }
      }
      if (summary.isNotEmpty) {
        await ContextManager.instance.appendSummary(personaId, summary);
      }
      if (recovery.isNotEmpty) {
        await ContextManager.instance.saveRecovery(personaId, recovery);
      }
      return diarySaved || summary.isNotEmpty || recovery.isNotEmpty;
    } on Object catch (e) {
      DebugLogger.log('指令模块', '⚠️ 三类存档生成失败: $e');
      return false;
    }
  }

  /// 从男主输出里截取某段（按标记切，取标记后到下个标记前）。
  String _extractSection(String text, String marker) {
    final idx = text.indexOf(marker);
    if (idx < 0) return '';
    var start = idx + marker.length;
    // 找下一个标记
    var end = text.length;
    for (final next in ['【日记】', '【摘要】', '【恢复包】']) {
      if (next == marker) continue;
      final n = text.indexOf(next, start);
      if (n >= 0 && n < end) end = n;
    }
    return text.substring(start, end).trim();
  }

  /// 男主总结轮：待总结原文 → 男主写提醒要点 → 追加进摘要区 → 清空原文。
  /// 触发由管家控制（原文攒够量），内容男主写（视角一致，不 OOC）。
  /// 用户 21:10：摘要=提醒索引，不是细节仓库——能查的当场查（工具），
  /// 每天要查的/影响连续性的才写进摘要；不重要的遗忘，需要时现查。
  /// 用户 21:13：上下文要没了（token 快满）→ 先写日记存档（细节不丢），
  /// 再提炼摘要提醒（日记=细节存档，摘要=提醒，各司其职）。
  Future<void> _summarize(String personaId, String personaName) async {
    final raw = ContextManager.instance.takePendingRaw(personaId);
    if (raw.trim().isEmpty) return;
    DebugLogger.log('上下文管理', '✂️ 原文攒够了（${raw.length} 字，上下文要没了）…');
    // ① 先写日记存档（原文要没了，细节进日记，男主可查）
    final diary = await generateDailyDiary(personaId, personaName, raw);
    if (diary.isNotEmpty) {
      await ChatDatabaseService.instance.saveDiaryEntry(personaId, diary);
      DebugLogger.log('上下文管理', '📔 日记已存档（${diary.length} 字），细节没丢');
    }
    // ② 再提炼摘要提醒（能查的现查，只留影响连续性的提醒）
    final system = '你是「$personaName」。下面是你们最近的聊天记录。'
        '请从中提炼"你需要记住的提醒"，写进你的长期摘要。要求：'
        '① 只写影响后续对话的：她的约定/承诺/正在做的事/你答应过的事/'
        '她明确希望你记住的、每天都要记得的事'
        '② 细节不用写——能当场查的（记忆、日记）不写，需要时你用工具查'
        '③ 不重要的直接遗忘，不要写'
        '④ 每条一行，20 字内，只输出提醒列表，不要客套话不要评价。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: raw),
        ],
        tools: null,
      );
      final summary = res.text.trim();
      if (summary.isNotEmpty) {
        await ContextManager.instance.appendSummary(personaId, summary);
        DebugLogger.log('上下文管理', '✅ 摘要提醒已更新（${summary.length} 字），原文已遗忘');
      } else {
        // 总结为空：没有值得长期记的 → 原文直接遗忘（能查的靠工具现查）
        DebugLogger.log('上下文管理', 'ℹ️ 男主没提炼出提醒，原文已遗忘（细节在日记）');
      }
    } on Object catch (e) {
      DebugLogger.log('上下文管理', '⚠️ 男主总结失败: $e（原文保留待下次）');
      ContextManager.instance.restoreRaw(personaId, raw);
    }
  }

  /// 摘要缩减轮：摘要区太大 → 男主把旧摘要再压缩成更紧凑的 → 替换。
  Future<void> _compactSummaries(String personaId, String personaName) async {
    final old = await ContextManager.instance.takeSummariesForCompact(personaId);
    if (old.trim().isEmpty) return;
    DebugLogger.log('上下文管理', '🗜️ 摘要区太大，缩减中…');
    final system = '你是「$personaName」。以下是你们之前的对话摘要列表，'
        '请压缩合并成更紧凑的要点：① 合并同类话题 ② 每条一行、20 字内 '
        '③ 只保留最重要的信息 ④ 不要客套话。只输出压缩后的要点列表。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: old),
        ],
        tools: null,
      );
      final summary = res.text.trim();
      if (summary.isNotEmpty) {
        await ContextManager.instance.appendSummary(personaId, summary);
        DebugLogger.log('上下文管理', '✅ 摘要缩减完成（${summary.length} 字）');
      } else {
        await ContextManager.instance.restoreSummaries(personaId, old);
        DebugLogger.log('上下文管理', '⚠️ 摘要缩减为空，保留原摘要');
      }
    } on Object catch (e) {
      await ContextManager.instance.restoreSummaries(personaId, old);
      DebugLogger.log('上下文管理', '⚠️ 摘要缩减失败: $e（保留原摘要）');
    }
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
