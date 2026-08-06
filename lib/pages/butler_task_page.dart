import 'package:flutter/material.dart';

import '../butler/task/butler_task.dart';
import '../butler/task/task_manager.dart';

/// 管家任务页 — 待处理 / 进行中 / 已完成。
///
/// 8-07 00:49 用户：管家中心要分类好看，任务要能"创建"。
/// - 粉色系主题统一（背景 0xFFFDF7F9 / 强调 0xFFC896B4）
/// - AppBar 加"＋ 新建任务"：选类型 + 写描述 → TaskManager.createTask
/// - 任务卡片：类型图标带色底、状态徽章圆角、边框柔和
class ButlerTaskPage extends StatefulWidget {
  const ButlerTaskPage({super.key});

  @override
  State<ButlerTaskPage> createState() => _ButlerTaskPageState();
}

class _ButlerTaskPageState extends State<ButlerTaskPage> {
  final TaskManager _taskManager = TaskManager.instance;
  List<Task> _pendingTasks = [];
  List<Task> _runningTasks = [];
  List<Task> _doneTasks = [];

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

  /// 8-07 00:49 用户：手动创建任务——选类型 + 写描述
  Future<void> _showCreateTaskSheet() async {
    TaskType? selected = TaskType.other;
    final descCtrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFFDF7F9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFC896B4).withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '新建任务',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6A4A5A),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<TaskType>(
                initialValue: selected,
                decoration: InputDecoration(
                  labelText: '任务类型',
                  labelStyle: const TextStyle(color: Color(0xFFC896B4)),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
                items: [
                  for (final t in TaskType.values)
                    DropdownMenuItem(value: t, child: Text(_taskTypeLabel(t))),
                ],
                onChanged: (v) => setSheetState(() => selected = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '任务描述（管家要做什么）',
                  labelStyle: const TextStyle(color: Color(0xFFC896B4)),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC896B4),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    final desc = descCtrl.text.trim();
                    if (desc.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('写一句任务描述吧')),
                      );
                      return;
                    }
                    _taskManager.createTask(
                      type: selected ?? TaskType.other,
                      description: desc,
                    );
                    Navigator.of(ctx).pop();
                    _refresh();
                  },
                  child: const Text('创建任务',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    descCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFFDF7F9),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            '管家任务',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A4A5A),
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0xFF6A4A5A)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            // 8-07 00:49 用户：新建任务入口
            TextButton.icon(
              onPressed: _showCreateTaskSheet,
              icon: const Icon(Icons.add, size: 18, color: Color(0xFFC896B4)),
              label: const Text(
                '新建任务',
                style: TextStyle(
                  color: Color(0xFFC896B4),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          bottom: TabBar(
            indicatorColor: const Color(0xFFC896B4),
            labelColor: const Color(0xFF6A4A5A),
            unselectedLabelColor:
                const Color(0xFF6A4A5A).withValues(alpha: 0.35),
            labelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            tabs: const [
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

  Widget _buildList(List<Task> tasks, String emptyText) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.task_alt,
              size: 48,
              color: const Color(0xFFC896B4).withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              emptyText,
              style: TextStyle(
                fontSize: 14,
                color: const Color(0xFF5A4A52).withValues(alpha: 0.45),
              ),
            ),
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

  Widget _buildTaskCard(Task task) {
    final typeLabel = _taskTypeLabel(task.type);
    final typeIcon = _taskTypeIcon(task.type);
    final typeColor = _taskTypeColor(task.type);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFC896B4).withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(typeIcon, size: 17, color: typeColor),
              ),
              const SizedBox(width: 10),
              Text(
                typeLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: typeColor,
                ),
              ),
              const Spacer(),
              _StatusBadge(status: task.status),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            task.description,
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Color(0xFF5A4A52),
            ),
          ),
          if (task.retryCount > 0 && task.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              '失败 ${task.retryCount} 次: ${task.errorMessage}',
              style: TextStyle(
                fontSize: 12,
                color: const Color(0xFFE07A7A).withValues(alpha: 0.9),
              ),
            ),
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
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8A7A80),
                  ),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    _taskManager.confirmComplete(task.id);
                    _refresh();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC896B4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
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
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8A7A80),
                  ),
                  child: const Text('放弃'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    _taskManager.retryByUser(task.id);
                    _refresh();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8FB8D8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Color _taskTypeColor(TaskType type) {
    {
      switch (type) {
        case TaskType.cleanupCheck:
        case TaskType.cleanupExecute:
          return const Color(0xFF7FB8A0);
        case TaskType.processMessage:
          return const Color(0xFF8FB8D8);
        case TaskType.syncData:
          return const Color(0xFFA8A0D8);
        case TaskType.deviceControl:
          return const Color(0xFFD8A86C);
        case TaskType.characterCreate:
          return const Color(0xFFC896B4);
        case TaskType.characterDelete:
          return const Color(0xFFE07A7A);
        case TaskType.exportData:
        case TaskType.importData:
          return const Color(0xFF88B8A8);
        case TaskType.keywordCollect:
          return const Color(0xFFD8C06C);
        case TaskType.arcConfirm:
          return const Color(0xFFC8A0D8);
        case TaskType.patternMerge:
          return const Color(0xFF8FC8C0);
        case TaskType.conversationSummary:
          return const Color(0xFFB0A8D8);
        case TaskType.aiMemoryConfig:
          return const Color(0xFF7FA8C8);
        case TaskType.other:
          return const Color(0xFFA8A8B0);
      }
    }
    return const Color(0xFFA8A8B0);
  }

  IconData _taskTypeIcon(TaskType type) {
    {
      switch (type) {
        case TaskType.cleanupCheck: return Icons.cleaning_services;
        case TaskType.cleanupExecute: return Icons.cleaning_services;
        case TaskType.processMessage: return Icons.chat;
        case TaskType.syncData: return Icons.sync;
        case TaskType.deviceControl: return Icons.devices;
        case TaskType.characterCreate: return Icons.person_add;
        case TaskType.characterDelete: return Icons.person_remove;
        case TaskType.exportData: return Icons.upload;
        case TaskType.importData: return Icons.download;
        case TaskType.keywordCollect: return Icons.tag;
        case TaskType.arcConfirm: return Icons.show_chart;
        case TaskType.patternMerge: return Icons.merge;
        case TaskType.conversationSummary: return Icons.summarize;
        case TaskType.aiMemoryConfig: return Icons.memory;
        case TaskType.other: return Icons.task;
      }
    }
    return Icons.task;
  }

  String _taskTypeLabel(TaskType type) {
    {
      switch (type) {
        case TaskType.cleanupCheck: return '清理检查';
        case TaskType.cleanupExecute: return '执行清理';
        case TaskType.processMessage: return '处理消息';
        case TaskType.syncData: return '同步数据';
        case TaskType.deviceControl: return '设备控制';
        case TaskType.characterCreate: return '创建角色';
        case TaskType.characterDelete: return '删除角色';
        case TaskType.exportData: return '导出数据';
        case TaskType.importData: return '导入数据';
        case TaskType.keywordCollect: return '关键词收集';
        case TaskType.arcConfirm: return '弧线确认';
        case TaskType.patternMerge: return '规律合并';
        case TaskType.conversationSummary: return '对话总结';
        case TaskType.aiMemoryConfig: return 'AI记忆配置';
        case TaskType.other: return '其他';
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
      color = const Color(0xFFE8A050); label = '待确认';
    } else if (status == TaskStatus.running) {
      color = const Color(0xFF6FA8D8); label = '执行中';
    } else if (status == TaskStatus.done) {
      color = const Color(0xFF8FB88F); label = '待确认完成';
    } else if (status == TaskStatus.failed) {
      color = const Color(0xFFE07A7A); label = '失败';
    } else if (status == TaskStatus.confirmed) {
      color = const Color(0xFF8FB88F); label = '已完成';
    } else {
      color = const Color(0xFFA8A8B0); label = '已取消';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
