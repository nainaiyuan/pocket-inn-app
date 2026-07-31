/// 任务管理器 — 管家所有操作的统一调度中心
///
/// 管家做任何事必须：创建任务 → 执行 → 通知用户确认 → 用户确认才算完成。
/// 所有任务都有唯一ID，用户可以定位、重试、取消。
library task_manager;

import 'dart:async';
import 'dart:collection';

// 复用 butler_task.dart 中的 TaskStatus 和 ButlerTask
import 'butler_task.dart';

/// 任务类型



/// 任务类型
enum TaskType {
  cleanupCheck,       // 清理检查
  cleanupExecute,     // 执行清理
  processMessage,     // 处理用户消息
  syncData,           // 数据同步
  deviceControl,      // 设备控制
  characterCreate,    // 创建角色
  characterDelete,    // 删除角色
  exportData,         // 导出数据
  importData,         // 导入数据
  keywordCollect,     // 温控校准：情绪偏离基线，问男主要关键词（回复格式 #keywords 词1,词2）
  arcConfirm,         // 温控校准：情绪回归基线，确认完整弧线（回复格式 #arc_end）
  patternMerge,       // 温控校准：情感区间高度重叠的组合，问男主是否同一类（回复格式 #same yes）
  conversationSummary,// 对话总结：对话结束，问男主要关键词（回复格式 #summary 词1,词2）
  other,              // 其他
}

/// 任务数据模型
class Task {
  final String id;
  final TaskType type;
  TaskStatus status;
  final String description;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? completedAt;
  int retryCount;
  final int maxRetries;
  Map<String, dynamic>? resultData;
  String? errorMessage;
  bool autoRetry; // 是否允许自动重试（只有自动清理类才允许）

