import 'package:get_it/get_it.dart';

import '../butler/butler.dart';
import '../butler/butler_database.dart';
import '../butler/modules/butler_module_hub.dart';
import '../data/api_configs.dart' as api_configs;
import '../data/app_settings.dart' as app_settings;
import '../data/mock_user_settings.dart' as mock_user_settings;
import '../data/preset_selection.dart' as preset_selection;
import '../services/api_config_service.dart';
import '../services/api_request_log_service.dart';
import '../services/app_backup_service.dart';
import '../services/app_data_service.dart';
import '../services/app_settings_service.dart';
import '../services/character_service.dart';
import '../services/chat_character_resolver.dart';
import '../services/chat_database_service.dart';
import '../services/chat_memory_service.dart' as chat_memory;
import '../services/chat_service.dart';
import '../services/font_service.dart';
import '../services/i_openai_api_service.dart';
import '../services/openai_compatible_api_service.dart';
import '../services/preset_service.dart';
import '../services/storage_service.dart';
import '../services/user_settings_service.dart';
import '../services/voice_chat_service.dart';
import '../services/trace_storage_prefs.dart';
import '../services/tts/tts_service.dart';
import '../butler/debug_lab/trace_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/world_book_service.dart';

/// 全局 DI 容器。
///
/// 新代码优先用 `getIt<XxxService>()`；旧代码保留 `XxxService.instance`
/// 不变，避免一次性大改回归。两者指向同一实例，互相兼容。
final getIt = GetIt.instance;

/// 将所有 service 按正确依赖顺序注册 + 初始化。
/// 每个步骤独立 try-catch，防止一个初始化失败阻塞后续步骤。
Future<void> setupServiceLocator() async {
  // ── 第1组：无依赖的基础 service（先注册再初始化） ──
  getIt.registerSingleton<StorageService>(StorageService.instance);
  await _tryInit('StorageService', () => getIt<StorageService>().initialize());

  getIt.registerSingleton<WorldBookService>(WorldBookService.instance);
  await _tryInit('WorldBookService', () => getIt<WorldBookService>().initialize());

  getIt.registerSingleton<CharacterService>(CharacterService.instance);
  await _tryInit('CharacterService', () => getIt<CharacterService>().initialize());

  getIt.registerSingleton<PresetService>(PresetService.instance);
  await _tryInit('PresetService', () => getIt<PresetService>().initialize());

  // ── 依赖 StorageService 的顶层函数 ──
  await _tryInit('preset_selection', () => preset_selection.initializeSelectedPreset());
  await _tryInit('app_settings', () => app_settings.initializeAppSettings());

  // ── API 服务 ──
  getIt.registerSingleton<ApiConfigService>(ApiConfigService.instance);
  await _tryInit('ApiConfigService', () => getIt<ApiConfigService>().initialize());

  getIt.registerSingleton<ApiRequestLogService>(ApiRequestLogService.instance);
  await _tryInit('ApiRequestLogService', () => getIt<ApiRequestLogService>().initialize());

  // ── Agent Debug Lab：轨迹持久化（摘要式 1-2KB×50，重启不丢）──
  await _tryInit('AgentTraceStore', () async {
    final prefs = await SharedPreferences.getInstance();
    TraceStore.configure(PrefsTraceStorage(prefs));
  });

  // ── 字体 ──
  getIt.registerSingleton<FontService>(FontService.instance);
  await _tryInit('FontService', () => getIt<FontService>().initializeCustomFont());

  // ── 用户设定 ──
  await _tryInit('user_settings', () => mock_user_settings.initializeUserSettings());

  // ── 聊天数据库 ──
  getIt.registerSingleton<ChatDatabaseService>(ChatDatabaseService.instance);
  await _tryInit('ChatDatabaseService', () => getIt<ChatDatabaseService>().initialize());

  // ── 长期记忆配置 ──
  await _tryInit('memory_config', () => chat_memory.initializeMemoryConfig());

  // ── API 配置列表 ──
  await _tryInit('api_configs', () => api_configs.initializeApiConfigs());

  // ── 聊天服务 ──
  getIt.registerSingleton<ChatService>(ChatService.instance);

  // ── 管家 ──
  // 关键：Butler 必须复用 ButlerModuleHub 的共享假面层引擎，
  // 否则假面层页面配置的身份词与聊天时用的不是同一份 → 替换不生效
  final hub = ButlerModuleHub.instance;
  final butler = Butler(sharedMaskEngine: hub.sharedMaskEngine);
  await _tryInit('ButlerDatabase', () => ButlerDatabase.instance.initialize());
  getIt.registerSingleton<Butler>(butler);
  _tryInitSync('ChatService.initButler', () => getIt<ChatService>().initButler(butler));

  // ── TTS ──
  getIt.registerSingleton<TtsService>(TtsService.instance);
  await _tryInit('TtsService', () => getIt<TtsService>().init());

  // ── 语音聊天 ──
  getIt.registerSingleton<VoiceChatService>(VoiceChatService.instance);
  await _tryInit('VoiceChatService', () => getIt<VoiceChatService>().init());

  // ── 懒加载 service（用到时才实例化，无初始化问题） ──
  getIt.registerLazySingleton<AppBackupService>(() => AppBackupService.instance);
  getIt.registerLazySingleton<AppDataService>(() => AppDataService.instance);
  getIt.registerLazySingleton<AppSettingsService>(() => AppSettingsService.instance);
  getIt.registerLazySingleton<ChatCharacterResolver>(() => ChatCharacterResolver.instance);
  getIt.registerLazySingleton<IOpenAiApiService>(() => OpenAICompatibleApiService.instance);
  getIt.registerLazySingleton<OpenAICompatibleApiService>(() => OpenAICompatibleApiService.instance);
  getIt.registerLazySingleton<UserSettingsService>(() => UserSettingsService.instance);
  getIt.registerLazySingleton<chat_memory.ChatMemoryService>(() => chat_memory.ChatMemoryService.instance);
}

/// 执行异步 [fn]，失败时打印日志但**不抛出异常**。
Future<void> _tryInit(String label, Future<void> Function() fn) async {
  try {
    await fn();
  } catch (e, stack) {
    // ignore: avoid_print
    print('⚠️ [$label] 初始化失败: $e\n$stack');
  }
}

/// 执行同步 [fn]，失败时打印日志但**不抛出异常**。
void _tryInitSync(String label, void Function() fn) {
  try {
    fn();
  } catch (e, stack) {
    // ignore: avoid_print
    print('⚠️ [$label] 初始化失败: $e\n$stack');
  }
}
