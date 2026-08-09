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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_config.dart';
import '../services/api_config_service.dart';
import '../services/i_openai_api_service.dart';
import '../services/openai_compatible_api_service.dart';
import 'ai_module_log.dart';
import 'capability_probe.dart';
import 'failover_router.dart';
import 'mock_ai_provider.dart';
import 'models.dart';
import 'provider_presets.dart';
import 'anthropic_transport.dart';
import 'tool_format_adapter.dart';

class AIProviderManager {
  AIProviderManager._();

  /// 内置测试 AI 的固定 id（用户 8-03 20:38 要求：内置一个 AI，
  /// 不用配置 API 就能测——模拟器扮演 DeepSeek，不联网不花 token）
  static const String builtinMockId = 'builtin-mock';

  /// 内置测试 AI 的 provider 定义（不持久化，每次启动自动有）
  /// 8-04 20:35（用户）：mock 要能模拟各种配置组合——memoryMode/
  /// refreshHours 运行时可变（重启还原），配置页"内置模拟 AI"卡片可改
  AIProviderConfig _builtinMockConfig = const AIProviderConfig(
        id: builtinMockId,
        name: '🧪 测试AI（内置）',
        type: ProviderType.local,
        baseUrl: 'mock://builtin',
        model: 'mock-1',
        note: '内置模拟器：不联网不花token，测试对话/工具调用链路用',
        priority: 99999,
      );

  /// 当前生效的 mock 配置（给配置页显示/编辑用）
  AIProviderConfig get builtinMockConfig => _builtinMockConfig;

  /// 更新 mock 配置（内存态，不落 DB；重启还原 stateless）
  /// memoryMode: stateless（无后台记忆）/ stateful（有后台记忆）
  /// clearRefreshHours: true 时把 refreshHours 清成 null
  /// （自检页测"stateful 没填超时 → 降级 stateless"用）
  void updateBuiltinMock(
      {String? memoryMode, int? refreshHours, bool clearRefreshHours = false}) {
    _builtinMockConfig = AIProviderConfig(
      id: _builtinMockConfig.id,
      name: _builtinMockConfig.name,
      type: _builtinMockConfig.type,
      baseUrl: _builtinMockConfig.baseUrl,
      model: _builtinMockConfig.model,
      note: _builtinMockConfig.note,
      priority: _builtinMockConfig.priority,
      memoryMode: memoryMode ?? _builtinMockConfig.memoryMode,
      refreshHours: clearRefreshHours
          ? null
          : (refreshHours ?? _builtinMockConfig.refreshHours),
    );
    // 同步路由里的 config（AIProviderState.config 可变，直接换引用）
    _router.stateOf(builtinMockId)?.config = _builtinMockConfig;
    AiModuleLog.log('模拟AI',
        '⚙️ mock 配置更新：memoryMode=${_builtinMockConfig.memoryMode}'
        ' refreshHours=${_builtinMockConfig.refreshHours}');
  }

  /// 8-04 20:39（用户：多内置几个固定形态的模拟 AI，一键测逻辑）：
  /// 变体实例（实例级固定开关，不跟随配置页静态开关）
  /// builtin-mock 主实例 = 跟随静态开关（配置页可改）
  final Map<String, MockAIProvider> _mockInstances = {
    builtinMockId: MockAIProvider(), // 无记忆·思考链·工具 都跟随配置页开关
    'builtin-mock-b': MockAIProvider(defaultReasoning: false, defaultTools: true), // 无记忆·思考关·工具开
    'builtin-mock-c': MockAIProvider(defaultReasoning: true, defaultTools: true), // 有记忆(1h)·思考开·工具开
    'builtin-mock-d': MockAIProvider(defaultReasoning: false, defaultTools: true), // 有记忆(1h)·思考关·工具开
    'builtin-mock-e': MockAIProvider(defaultReasoning: true, defaultTools: false), // 无记忆·思考开·工具关（纯聊天模型）
  };

  /// 5 个内置模拟 AI 的固定形态（name 直观显示形态，聊天页/配置页可见）
  static const List<AIProviderConfig> builtinMockVariants = [
    AIProviderConfig(
      id: builtinMockId,
      name: '🧪模拟A 无记忆·思考开·工具开',
      type: ProviderType.local,
      baseUrl: 'mock://builtin',
      model: 'mock-1',
      note: '内置模拟器：DeepSeek 形态（stateless 全量带+思考链+工具）',
      priority: 99999,
    ),
    AIProviderConfig(
      id: 'builtin-mock-b',
      name: '🧪模拟B 无记忆·思考关·工具开',
      type: ProviderType.local,
      baseUrl: 'mock://builtin',
      model: 'mock-1',
      note: '内置模拟器：无思考链模型（stateless+工具，reasoning=null）',
      priority: 99999,
    ),
    AIProviderConfig(
      id: 'builtin-mock-c',
      name: '🧪模拟C 有记忆·思考开·工具开',
      type: ProviderType.local,
      baseUrl: 'mock://builtin',
      model: 'mock-1',
      note: '内置模拟器：后台有记忆 AI（stateful 1h，prompt 轻量+超时恢复）',
      priority: 99999,
      memoryMode: 'stateful',
      refreshHours: 1,
    ),
    AIProviderConfig(
      id: 'builtin-mock-d',
      name: '🧪模拟D 有记忆·思考关·工具开',
      type: ProviderType.local,
      baseUrl: 'mock://builtin',
      model: 'mock-1',
      note: '内置模拟器：后台有记忆+无思考链（stateful 1h，reasoning=null）',
      priority: 99999,
      memoryMode: 'stateful',
      refreshHours: 1,
    ),
    AIProviderConfig(
      id: 'builtin-mock-e',
      name: '🧪模拟E 无记忆·思考开·工具关',
      type: ProviderType.local,
      baseUrl: 'mock://builtin',
      model: 'mock-1',
      note: '内置模拟器：纯聊天模型（无 function calling，只文本回复）',
      priority: 99999,
    ),
  ];

