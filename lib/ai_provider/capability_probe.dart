/// AI 能力探测层（2026-08-04 通用 AI 适配层 · 第一部分）
///
/// 职责：
/// 1. 首次连接某个 provider+model 时，实测它支持什么：
///    - 工具调用格式（openai 原生 / 文本协议 / 纯聊天）
///    - 思考链（reasoning）字段
///    - 流式输出
///    - 后台记忆（8-05 用户：不查表，实测为准——管家发两条裸消息问暗号，
///      答得出 = 服务端真有记忆；答不出 = 无记忆，按 stateless 全量带）
/// 2. 结果按 `baseUrl|model` 缓存（内存 + shared_preferences），不重复测；
///    同 API 不同模型各存各的（如 DeepSeek 有的版本要思考链、有的不要）。
/// 3. 探测失败静默降级为 URL 猜测，绝不阻塞聊天、绝不让设置页卡住。
///
/// 设计约束：
/// - 探测只回答"原生工具行不行"，具体格式翻译交给 ToolFormatAdapter（注册表可扩展）
/// - 探测用 OpenAI 兼容通道（当前唯一 transport）；Claude/Gemini 原生端点
///   等原生 transport 做好后再扩展实测（适配器已就位，见 tool_format_adapter.dart）
/// - 内置 mock 跳过探测（已知能力，硬编码）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../models/api_config.dart';
import '../services/i_openai_api_service.dart';
import '../services/openai_compatible_api_service.dart';
import 'ai_key_value_store.dart';
import 'ai_module_log.dart';
import 'anthropic_transport.dart';
import 'tool_format_adapter.dart';

/// 探测出的能力画像（可序列化，缓存用）。
class AIProviderCapabilities {
  const AIProviderCapabilities({
    required this.toolFormat,
    required this.supportsReasoning,
    required this.supportsStreaming,
    this.supportsBackendMemory = false,
    // 8-09 17:2x：工具轮思考是否必须回传思考链（DeepSeek 类 = true）
    this.returnRequired = false,
    this.probedAt,
    this.probeSource = 'guess',
  });

  /// 首选工具调用格式：'openai' / 'text' / 'none'
  /// （未来原生 transport 就绪后扩展 'anthropic' / 'gemini'）
  final String toolFormat;

  /// 是否返回思考链（reasoning）字段
  final bool supportsReasoning;

  /// 是否支持流式输出（仅展示用；实际请求仍会尝试流式）
  final bool supportsStreaming;

  /// 后台是否有记忆（8-05 实测）：服务端跨请求记得内容 → stateful 轻量带；
  /// 无 → stateless 每次全量带。安全默认 false（全量带永远不会错）。
  final bool supportsBackendMemory;

  /// 工具轮思考是否必须回传思考链（8-09 用户：DeepSeek 类原生工具调用
  /// 不传 reasoning_content 就 400 = true；其他 AI 不要求 = false）
  final bool returnRequired;

  /// 探测时间；null = 从未实测（纯猜测）
  final DateTime? probedAt;

  /// 'probe' = 实测结果；'guess' = URL 规则猜测（探测失败/未探测）
  final String probeSource;

  bool get isProbed => probeSource == 'probe';

  AIProviderCapabilities copyWith({
    String? toolFormat,
    bool? supportsReasoning,
    bool? supportsStreaming,
    bool? supportsBackendMemory,
    bool? returnRequired,
    DateTime? probedAt,
    String? probeSource,
  }) {
    return AIProviderCapabilities(
      toolFormat: toolFormat ?? this.toolFormat,
      supportsReasoning: supportsReasoning ?? this.supportsReasoning,
      supportsStreaming: supportsStreaming ?? this.supportsStreaming,
      supportsBackendMemory:
          supportsBackendMemory ?? this.supportsBackendMemory,
      returnRequired: returnRequired ?? this.returnRequired,
      probedAt: probedAt ?? this.probedAt,
      probeSource: probeSource ?? this.probeSource,
    );
  }

  /// 系别展示名（UI 能力灯用；未来新格式在这里加一行即可）
  String get systemLabel {
    switch (toolFormat) {
      case 'openai':
        return 'OpenAI 系';
      case 'anthropic':
        return 'Claude 系';
      case 'gemini':
        return 'Gemini 系';
      case 'text':
        return '文本协议';
      case 'none':
        return '纯聊天';
      default:
        return '未知';
    }
  }