  Task({
    required this.id,
    required this.type,
    this.status = TaskStatus.pending,
    required this.description,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.completedAt,
    this.retryCount = 0,
    this.maxRetries = 3,
    this.resultData,
    this.errorMessage,
    this.autoRetry = false,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();
}

/// 任务管理器
class TaskManager {
  /// 单例
  static final TaskManager instance = TaskManager._();
  TaskManager._();

  final ListQueue<Task> _taskQueue = ListQueue();
  final List<Task> _completedTasks = [];
  Task? _currentTask;

  /// 创建任务
  Task createTask({
    required TaskType type,
    required String description,
    bool autoRetry = false,
    int maxRetries = 3,
  }) {
    final task = Task(
      id: _generateId(type),
      type: type,
      description: description,
      autoRetry: autoRetry,
      maxRetries: maxRetries,
    );
    _taskQueue.add(task);
    return task;
  }

  /// 获取下一个待处理的任务
  Task? getNextPending() {
    if (_currentTask != null && _currentTask!.status == TaskStatus.running) {
      return _currentTask;
    }
    for (final task in _taskQueue) {
      if (task.status == TaskStatus.pending) {
        _currentTask = task;
        task.status = TaskStatus.running;
        task.updatedAt = DateTime.now();
        return task;
      }
    }
    return null;
  }

  /// 标记任务为"等待用户确认"
  void markWaitingConfirm(String taskId) {
    final task = findTask(taskId);
    if (task != null) {
      task.status = TaskStatus.done;
      task.updatedAt = DateTime.now();
    }
  }

  /// 用户确认完成
  void confirmComplete(String taskId) {
    final task = findTask(taskId);
    if (task != null) {
      task.status = TaskStatus.confirmed;
      task.completedAt = DateTime.now();
      task.updatedAt = DateTime.now();
      _taskQueue.remove(task);
      _completedTasks.add(task);
      _currentTask = null;
    }
  }

  /// 标记失败
  void markFailed(String taskId, String errorMessage) {
    final task = findTask(taskId);
    if (task != null) {
      task.status = TaskStatus.failed;
      task.errorMessage = errorMessage;
      task.retryCount++;
      task.updatedAt = DateTime.now();
      _currentTask = null;

      // 自动重试的任务，放回队列
      if (task.autoRetry && task.retryCount < task.maxRetries) {
        task.status = TaskStatus.pending;
        _taskQueue.addLast(task);
      }
    }
  }

  /// 用户手动重试失败的任务
  void retryByUser(String taskId) {
    final task = findTask(taskId);
    if (task != null && task.status == TaskStatus.failed) {
      task.status = TaskStatus.pending;
      task.errorMessage = null;
      task.updatedAt = DateTime.now();
      _taskQueue.addLast(task);
    }
  }

  /// 取消任务
  void cancel(String taskId) {
    final task = findTask(taskId);
    if (task != null) {
      task.status = TaskStatus.cancelled;
      task.updatedAt = DateTime.now();
      _taskQueue.remove(task);
      _completedTasks.add(task);
      _currentTask = null;
    }
  }

  /// 查找任务
  Task? findTask(String taskId) {
    for (final task in _taskQueue) {
      if (task.id == taskId) return task;
    }
    for (final task in _completedTasks) {
      if (task.id == taskId) return task;
    }
    if (_currentTask?.id == taskId) return _currentTask;
    return null;
  }

  /// 获取所有活跃任务
  List<Task> getActiveTasks() {
    return _taskQueue.where((t) =>
      t.status == TaskStatus.pending ||
      t.status == TaskStatus.running ||
      t.status == TaskStatus.done
    ).toList();
  }

  /// 获取失败的任务（用户可手动重试）
  List<Task> getFailedTasks() {
    return _taskQueue.where((t) => t.status == TaskStatus.failed).toList();
  }

  /// 获取历史记录
  List<Task> getHistory({int limit = 50}) {
    return _completedTasks.reversed.take(limit).toList();
  }

  /// 清空所有任务（测试用，避免单例跨测试污染）
  void clearAll() {
    _taskQueue.clear();
    _completedTasks.clear();
    _pendingButlerTasks.clear();
    _completedButlerTasks.clear();
    _currentTask = null;
  }

  /// 生成唯一ID
  String _generateId(TaskType type) {
    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch;
    final random = (timestamp % 10000).toString().padLeft(4, '0');
    return '${type.name}_$timestamp$random';
  }

  /// 从管家 AI 指令列表创建任务
  List<ButlerTask> createTasks(List<dynamic> intents) {
    final tasks = <ButlerTask>[];
    for (final intent in intents) {
      final task = ButlerTask(
        id: _generateId(TaskType.other),
        description: '${intent.type}: ${intent.params.toString()}',
        type: intent.type,
        params: intent.params,
      );
      _pendingButlerTasks.add(task);
      tasks.add(task);
    }
    return tasks;
  }

  /// 执行指定任务（返回结果）
  Future<TaskResult> execute(String taskId) async {
    ButlerTask? task; // ignore: prefer_final_locals
    task = findTask(taskId) is ButlerTask ? findTask(taskId) as ButlerTask? : null;
    task ??= _findButlerTask(taskId);
    if (task == null) {
      return TaskResult(success: false, error: '任务 $taskId 不存在');
    }

    task.status = TaskStatus.running;
    task.updatedAt = DateTime.now();

    try {
      // 模拟执行
      task.status = TaskStatus.done;
      task.updatedAt = DateTime.now();
      return TaskResult(success: true);
    } catch (e) {
      task.status = TaskStatus.failed;
      task.lastError = e.toString();
      task.failCount++;
      task.updatedAt = DateTime.now();
      return TaskResult(success: false, error: e.toString());
    }
  }

  /// 获取所有待处理任务（包含 Task 和 ButlerTask）
  List getTasks() {
    return [
      ..._taskQueue.where((t) => t.status == TaskStatus.pending),
      ..._pendingButlerTasks.where((t) => t.status == TaskStatus.pending),
    ];
  }

  ButlerTask? _findButlerTask(String taskId) {
    for (final t in _pendingButlerTasks) {
      if (t.id == taskId) return t;
    }
    for (final t in _completedButlerTasks) {
      if (t.id == taskId) return t;
    }
    return null;
  }

  final List<ButlerTask> _pendingButlerTasks = [];
  final List<ButlerTask> _completedButlerTasks = [];
}

/// TaskResult
class TaskResult {
  final bool success;
  final String? error;
  final String? solution;

  TaskResult({required this.success, this.error, this.solution});
}
