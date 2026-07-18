import 'package:flutter/material.dart';

import '../butler/task/task_manager.dart' as bt;
import '../butler/task/butler_task.dart';

/// 管家任务列表页面
class ButlerTaskPage extends StatefulWidget {
  const ButlerTaskPage({super.key});

  @override
  State<ButlerTaskPage> createState() => _ButlerTaskPageState();
}

class _ButlerTaskPageState extends State<ButlerTaskPage> {
  final TaskManager _taskManager = TaskManager.instance;
  List<dynamic> _pendingTasks = [];
  List<dynamic> _runningTasks = [];
  List<dynamic> _doneTasks = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final all = _taskManager.getActiveTasks();
    final history = _taskManager.getHistory();
    final failed = _taskManager.getFailedTasks();
    setState(() {
      _pendingTasks = all.where((t) => t.status == TaskStatus.pending).toList();
      _runningTasks = [
        ...all.where((t) => t.status == TaskStatus.running),
        ...failed,
      ];
      _doneTasks = history
          .where((t) =>
              t.status == TaskStatus.confirmed ||
              t.status == TaskStatus.cancelled)
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('管家任务'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '待处理'),
              Tab(text: '进行中'),
              Tab(text: '已完成'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildList(_pendingTasks, '没有待处理的任务'),
            _buildList(_runningTasks, '没有进行中的任务'),
            _buildList(_doneTasks, '还没有完成的任务'),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<dynamic> tasks, String emptyText) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt, size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(emptyText,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: tasks.length,
      itemBuilder: (context, index) => _buildTaskCard(tasks[index]),
    );
  }

  Widget _buildTaskCard(task) {
    final theme = Theme.of(context);
    final typeLabel = _taskTypeLabel(task.type);
    final typeIcon = _taskTypeIcon(task.type);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(typeIcon, size: 20,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(typeLabel,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary)),
                const Spacer(),
                _StatusBadge(status: task.status),
              ],
            ),
            const SizedBox(height: 8),
            Text(task.description, style: theme.textTheme.bodyMedium),
            if (task.retryCount > 0 && task.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text('失败 ${task.retryCount} 次: ${task.errorMessage}',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.red)),
            ],
            if (task.status == TaskStatus.pending) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      _taskManager.cancel(task.id);
                      _refresh();
                    },
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      _taskManager.confirmComplete(task.id);
                      _refresh();
                    },
                    child: const Text('确认执行'),
                  ),
                ],
              ),
            ],
            if (task.status == TaskStatus.failed) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      _taskManager.cancel(task.id);
                      _refresh();
                    },
                    child: const Text('放弃'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      _taskManager.retryByUser(task.id);
                      _refresh();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _taskTypeIcon(type) {
    if (type is String) {
      switch (type) {
        case 'save_note': return Icons.note_add;
        case 'set_config': return Icons.settings;
        case 'lock_vault': return Icons.lock;
        case 'call_character': return Icons.chat;
        case 'query_memory': return Icons.search;
        case 'set_trigger': return Icons.notifications_active;
        case 'analyze_image': return Icons.image;
      }
    }
    return Icons.task;
  }

  String _taskTypeLabel(type) {
    if (type is TaskType) {
      switch (type) {
        case bt.TaskType.cleanupCheck: return '清理检查';
        case bt.TaskType.cleanupExecute: return '执行清理';
        case bt.TaskType.processMessage: return '处理消息';
        case bt.TaskType.syncData: return '同步数据';
        case bt.TaskType.deviceControl: return '设备控制';
        case bt.TaskType.characterCreate: return '创建角色';
        case bt.TaskType.characterDelete: return '删除角色';
        case bt.TaskType.exportData: return '导出数据';
        case bt.TaskType.importData: return '导入数据';
        case bt.TaskType.other: return '其他';
      }
    }
    if (type is String) {
      switch (type) {
        case 'save_note': return '记笔记';
        case 'set_config': return '修改设置';
        case 'lock_vault': return '锁定保险箱';
        case 'call_character': return '联系角色';
        case 'query_memory': return '查询记忆';
        case 'set_trigger': return '设置触发器';
        case 'analyze_image': return '分析图片';
      }
    }
    return '任务';
  }
}

class _StatusBadge extends StatelessWidget {
  final status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;

    if (status == TaskStatus.pending) {
      color = Colors.orange; label = '待确认';
    } else if (status == TaskStatus.running) {
      color = Colors.blue; label = '执行中';
    } else if (status == TaskStatus.done) {
      color = Colors.green; label = '待确认完成';
    } else if (status == TaskStatus.failed) {
      color = Colors.red; label = '失败';
    } else if (status == TaskStatus.confirmed) {
      color = Colors.green; label = '已完成';
    } else {
      color = Colors.grey; label = '已取消';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
    );
  }
}