  /// 能力灯摘要（UI 展示）：能用哪个亮哪个
  String get capabilitySummary {
    final parts = <String>[
      '原生工具 ${toolFormat == 'openai' ? '✓' : '✗'}',
      '思考链 ${supportsReasoning ? '✓' : '✗'}',
      '回传要求 ${returnRequired ? '✓' : '✗'}',
      '流式 ${supportsStreaming ? '✓' : '✗'}',
      '后台记忆 ${supportsBackendMemory ? '✓' : '✗'}',
    ];
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'toolFormat': toolFormat,
        'supportsReasoning': supportsReasoning,
        'supportsStreaming': supportsStreaming,
        'supportsBackendMemory': supportsBackendMemory,
        'returnRequired': returnRequired,
        'probedAt': probedAt?.toIso8601String(),
        'probeSource': probeSource,
      };

  factory AIProviderCapabilities.fromJson(Map<String, dynamic> json) {
    final rawProbedAt = json['probedAt'] as String?;
    return AIProviderCapabilities(
      toolFormat: json['toolFormat'] as String? ?? 'openai',
      supportsReasoning: json['supportsReasoning'] as bool? ?? false,
      supportsStreaming: json['supportsStreaming'] as bool? ?? false,
      supportsBackendMemory: json['supportsBackendMemory'] as bool? ?? false,
      returnRequired: json['returnRequired'] as bool? ?? false,
      probedAt: rawProbedAt == null ? null : DateTime.tryParse(rawProbedAt),
      probeSource: json['probeSource'] as String? ?? 'guess',
    );
  }
}

/// 探测缓存：内存 + 可注入存储双层，key = `baseUrl|model`。
/// 存储默认 shared_preferences；换环境注入自己的 [AiKeyValueStore]。
class CapabilityCache {
  CapabilityCache._();

  static final CapabilityCache instance = CapabilityCache._();

  /// 8-05 升 v2：新增后台记忆实测字段，旧缓存没有该结果 → 作废重测
  /// 8-07 23:1x 升 v3：探测增强（openai 不通时实测 anthropic 原生格式，
  /// 不按 URL 名字猜；deepseek 优先 + /anthropic 归一化）——旧缓存可能存了
  /// 误判的 'text' 格式，作废重测
  static const String storageKey = 'ai_provider_capabilities_v3';

  AiKeyValueStore _store = const SharedPrefsAiStore();

  /// 注入自定义存储（app 启动/测试时调用）。
  void configure({AiKeyValueStore? store}) {
    if (store != null) {
      _store = store;
    }
  }

  final Map<String, AIProviderCapabilities> _memory = {};
  bool _loaded = false;

  static String keyFor(ResolvedApiConfig config) =>
      '${config.baseUrl.trim()}|${config.model.trim()}';

  Future<void> _ensureLoaded() async {
    if (_loaded) {
      return;
    }
    try {
      final raw = await _store.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((k, v) {
            if (v is Map<String, dynamic>) {
              _memory[k] = AIProviderCapabilities.fromJson(v);
            }
          });
        }
      }
    } on Object catch (error) {
      AiModuleLog.log('AI探测', '缓存加载失败(可忽略): $error');
    }
    _loaded = true;
  }

  /// 读缓存；miss 返回 null（不触发探测）。
  Future<AIProviderCapabilities?> get(String key) async {
    await _ensureLoaded();
    return _memory[key];
  }

  /// 写缓存（内存 + 落盘）。
  Future<void> put(String key, AIProviderCapabilities caps) async {
    _memory[key] = caps;
    try {
      await _store.setString(
        storageKey,
        jsonEncode({
          for (final entry in _memory.entries) entry.key: entry.value.toJson(),
        }),
      );
    } on Object catch (error) {
      AiModuleLog.log('AI探测', '缓存写入失败(可忽略): $error');
    }
  }

  /// 失效单个 key（用户改了 baseUrl/model 或点"重新检测"时调用）。
  void invalidate(String key) => _memory.remove(key);
}

/// 探测器：用 OpenAI 兼容通道实测一个 provider+model 的能力。
class CapabilityProbe {
  CapabilityProbe({IOpenAiApiService? api})
      : _api = api ?? OpenAICompatibleApiService.instance;

  final IOpenAiApiService _api;

