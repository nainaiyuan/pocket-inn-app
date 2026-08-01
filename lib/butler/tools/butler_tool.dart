/// 管家工具层 — 把管家模块抽象成"工具"（像 OpenAI function calling / 龙虾的技能工具）
///
/// 不同模块 = 管家的不同工具：
///   🔧 情绪弧线查询（emotion_arcs_query）
///   🔧 规律查询（pattern_query）
///   🔧 基线查询（baseline_query）
///   🔧 语义情绪分析（semantic_mood_analyze）
///   🔧 假面替换（identity_mask）
///   🔧 记忆检索（memory_recall）
///   🔧 调用男主 AI（ai_chat）
///
/// 技能（ButlerSkill）执行时 = 依次调用工具；每次调用都会被记录，
/// 日志页的流程树里能看到：调了哪个工具、输入什么、输出什么、耗时多少、成功还是失败。
library;

/// 一次工具调用的完整记录（日志页展示用）
class ButlerToolCall {
  final String toolId;
  final String toolName;

  /// 输入摘要（人话，如 "近7天 男主=沈星回"）
  final String argsSummary;

  /// 输出摘要（人话，如 "12条弧线：开心72、烦躁45"）
  String? resultSummary;

  /// 失败原因（null = 成功）
  String? error;

  int elapsedMs = 0;

  ButlerToolCall({
    required this.toolId,
    required this.toolName,
    required this.argsSummary,
  });
}

/// 工具基类：一个工具 = 名字 + 描述（干什么用）+ call（干活，返回人话摘要）
abstract class ButlerTool {
  String get id;
  String get name;

  /// 这个工具是干嘛的、什么时候用
  String get description;

  /// 执行工具。返回输出摘要（人话）；抛异常 = 失败。
  Future<String> call(Map<String, dynamic> args);
}
