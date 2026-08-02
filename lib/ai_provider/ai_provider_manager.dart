/// AI Provider 管理入口（唯一对外门面）。
///
/// 管家（butler）只允许通过本类调用 AI，不允许直接碰底层 service。
/// 本类职责：
/// - 配置管理：预设厂商 + 一个自定义槽位，用户只需填 Key / 勾选；
/// - 手动优先级：用户排序后写回，路由按序尝试；
/// - 男主绑定：每个男主可指定自己的 Provider 白名单顺序；
/// - 故障切换：全部交给 [FailoverRouter]。
///
/// 持久化用 shared_preferences（JSON），重启不丢配置。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_config.dart';
import '../services/api_config_service.dart';
import '../services/i_openai_api_service.dart';
import '../services/openai_compatible_api_service.dart';
import '../utils/debug_logger.dart';
import 'failover_router.dart';
import 'models.dart';
import 'provider_presets.dart';
import 'tool_format_adapter.dart';

class AIProviderManager {
  AIProviderManager._();

  static final AIProviderManager instance = AIProviderManager._();

  static const String _storageKey = 'ai_provider_config_v1';
  static const String _storageKeyBindings = 'ai_provider_bindings_v1';
  static const String _storageKeyPersonaSettings = 'ai_provider_persona_settings_v1';

  /// 全局默认的 key（'' 表示全局）。
  static const String globalPersonaId = '';

  /// 自定义槽位的固定 id，全项目只允许一个。
  static const String customProviderId = 'custom';

  final FailoverRouter _router = FailoverRouter();
  final List<PersonaAIBinding> _bindings = [];

  /// personaId → 行为设置。'' = 全局默认。
  final Map<String, PersonaAISettings> _personaSettings = {};
  List<AIProviderConfig> _configs = [];
  bool _initialized = false;
  bool _loading = false;

  /// 配置变更时 +1，设置页 UI 监听它刷新。
  final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  IOpenAiApiService get _api => OpenAICompatibleApiService.instance;