  /// 实测入口。内部已做超时/异常保护：任何失败都降级为 [guess]，
  /// 只在极端情况下（网络完全不通）抛错，调用方兜底。
  Future<AIProviderCapabilities> probe(ResolvedApiConfig config) async {
    if (config.model.trim().isEmpty) {
      return guess(config);
    }

    // ① 工具格式 + 思考链：一个带 ping 工具的极简请求
    var toolFormat = 'openai';
    var supportsReasoning = _hintsReasoning(config);
    var probed = true;
    try {
      final result = await _api.createChatCompletion(
        config,
        messages: const [
          {
            'role': 'user',
            'content': '请调用 ping 工具。只输出工具调用，不要解释。',
          },
        ],
        defaults: const {'max_tokens': 60, 'temperature': 0},
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'ping',
              'description': '测试工具调用',
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
        ],
      );
      if (result.toolCalls != null && result.toolCalls!.isNotEmpty) {
        // 原生工具调用成功返回 → openai 系
        toolFormat = 'openai';
      } else {
        // 成功但没调工具：prompt 都明说"请调用 ping 工具"了还不调，
        // 不一定是模型不会——也可能是端点实际是 Anthropic 格式、
        // OpenAI 格式请求被当成普通文本对话。8-07 23:0x 用户：
        // "不要匹配名字去匹配调用方式，管家统一适配（像 MCP）"→
        // 再实测 Anthropic 原生格式，识别真实能力再定
        toolFormat = await _probeAnthropicFormat(config) ?? 'text';
      }
      final thinking = result.thinkingChain;
      if (thinking != null && thinking.trim().isNotEmpty) {
        supportsReasoning = true;
      }
    } on Object catch (error) {
      if (isFormatError(error)) {
        // API 不认 tools 字段（报错提到工具/函数/参数）→ 可能根本不是
        // OpenAI 兼容端点 → 试 Anthropic 原生格式
        toolFormat = await _probeAnthropicFormat(config) ?? 'text';
      } else {
        // 网络/鉴权/超时 → 实测不了，用 URL 猜测
        final g = guess(config);
        toolFormat = g.toolFormat;
        supportsReasoning = g.supportsReasoning;
        probed = false;
      }
    }

    // ①b 思考模式实测（8-09 17:0x 用户设计定稿：开关可用性由实测决定，
    // 不能思考的 AI 按钮置灰）：
    // 带 thinking:{type:enabled}（DeepSeek V3.2 思考参数）的极简对话请求，
    // 返回 reasoning_content = 真支持思考模式（supportsReasoning=true）。
    // 失败/无返回 = 不支持或参数名不认（保持 hints 推断值，不误判）。
    // 探测请求失败（网络等）时跳过，避免雪上加霜。
    if (probed) {
      try {
        final thinkingProbe = await _api.createChatCompletion(
          config,
          messages: const [
            {'role': 'user', 'content': '1+1=？'},
          ],
          defaults: const {
            // 8-09 22:5x 修复（用户：V4 有思考链却看不到，开关被置灰）：
            // 原 max_tokens=60 太小——V4 思考模式（Think High/Max）思考
            // 本身就要几百 token 预算，60 根本跑不起来 → 无 reasoning_content
            // → 误判"不支持思考" → 配置页开关置灰 → 用户想开都开不了。
            // 调大到 2000 给思考留空间；非思考模型回答极短，多花 token 可忽略。
            'max_tokens': 2000,
            'temperature': 0,
            // DeepSeek V3.2/V4 thinking 参数（其他家不认 → 报错静默忽略，
            // 保持 hints 推断；不误判为"不支持思考"）
            'thinking': {'type': 'enabled'},
            // DeepSeek V4：思考深度参数（non-thinking/high/max），
            // 探测用 high 即可证明支持思考（max 太慢）
            'reasoning_effort': 'high',
          },
        );
        final tc = thinkingProbe.thinkingChain;
        if (tc != null && tc.trim().isNotEmpty) {
          supportsReasoning = true;
        }
      } on Object {
        // 参数不认/超时 → 保持 hints 推断值，静默
      }
    }

    // ② 流式探测：读第一个 chunk 验证 SSE（仅当上面实测成功过）
    var supportsStreaming = false;
    if (probed) {
      try {
        await for (final _ in _api.createStreamingChatCompletion(
          config,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          defaults: const {
            'max_tokens': 5,
            'temperature': 0,
            'stream': true,
          },
        )) {
          supportsStreaming = true;
          break;
        }
      } on Object {
        supportsStreaming = false;
      }
    }