  /// 全部 provider（含内置测试AI），按优先级排序
  List<AIProviderConfig> _allProviders() {
    final list = _sorted();
    // 8-05 14:28（用户："平时就关掉，页面上不要把测试的放到哪里都是"）：
    // 模拟 AI 平时隐藏，测试模式开才进列表（聊天页可选）
    if (_testModeEnabled) {
      // 8-04 20:39（用户：多内置几个）：5 个固定形态变体全部在列
      // （聊天页切换器可见可切换；配置页渲染时排除、走专属卡片）
      for (final v in builtinMockVariants) {
        if (!list.any((c) => c.id == v.id)) {
          list.add(v.id == builtinMockId ? _builtinMockConfig : v);
        }
      }
    }
    return list;
  }

  /// 测试模式（8-05 14:28 用户："各种测 bug 的放到测 bug 的那里…
  /// 平时就关掉，页面上不要把测试的放到哪里都是"）。
  /// 默认关：mock 不注册路由、不进任何列表、聊天页不可见；
  /// 开：mock 恢复注册（聊天页可选 + 一键验收可用）。
  static bool _testModeEnabled = false;
  static bool get testModeEnabled => _testModeEnabled;

  static void setTestModeEnabled(bool value) {
    if (_testModeEnabled == value) return;
    _testModeEnabled = value;
    final manager = instance;
    manager._syncRouter();
    // 关掉测试模式时，清掉指向 mock 的"上次使用"记录：
    // 否则聊天顶栏显示"没有可用 AI"、发送时路由也找不到 mock
    if (!value) {
      manager._clearMockLastProviders();
    }
    // 8-05 17:04 用户（彻底隔离）：测试模式开 = 真实 AI 功能全部关掉
    // （自动，不用用户手动）；测试模式关 = 自动恢复用户之前配置。
    // 任何入口（弹层开关/横幅退出）都走这里 → 天然自动。
    if (value) {
      manager._isolateRealProviders();
    } else {
      manager._restoreRealProviders();
    }
    manager.changeNotifier.value++;
    AiModuleLog.log(
      'AI探测',
      value ? '🧪 测试模式：开（模拟 AI 可选）' : '🧪 测试模式：关（模拟 AI 隐藏）',
    );
  }

  /// 清掉所有指向 mock 的 lastProvider 记录（测试模式关闭时调用）
  void _clearMockLastProviders() {
    for (final entry in _personaSettings.entries) {
      final id = entry.value.lastProviderId;
      if (id != null && _mockInstances.containsKey(id)) {
        _personaSettings[entry.key] =
            entry.value.copyWith(clearLastProvider: true);
      }
    }
  }

  /// 内置模拟 AI 判定（8-05 14:32 用户：测试对话必须与真实数据隔离）。
  /// 聊天/落库/管家分析处用它判断"当前是不是测试对话"。
  static bool isMockId(String id) =>
      id == builtinMockId || id.startsWith('builtin-mock');

  static final AIProviderManager instance = AIProviderManager._();

  static const String _storageKey = 'ai_provider_config_v1';
  static const String _storageKeyBindings = 'ai_provider_bindings_v1';
  static const String _storageKeyPersonaSettings = 'ai_provider_persona_settings_v1';

  /// 全局默认的 key（'' 表示全局）。
  static const String globalPersonaId = '';

  /// 8-05 14:5x（用户：测试 AI 和真实 AI 走一个通道但必须隔离）：
  /// 测试空间 key = ${真实personaId}__mock__test。provider 解析时剥掉后缀
  /// → 继承真实 persona 的绑定/选择（测试模式下真实 persona 选的是 mock），
  /// 沉淀/总结等主动调 AI 也走 mock，绝不落到真实 API 花额度；
  /// 数据写入层（ContextManager/DB）仍用完整测试 key → 数据隔离。
  // 8-07 14:03 用户：统一测试标签。mock 和真实 AI 测试共用同一个测试空间
  // （${personaId}__test），退出测试模式时按标签一键删；真实数据零接触。
  // 注：旧数据 __mock__test 结尾也是 __test，删除 LIKE '%__test' 可兼容。
  static const String mockTestSuffix = '__test';

  String _stripMockTestSuffix(String? personaId) {
    if (personaId != null && personaId.endsWith(mockTestSuffix)) {
      return personaId.substring(0, personaId.length - mockTestSuffix.length);
    }
    return personaId ?? '';
  }

  /// 自定义槽位的固定 id，全项目只允许一个。
  static const String customProviderId = 'custom';

  final FailoverRouter _router = FailoverRouter();
  final CapabilityProbe _probe = CapabilityProbe();
  final List<PersonaAIBinding> _bindings = [];

  /// personaId → 行为设置。'' = 全局默认。
  final Map<String, PersonaAISettings> _personaSettings = {};
  List<AIProviderConfig> _configs = [];
  bool _initialized = false;
  bool _loading = false;

  /// 配置变更时 +1，设置页 UI 监听它刷新。
  final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  /// 能力状态单一数据源（8-04 16:0x 用户要求"从一个地方读取，联动好，
  /// 像可插拔技能一样"）：providerId → 能力画像。
  /// 探测/重测/加载完成后写入这里并 bump [capabilityNotifier]，
  /// 配置页 / 聊天弹层 / 工具箱全部从这里读 —— 一处检测，处处联动。
  final Map<String, AIProviderCapabilities> _capState = {};

  /// 能力状态变更时 +1，UI 能力灯监听它刷新（单一数据源的广播通道）。
  final ValueNotifier<int> capabilityNotifier = ValueNotifier<int>(0);

  /// 写能力状态并广播（值没变也 +1：ValueNotifier 同值不通知，而
  /// 探测来源可能从 guess 变 probe，用 +1 保证 UI 每次都刷新）。
  void _setCapState(String id, AIProviderCapabilities caps) {
    _capState[id] = caps;
    capabilityNotifier.value++;
  }

