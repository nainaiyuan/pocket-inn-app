/// 管家任务模型

class ButlerTask {
  /// 任务 ID（简短好记，如 "1", "2"）
  final String id;

  /// 任务类型（对应 ButlerIntent.type）
  final String type;

  /// 任务的文字描述（给用户看的）
  final String description;

  /// 指令参数（执行时用）
  final Map<String, dynamic> params;

  /// 当前状态
  TaskStatus status;

  /// 创建时间
  final DateTime createdAt;

  /// 最后更新时间
  DateTime updatedAt;

  /// 失败次数（超过上限标记为失败）
  int failCount;

  /// 失败时的错误信息
  String? lastError;

  ButlerTask({
    required this.id,
    required this.type,
    required this.description,
    this.params = const {},
    this.status = TaskStatus.pending,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.failCount = 0,
    this.lastError,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// 简短的摘要（用于列表显示）
  String get summary => '#$id $description';

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'description': description,
    'params': params,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'failCount': failCount,
    'lastError': lastError,
  };

  factory ButlerTask.fromJson(Map<String, dynamic> json) => ButlerTask(
    id: json['id'] as String,
    type: json['type'] as String,
    description: json['description'] as String,
    params: json['params'] as Map<String, dynamic>? ?? {},
    status: TaskStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => TaskStatus.pending,
    ),
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    failCount: json['failCount'] as int? ?? 0,
    lastError: json['lastError'] as String?,
  );
}

/// 任务状态
enum TaskStatus {
  /// 等待执行
  pending,

  /// 正在执行
  running,

  /// 执行成功，等待用户确认
  done,

  /// 执行失败
  failed,

  /// 用户已确认完成
  confirmed,

  /// 已取消/关闭
  cancelled,
}

/// 任务执行结果
class TaskResult {
  final bool success;
  final String? error;
  final String? solution;   // AI 给的解决方案（失败时）

  TaskResult({
    required this.success,
    this.error,
    this.solution,
  });
}