    // ③ 后台记忆实测（8-05 用户：不要查表，管家第一次配 API 就亲自问 AI）：
    // 两条裸消息（不带任何历史、没有 system）——第一条让 AI 记住随机暗号，
    // 第二条问暗号是什么。答得出 = 服务端真有跨请求记忆（stateful）；
    // 答不出 = 无记忆（stateless 每次全量带）。随机暗号防日常回复误判。
    var supportsBackendMemory = false;
    if (probed) {
      supportsBackendMemory = await _probeBackendMemory(config);
    }

    return AIProviderCapabilities(
      toolFormat: toolFormat,
      supportsReasoning: supportsReasoning,
      supportsStreaming: supportsStreaming,
      supportsBackendMemory: supportsBackendMemory,
      probedAt: DateTime.now(),
      probeSource: probed ? 'probe' : 'guess',
    );
  }

  final Random _random = Random();

  /// 🧠 后台记忆实测（8-05 用户要求，不查表）：
  /// 1) 第一条明确告知这是【记忆测试·第一次对话】（共两次），让 AI 记住暗号
  ///    ——不说明的话 AI 会自由发挥（拒绝/反问/第二次不知道在问什么）
  /// 2) 第二条（不带任何历史）问暗号是什么
  /// 第二条回复里含暗号 → 有后台记忆；否则 → 无。
  /// 任何失败按"无记忆"处理——无记忆是安全默认（stateless 全量带
  /// 永远不会错，只是不省 token；反向误判才致命：AI 会失忆）。
  Future<bool> _probeBackendMemory(ResolvedApiConfig config) async {
    final marker = '翡翠西瓜${1000 + _random.nextInt(9000)}';
    try {
      // 第一条：明说是记忆测试、一共两次、这是第一次、之后会问什么、
      // 现在只需确认——AI 知道流程后才会好好配合（8-05 13:58 用户）
      // 14:07 用户：不要说"回答内容本身"这种绕的话，直接告诉 AI——
      // 第二句只需回暗号本身、无需说其他的；记住后回"好的"触发第二次对话
      await _api.createChatCompletion(
        config,
        messages: [
          {
            'role': 'user',
            'content': '【记忆测试】这是第一次对话，一共两次。'
                '请记住暗号：$marker。'
                '等会儿我发第二条消息时，你只需原样回复这个暗号本身，无需说其他的。'
                '记住后请回复"好的"触发第二次对话。',
          },
        ],
        defaults: const {'max_tokens': 10, 'temperature': 0},
      );
      // 第二条：不带任何历史，问暗号是什么（如果服务端记得，能答出来）
      final res = await _api.createChatCompletion(
        config,
        messages: [
          {
            'role': 'user',
            'content': '【记忆测试·第二次对话】我刚才让你记住的那句话是什么？'
                '只回答那句话的内容本身，不要解释。',
          },
        ],
        defaults: const {'max_tokens': 30, 'temperature': 0},
      );
      final text = res.text.replaceAll(RegExp(r'\s'), '');
      final hit = text.contains(marker);
      AiModuleLog.log(
        'AI探测',
        hit
            ? '🧠 后台记忆实测：有（第二次答出暗号）→ 可配"有后台记忆"轻量带'
            : '🧠 后台记忆实测：无（第二次未答出暗号）→ 按 stateless 每次全量带',
      );
      return hit;
    } on Object catch (error) {
      AiModuleLog.log(
        'AI探测',
        '🧠 后台记忆实测失败(按无记忆处理，安全默认): '
        '${error.toString().length > 120 ? error.toString().substring(0, 120) : error}',
      );
      return false;
    }
  }

  /// Anthropic 原生格式实测（8-07 23:0x 用户：不按名字猜格式，实测为准）。
  /// 用 Anthropic 格式（POST /v1/messages + tools）发 ping，能返回 tool_use
  /// = 端点真是 Anthropic 格式 → 返回 'anthropic'；失败/不识别 → null。
  Future<String?> _probeAnthropicFormat(ResolvedApiConfig config) async {
    try {
      final result = await createAnthropicCompletion(
        config,
        messages: const [
          {'role': 'user', 'content': '请调用 ping 工具。只输出工具调用，不要解释。'},
        ],
        defaults: const {'max_tokens': 60, 'temperature': 0},
        tools: const AnthropicAdapter().translateTools(const [
          {
            'type': 'function',
            'function': {
              'name': 'ping',
              'description': '测试工具调用',
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
        ]),
      );
      if (result.toolCalls != null && result.toolCalls!.isNotEmpty) {
        AiModuleLog.log(
          'AI探测',
          '🔍 ${config.name} 实测识别为 Anthropic 原生格式'
          '（OpenAI 格式不通，Anthropic 格式 ping 成功）',
        );
        return 'anthropic';
      }
      return null;
    } on Object catch (error) {
      AiModuleLog.log(
        'AI探测',
        '🔍 ${config.name} Anthropic 格式实测失败（非 Anthropic 端点）: '
        '${error.toString().length > 100 ? error.toString().substring(0, 100) : error}',
      );
      return null;
    }
  }

  /// URL 规则猜测（探测失败/未探测时的兜底，与 ToolFormatRegistry 一致）。
  AIProviderCapabilities guess(ResolvedApiConfig config) {
    final adapter = resolveToolFormat(config.baseUrl);
    var toolFormat = adapter.formatId;
    // 当前 transport 只有 OpenAI 兼容通道：anthropic/gemini 原生地址
    // 现在调不通 → 按文本协议处理（等原生 transport 做好再改这里）
    if (toolFormat == 'anthropic' || toolFormat == 'gemini') {
      toolFormat = 'text';
    }
    return AIProviderCapabilities(
      toolFormat: toolFormat,
      supportsReasoning: _hintsReasoning(config),
      supportsStreaming: true, // 未知时乐观假设，实际失败不影响使用
      supportsBackendMemory: false, // 未知时按无记忆（全量带永远安全）
      probeSource: 'guess',
    );
  }

  /// 思考链乐观推断：模型名含 reasoner/thinking、**DeepSeek 系 baseUrl**
  /// （V3.2+ 全系支持思考模式，8-09 22:5x 用户：V4 明明有思考链却看不到——
  /// 探测①b 参数格式若不被认 → 误判不支持 → 开关置灰 → 用户开不了），
  /// 或 customBody 里配了思考相关参数。
  /// DeepSeek 思考模式靠请求参数开启，探测请求不带思考参数时不返回
  /// reasoning_content，但不能因此判"不支持"。
  bool _hintsReasoning(ResolvedApiConfig config) {
    final model = config.model.toLowerCase();
    if (model.contains('reasoner') || model.contains('thinking')) {
      return true;
    }
    // 8-09 22:5x：DeepSeek 官方文档 V3.2+ 全系支持 thinking mode
    // （deepseek-chat/deepseek-reasoner 及 V4 系列）——按 baseUrl 兜底
    // 判支持，避免探测失败时把开关置灰（用户想开都开不了）。
    final baseUrl = config.baseUrl.toLowerCase();
    if (baseUrl.contains('deepseek')) {
      return true;
    }
    try {
      final body = config.parseCustomBody();
      return body.keys.any((k) {
        final key = k.toLowerCase();
        return key.contains('reason') || key.contains('think');
      });
    } on Object {
      return false;
    }
  }
}

/// 格式类错误判定：HTTP 400/422 且报错提到工具/函数/参数等 → 是格式问题，
/// 触发"降级下一种调用方式"；网络/超时/401/500 → 不是格式问题，走 provider
/// failover（防把网络抖动误判成格式问题、把好好的 openai 格式降级成文本协议）。
///
/// 8-08 22:5x（用户：老弹灰框一串错误，可能就是 400）：DeepSeek 思考模式
/// 工具轮报 "The 'reasoning_content' in the thinking mode must be passed back"
/// ——这句没有 tool/function/argument 等词，原来判定为"非格式错误"→ 不降级
/// → failover/弹窗。补 reasoning/thinking/思考 关键词：这类 400 是消息格式
/// 问题（原生 tool_calls 回传要求太高），应降级 text 协议（translateToolRound
/// 丢弃 tool_calls 合并结果，天然免疫 400）。
bool isFormatError(Object error) {
  final message = error.toString().toLowerCase();
  final mentionsFormat = message.contains('tool') ||
      message.contains('function') ||
      message.contains('argument') ||
      message.contains('parameter') ||
      message.contains('unknown field') ||
      message.contains('unexpected') ||
      message.contains('invalid request') ||
      // 8-08 22:5x：DeepSeek 思考模式回传要求（reasoning_content 必须原样带回）
      message.contains('reasoning_content') ||
      message.contains('reasoning') ||
      message.contains('thinking') ||
      message.contains('思考');
  final badStatus = message.contains('400') || message.contains('422');
  return mentionsFormat && badStatus;
}
