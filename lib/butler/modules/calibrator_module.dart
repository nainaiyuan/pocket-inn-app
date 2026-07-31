/// 温控校准模块 — 监测用户情绪是否偏离基线，必要时让男主介入
///
/// 闭环设计（butler_algorithm.md 第 6 节）：
/// ```
/// 基线0 → 用户情绪变化（偏离基线≥20）
///   → 创建 keywordCollect 任务（问男主要关键词）
///   → 男主回复 "#keywords 词1,词2"
///   → 管家解析入库 → 弧线/规律积累 → 基线滚动平均形成
///   → 关键词组合≥3次 → 规律确认
/// ```
///
/// 本模块只做前半段：**检测偏离 → 创建任务**。
/// 后半段（男主回复解析）由 TaskResponseHandler 处理（见 task/）。
///
/// 阈值（来自 MoodBaseline.detectDeviation）：
/// | 偏离值 | 行为 |
/// |--------|------|
/// | < 20   | 正常，不处理 |
/// | 20-39  | 轻度：创建 keywordCollect 任务 |
/// | ≥ 40   | 显著：创建 keywordCollect 任务 + isAnomaly=true |
///
/// 防抖：连续 3 次回归浮动带（<margin）才解除警戒，防止反复触发。
library;

import 'dart:async';

import '../../utils/debug_logger.dart';
import '../modules/butler_module.dart';
import '../mood_analysis/mood_interface.dart';
import '../patterns/mood_baseline.dart';
import '../patterns/pattern_engine.dart';
import '../task/butler_task.dart';
import '../task/task_manager.dart';

/// 温控校准模块
class CalibratorModule extends ButlerModule {
  /// 任务管理器（可注入，测试用）
  final TaskManager taskManager;

  /// 规律引擎（提供基线，可注入）
  final PatternEngine? patternEngine;

  /// 浮动带宽度（默认 ±10）
  final double margin;

  /// 连续样本在浮动带内的计数（防抖）
  int _settledCount = 0;

  /// 最近一次触发任务的时间（防频繁触发）
  DateTime? _lastTaskAt;

  /// 两次任务的最小间隔（秒）
  final int minIntervalSeconds;

  /// 任务超时（秒），超时标记 timeout
  final int taskTimeoutSeconds;

  /// 超时计时器（dispose 时取消，防止测试/退出时残留）
  final List<Timer> _timers = [];

  CalibratorModule({
    TaskManager? taskManager,
    this.patternEngine,
    this.margin = 10,
    this.minIntervalSeconds = 60,
    this.taskTimeoutSeconds = 30,
  }) : taskManager = taskManager ?? TaskManager.instance;

  /// 取消所有未完成的超时计时器（模块销毁时调用）
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  @override
  String get id => 'calibrator';

  @override
  String get name => '温控校准';

  @override
  String get description => '检测情绪偏离基线，让男主介入问原因，积累关键词形成规律';

  @override
  ButlerModuleStage get stage => ButlerModuleStage.analyze;

  @override
  bool get enabled => true;

  @override
  Future<ButlerModuleResult> onUserMessage(
    ButlerContext context,
    String text,
  ) async {
    final mood = context.getData<MoodResult>('mood_result');
    if (mood == null) {
      // 前面没有情绪模块 → 本模块不做事
      return ButlerModuleResult.pass(text);
    }

    // 基线不可信 → 只积累，不触发
    final baseline = patternEngine?.baseline;
    if (baseline == null || !baseline.isReliable) {
      DebugLogger.log('温控', '基线不可信（样本<5），只积累样本不触发任务');
      return ButlerModuleResult.pass(text);
    }

    // 动态维度：分析器输出什么维度就检测什么维度。
    // 基线里还没有的维度（新模型/新标签首次出现）= 管家还不认识 →
    // 记录"新维度待认识"日志（等基线积累后自然参与偏离检测）。
    final known = baseline.knownDimensions.toSet();
    final unknownDims = mood.dimensions.keys
        .where((d) => !known.contains(d))
        .toList();
    if (unknownDims.isNotEmpty) {
      DebugLogger.log(
        '温控',
        '新维度出现（管家还不认识，和男主一起认识用户）: '
        '${unknownDims.join('、')}',
      );
    }

    final deviation = baseline.detectDeviation(mood.dimensions);
    DebugLogger.log(
      '温控',
      '偏离检测: ${deviation.reason}（严重度 ${deviation.severity.name}）',
    );

    // 正常波动 → 检查是否已回归（防抖解除）
    if (!deviation.isDeviated) {
      _settledCount++;
      DebugLogger.log('温控', '回归浮动带，连续 $_settledCount 次');
      if (_settledCount >= 3) {
        _settledCount = 0;
        _createTask(
          context,
          TaskType.arcConfirm,
          description: '情绪已回归基线，请男主确认本次情绪弧线完整',
          resultData: {
            'deviation': deviation.maxDeviation,
            'max_dimension': deviation.maxDimension,
          },
        );
      }
      return ButlerModuleResult.pass(text);
    }

    // 偏离了 → 重置防抖计数
    _settledCount = 0;

    // 防频繁触发：距离上次任务 < minIntervalSeconds → 跳过
    if (_lastTaskAt != null &&
        DateTime.now().difference(_lastTaskAt!).inSeconds < minIntervalSeconds) {
      DebugLogger.log('温控', '距上次任务 < $minIntervalSeconds 秒，跳过（防抖）');
      return ButlerModuleResult.pass(text);
    }

    final isAnomaly = deviation.severity == DeviationSeverity.significant;
    _createTask(
      context,
      TaskType.keywordCollect,
      description: isAnomaly
          ? '用户情绪显著偏离基线（${deviation.reason}），请男主询问触发原因并回复关键词'
          : '用户情绪偏离基线（${deviation.reason}），请男主询问触发原因并回复关键词',
      resultData: {
        'deviation': deviation.maxDeviation,
        'is_anomaly': isAnomaly,
        'max_dimension': deviation.maxDimension,
        'concentration': mood.concentration.name,
        'severity': deviation.severity.name,
      },
    );

    return ButlerModuleResult.pass(text);
  }

  /// 创建内部任务（带超时标记）
  void _createTask(
    ButlerContext context,
    TaskType type, {
    required String description,
    Map<String, dynamic>? resultData,
  }) {
    final task = taskManager.createTask(
      type: type,
      description: description,
    );
    task.resultData = resultData ?? {};
    task.resultData!['userId'] = context.userId;
    task.resultData!['characterId'] = context.characterId;
    task.resultData!['sessionId'] = context.sessionId;

    _lastTaskAt = DateTime.now();

    DebugLogger.log('温控', '创建任务 ${task.id}（${type.name}）: $description');

    // 超时标记：30 秒后若仍未完成 → timeout（防止阻塞对话）
    final timer = Timer(Duration(seconds: taskTimeoutSeconds), () {
      final current = taskManager.findTask(task.id);
      if (current != null &&
          current.status != TaskStatus.confirmed &&
          current.status != TaskStatus.failed &&
          current.status != TaskStatus.cancelled) {
        current.status = TaskStatus.timeout;
        current.updatedAt = DateTime.now();
        DebugLogger.log('温控', '任务 ${task.id} 超时（${taskTimeoutSeconds}s 无响应）');
      }
    });
    _timers.add(timer);
  }
}
