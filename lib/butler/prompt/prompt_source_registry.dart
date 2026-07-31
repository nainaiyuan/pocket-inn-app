/// Prompt 来源注册表 — 哪些模块可以向 Prompt 提供片段
///
/// 这就是"Prompt 模块"的核心：
/// 管家把各模块（情绪/记忆/规律/要素/碎片/时间…）收集到的信息
/// 在这里统一注册、统一拼装，最后直接扔给男主 AI。
///
/// 用法：
/// 1. 每个模块实现 [PromptSource] 接口（提供片段）
/// 2. 在 [PromptSourceRegistry] 里注册
/// 3. [ButlerPromptBuilder] 按优先级拼装所有来源的片段
library;

import 'prompt_fragment.dart';

/// Prompt 来源 — 能向男主 Prompt 提供上下文片段的模块
abstract class PromptSource {
  /// 来源 id（如 'mood'）
  String get sourceId;

  /// 来源显示名（如 '情绪分析'）
  String get sourceName;

  /// 是否启用
  bool get enabled;

  /// 默认优先级（越小越靠前）
  int get priority => 100;

  /// 构建片段
  /// [context] 管线的 ButlerContext（含其他模块塞的数据）
  /// [input] 当前用户输入（脱敏后）
  Future<PromptFragment?> buildFragment({
    required dynamic context,
    required String input,
  });
}

/// Prompt 来源注册表
class PromptSourceRegistry {
  static final PromptSourceRegistry instance = PromptSourceRegistry._();

  PromptSourceRegistry._();

  final List<PromptSource> _sources = [];

  /// 注册来源
  void register(PromptSource source) {
    _sources.removeWhere((s) => s.sourceId == source.sourceId);
    _sources.add(source);
    _sources.sort((a, b) => a.priority.compareTo(b.priority));
  }

  /// 取消注册
  void unregister(String sourceId) {
    _sources.removeWhere((s) => s.sourceId == sourceId);
  }

  /// 全部来源
  List<PromptSource> get all => List.unmodifiable(_sources);
}
