/// 模块开关存储 — 每个管家模块的启用状态（持久化）
///
/// 存在 SharedPreferences 里（key: butler_module_enabled_<模块id>）。
/// 默认全开；用户关掉后，重启 APP 也保持关闭。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 模块开关存储（单例）
class ModuleSettingsStore {
  static final ModuleSettingsStore instance = ModuleSettingsStore._();

  ModuleSettingsStore._();

  static const String _prefix = 'butler_module_enabled_';

  /// 读取某模块是否启用（默认 true = 全开）
  Future<bool> isEnabled(String moduleId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_prefix$moduleId') ?? true;
  }

  /// 设置某模块启用状态
  Future<void> setEnabled(String moduleId, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefix$moduleId', enabled);
  }

  /// 读取多个模块的开关状态（批量，减少 IO）
  Future<Map<String, bool>> getEnabledMap(List<String> moduleIds) async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final id in moduleIds) id: prefs.getBool('$_prefix$id') ?? true,
    };
  }
}