  /// 首次使用前必须调用（app 启动时）。
  Future<void> initialize() async {
    if (_initialized || _loading) {
      return;
    }
    _loading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      _configs = (raw == null || raw.isEmpty) ? [] : _decodeConfigs(raw);
      // 一次性迁移：旧版「API 设置」里已配置的 Key，导入为自定义 Provider
      if (customProvider == null) {
        await _migrateLegacyConfig();
      }
      _bindings
        ..clear()
        ..addAll(_decodeBindings(prefs.getString(_storageKeyBindings)));
      _personaSettings
        ..clear()
        ..addAll(_decodePersonaSettings(prefs.getString(_storageKeyPersonaSettings)));
      _syncRouter();
      _initialized = true;
      DebugLogger.log(
        'AI管理',
        '初始化完成，共 ${_configs.length} 个 Provider，'
        '可用 ${_router.resolve().length} 个，绑定 ${_bindings.length} 个男主',
      );
    } finally {
      _loading = false;
    }
  }

  void _syncRouter() {
    _router.clear();
    for (final config in _configs) {
      _router.register(config);
    }
  }

  /// 一次性迁移：把旧版「API 设置」（api_configs）里选中的配置
  /// 导入为自定义 Provider，保证升级后聊天不断。
  /// 只在没有自定义槽位时执行一次。
  Future<void> _migrateLegacyConfig() async {
    try {
      final legacy = await ApiConfigService.instance.loadAllWithSelection();
      final selectedModelId = legacy.selectedModelId;
      if (selectedModelId == null || selectedModelId.isEmpty) {
        return;
      }
      ApiConfig? provider;
      String? modelId;
      for (final config in legacy.configs) {
        for (final model in config.models) {
          if (model.id == selectedModelId) {
            provider = config;
            modelId = model.modelId;
            break;
          }
        }
        if (provider != null) {
          break;
        }
      }
      if (provider == null ||
          modelId == null ||
          modelId.isEmpty ||
          provider.apiKey.trim().isEmpty) {
        return;
      }
      final config = AIProviderConfig(
        id: customProviderId,
        name: '${provider.name}（旧配置）',
        type: ProviderType.cloud,
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: modelId,
        isCustom: true,
        enabled: true,
        priority: 500,
        note: '自动从旧版 API 设置迁移而来',
      );
      _configs = [..._configs, config];
      _syncRouter();
      await _persist();
      DebugLogger.log(
        'AI管理',
        '已从旧配置迁移: ${provider.name} / $modelId',
      );
    } on Object catch (error) {
      DebugLogger.log('AI管理', '旧配置迁移失败(可忽略): $error');
    }
  }

  // ---------------------------------------------------------------------------
  // 只读
  // ---------------------------------------------------------------------------

  /// 全部 Provider，按优先级排序。
  List<AIProviderConfig> get providers => List.unmodifiable(_sorted());

  /// 带运行时健康状态的列表（UI 展示用）。
  List<AIProviderState> get providerStates => [
        for (final config in _sorted())
          _router.stateOf(config.id) ?? AIProviderState(config: config),
      ];

  /// 自定义槽位（没有则为 null）。
  AIProviderConfig? get customProvider {
    for (final config in _configs) {
      if (config.isCustom) {
        return config;
      }
    }
    return null;
  }

  /// 某男主当前的绑定（null 或空 = 跟随全局）。
  List<String>? bindingFor(String personaId) {
    for (final binding in _bindings) {
      if (binding.personaId == personaId) {
        return binding.providerIds;
      }
    }
    return null;
  }

  /// 某男主（或全局）是否允许故障自动切换。默认开。
  bool autoSwitchFor(String? personaId) {
    final key = _settingsKey(personaId);
    return _personaSettings[key]?.autoSwitch ??
        _personaSettings[globalPersonaId]?.autoSwitch ??
        true;
  }

  /// 某男主（或全局）最近一次成功使用的 Provider id。
  /// 没有记录时返回第一个候选（按优先级）的 id。
  String? lastProviderFor(String? personaId) {
    final key = _settingsKey(personaId);
    final own = _personaSettings[key]?.lastProviderId;
    if (own != null && own.isNotEmpty) {
      return own;
    }
    final global = _personaSettings[globalPersonaId]?.lastProviderId;
    if (global != null && global.isNotEmpty) {
      return global;
    }
    final candidates = candidatesFor(personaId);
    return candidates.isEmpty ? null : candidates.first.id;
  }

  /// 某男主的候选 Provider（勾选列表用）。
  /// 有绑定 = 绑定顺序；无绑定 = 全局优先级顺序。只含启用的。
  List<AIProviderConfig> candidatesFor(String? personaId) {
    final binding = bindingFor(_settingsKey(personaId));
    final all = _sorted();
    if (binding != null && binding.isNotEmpty) {
      final byId = {for (final config in all) config.id: config};
      return [
        for (final id in binding)
          if (byId[id] != null && byId[id]!.enabled) byId[id]!,
      ];
    }
    return [for (final config in all) if (config.enabled) config];
  }

  /// 设置某男主（或全局）是否自动切换。
  Future<void> setAutoSwitch(String? personaId, bool value) async {
    final key = _settingsKey(personaId);
    final current = _personaSettings[key] ?? const PersonaAISettings();
    _personaSettings[key] = current.copyWith(autoSwitch: value);
    await _persist();
    DebugLogger.log(
      'AI管理',
      '自动切换 ${value ? '开启' : '关闭'} (${key.isEmpty ? '全局' : key})',
    );
  }

  // ---------------------------------------------------------------------------
  // 配置修改
  // ---------------------------------------------------------------------------

  Future<void> setApiKey(String id, String apiKey) =>
      _update(id, (config) => config.copyWith(apiKey: apiKey.trim()));

  Future<void> setModel(String id, String model) =>
      _update(id, (config) => config.copyWith(model: model.trim()));

  Future<void> setBaseUrl(String id, String baseUrl) =>
      _update(id, (config) => config.copyWith(baseUrl: baseUrl.trim()));

  Future<void> setEnabled(String id, bool enabled) =>
      _update(id, (config) => config.copyWith(enabled: enabled));

  /// 手动排序：传入完整的有序 id 列表，未提及的自动排到后面。
  Future<void> setPriority(List<String> orderedIds) async {
    final rank = <String, int>{
      for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
    };
    _configs = [
      for (var i = 0; i < _configs.length; i++)
        _configs[i].copyWith(
          priority: rank[_configs[i].id] ?? (1000 + i),
        ),
    ];
    _syncRouter();
    await _persist();
  }

  /// 保存 / 覆盖自定义槽位（唯一）。全部字段由用户填写。
  Future<void> saveCustomProvider({
    required String name,
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final existing = customProvider;
    final config = AIProviderConfig(
      id: customProviderId,
      name: name.trim().isEmpty ? '自定义' : name.trim(),
      type: ProviderType.cloud,
      baseUrl: baseUrl.trim(),
      apiKey: apiKey.trim(),
      model: model.trim(),
      isCustom: true,
      enabled: true,
      priority: existing?.priority ?? 500,
    );
    _configs = [
      for (final item in _configs)
        if (!item.isCustom) item,
      config,
    ];
    _syncRouter();
    await _persist();
  }

  /// 删除自定义槽位。
  Future<void> removeCustomProvider() async {
    _configs = [
      for (final item in _configs)
        if (!item.isCustom) item,
    ];
    _syncRouter();
    await _persist();
  }

  /// 从预设模板添加一个 AI（地址 / 模型由模板填好，用户只命名 + 填 Key）。
  /// 同一模板可以添加多次（比如两个 DeepSeek：一个官方、一个中转站），
  /// id 自动加后缀保证唯一。
  Future<void> addProviderFromPreset(
    AIProviderPreset preset, {
    required String name,
    String apiKey = '',
  }) async {
    // 生成唯一 id：同模板重复添加时加数字后缀
    var id = preset.id;
    var suffix = 2;
    while (_configs.any((c) => c.id == id)) {
      id = '${preset.id}_$suffix';
      suffix++;
    }
    final config = AIProviderConfig(
      id: id,
      name: name.trim().isEmpty ? preset.name : name.trim(),
      type: preset.type,
      baseUrl: preset.baseUrl,
      apiKey: apiKey.trim(),
      model: preset.model,
      enabled: true,
      priority: 100 + _configs.length * 10,
      note: preset.note,
    );
    _configs = [..._configs, config];
    _syncRouter();
    await _persist();
    DebugLogger.log('AI管理', '已添加 AI: ${config.name} (${config.id})');
  }

  /// 通用保存：新增或整体更新一个 AI（编辑表单用，全字段可改）。
  Future<void> saveProvider(AIProviderConfig config) async {
    final index = _configs.indexWhere((item) => item.id == config.id);
    if (index >= 0) {
      _configs = [..._configs]..[index] = config;
    } else {
      _configs = [..._configs, config];
    }
    _syncRouter();
    await _persist();
    DebugLogger.log('AI管理', '已保存 AI: ${config.name}');
  }

  /// 删除一个 AI（同时清理男主绑定里的引用）。
  Future<void> removeProvider(String id) async {
    _configs = [
      for (final item in _configs)
        if (item.id != id) item,
    ];
    for (final binding in _bindings) {
      binding.providerIds.remove(id);
    }
    _bindings.removeWhere((binding) => binding.providerIds.isEmpty);
    _syncRouter();
    await _persist();
    DebugLogger.log('AI管理', '已删除 AI: $id');
  }

  /// 一键清空所有 AI 配置（含绑定）。
  Future<void> resetToDefaults() async {
    _configs = [];
    _bindings.clear();
    _syncRouter();
    await _persist();
  }

  Future<void> _update(
    String id,
    AIProviderConfig Function(AIProviderConfig) transform,
  ) async {
    _configs = [
      for (final config in _configs)
        if (config.id == id) transform(config) else config,
    ];
    _syncRouter();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // 男主绑定
  // ---------------------------------------------------------------------------

  /// 给男主设置专用 Provider 列表（白名单 + 顺序）。传空 = 跟随全局。
  Future<void> setPersonaBinding(
    String personaId,
    List<String> providerIds,
  ) async {
    _bindings.removeWhere((binding) => binding.personaId == personaId);
    _bindings.add(
      PersonaAIBinding(
        personaId: personaId,
        providerIds: List.of(providerIds),
      ),
    );
    await _persist();
  }

  /// 清除某男主的绑定，恢复跟随全局。
  Future<void> clearPersonaBinding(String personaId) async {
    _bindings.removeWhere((binding) => binding.personaId == personaId);
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // 调用（管家入口）
  // ---------------------------------------------------------------------------

  /// 非流式聊天。失败按男主的自动切换设置决定：换下一个 / 直接报错。
  ///
  /// [personaId] 传 null 或空 = 用全局优先级 + 全局自动切换设置。
  Future<AIProviderResult> chat(
    String? personaId,
    List<AIChatMessage> messages, {
    Map<String, dynamic>? defaults,
    List<Map<String, dynamic>>? tools,
    ChatCompletionCancelToken? cancellationToken,
  }) async {
    try {
      final result = await _router.executeWithFailover(
        personaId: personaId,
        bindings: _bindings,
        allowFailover: autoSwitchFor(personaId),
        isAbort: (error) => error is ChatCompletionCancelledException,
        action: (config) async {
          // 工具格式翻译层（用户 19:29/19:34/19:42 设计）：
          // 底层调用/参数/执行不变，只翻译"工具声明/返回"格式。
          // - openai：直通（translateTools 原样返回）
          // - anthropic/gemini：未来原生 API 的 ApiService 用 adapter 翻译
          // - text：本地模型文本协议兜底——不传原生 tools，
          //   工具说明注入 system；回复里 ⟨工具:…⟩JSON⟨/工具⟩ 块解析执行
          final adapter = resolveToolFormat(
            config.baseUrl,
            toolFormatOverride: config.toolFormat,
          );
          final translatedTools = adapter.translateTools(tools ?? const []);
          // 文本协议：把工具说明拼进 system（不传原生 tools）
          var effectiveMessages = messages;
          if (adapter.formatId == 'text' && (tools?.isNotEmpty ?? false)) {
            final hint = adapter.buildToolHint(tools!);
            if (hint.isNotEmpty) {
              effectiveMessages = [
                AIChatMessage(role: 'system', content: hint),
                ...messages,
              ];
            }
          }
          final apiResult = await _api.createChatCompletion(
            _resolve(config),
            messages: [
              for (final message in effectiveMessages) message.toApiJson(),
            ],
            defaults: defaults,
            tools: translatedTools,
            cancellationToken: cancellationToken,
          );
          // 文本协议：从回复文本解析 ⟨工具:…⟩ 块 → 内部统一 toolCalls，
          // 并把块从文本里剥掉（用户只看到男主自然的话）
          var finalText = apiResult.text;
          var finalToolCalls = apiResult.toolCalls;
          if (adapter.formatId == 'text') {
            final textCalls = adapter.parseToolCallsFromText(apiResult.text);
            if (textCalls.isNotEmpty) {
              finalToolCalls = [...?finalToolCalls, ...textCalls];
              finalText = adapter.stripToolBlocks(apiResult.text);
            }
          }
          return AIProviderResult(
            text: finalText,
            thinking: apiResult.thinkingChain ?? '',
            reasoningContent: apiResult.thinkingChain,
            usage: apiResult.usage,
            toolCalls: finalToolCalls,
          );
        },
      );
      _recordSuccess(personaId, result);
      _logRouting('chat', personaId, result);
      return result;
    } on AIAllProvidersFailedException catch (e) {
      DebugLogger.log(
        'AI路由',
        '❌ 全部失败: ${e.tried.isEmpty ? '(无可用)' : e.tried.join('、')}'
        ' 最后错误: ${e.lastError}',
      );
      rethrow;
    } on AIProviderUnavailableException catch (e) {
      DebugLogger.log(
        'AI路由',
        '❌ 自动切换已关闭，${e.providerName} 不可用: ${e.cause}',
      );
      rethrow;
    }
  }

  /// 流式聊天。首个字节之前的失败会自动切换 Provider；
  /// 已经出字后断流则直接报错（不静默切换）。
  Stream<AIProviderResult> chatStream(
    String? personaId,
    List<AIChatMessage> messages, {
    Map<String, dynamic>? defaults,
    ChatCompletionCancelToken? cancellationToken,
  }) async* {
    String? currentProvider;
    try {
      await for (final chunk in _router.streamWithFailover(
        personaId: personaId,
        bindings: _bindings,
        allowFailover: autoSwitchFor(personaId),
        isAbort: (error) => error is ChatCompletionCancelledException,
        action: (config) async* {
          await for (final progress in _api.createStreamingChatCompletion(
            _resolve(config),
            messages: [for (final message in messages) message.toApiJson()],
            defaults: defaults,
            cancellationToken: cancellationToken,
          )) {
            yield AIProviderResult(
              text: progress.textDelta,
              thinking: progress.thinkingDelta,
              done: progress.done,
            );
          }
        },
      )) {
        if (chunk.providerId != currentProvider) {
          currentProvider = chunk.providerId;
          _logRouting('stream', personaId, chunk);
        }
        if (chunk.done) {
          _recordSuccess(personaId, chunk);
        }
        yield chunk;
      }
    } on AIAllProvidersFailedException catch (e) {
      DebugLogger.log(
        'AI路由',
        '❌ 流式全部失败: ${e.tried.isEmpty ? '(无可用)' : e.tried.join('、')}'
        ' 最后错误: ${e.lastError}',
      );
      rethrow;
    } on AIProviderUnavailableException catch (e) {
      DebugLogger.log(
        'AI路由',
        '❌ 流式自动切换已关闭，${e.providerName} 不可用: ${e.cause}',
      );
      rethrow;
    }
  }

  /// 快速检查：某男主（或全局）当前有没有可用的 Provider。
  /// 用于发消息前的 fail-fast，避免白等。
  bool hasUsable(
    String? personaId, {
    AICapability capability = AICapability.chat,
  }) {
    return _router
        .resolve(personaId: personaId, capability: capability, bindings: _bindings)
        .isNotEmpty;
  }

  /// 当前可用的 Provider 名列表（设置页展示用）。
  List<String> usableProviderNames(
    String? personaId, {
    AICapability capability = AICapability.chat,
  }) {
    return [
      for (final state in _router.resolve(
        personaId: personaId,
        capability: capability,
        bindings: _bindings,
      ))
        state.config.name,
    ];
  }

  void _logRouting(String mode, String? personaId, AIProviderResult result) {
    final who = personaId == null || personaId.isEmpty ? '全局' : personaId;
    if (result.failedProviders.isNotEmpty) {
      DebugLogger.log(
        'AI路由',
        '$mode 故障切换: ${result.failedProviders.join('、')} → '
        '${result.providerName} (persona: $who)',
      );
    } else {
      DebugLogger.log(
        'AI路由',
        '$mode 使用 ${result.providerName} (persona: $who)',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 诊断
  // ---------------------------------------------------------------------------

  /// 测试某个 Provider 的连通性（设置页用）。
  Future<({bool success, String message})> testProvider(String id) async {
    AIProviderConfig? config;
    for (final item in _configs) {
      if (item.id == id) {
        config = item;
        break;
      }
    }
    if (config == null) {
      return (success: false, message: '配置不存在');
    }
    try {
      final result = await _api.testConnection(_resolve(config));
      return (success: result.success, message: result.message);
    } on Object catch (error) {
      return (success: false, message: '$error');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  ResolvedApiConfig _resolve(AIProviderConfig config) => ResolvedApiConfig(
        id: config.id,
        name: config.name,
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        model: config.model,
      );

  List<AIProviderConfig> _sorted() {
    final list = List.of(_configs);
    list.sort((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      return byPriority != 0
          ? byPriority
          : a.name.compareTo(b.name);
    });
    return list;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode([for (final config in _configs) config.toJson()]),
    );
    await prefs.setString(
      _storageKeyBindings,
      jsonEncode([for (final binding in _bindings) binding.toJson()]),
    );
    await prefs.setString(
      _storageKeyPersonaSettings,
      jsonEncode({
        for (final entry in _personaSettings.entries)
          entry.key: entry.value.toJson(),
      }),
    );
    changeNotifier.value++;
  }

  /// 调用成功后记录"当前用的 Provider"，UI 据此展示。
  void _recordSuccess(String? personaId, AIProviderResult result) {
    final providerId = result.providerId;
    if (providerId == null || providerId.isEmpty) {
      return;
    }
    final key = _settingsKey(personaId);
    final current = _personaSettings[key] ?? const PersonaAISettings();
    if (current.lastProviderId == providerId) {
      return;
    }
    _personaSettings[key] =
        current.copyWith(lastProviderId: providerId);
    // 不落盘（高频），只通知 UI 刷新
    changeNotifier.value++;
  }

  String _settingsKey(String? personaId) =>
      (personaId == null || personaId.isEmpty) ? globalPersonaId : personaId;

  List<AIProviderConfig> _decodeConfigs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      // 过滤未配置的：云端没填 Key = 未配置，不显示（本地模型不需要 Key）。
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>)
            AIProviderConfig.fromJson(item),
      ].where(
        (config) =>
            config.type == ProviderType.local ||
            config.apiKey.trim().isNotEmpty,
      ).toList();
    } on Object {
      return const [];
    }
  }

  List<PersonaAIBinding> _decodeBindings(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>)
            PersonaAIBinding.fromJson(item),
      ];
    } on Object {
      return const [];
    }
  }

  Map<String, PersonaAISettings> _decodePersonaSettings(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const {};
      }
      return {
        for (final entry in decoded.entries)
          if (entry.value is Map<String, dynamic>)
            entry.key: PersonaAISettings.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
    } on Object {
      return const {};
    }
  }
}
