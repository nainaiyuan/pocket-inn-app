/// 模块注册表 — 所有管家模块在这里登记
///
/// 加新功能 = 新建模块文件 + 在这里 add 一行。
/// 改逻辑 = 只改那个模块文件。
/// 关掉 = 在设置里关开关（或从注册表移除）。
library;

import 'butler_module.dart';

/// 模块注册表
/// 单例，全局唯一
class ModuleRegistry {
  static final ModuleRegistry instance = ModuleRegistry._();

  /// 创建独立实例（测试/隔离用）
  /// 默认场景请用 [instance] 单例
  ModuleRegistry();

  ModuleRegistry._();

  /// 已注册的模块（按 stage 排序）
  final List<ButlerModule> _modules = [];

  /// 注册一个模块
  /// [priority] 同 stage 内的顺序，越小越先执行
  void register(ButlerModule module, {int priority = 100}) {
    _modules.removeWhere((m) => m.id == module.id);
    _modules.add(module);
    _modules.sort((a, b) {
      final stageCompare = a.stage.index.compareTo(b.stage.index);
      if (stageCompare != 0) return stageCompare;
      return _priorityOf(a).compareTo(_priorityOf(b));
    });
    _priorities[module.id] = priority;
  }

  final Map<String, int> _priorities = {};

  int _priorityOf(ButlerModule module) => _priorities[module.id] ?? 100;

  /// 取消注册
  void unregister(String id) {
    _modules.removeWhere((m) => m.id == id);
    _priorities.remove(id);
  }

  /// 获取全部模块（按执行顺序）
  List<ButlerModule> get all => List.unmodifiable(_modules);

  /// 获取指定 stage 的模块
  List<ButlerModule> byStage(ButlerModuleStage stage) =>
      _modules.where((m) => m.stage == stage).toList(growable: false);

  /// 按 id 查找
  ButlerModule? find(String id) {
    for (final m in _modules) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 启用的模块数
  int get enabledCount =>
      _modules.where((m) => m.enabled).length;
}
