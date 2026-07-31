/// Prompt 片段 — Prompt 拼装的最小单位
///
/// 每个片段有明确来源（哪个模块产的），方便：
/// - 排查："这段是哪来的？" → 看 source
/// - 管理：调整某类片段的措辞/顺序
/// - 开关：某个来源的片段可以整体不拼
library;

/// Prompt 片段
class PromptFragment {
  /// 来源模块 id（如 'mood'、'memory'、'pattern'）
  final String sourceId;

  /// 来源显示名（如 '情绪分析'）
  final String sourceName;

  /// 片段内容（已经格式化好的文本）
  final String content;

  /// 优先级：越小越靠前
  final int priority;

  const PromptFragment({
    required this.sourceId,
    required this.sourceName,
    required this.content,
    this.priority = 100,
  });
}

/// Prompt 拼装结果
class PromptBuildResult {
  /// 拼好的完整上下文文本（空行分隔）
  final String text;

  /// 所有片段（按优先级排序）
  final List<PromptFragment> fragments;

  /// 被跳过的片段（disabled 的来源）
  final List<PromptFragment> skipped;

  const PromptBuildResult({
    required this.text,
    required this.fragments,
    this.skipped = const [],
  });

  bool get isEmpty => fragments.isEmpty;
}