  /// 底层 API 实现（可注入，默认 OpenAI 兼容实现；测试/换 transport 时
  /// 用 [configureApi] 替换，模块代码零改动）。
  IOpenAiApiService _api = OpenAICompatibleApiService.instance;

  /// 注入自定义 API 实现（测试或未来接原生 transport 时调用）。
  void configureApi(IOpenAiApiService api) => _api = api;

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
      // 8-05 17:04：上次异常退出可能留下"真实 AI 已禁用"残留 → 自动恢复
      unawaited(_recoverRealSnapshotIfAny());
      _initialized = true;
      AiModuleLog.log(
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
    // 内置测试 AI（mock）不持久化，但必须注册进路由——否则
    // hasUsable / resolve / executeWithFailover 永远找不到它，
    // 选中"🧪 测试AI（内置）"后发消息会被"没有可用 Provider"拦截
    // （用户 8-03 21:12 反馈：测试AI被检测API拦住了，就是这个原因）
    // 8-04 20:39（用户：多内置几个）：5 个固定形态变体全部注册
    // 8-05 14:28（用户：平时关掉）：测试模式开才注册，关则不注册
    if (_testModeEnabled) {
      for (final v in builtinMockVariants) {
        _router.register(v);
      }
      // 主实例配置（配置页手动改的 memoryMode/refreshHours）覆盖内置形态
      _router.stateOf(builtinMockId)?.config = _builtinMockConfig;
    } else {
      for (final v in builtinMockVariants) {
        _router.unregister(v.id);
      }
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
      AiModuleLog.log(
        'AI管理',
        '已从旧配置迁移: ${provider.name} / $modelId',
      );
    } on Object catch (error) {
      AiModuleLog.log('AI管理', '旧配置迁移失败(可忽略): $error');
    }
  }

  // ---------------------------------------------------------------------------
  // 只读
  // ---------------------------------------------------------------------------

  /// 全部 Provider，按优先级排序（含内置测试AI）。
  List<AIProviderConfig> get providers => List.unmodifiable(_allProviders());

  /// 带运行时健康状态的列表（UI 展示用）。
  List<AIProviderState> get providerStates => [
        for (final config in _allProviders())
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
    // 8-05 16:52 用户（严重）：测试模式开着时普通聊天偷偷走真实 DeepSeek——
    // lastProvider 是真实 AI 时 isMockChat=false → 对话落真实空间+花真实额度。
    // 修：测试模式开 → 强制指向 mock（互斥：测试 AI 开 = 真实 AI 关）。
    // 用户/验收切了具体 mock 变体则返回该变体，否则默认主实例。
    if (_testModeEnabled) {
      final own = _personaSettings[_settingsKey(personaId)]?.lastProviderId;
      // 8-05 17:04 修正：16:52 用 _mockChoiceUsable 判断（非 mock id 恒 true）
      // → own=deepseek 直接返回，修复根本没生效（用户实测第一句就露馅）。
      // own 必须是 mock 变体才返回，否则强制 mock 主实例。
      if (own != null && own.isNotEmpty && isMockId(own)) {
        return own;
      }
      // 8-05 17:2x（验收④⑧根因）：sw() 会 resetLastProvider 清 own →
      // 之前一律返回主实例 builtin-mock → 决策读主实例配置（stateless），
      // 绑定里的 mock-c（stateful 1h）被无视 → 连续使用误判 needRecover、
      // 超时误判 idleExpired=false。修：own 为空时读当前绑定里的 mock
      // 变体（验收/用户切了哪个变体就用哪个变体的形态配置）。
      final binding = bindingFor(_settingsKey(personaId));
      if (binding != null) {
        for (final id in binding) {
          if (isMockId(id)) return id;
        }
      }
      return builtinMockVariants.first.id;
    }
    final key = _settingsKey(personaId);
    final own = _personaSettings[key]?.lastProviderId;
    if (own != null && own.isNotEmpty && _mockChoiceUsable(own)) {
      return own;
    }
    final global = _personaSettings[globalPersonaId]?.lastProviderId;
    if (global != null && global.isNotEmpty && _mockChoiceUsable(global)) {
      return global;
    }
    final candidates = candidatesFor(personaId);
    return candidates.isEmpty ? null : candidates.first.id;
  }

  /// 8-05 15:0x（用户：聊天页左上角残留测试 AI）：测试模式关 = mock 不可用。
  /// 上次测试留下的 lastProvider=mock（持久化）在重启后仍会命中 →
  /// 顶栏 badge 显示"未配置"。这里把它视为无效选择 → 回退到真实候选。
  bool _mockChoiceUsable(String id) =>
      !_mockInstances.containsKey(id) || _testModeEnabled;

  // ---------------------------------------------------------------------------
  // 测试模式 = 真实 AI 彻底隔离（8-05 17:04 用户）
  // ---------------------------------------------------------------------------
  static const _storageKeyRealSnapshot = 'ai_provider_real_enabled_snapshot';
  final Map<String, bool> _realEnabledSnapshot = {};

  /// 测试模式开：把真实 AI 全部临时禁用（功能关掉），快照持久化——
  /// app 被杀/重启后 initialize 检测残留快照自动恢复，真实 AI 不会永久禁用。
  void _isolateRealProviders() {
    _realEnabledSnapshot.clear();
    for (final config in _allProviders()) {
      if (!_isMockId(config.id) && config.enabled) {
        _realEnabledSnapshot[config.id] = true;
        unawaited(_update(config.id, (c) => c.copyWith(enabled: false)));
      }
    }
    unawaited(_persistRealSnapshot());
    AiModuleLog.log('AI隔离', '🧪 测试模式开：真实 AI 已全部临时禁用');
  }

  /// 测试模式关：按快照恢复真实 AI（用户之前的选择，绝不改动没勾的）。
  void _restoreRealProviders() {
    if (_realEnabledSnapshot.isEmpty) return;
    final snapshot = Map.of(_realEnabledSnapshot);
    _realEnabledSnapshot.clear();
    for (final entry in snapshot.entries) {
      unawaited(_update(entry.key, (c) => c.copyWith(enabled: entry.value)));
    }
    unawaited(_clearRealSnapshot());
    AiModuleLog.log('AI隔离', '🧪 测试模式关：真实 AI 已恢复用户之前配置');
  }

