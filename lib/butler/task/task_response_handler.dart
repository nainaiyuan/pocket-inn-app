/// 内部任务响应处理器 — 解析男主回复中的任务标记，完成温控闭环
///
/// 男主在回复中附带任务响应，格式（butler_algorithm.md 第 7 节）：
/// | 任务 | 男主回复格式 | 含义 |
/// |------|------------|------|
/// | keywordCollect | `#keywords 词1,词2` | 报告触发情绪的关键词 |
/// | arcConfirm | `#arc_end` | 确认弧线完整 |
/// | patternMerge | `#same yes` | 确认两个组合是同一类 |
/// | conversationSummary | `#summary 词1,词2` | 报告对话关键词 |
///
/// 处理流程：
/// 1. 从男主回复中提取 `#标记` 行
/// 2. 匹配到任务类型 → 找到对应 pending 任务 → 标记 confirmed
/// 3. 关键词写入弧线记录（供规律引擎积累）
library;

import '../../utils/debug_logger.dart';
import '../patterns/pattern_engine.dart';
import 'butler_task.dart';
import 'task_manager.dart';

/// 任务响应解析结果
class TaskResponseResult {
  /// 是否解析到了任务标记
  final bool matched;

  /// 匹配到的任务类型名
  final String? taskType;

  /// 提取的关键词列表
  final List<String> keywords;

  /// 清理掉任务标记后的回复文本（剩下的才给用户看）
  final String cleanedText;

  const TaskResponseResult({
    required this.matched,
    this.taskType,
    this.keywords = const [],
    required this.cleanedText,
  });
}

/// 任务响应处理器
class TaskResponseHandler {
  /// 任务管理器
  final TaskManager taskManager;

  /// 规律引擎（关键词写入弧线用，可注入）
  final PatternEngine? patternEngine;

  /// 关键词落地回调（可注入）
  /// 男主反馈 `#keywords 加班,累` 时触发，由上层把关键词写进弧线/记忆
  final void Function(List<String> keywords)? onKeywordsCollected;

  /// 本次会话男主反馈过的关键词（去重累积）
  /// 对话结束时上层可读取，合并进 EmotionArc.triggerKeywords
  final List<String> collectedKeywords = [];

  TaskResponseHandler({
    TaskManager? taskManager,
    this.patternEngine,
    this.onKeywordsCollected,
  }) : taskManager = taskManager ?? TaskManager.instance;

  /// 标记 → 任务类型映射
  static const Map<String, String> _tagToTaskType = {
    '#keywords': 'keywordCollect',
    '#arc_end': 'arcConfirm',
    '#same': 'patternMerge',
    '#summary': 'conversationSummary',
  };

  /// 解析男主回复中的任务标记
  ///
  /// 返回 [TaskResponseResult]：
  /// - matched=true 且关键词非空 → 已处理，关键词入库
  /// - matched=true 但关键词空 → 标记识别但无词（如 #arc_end）
  /// - matched=false → 纯正常回复，原样返回
  TaskResponseResult handle(String assistantReply) {
    // 逐行找 #标记
    final lines = assistantReply.split('\n');
    String? matchedTag;
    List<String> keywords = [];
    final keptLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      final lower = trimmed.toLowerCase();

      // 匹配 #keywords / #summary（带关键词）
      if (lower.startsWith('#keywords') || lower.startsWith('#summary')) {
        matchedTag = trimmed.split(RegExp(r'[\s,，]+')).first.toLowerCase();
        // 8-08 02:1x：indexOf(' ') = -1 时 substring(-1) 崩溃（#keywords 无空格）
        final sp = trimmed.indexOf(' ');
        final rest = (sp >= 0 ? trimmed.substring(sp) : '').trim();
        keywords = rest
            .split(RegExp(r'[\s,，、]+'))
            .where((k) => k.isNotEmpty)
            .toList();
        continue;
      }

      // 匹配 #arc_end / #same
      if (lower.startsWith('#arc_end')) {
        matchedTag = '#arc_end';
        continue;
      }
      if (lower.startsWith('#same')) {
        matchedTag = '#same';
        final sp = trimmed.indexOf(' ');
        final rest = (sp >= 0 ? trimmed.substring(sp) : '').trim().toLowerCase();
        keywords = rest == 'yes' || rest == '是' ? ['yes'] : ['no'];
        continue;
      }

      // 普通行保留
      keptLines.add(line);
    }

    if (matchedTag == null) {
      return TaskResponseResult(
        matched: false,
        cleanedText: assistantReply,
      );
    }

    final taskType = _tagToTaskType[matchedTag];

    // 找到对应的 pending 任务并确认
    _confirmPendingTask(taskType);

    // 关键词入库（规律引擎记录一次命中，积累规律）
    if (keywords.isNotEmpty) {
      // 暂存：供上层在对话结束时合并进弧线/记忆
      for (final k in keywords) {
        if (!collectedKeywords.contains(k)) collectedKeywords.add(k);
      }
      DebugLogger.log('温控', '男主反馈关键词: ${keywords.join('、')} → 已暂存 ${collectedKeywords.length} 个');

      // 回调：让上层立即写入弧线/记忆（如果已接线）
      onKeywordsCollected?.call(List.from(keywords));
    }

    return TaskResponseResult(
      matched: true,
      taskType: taskType,
      keywords: keywords,
      cleanedText: keptLines.join('\n').trim(),
    );
  }

  /// 确认对应类型的 pending 任务
  void _confirmPendingTask(String? taskType) {
    if (taskType == null) return;

    for (final task in taskManager.getActiveTasks()) {
      if (task.type.name == taskType &&
          (task.status == TaskStatus.pending ||
           task.status == TaskStatus.running ||
           task.status == TaskStatus.done ||
           task.status == TaskStatus.timeout)) {
        taskManager.confirmComplete(task.id);
        DebugLogger.log('温控', '任务 ${task.id}（$taskType）已被男主响应确认');
        return;
      }
    }
  }
}
