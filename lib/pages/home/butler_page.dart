import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ai_provider/ai_provider_manager.dart';
import '../../butler/modules/butler_module_hub.dart';
import '../../butler/memory/emotion_arc.dart';
import '../../butler/patterns/pattern_engine.dart';
import '../../butler/storage/storage_registry.dart';
import '../../butler/task/butler_task.dart';
import '../../butler/task/task_manager.dart';
import '../ai_config_page.dart';
import '../butler_modules_page.dart';
import '../butler_task_page.dart';
import '../debug/debug_toolbox_page.dart';
import '../mood_analysis_page.dart';
import '../pattern_memory_page.dart';
import 'widgets/star_map_view.dart';

/// 管家中心 — 手机式底部导航版（8-07 00:58 用户）。
///
/// 用户原话："管家模块可以做成像手机一样，底部有按钮切换不同的，
/// 多点图、可视化；规律和记忆做成圆/圈/星球那种，好看。"
///
/// 4 个 Tab：
///   💗 情绪    — 情绪环图（最新情绪分布四色圆环 + 中心主导情绪）
///   🌌 规律·记忆 — 星球图（星空 + 中心"我"星球 + 轨道规律星球 + 记忆星星）
///   📋 任务    — 任务速览（待处理/进行中/失败 + 新建任务）
///   ⚙️ 更多    — AI 配置 / 管家模块 / 情感基线 / 调试工具箱
class ButlerPage extends StatefulWidget {
  const ButlerPage({super.key});

  @override
  State<ButlerPage> createState() => _ButlerPageState();
}

class _ButlerPageState extends State<ButlerPage> {
  int _tab = 1; // 默认打开星球图（最惊艳）
  List<EmotionArc> _arcs = [];
  int _memoryCount = 0;

  @override
  void initState() {
    super.initState();
    _loadMood();
    _loadMemoryCount();
  }

  Future<void> _loadMood() async {
    final arcs = await StorageRegistry.instance.emotionArcs.loadAll();
    if (!mounted) return;
    setState(() => _arcs = arcs);
  }

  Future<void> _loadMemoryCount() async {
    try {
      final manager = ButlerModuleHub.instance.sharedMemoryManager;
      if (manager != null) {
        await manager.loadFromStore();
        if (!mounted) return;
        setState(() => _memoryCount = manager.getAll().length);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFFFDF7F9),
      child: SafeArea(
        child: Column(
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
              child: Row(
                children: [
                  const Text(
                    '管家中心',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2,
                      color: Color(0xFF6A4A5A),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _tabNames[_tab],
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 1,
                      color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
            // 内容区（IndexedStack 保持各 Tab 状态）
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _MoodTab(arcs: _arcs),
                  _UniverseTab(
                    memoryCount: _memoryCount,
                    onMemoryCountChanged: () => _loadMemoryCount(),
                  ),
                  _TasksTab(),
                  const _MoreTab(),
                ],
              ),
            ),
            // 底部导航（手机式）
            _BottomNav(
              current: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ],
        ),
      ),
    );
  }

  static const _tabNames = ['情绪', '规律·记忆', '任务', '更多'];
}

// =====================================================================
// 💗 情绪 Tab：四色情绪环图
// =====================================================================
class _MoodTab extends StatelessWidget {
  const _MoodTab({required this.arcs});

  final List<EmotionArc> arcs;

  static const _dims = [
    ('喜悦', Color(0xFFE896B8)),
    ('依恋', Color(0xFFB896E8)),
    ('悲伤', Color(0xFF96B8E8)),
    ('愤怒', Color(0xFFE8A078)),
  ];