  Future<void> _persistRealSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _storageKeyRealSnapshot, jsonEncode(_realEnabledSnapshot));
  }

  Future<void> _clearRealSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKeyRealSnapshot);
  }

  /// app 启动：上次异常退出可能留下"真实 AI 已禁用"的残留 → 自动恢复。
  Future<void> _recoverRealSnapshotIfAny() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKeyRealSnapshot);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in map.entries) {
        if (e.value == true) {
          unawaited(_update(e.key, (c) => c.copyWith(enabled: true)));
        }
      }
    } catch (_) {}
    await prefs.remove(_storageKeyRealSnapshot);
    AiModuleLog.log('AI隔离', '♻️ 检测到测试模式残留快照，真实 AI 已自动恢复');
  }

  /// 测试对话专用绑定：mock 强制最前，真实 AI 排后。
  /// 兜底：即使真实组没清空（用户漏关），测试对话也永不花真实额度。
  List<PersonaAIBinding> _testBindingsFor(String pid) {
    final mockIds = [for (final v in builtinMockVariants) v.id];
    final existing = bindingFor(_settingsKey(pid));
    final base = (existing != null && existing.isNotEmpty)
        ? existing
        : [for (final c in _allProviders()) if (c.enabled) c.id];
    return [
      PersonaAIBinding(
        personaId: pid,
        providerIds: [
          ...mockIds,
          for (final id in base)
            if (!mockIds.contains(id)) id,
        ],
      ),
    ];
  }

  /// 8-05 16:0x（用户：真实/测试 AI 分组一键开关）：开测试模式前的
  /// 原绑定快照（per persona，null = 跟随全局）。关测试模式时原样恢复——
  /// 用户可能故意不勾某些 AI，绝不能恢复成全选（16:19 用户强调）。
  static final Map<String, List<String>?> _bindingSnapshot = {};
  static void saveBindingSnapshot(String personaId, List<String>? binding) =>
      _bindingSnapshot[personaId] =
          binding == null ? null : List.of(binding);
  static List<String>? takeBindingSnapshot(String personaId) =>
      _bindingSnapshot.remove(personaId);

  bool _isMockId(String id) =>
      id == builtinMockId || id.startsWith('builtin-mock');

  /// 8-05 16:36 用户：一键退出测试模式——恢复该男主原绑定（原样还原，
  /// 绝不全选）。聊天页横幅「退出测试」/ AI 弹层测试组开关共用。
  static void exitTestMode(String personaId) {
    final manager = instance;
    AIProviderManager.setTestModeEnabled(false);
    final snap = takeBindingSnapshot(personaId);
    if (snap != null) {
      // 原绑定里可能有 mock（测试模式已关、mock 已注销）→ 过滤掉，
      // 避免持久化脏数据；过滤后为空 → 原绑定本来就只有 mock → 跟随全局
      final realSnap = [
        for (final id in snap)
          if (!manager._isMockId(id)) id,
      ];
      if (realSnap.isEmpty) {
        manager.clearPersonaBinding(personaId);
      } else {
        manager.setPersonaBinding(personaId, realSnap);
      }
    } else {
      // 原状态 = 跟随全局 → 恢复跟随全局
      manager.clearPersonaBinding(personaId);
    }
  }


  /// 某男主的候选 Provider（勾选列表用）。
  /// 有绑定 = 绑定顺序；无绑定 = 全局优先级顺序。只含启用的。
  List<AIProviderConfig> candidatesFor(String? personaId) {
    final binding = bindingFor(_settingsKey(personaId));
    final all = _allProviders();
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
    AiModuleLog.log(
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
  /// 返回新添加的 provider id（调用方拿去做"添加后立即能力探测"）。
  Future<String> addProviderFromPreset(
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
    AiModuleLog.log('AI管理', '已添加 AI: ${config.name} (${config.id})');
    return config.id;
  }

  /// 通用保存：新增或整体更新一个 AI（编辑表单用，全字段可改）。
  Future<void> saveProvider(AIProviderConfig config) async {
    // 编辑时 baseUrl/model 可能变了 → 旧能力缓存作废（新 key 探测后自动写入）
    final index = _configs.indexWhere((item) => item.id == config.id);
    if (index >= 0) {
      final old = _configs[index];
      if (old.baseUrl.trim() != config.baseUrl.trim() ||
          old.model.trim() != config.model.trim()) {
        CapabilityCache.instance.invalidate(
          CapabilityCache.keyFor(_resolve(old)),
        );
        _capState.remove(config.id);
        capabilityNotifier.value++;
        AiModuleLog.log('AI探测', '${config.name} 地址/模型变了，旧能力缓存已作废');
      }
      _configs = [..._configs]..[index] = config;
    } else {
      _configs = [..._configs, config];
    }
    _syncRouter();
    await _persist();
    AiModuleLog.log('AI管理', '已保存 AI: ${config.name}');
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
    _capState.remove(id); // 单一数据源同步清理
    capabilityNotifier.value++;
    _syncRouter();
    await _persist();
    AiModuleLog.log('AI管理', '已删除 AI: $id');
  }

  /// 一键清空所有 AI 配置（含绑定）。
  Future<void> resetToDefaults() async {
    _configs = [];
    _bindings.clear();
    _capState.clear(); // 单一数据源同步清理
    capabilityNotifier.value++;
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
      // 8-05 14:5x：测试空间 key → 继承真实 persona 的 provider（测试时=mock），
      // 沉淀/总结等主动调 AI 不落到真实 API
      // 8-05 16:0x（用户发现：测试时真实 AI 勾着 → 路由优先走真实 DeepSeek 花额度）：
      // 测试对话用专用绑定（mock 强制最前）→ 兜底保证测试永不花真实额度
      final isTestChat = personaId != null && personaId.endsWith(mockTestSuffix);
      personaId = _stripMockTestSuffix(personaId);
      final bindings =
          isTestChat && _testModeEnabled ? _testBindingsFor(personaId) : _bindings;
      final result = await _router.executeWithFailover(
        personaId: personaId,
        bindings: bindings,
        allowFailover: autoSwitchFor(personaId),
        isAbort: (error) => error is ChatCompletionCancelledException,
        action: (config) async {
          // 内置测试 AI：不走网络，模拟器扮演 DeepSeek
          // （用户 8-03 20:38 要求：不用配置 API 就能测；
          //   8-04 20:39：5 个固定形态变体按 id 分发到独立实例）
          final mock = _mockInstances[config.id];
          if (mock != null) {
            final r = mock.chat(
              messages,
              toolRound: messages.any((m) => m.role == 'tool'),
            );
            return AIProviderResult(
              text: r.text,
              thinking: r.thinking,
              reasoningContent: r.reasoningContent,
              toolCalls: r.toolCalls,
              usage: r.usage,
              providerId: config.id,
              providerName: config.name,
            );
          }
          // 通用适配层（2026-08-04）：
          // ① 取能力画像（缓存命中直接用，miss 才实测，绝不阻塞聊天）；
          // ② 按降级链尝试调用方式：openai → 文本协议 → 纯聊天；
          // ③ 只有"格式类错误"才降级；网络/鉴权/超时直接抛给 failover 换 Provider
          //    （防把网络抖动误判成格式问题）。
          final caps = await capabilitiesFor(config.id);
          final chain = _formatFallbackChain(config, caps);
          Object? lastFormatError;
          for (final formatId in chain) {
            try {
              return await _chatWithFormat(
                config,
                formatId,
                messages,
                defaults: defaults,
                tools: tools,
                cancellationToken: cancellationToken,
              );
            } on ChatCompletionCancelledException {
              rethrow;
            } on Object catch (error) {
              if (isFormatError(error)) {
                lastFormatError = error;
                // 8-09 17:2x：碰壁记忆——思考模式 AI 原生工具轮格式类错误
                // （reasoning_content 回传要求相关）→ 记 returnRequired=true，
                // UI 显示"工具轮方式"A/B 开关（下次用户可直接选 B 免回传）
                if (config.thinkingEnabled == true ||
                    config.thinkingSupported == true) {
                  unawaited(_update(
                    config.id,
                    (c) => c.copyWith(returnRequired: true),
                  ));
                }
                AiModuleLog.log(
                  'AI路由',
                  '⚠️ ${config.name} 的 $formatId 格式调用失败（格式类错误）→ '
                  '降级下一种: ${_truncateForLog(error.toString())}',
                );
                continue;
              }
              rethrow;
            }
          }
          // 所有调用方式都失败 → 抛给上层：UI 把该 AI 标红"一种都不能用"
          throw AIFormatAllFailedException(
            providerName: config.name,
            formats: chain,
            lastError: lastFormatError,
          );
        },
      );
      _recordSuccess(personaId, result);
      _logRouting('chat', personaId, result);
      return result;
    } on AIAllProvidersFailedException catch (e) {
      AiModuleLog.log(
        'AI路由',
        '❌ 全部失败: ${e.tried.isEmpty ? '(无可用)' : e.tried.join('、')}'
        ' 最后错误: ${e.lastError}',
      );
      rethrow;
    } on AIProviderUnavailableException catch (e) {
      AiModuleLog.log(
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
      AiModuleLog.log(
        'AI路由',
        '❌ 流式全部失败: ${e.tried.isEmpty ? '(无可用)' : e.tried.join('、')}'
        ' 最后错误: ${e.lastError}',
      );
      rethrow;
    } on AIProviderUnavailableException catch (e) {
      AiModuleLog.log(
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
    // 8-05 14:5x：测试空间 key 继承真实 persona 的 provider
    // 8-05 16:0x：测试对话用专用绑定（mock 强制最前），测试不花真实额度
    final isTestChat = personaId != null && personaId.endsWith(mockTestSuffix);
    personaId = _stripMockTestSuffix(personaId);
    final bindings =
        isTestChat && _testModeEnabled ? _testBindingsFor(personaId) : _bindings;
    return _router
        .resolve(personaId: personaId, capability: capability, bindings: bindings)
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
      AiModuleLog.log(
        'AI路由',
        '$mode 故障切换: ${result.failedProviders.join('、')} → '
        '${result.providerName} (persona: $who)',
      );
    } else {
      AiModuleLog.log(
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
      if (!result.success) {
        return (success: false, message: result.message);
      }
      // 连通 OK → 顺带做能力探测（缓存 miss 才发探测请求，探测失败自动
      // 降级为 URL 猜测，不会让"测试连接"按钮报错）
      final caps = await capabilitiesFor(id);
      final summary = caps.isProbed
          ? '能力实测：${caps.systemLabel}（${caps.capabilitySummary}）'
          : '能力未实测（猜测）：${caps.systemLabel}（${caps.capabilitySummary}）';
      return (success: true, message: '${result.message}；$summary');
    } on Object catch (error) {
      return (success: false, message: '$error');
    }
  }

  // ---------------------------------------------------------------------------
  // 能力探测（通用 AI 适配层，2026-08-04）
  // ---------------------------------------------------------------------------

  /// 取某 Provider 的能力画像：缓存命中直接返回；miss 才实测。
  /// - 缓存 key = `baseUrl|model`：同 API 不同模型各存各的
  ///   （如 DeepSeek 有的版本要思考链、有的不要）
  /// - 探测失败静默降级为 URL 猜测，绝不阻塞聊天
  /// - 内置测试 AI 跳过探测（已知能力）
  Future<AIProviderCapabilities> capabilitiesFor(String id) async {
    final config = _configById(id);
    if (config == null) {
      return const AIProviderCapabilities(
        toolFormat: 'openai',
        supportsReasoning: false,
        supportsStreaming: true,
      );
    }
    if (_mockInstances.containsKey(config.id)) {
      return _mockCapsFor(config.id);
    }
    final resolved = _resolve(config);
    final key = CapabilityCache.keyFor(resolved);
    final cached = await CapabilityCache.instance.get(key);
    if (cached != null) {
      // 单一数据源：命中缓存也同步进内存态（页面可能是冷启动后第一次读）
      _setCapState(config.id, cached);
      return cached;
    }
    AIProviderCapabilities caps;
    try {
      caps = await _probe.probe(resolved);
      // 8-09 17:2x：return-required = 静态判定（DeepSeek 已知事实）∪ 碰壁记忆
      caps = caps.copyWith(
        returnRequired: _isReturnRequired(resolved) || config.returnRequired,
      );
      // 🧠 后台记忆实测 → 自动对齐 memoryMode（8-05 用户：不查表，实测为准）
      await _applyMemoryModeFromProbe(config, caps);
      AiModuleLog.log(
        'AI探测',
        '${config.name}(${config.model}) 实测: ${caps.systemLabel} · '
        '${caps.capabilitySummary}',
      );
    } on Object catch (error) {
      caps = _probe.guess(resolved);
      caps = caps.copyWith(
        returnRequired: _isReturnRequired(resolved) || config.returnRequired,
      );
      AiModuleLog.log(
        'AI探测',
        '⚠️ ${config.name} 探测失败，用 URL 猜测(${caps.systemLabel}): '
        '${_truncateForLog(error.toString())}',
      );
    }
    await CapabilityCache.instance.put(key, caps);
    _setCapState(config.id, caps); // 广播给所有 UI 能力灯
    // 8-09 17:0x：思考模式支持度同步到配置（UI 开关可用性：不支持 → 置灰）
    if (caps.isProbed) {
      await _update(config.id, (c) => c.copyWith(
            thinkingSupported: caps.supportsReasoning,
            // 8-09 17:2x：return-required 同步（DeepSeek 类静态判定 +
            // 运行时碰壁记忆），UI 据此显示"工具轮方式"A/B 开关
            returnRequired: caps.returnRequired,
          ));
    }
    return caps;
  }

  /// 🧠 后台记忆实测 → 自动对齐 memoryMode（8-05 用户："你直接拿一个表，
  /// 万一未来 deepseek 不做了呢？用户用不认识的 API，说它没后台记忆不就不准吗？"
  /// → 不查表，第一次配 API 就实测，实测结果自动落到配置）。
  /// 14:19 用户新规则（实测为准，冲突时默认关掉手动配置）：
  /// - 实测有记忆 → 自动设为 stateful；若还没配"空闲超时"→ 回调通知
  ///   （UI 弹窗 + 管家任务提醒用户去填，红点常驻配置页）
  /// - 实测无记忆 但手动配了 stateful → 自动改回 stateless（默认覆盖手动）
  ///   并回调通知（让用户知道手动配置被实测结果覆盖了）
  Future<void> _applyMemoryModeFromProbe(
      AIProviderConfig config, AIProviderCapabilities caps) async {
    if (!caps.isProbed) {
      return;
    }
    final idx = _configs.indexWhere((c) => c.id == config.id);
    if (idx < 0) {
      return;
    }
    final current = _configs[idx];

    if (caps.supportsBackendMemory) {
      // ① 实测有记忆：确保 stateful（自动补设，用户可改回）
      var changed = false;
      if (current.memoryMode != 'stateful') {
        _configs[idx] = current.copyWith(memoryMode: 'stateful');
        changed = true;
      }
      if (changed) {
        _syncRouter();
        await _persist();
        changeNotifier.value++;
      }
      // ② 还没配空闲超时 → 提醒（有记忆要真正"轻量带"必须填超时；
      //    不填则 stateful 按 stateless 用，安全但没省 token）
      if (_configs[idx].refreshHours == null) {
        AiModuleLog.log(
          'AI探测',
          '🧠 ${config.name} 实测有后台记忆 → 已自动设为"有后台记忆"'
          '，但未配空闲超时，提醒用户去配置页填写',
        );
        _memoryConfigNotice?.call(
          '🧠 ${config.name} 有后台记忆',
          '管家实测发现这个 AI 服务端能记住对话（有后台记忆）。\n\n'
          '已自动设为"有后台记忆"。请到 AI 配置页编辑它，填"空闲超时"'
          '（小时）启用轻量携带；不填则仍按每次全量带（安全，不省 token）。',
          _configs[idx],
        );
      }
    } else if (current.memoryMode == 'stateful') {
      // ③ 实测无记忆 + 手动配了 stateful → 默认以实测为准，关掉手动配置
      _configs[idx] = current.copyWith(memoryMode: 'stateless', refreshHours: null);
      _syncRouter();
      await _persist();
      changeNotifier.value++;
      AiModuleLog.log(
        'AI探测',
        '🧠 ${config.name} 实测无后台记忆 → 已自动改回"无后台记忆"'
        '（覆盖手动配置；每次全量带，AI 不会失忆）',
      );
      _memoryConfigNotice?.call(
        '🧠 ${config.name} 实测无后台记忆',
        '你手动把它设成了"有后台记忆"，但管家实测它服务端记不住'
        '（无状态 API，如 DeepSeek）。\n\n'
        '已自动改回"无后台记忆"（每次全量带）——这样不会因为 AI 失忆而出错。',
        _configs[idx],
      );
    }
  }

  /// 🧠 后台记忆实测通知回调（UI 注入，2026-08-05 14:19 用户：
  /// "发现是有记忆的，就弹窗告诉用户…并且给管家的那个任务那里，去弄一个任务"）。
  /// ai_provider 保持纯 Dart 自包含：弹窗/建任务由 UI 层在 main.dart 注入实现。
  static void Function(String title, String message, AIProviderConfig config)?
      _memoryConfigNotice;

  static set memoryConfigNotice(
          void Function(String title, String message, AIProviderConfig config)?
              handler) =>
      _memoryConfigNotice = handler;

  /// 内置模拟 AI 的能力画像（8-04 硬编码已知能力；8-05 按形态区分：
  /// C/D 有后台记忆 → 🧠 灯亮；E 工具关 → 纯聊天。skip 探测）
  AIProviderCapabilities _mockCapsFor(String id) {
    switch (id) {
      case 'builtin-mock-c':
        return const AIProviderCapabilities(
          toolFormat: 'openai',
          supportsReasoning: true,
          supportsStreaming: true,
          supportsBackendMemory: true,
          probeSource: 'guess',
        );
      case 'builtin-mock-d':
        return const AIProviderCapabilities(
          toolFormat: 'openai',
          supportsReasoning: false,
          supportsStreaming: true,
          supportsBackendMemory: true,
          probeSource: 'guess',
        );
      case 'builtin-mock-e':
        return const AIProviderCapabilities(
          toolFormat: 'none',
          supportsReasoning: true,
          supportsStreaming: true,
          probeSource: 'guess',
        );
      default: // 主实例 A（跟随配置页开关）/ B（思考关）
        return AIProviderCapabilities(
          toolFormat: 'openai',
          supportsReasoning: id != 'builtin-mock-b',
          supportsStreaming: true,
          // 主实例：配置页把 memoryMode 改成 stateful → 🧠 灯跟着亮
          supportsBackendMemory:
              id == builtinMockId && _builtinMockConfig.isStateful,
          probeSource: 'guess',
        );
    }
  }

  /// 只读能力状态（UI 能力灯统一入口）：内存态优先，miss 返回 null
  /// （不触发探测，探测走 [capabilitiesFor]）。
  AIProviderCapabilities? capabilityStateFor(String id) => _capState[id];

  /// 批量把持久化能力缓存载入内存态（页面打开时调用，防冷启动空白）；
  /// 不触发任何网络探测。
  Future<void> refreshCapabilityState() async {
    for (final config in _configs) {
      final resolved = _resolve(config);
      final caps =
          await CapabilityCache.instance.get(CapabilityCache.keyFor(resolved));
      if (caps != null) {
        _capState[config.id] = caps;
      }
    }
    capabilityNotifier.value++;
  }

  /// 只读能力画像（UI 列表展示用，不触发探测）。
  Future<AIProviderCapabilities?> cachedCapabilitiesFor(String id) async {
    final config = _configById(id);
    if (config == null) {
      return null;
    }
    final resolved = _resolve(config);
    return CapabilityCache.instance.get(CapabilityCache.keyFor(resolved));
  }

  /// 强制重新探测（"信号台"重测按钮用）：作废缓存 → 实测 → 回写缓存。
  /// 用户觉得能力灯不对（比如厂商升级了接口）就点一下重测。
  Future<AIProviderCapabilities> reprobeProvider(String id) async {
    final config = _configById(id);
    if (config == null) {
      return const AIProviderCapabilities(
        toolFormat: 'openai',
        supportsReasoning: false,
        supportsStreaming: true,
      );
    }
    final resolved = _resolve(config);
    CapabilityCache.instance.invalidate(CapabilityCache.keyFor(resolved));
    AiModuleLog.log('AI探测', '🔄 ${config.name} 手动重测…');
    return capabilitiesFor(id);
  }

  AIProviderConfig? _configById(String id) {
    for (final config in _configs) {
      if (config.id == id) {
        return config;
      }
    }
    return null;
  }

  /// 8-09 17:2x：静态判定"工具轮思考必须回传思考链"（已知事实表）。
  /// DeepSeek 官方端点 = true（思考模式工具轮不传 reasoning_content 就 400）；
  /// 其他厂商 = false（OpenAI/Gemini/Claude 不要求回传）。
  /// 运行时碰壁（原生工具轮 400 + reasoning 关键词）会另行记忆到配置。
  bool _isReturnRequired(ResolvedApiConfig resolved) {
    final url = resolved.baseUrl.toLowerCase();
    return url.contains('deepseek');
  }

  /// 格式降级链：用户显式指定 → 只试那一种（尊重用户，不自动降级）；
  /// 'auto' → 探测首选 + 兜底顺序（openai → 文本协议 → 纯聊天）。
  List<String> _formatFallbackChain(
    AIProviderConfig config,
    AIProviderCapabilities caps,
  ) {
    final explicit = config.toolFormat;
    if (explicit != 'auto' && explicit.isNotEmpty) {
      return [explicit];
    }
    // 8-09 17:2x（用户设计定稿）：工具轮兜底开关（textToolRound）——
    // 给"原生工具调用必须回传思考链"的 AI（DeepSeek 类）省 token：
    // 不用原生、工具一律走文本协议（⟨工具:⟩ 块），就不产生原生 tool_calls，
    // 自然不需要回传思考链。思考参数（thinkingEnabled）不受影响，
    // 对话照常思考——文本协议与思考正交。
    if (config.textToolRound) {
      return ['text', 'none'];
    }
    switch (caps.toolFormat) {
      case 'text':
        return ['text', 'none'];
      case 'none':
        return ['none'];
      // 8-07 23:0x：实测识别出 Anthropic 原生格式 → 原生调用优先，
      // 失败再降级文本协议（格式错误才降，网络/鉴权走 provider failover）
      case 'anthropic':
        return ['anthropic', 'text', 'none'];
      default:
        return ['openai', 'text', 'none'];
    }
  }

  /// 用指定调用方式执行一次非流式聊天（格式翻译逻辑，formatId 由降级链传入）。
  /// 底层工具调用/参数/执行不变，只翻译"工具声明/返回"格式。
  Future<AIProviderResult> _chatWithFormat(
    AIProviderConfig config,
    String formatId,
    List<AIChatMessage> messages, {
    Map<String, dynamic>? defaults,
    List<Map<String, dynamic>>? tools,
    ChatCompletionCancelToken? cancellationToken,
  }) async {
    final adapter = resolveToolFormat(
      config.baseUrl,
      toolFormatOverride: formatId,
    );
    final translatedTools = adapter.translateTools(tools ?? const []);
    // 文本协议：工具轮翻译（不发原生 tool_calls，DeepSeek 思考模式
    // 回传 reasoning_content 拿不到就 400，8-03 06:54）+ 工具说明拼进 system
    var effectiveMessages = messages;
    if (adapter.formatId == 'text') {
      effectiveMessages = adapter.translateToolRound(messages);
      if (tools?.isNotEmpty ?? false) {
        final hint = adapter.buildToolHint(tools!);
        if (hint.isNotEmpty) {
          effectiveMessages = [
            AIChatMessage(role: 'system', content: hint),
            ...effectiveMessages,
          ];
        }
      }
    }
    // 8-07 23:0x 用户：MCP 式统一适配——不管男主用什么格式，管家统一转换调用。
    // anthropic 原生格式走独立 transport（POST /v1/messages）；其余走 OpenAI 兼容
    final apiResult = adapter.formatId == 'anthropic'
        ? await createAnthropicCompletion(
            _resolve(config),
            messages: [
              for (final message in effectiveMessages) message.toApiJson(),
            ],
            defaults: defaults,
            tools: translatedTools,
            cancellationToken: cancellationToken,
          )
        : await _api.createChatCompletion(
            _resolve(config),
            messages: [
              for (final message in effectiveMessages) message.toApiJson(),
            ],
            defaults: defaults,
            tools: translatedTools,
            cancellationToken: cancellationToken,
          );
    // 文本残留工具块处理（8-07 21:2x 用户实测：男主会在文本里写其他家原生
    // 格式，如 anthropic 的 <invoke name="X">…</invoke>（流式带 <|IDSMLI|>
    // 标记）。原生 tool_calls 已有时 = 双写残留（剥掉不显示，不重复执行）；
    // 原生没有时 = 唯一调用来源（解析执行）。任何格式都处理。
    var finalText = apiResult.text;
    var finalToolCalls = apiResult.toolCalls;
    final textCalls = <Map<String, dynamic>>[
      ...adapter.parseToolCallsFromText(apiResult.text),
      // invoke XML 兜底（自家解析没命中时，任何格式都试）
      ...parseAnthropicInvokeCalls(apiResult.text),
    ];
    if (textCalls.isNotEmpty) {
      if (finalToolCalls == null || finalToolCalls.isEmpty) {
        finalToolCalls = textCalls;
      }
      // 8-07 21:42 用户：多记日志，男主会辅助找 bug
      AiModuleLog.log(
        'AI路由',
        '📝 文本残留工具调用 ${textCalls.length} 个'
        '（${textCalls.map((c) => c['name']).join('、')}）'
        '${finalToolCalls.isEmpty ? '→ 作为唯一调用执行' : '→ 原生已有，只剥不重复'}',
      );
      finalText = adapter.stripToolBlocks(apiResult.text);
      // 自家 strip 没剥掉（如 openai 空实现）→ invoke XML 剥离兜底
      if (finalText == apiResult.text) {
        finalText = stripAnthropicInvokeBlocks(apiResult.text);
        if (finalText != apiResult.text) {
          AiModuleLog.log('AI路由', '🧹 invoke XML 兜底剥离（含流式标记清洗）');
        }
      }
    }
    return AIProviderResult(
      text: finalText,
      thinking: apiResult.thinkingChain ?? '',
      reasoningContent: apiResult.thinkingChain,
      usage: apiResult.usage,
      toolCalls: finalToolCalls,
    );
  }

  String _truncateForLog(String value, {int maxLength = 160}) {
    if (value.length <= maxLength) {
      return value;
    }
    return '${value.substring(0, maxLength)}…';
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  ResolvedApiConfig _resolve(AIProviderConfig config) => ResolvedApiConfig(
        id: config.id,
        name: config.name,
        // 8-07 23:0x 用户："先适配 DeepSeek 原生"——DeepSeek 的 Anthropic
        // 兼容端点（/anthropic）归一化回 OpenAI 兼容主端点
        // （https://api.deepseek.com/chat/completions），走原生 JSON tool_calls
        baseUrl: normalizeDeepSeekBaseUrl(config.baseUrl),
        apiKey: config.apiKey,
        model: config.model,
        // 8-09 17:0x：思考模式开关传递（用户设计定稿）
        thinkingEnabled: config.thinkingEnabled,
      );

  /// DeepSeek 的 Anthropic 兼容端点（api.deepseek.com/anthropic）归一化回
  /// OpenAI 兼容主端点——注册表已把 deepseek 优先判为 OpenAI 兼容，
  /// 路径也要对齐（否则请求发到 /anthropic/chat/completions 404）。
  static String normalizeDeepSeekBaseUrl(String baseUrl) {
    final url = baseUrl.trim().toLowerCase();
    if (url.contains('deepseek') && url.contains('/anthropic')) {
      final idx = baseUrl.toLowerCase().indexOf('/anthropic');
      return baseUrl.substring(0, idx);
    }
    return baseUrl;
  }

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

  String _settingsKey(String? personaId) {
    // 8-05 14:5x：测试空间 key 剥掉 __mock__test 后缀 →
    // 继承真实 persona 的设置（provider 选择/自动切换/绑定）
    final pid = _stripMockTestSuffix(personaId);
    return (pid.isEmpty) ? globalPersonaId : pid;
  }

  /// 清掉"上次用的 Provider"（8-04 22:3x 验收⑤⑦⑧修复）：
  /// assembleDecision 的 stateful 判定读 lastProviderFor（上次用的），
  /// 验收切换绑定后若上次是 stateful（如模拟C），决策会错误地走
  /// stateful 分支 → needsSummarize 永不检查。重置后 lastProviderFor
  /// 回退到 candidates.first（=当前绑定）→ 决策按当前绑定判定。
  /// 只改内存（不落盘，验收结束自动消失）。
  void resetLastProvider(String? personaId) {
    final key = _settingsKey(personaId);
    final current = _personaSettings[key];
    if (current == null) return;
    _personaSettings[key] = current.copyWith(clearLastProvider: true);
    changeNotifier.value++;
  }

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
