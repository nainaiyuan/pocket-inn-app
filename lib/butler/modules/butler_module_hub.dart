/// 管家模块组装 — 所有模块在这里注册
///
/// 加新模块 = 新建模块文件 + 在这里 register 一行。
/// 这是整个管家模块体系的总装车间。
library;

import '../butler_config.dart';
import '../butler_database.dart';
import '../insight/insight_engine.dart';
import '../mask_engine.dart';
import '../memory/user_element_engine.dart';
import '../memory/user_element_store.dart';
import '../memory/user_memory.dart';
import '../mood_analysis/mood_analyzer_impl.dart';
import '../patterns/pattern_engine.dart';
import '../prompt/prompt_source_registry.dart';
import '../storage/storage_registry.dart';
import 'blocklist_module.dart';
import 'butler_module.dart';
import 'calibrator_module.dart';
import 'mask_module.dart';
import 'module_registry.dart';
import 'module_settings_store.dart';
import 'mood_module.dart';
import 'pipeline_runner.dart';
import 'retrieval_module.dart';

/// 管家模块组装器
/// 负责创建、注册所有模块，并提供管线执行入口
class ButlerModuleHub {
  /// 全局共享实例（懒加载）
  /// 温控/检索/管理页共用同一份，保证规律、记忆、假面层数据一致
  static ButlerModuleHub? _sharedInstance;

  static ButlerModuleHub get instance =>
      _sharedInstance ??= ButlerModuleHub();

  /// 注册表（单例）
  final ModuleRegistry registry;

  /// 管线执行器
  final PipelineRunner pipeline;

  /// 模块开关存储
  final ModuleSettingsStore settingsStore;

  /// 可注入的检索组件（测试用）
  final PatternEngine? patternEngine;
  final UserMemoryManager? memoryManager;
  final UserElementEngine? elementEngine;
  final InsightEngine? insightEngine;

  /// 是否启用数据库相关检索（洞察/近期互动）。
  /// 测试环境没有数据库时可置 false。
  final bool enableDbRetrieval;

  /// 已创建的模块实例（供外部查询状态）
  final Map<String, ButlerModule> modules = {};

  ButlerModuleHub({
    ModuleRegistry? registry,
    MaskEngine? maskEngine,
    ButlerConfig? config,
    ModuleSettingsStore? settingsStore,
    ButlerDatabase? database,
    PatternEngine? patternEngine,
    UserMemoryManager? memoryManager,
    UserElementEngine? elementEngine,
    InsightEngine? insightEngine,
    bool enableDbRetrieval = true,
  }) : registry = registry ?? ModuleRegistry.instance,
       pipeline = PipelineRunner(registry: registry ?? ModuleRegistry.instance),
       settingsStore = settingsStore ?? ModuleSettingsStore.instance,
       patternEngine = patternEngine,
       memoryManager = memoryManager,
       elementEngine = elementEngine,
       insightEngine = insightEngine,
       enableDbRetrieval = enableDbRetrieval {
    final effectiveConfig = config ?? ButlerConfig();

    // 共享的规律引擎（基线与规律只有一份，温控和检索共用）
    final sharedPatternEngine =
        patternEngine ?? PatternEngine(UserElementStore());
    // 规律持久化（SQLite，重启不丢）
    sharedPatternEngine.attachStore(StorageRegistry.instance.patterns);

    // ===== 注册全部模块（按执行顺序） =====

    // ① 禁区拦截（guard，最先）
    _register(BlocklistModule());

    // ② 假面层（guard，第二位）
    final sharedMaskEngine = maskEngine ?? MaskEngine();
    // 身份持久化（SQLite，重启不丢）
    sharedMaskEngine.attachStore(StorageRegistry.instance.identity);
    _register(MaskModule(
      maskEngine: sharedMaskEngine,
      config: effectiveConfig,
    ));

    // ③ 情绪分析（analyze）
    _register(MoodModule(analyzer: MoodAnalyzerImpl()));

    // ④ 温控校准（analyze）— 检测情绪偏离基线，创建 keywordCollect 任务
    _register(CalibratorModule(
      patternEngine: sharedPatternEngine,
    ));

    // ⑤ 检索调度（analyze）— 六路检索拼上下文
    final db = database ?? ButlerDatabase.instance;
    final interactionStore = StorageRegistry.instance.interaction;
    final sharedMemoryManager = memoryManager ?? UserMemoryManager();
    // 用户记忆持久化（SQLite，重启不丢）
    sharedMemoryManager.attachStore(StorageRegistry.instance.userMemory);
    _register(RetrievalModule(
      patternEngine: sharedPatternEngine,
      memoryManager: sharedMemoryManager,
      elementEngine: elementEngine ?? UserElementEngine(UserElementStore()),
      insightEngine: enableDbRetrieval
          ? (insightEngine ?? InsightEngine(db: db))
          : null,
      recentRecordsLoader: enableDbRetrieval
          ? () async {
              final records = await interactionStore.recentAny(limit: 3);
              return records.map((r) => r.toJson()).toList();
            }
          : null,
    ));

    // 未来在这里加：
    // ⑥ 碎片系统（analyze）— FragmentModule

    // ===== 注册 Prompt 来源（检索结果拼进男主 Prompt）=====
    PromptSourceRegistry.instance.register(RetrievalPromptSource());
  }

  void _register(ButlerModule module) {
    registry.register(module);
    modules[module.id] = module;
  }

  /// 加载持久化的开关状态（APP 启动时调用）
  Future<void> loadSettings() async {
    final ids = modules.keys.toList();
    final map = await settingsStore.getEnabledMap(ids);
    for (final entry in map.entries) {
      modules[entry.key]?.setUserEnabled(entry.value);
    }
  }

  /// 加载全部持久化数据：规律、用户记忆、假面层身份（APP 启动时调用）
  Future<void> loadPersistentData() async {
    await Future.wait([
      if (sharedPatternEngine != null) sharedPatternEngine!.loadFromStore(),
      if (sharedMemoryManager != null) sharedMemoryManager!.loadFromStore(),
      if (sharedMaskEngine != null) sharedMaskEngine!.loadFromStore(),
    ]);
  }

  /// 共享规律引擎（温控/检索/管理页共用同一份）
  /// 从注册的模块里取，保证和运行时用的是同一个实例
  PatternEngine? get sharedPatternEngine {
    final calibrator = modules['calibrator'];
    if (calibrator is CalibratorModule) return calibrator.patternEngine;
    final retrieval = modules['retrieval'];
    if (retrieval is RetrievalModule) return retrieval.patternEngine;
    return null;
  }

  /// 共享假面层引擎（禁区/检索/管理页共用同一份）
  MaskEngine? get sharedMaskEngine {
    final mask = modules['mask'];
    if (mask is MaskModule) return mask.maskEngine;
    return null;
  }

  /// 共享用户记忆管理器（检索/管理页共用同一份）
  UserMemoryManager? get sharedMemoryManager {
    final retrieval = modules['retrieval'];
    if (retrieval is RetrievalModule) return retrieval.memoryManager;
    return null;
  }

  /// 切换某模块开关（UI 调用，持久化）
  Future<void> setModuleEnabled(String id, bool enabled) async {
    modules[id]?.setUserEnabled(enabled);
    await settingsStore.setEnabled(id, enabled);
  }

  /// 获取某模块（按 id）
  T? module<T extends ButlerModule>(String id) => modules[id] as T?;

  /// 模块数量
  int get count => modules.length;
}