  @override
  Widget build(BuildContext context) {
    final latest = arcs.isEmpty ? null : arcs.last;
    final mood = latest?.endMood ?? const <String, double>{};

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        // 情绪环
        Container(
          height: 260,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFDF0F5), Color(0xFFF7EAF2)],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: const Color(0xFFC896B4).withValues(alpha: 0.2),
            ),
          ),
          child: latest == null
              ? Center(
                  child: Text(
                    '还没有情绪记录\n聊起来之后这里会亮起四色光环',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: const Color(0xFF5A4A52).withValues(alpha: 0.45),
                    ),
                  ),
                )
              : CustomPaint(
                  size: const Size(double.infinity, 260),
                  painter: _MoodRingPainter(mood: mood),
                ),
        ),
        const SizedBox(height: 14),
        // 四维说明卡
        Row(
          children: [
            for (final (name, color) in _dims)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF5A4A52),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${(mood[name] ?? 0).round()}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        // 统计
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFFC896B4).withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome,
                  size: 18, color: Color(0xFFC896B4)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '共 ${arcs.length} 次情绪弧线'
                  '${latest == null ? '' : ' · 最近 ${_ago(latest.time)}'}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF5A4A52),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const MoodAnalysisPage(),
                  ),
                ),
                child: const Text(
                  '详细分析',
                  style: TextStyle(
                    color: Color(0xFFC896B4),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}

/// 四色情绪环：每维 90°，半径 = 情绪强度
class _MoodRingPainter extends CustomPainter {
  _MoodRingPainter({required this.mood});

  final Map<String, double> mood;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 10);
    final baseR = math.min(size.width, size.height) * 0.16;

    // 灰底环
    final bgRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = const Color(0xFFC896B4).withValues(alpha: 0.1);
    canvas.drawCircle(center, baseR + 45, bgRing);

    // 四段弧（0° 起顺时针：喜悦/依恋/悲伤/愤怒）
    const dims = _MoodTab._dims;
    for (var i = 0; i < dims.length; i++) {
      final (name, color) = dims[i];
      final value = (mood[name] ?? 0).clamp(0.0, 100.0);
      final r = baseR + (value / 100) * 45;
      final start = i * math.pi / 2 - math.pi / 2;
      final sweep = math.pi / 2 - 0.12; // 留缝

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        start + 0.06,
        sweep,
        false,
        paint,
      );
    }

    // 中心：主导情绪
    final dominant = dims.reduce((a, b) {
      final va = mood[a.$1] ?? 0;
      final vb = mood[b.$1] ?? 0;
      return va >= vb ? a : b;
    });
    final dv = (mood[dominant.$1] ?? 0).round();

    final tp1 = TextPainter(
      text: TextSpan(
        text: dominant.$1,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: dominant.$2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp1.paint(canvas, center - Offset(tp1.width / 2, tp1.height));

    final tp2 = TextPainter(
      text: TextSpan(
        text: '$dv',
        style: const TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          color: Color(0xFF6A4A5A),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(
      canvas,
      center - Offset(tp2.width / 2, -2),
    );

    final tp3 = TextPainter(
      text: TextSpan(
        text: '当前情绪',
        style: TextStyle(
          fontSize: 11,
          color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp3.paint(
      canvas,
      center + Offset(-tp3.width / 2, 32),
    );
  }

  @override
  bool shouldRepaint(covariant _MoodRingPainter oldDelegate) =>
      oldDelegate.mood != mood;
}

// =====================================================================
// 🌌 规律·记忆 Tab：星球图
// =====================================================================
class _UniverseTab extends StatefulWidget {
  const _UniverseTab({
    required this.memoryCount,
    this.onMemoryCountChanged,
  });

  final int memoryCount;
  final VoidCallback? onMemoryCountChanged;

  @override
  State<_UniverseTab> createState() => _UniverseTabState();
}

class _UniverseTabState extends State<_UniverseTab> {
  List<PatternStats> get _patterns {
    final engine = ButlerModuleHub.instance.sharedPatternEngine;
    return engine?.confirmedPatterns ?? [];
  }

  void _showPatternDetail(PatternStats p) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2A1B3D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: StarMapView.patternColor(p).withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.public,
                    color: StarMapView.patternColor(p),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    p.keywords.join(' · '),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${StarMapView.patternMood(p)}方向 · 出现 ${p.count} 次 · '
              '置信度 ${(p.confidence * 100).round()}%',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 18),
            // 情绪偏移条
            for (final (name, color, value) in [
              ('喜悦', const Color(0xFFE896B8), p.shiftJoy),
              ('依恋', const Color(0xFFB896E8), p.shiftAttachment),
              ('悲伤', const Color(0xFF96B8E8), p.shiftSad),
              ('愤怒', const Color(0xFFE8A078), p.shiftAnger),
            ]) ...[
              Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (value.abs() / 100).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor:
                            Colors.white.withValues(alpha: 0.08),
                        valueColor: AlwaysStoppedAnimation(
                          value >= 0 ? color : color.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 36,
                    child: Text(
                      value >= 0 ? '+${value.round()}' : '${value.round()}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 10),
            Text(
              '聊到这些词时你的情绪会 ${StarMapView.patternMood(p)}（相对平时偏移）',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final patterns = _patterns;
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: StarMapView(
                patterns: patterns,
                memoryCount: widget.memoryCount,
                onPatternTap: _showPatternDetail,
              ),
            ),
          ),
        ),
        // 底部统计条
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: _StatChip(
                  icon: Icons.public,
                  color: const Color(0xFFB896E8),
                  label: '规律 ${patterns.length} 条',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatChip(
                  icon: Icons.star_outline,
                  color: const Color(0xFFE8D8A0),
                  label: '记忆 ${widget.memoryCount} 条',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatChip(
                  icon: Icons.settings_outlined,
                  color: const Color(0xFFA8D0A8),
                  label: '管理',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PatternMemoryPage(hub: ButlerModuleHub.instance),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.color,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF5A4A52),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 📋 任务 Tab：速览 + 新建
// =====================================================================
class _TasksTab extends StatefulWidget {
  const _TasksTab();

  @override
  State<_TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<_TasksTab> {
  final TaskManager _taskManager = TaskManager.instance;
  List<Task> _pending = [];
  List<Task> _running = [];
  List<Task> _done = [];

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
      _pending = all.where((t) => t.status == TaskStatus.pending).toList();
      _running = [
        ...all.where((t) => t.status == TaskStatus.running),
        ...failed,
      ];
      _done = history
          .where((t) =>
              t.status == TaskStatus.confirmed ||
              t.status == TaskStatus.cancelled)
          .take(3)
          .toList();
    });
  }

  Future<void> _showCreateSheet() async {
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
                    DropdownMenuItem(value: t, child: Text(_typeLabel(t))),
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
                  child: const Text(
                    '创建任务',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    descCtrl.dispose();
  }

  String _typeLabel(TaskType t) {
    switch (t) {
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

  @override
  Widget build(BuildContext context) {
    final tasks = [..._pending, ..._running, ..._done];
    return Column(
      children: [
        // 顶部：新建 + 查看全部
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC896B4),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text(
                    '新建任务',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  onPressed: _showCreateSheet,
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF8A7A80),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  side: BorderSide(
                    color: const Color(0xFFC896B4).withValues(alpha: 0.4),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.launch, size: 16),
                label: const Text('全部任务'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ButlerTaskPage()),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? Center(
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
                        '还没有任务\n点"新建任务"给管家派活',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  itemCount: tasks.length,
                  itemBuilder: (context, i) => _TaskCard(
                    task: tasks[i],
                    onChanged: _refresh,
                  ),
                ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.onChanged});

  final Task task;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final color = _color(task.type);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
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
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(_icon(task.type), size: 16, color: color),
              ),
              const SizedBox(width: 10),
              Text(
                _label(task.type),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const Spacer(),
              _Badge(status: task.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            task.description,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Color(0xFF5A4A52),
            ),
          ),
          if (task.retryCount > 0 && task.errorMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              '失败 ${task.retryCount} 次: ${task.errorMessage}',
              style: TextStyle(
                fontSize: 11,
                color: const Color(0xFFE07A7A).withValues(alpha: 0.9),
              ),
            ),
          ],
          if (task.status == TaskStatus.pending) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    TaskManager.instance.cancel(task.id);
                    onChanged();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8A7A80),
                  ),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: () {
                    TaskManager.instance.confirmComplete(task.id);
                    onChanged();
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
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    TaskManager.instance.cancel(task.id);
                    onChanged();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8A7A80),
                  ),
                  child: const Text('放弃'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: () {
                    TaskManager.instance.retryByUser(task.id);
                    onChanged();
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

  Color _color(TaskType type) {
    switch (type) {
      case TaskType.cleanupCheck:
      case TaskType.cleanupExecute: return const Color(0xFF7FB8A0);
      case TaskType.processMessage: return const Color(0xFF8FB8D8);
      case TaskType.syncData: return const Color(0xFFA8A0D8);
      case TaskType.deviceControl: return const Color(0xFFD8A86C);
      case TaskType.characterCreate: return const Color(0xFFC896B4);
      case TaskType.characterDelete: return const Color(0xFFE07A7A);
      case TaskType.exportData:
      case TaskType.importData: return const Color(0xFF88B8A8);
      case TaskType.keywordCollect: return const Color(0xFFD8C06C);
      case TaskType.arcConfirm: return const Color(0xFFC8A0D8);
      case TaskType.patternMerge: return const Color(0xFF8FC8C0);
      case TaskType.conversationSummary: return const Color(0xFFB0A8D8);
      case TaskType.aiMemoryConfig: return const Color(0xFF7FA8C8);
      case TaskType.other: return const Color(0xFFA8A8B0);
    }
  }

  IconData _icon(TaskType type) {
    switch (type) {
      case TaskType.cleanupCheck:
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

  String _label(TaskType type) {
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
}

class _Badge extends StatelessWidget {
  const _Badge({required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    switch (status) {
      case TaskStatus.pending:
        color = const Color(0xFFE8A050); label = '待确认';
      case TaskStatus.running:
        color = const Color(0xFF6FA8D8); label = '执行中';
      case TaskStatus.done:
        color = const Color(0xFF8FB88F); label = '待确认完成';
      case TaskStatus.failed:
        color = const Color(0xFFE07A7A); label = '失败';
      case TaskStatus.confirmed:
        color = const Color(0xFF8FB88F); label = '已完成';
      case TaskStatus.cancelled:
      case TaskStatus.timeout:
        color = const Color(0xFFA8A8B0); label = '已取消';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// =====================================================================
// ⚙️ 更多 Tab：入口列表
// =====================================================================
class _MoreTab extends StatelessWidget {
  const _MoreTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        _EntryCard(
          icon: Icons.hub_outlined,
          iconColor: const Color(0xFFA8D0A8),
          title: 'AI 配置',
          subtitleBuilder: (context) => ValueListenableBuilder<int>(
            valueListenable: AIProviderManager.instance.changeNotifier,
            builder: (context, _, __) {
              final manager = AIProviderManager.instance;
              final usable = manager.usableProviderNames(null);
              if (usable.isEmpty) {
                return const Text(
                  '⚠️ 还没有可用的 AI，点这里配置',
                  style: TextStyle(color: Color(0xFFE07A7A), fontSize: 12),
                );
              }
              return Text(
                '可用：${usable.join('、')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
                ),
              );
            },
          ),
          onTap: (context) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AiConfigPage()),
          ),
        ),
        const SizedBox(height: 10),
        _EntryCard(
          icon: Icons.widgets_outlined,
          iconColor: const Color(0xFFC896B4),
          title: '管家模块',
          subtitleBuilder: (context) {
            final hub = ButlerModuleHub.instance;
            final modules = hub.registry.all;
            final activeCount = modules.where((m) => m.isActive).length;
            return Text(
              '$activeCount/${modules.length} 个模块运行中：'
              '${modules.map((m) => m.name).join('、')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
              ),
            );
          },
          onTap: (context) => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ButlerModulesPage(hub: ButlerModuleHub.instance),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _EntryCard(
          icon: Icons.auto_awesome_outlined,
          iconColor: const Color(0xFFC896B4),
          title: '情感基线（完整版）',
          subtitle: '情绪弧线时间线、趋势图、筛选',
          onTap: (context) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MoodAnalysisPage()),
          ),
        ),
        const SizedBox(height: 10),
        _EntryCard(
          icon: Icons.build_circle_outlined,
          iconColor: const Color(0xFFD8A8C8),
          title: '调试工具箱',
          subtitle: '日志、API 记录、一键自检、AI 能力检测',
          onTap: (context) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DebugToolboxPage()),
          ),
        ),
      ],
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.subtitleBuilder,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget Function(BuildContext)? subtitleBuilder;
  final void Function(BuildContext)? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap == null ? null : () => onTap!(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: iconColor.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: iconColor.withValues(alpha: 0.15)),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF5A4A52),
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (subtitleBuilder != null)
                      subtitleBuilder!(context)
                    else if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.45),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 底部导航（手机式）
// =====================================================================
class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.current, required this.onChanged});

  final int current;
  final ValueChanged<int> onChanged;

  static const _items = [
    (Icons.favorite_outline, Icons.favorite, '情绪'),
    (Icons.public_outlined, Icons.public, '规律·记忆'),
    (Icons.task_alt_outlined, Icons.task_alt, '任务'),
    (Icons.more_horiz_outlined, Icons.more_horiz, '更多'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFC896B4).withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 22,
                color: const Color(0xFFC896B4).withValues(alpha: 0.12),
              ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => onChanged(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        i == current ? _items[i].$2 : _items[i].$1,
                        size: 20,
                        color: i == current
                            ? const Color(0xFFC896B4)
                            : const Color(0xFF8A7A80).withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _items[i].$3,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: i == current
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: i == current
                              ? const Color(0xFFC896B4)
                              : const Color(0xFF8A7A80).withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
