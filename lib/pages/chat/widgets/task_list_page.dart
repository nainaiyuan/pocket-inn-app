import 'package:flutter/material.dart';
import '../../../services/card_task_store.dart';
import '../../../services/global_timer_card_service.dart';

/// 📋 任务列表页（8-06 13:45 用户：卡片"放任务的地方"）
///
/// 所有计时/互动卡片任务都在这里：发起者/分类/状态（进行中/已完成/已撤销/已到期）/
/// 倒计时/结果。和悬浮卡片共享同一数据源 → 双向同步：
/// - 卡片上点完成/选项 → 列表实时更新
/// - 列表里点完成/删除 → 若对应卡片还在显示，同步结束
class TaskListPage extends StatefulWidget {
  const TaskListPage({super.key});

  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage> {
  List<CardTask> _tasks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    _tasks = await CardTaskStore.instance.load();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        elevation: 0,
        title: const Text(
          '📋 任务列表',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF6A4A52)),
        ),
        actions: [
          IconButton(
            tooltip: '清理已完成的',
            icon: const Icon(Icons.cleaning_services_outlined,
                color: Color(0xFF8A7A80), size: 20),
            onPressed: () async {
              await CardTaskStore.instance.removeDone();
              _reload();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF8A7A80), size: 20),
            onPressed: _reload,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tasks.isEmpty
              ? const _EmptyView()
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: _tasks.length,
                    itemBuilder: (_, i) => _TaskTile(
                      task: _tasks[i],
                      onChanged: _reload,
                    ),
                  ),
                ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🗂️', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 12),
          const Text(
            '还没有任务',
            style: TextStyle(fontSize: 15, color: Color(0xFF8A7A80)),
          ),
          const SizedBox(height: 6),
          const Text(
            '男主给你设计时卡片 / 互动卡片时\n会自动出现在这里',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFFB0A0A6), height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  final CardTask task;
  final VoidCallback onChanged;
  const _TaskTile({required this.task, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(task);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶行：发起者·分类 + 状态徽标
          Row(
            children: [
              Expanded(
                child: Text(
                  '${task.initiator}${task.category.isEmpty ? '' : ' · ${task.category}'}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A52),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _statusText(task),
                  style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 卡面内容
          Text(
            task.title,
            style: const TextStyle(fontSize: 14, height: 1.4, color: Color(0xFF3A2E33)),
          ),
          // 结果 / 申请理由
          if (task.result != null && task.result!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '结果：${task.result}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A6A96)),
            ),
          ],
          if (task.requestReason != null && task.requestReason!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFF7EAF1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '💬 申请调整：${task.requestReason}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6A4A52)),
              ),
            ),
          ],
          // 操作行：完成 / 删除（仅 active 显示完成）
          if (task.isActive) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                _ListBtn(
                  icon: Icons.check_circle_outline,
                  label: '标记完成',
                  color: const Color(0xFF7FA88A),
                  onTap: () async {
                    await CardTaskStore.instance.update(task.id, (t) {
                      t.status = 'done';
                      t.result = t.result ?? '她在任务列表里标记为已完成';
                    });
                    // 若卡片还在显示 → 同步结束（双向同步）
                    if (GlobalTimerCardService.instance.isActive &&
                        GlobalTimerCardService.instance.taskId == task.id) {
                      GlobalTimerCardService.instance.finish();
                    }
                    onChanged();
                  },
                ),
                const SizedBox(width: 8),
                _ListBtn(
                  icon: Icons.delete_outline,
                  label: '删除',
                  color: const Color(0xFFD98A9E),
                  onTap: () async {
                    if (GlobalTimerCardService.instance.isActive &&
                        GlobalTimerCardService.instance.taskId == task.id) {
                      GlobalTimerCardService.instance.finish();
                    }
                    await CardTaskStore.instance.remove(task.id);
                    onChanged();
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _statusText(CardTask t) {
    if (t.isCancelled) return '已撤销';
    if (t.isDone) return '已完成';
    if (t.isExpired) return '已到期';
    if (t.endAt == null) return '进行中';
    final s = t.remainingSeconds;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '还剩 $m:$ss';
  }

  Color _statusColor(CardTask t) {
    if (t.isCancelled) return const Color(0xFF9A8A90);
    if (t.isDone) return const Color(0xFF7FA88A);
    if (t.isExpired) return const Color(0xFFD98A9E);
    return const Color(0xFFC896B4);
  }
}

class _ListBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ListBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}
