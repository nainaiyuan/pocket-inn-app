import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ai_provider/ai_provider_manager.dart';
import '../../butler/modules/butler_module_hub.dart';
import '../../butler/memory/emotion_arc.dart';
import '../../butler/memory/relation_migration.dart';
import '../../butler/memory/relation_record.dart';
import '../../butler/patterns/pattern_engine.dart';
import '../../butler/storage/storage_registry.dart';
import '../../services/relation_change_notifier.dart';
import '../../butler/task/butler_task.dart';
import '../../butler/task/task_manager.dart';
import '../ai_config_page.dart';
import '../butler_modules_page.dart';
import '../butler/pet_setup_page.dart';
import '../butler_task_page.dart';
import '../debug/debug_toolbox_page.dart';
import '../mood_analysis_page.dart';
import '../pattern_memory_page.dart';
import 'widgets/relation_map_view.dart';
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
  int _tab = 1; // 默认打开关系图（最惊艳）
  List<RelationRecord> _relationRecords = [];
  int _memoryCount = 0;

  @override
  void initState() {
    super.initState();
    _loadMemoryCount();
    // 男主记了新关系 → 刷新关系图
    RelationChangeNotifier.instance.addListener(refreshRelations);
  }

  @override
  void dispose() {
    RelationChangeNotifier.instance.removeListener(refreshRelations);
    super.dispose();
  }

  /// 关系图数据刷新（男主记了新关系后调用）
  Future<void> refreshRelations() async {
    try {
      // 旧记忆一次性迁入关系网（幂等，失败静默，不影响使用）
      await RelationMigration.migrateLegacyMemories();
      final records = await StorageRegistry.instance.relations.loadAll();
      if (!mounted) return;
      setState(() => _relationRecords = records);
    } catch (_) {}
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
                  _MoodTab(records: _relationRecords),
                  _UniverseTab(
                    records: _relationRecords,
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
  const _MoodTab({required this.records});

  /// 关系记录（情绪类记录 → 动态情绪词环）
  /// 8-07 01:28 用户：没情绪就不显示内置环，提示再聊聊
  final List<RelationRecord> records;

  /// 情绪词色板（动态环循环取色）
  static const _wordColors = [
    Color(0xFFE896B8), // 粉
    Color(0xFFB896E8), // 紫
    Color(0xFF96B8E8), // 蓝
    Color(0xFFE8A078), // 橙
    Color(0xFF8FC8A0), // 绿
    Color(0xFFE8D8A0), // 黄
    Color(0xFF96C8C8), // 青
    Color(0xFFC8A0E8), // 紫红
  ];

  /// 从情绪记录提取情绪词 → 按出现次数聚合
  /// 男主记"她→感到→焦虑"：object=焦虑 就是情绪词
  List<({String label, double value, Color color})> get _emotionWords {
    final counts = <String, int>{};
    for (final r in records) {
      if (r.category != '情绪') continue;
      final word = r.object.trim();
      if (word.isEmpty || word.length > 6) continue;
      counts[word] = (counts[word] ?? 0) + 1;
    }
    if (counts.isEmpty) return const [];
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final max = sorted.first.value.toDouble();
    final list = sorted.take(8).toList();
    return [
      for (var i = 0; i < list.length; i++)
        (
          label: list[i].key,
          // 词频归一化：出现最多 = 100，最少也有 25（保证看得见）
          value: 25 + (list[i].value / max) * 75,
          color: _wordColors[i % _wordColors.length],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final words = _emotionWords;
    final hasWords = words.isNotEmpty;
    final ringDims = words;

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
          child: hasWords
              ? CustomPaint(
                  size: const Size(double.infinity, 260),
                  painter: _MoodRingPainter(dims: ringDims),
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.chat_bubble_outline,
                        size: 34,
                        color: Color(0xFFC896B4),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '还没有情绪记录\n去跟男主聊聊吧，聊到你的情绪变化\n他会帮你记下来，这里就会亮起来',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.7,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 14),
        // 维度说明卡（动态词 / 四色）
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final d in ringDims)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: d.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      d.label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF5A4A52),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${d.value.round()}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: d.color,
                      ),
                    ),
                  ],
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
                  hasWords
                      ? '情绪词 ${words.length} 种 · 来自关系记录'
                      : '还没有情绪记录',
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

/// 情绪环：每维一段弧，半径 = 强度（动态情绪词 / 四色兜底共用）
class _MoodRingPainter extends CustomPainter {
  _MoodRingPainter({required this.dims});

  /// (标签, 强度0-100, 颜色)
  final List<({String label, double value, Color color})> dims;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 10);
    final baseR = math.min(size.width, size.height) * 0.16;
    final n = dims.length;
    if (n == 0) return;

    // 灰底环
    final bgRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = const Color(0xFFC896B4).withValues(alpha: 0.1);
    canvas.drawCircle(center, baseR + 45, bgRing);

    // 每维一段弧（均分 360°）
    final arc = 2 * math.pi / n;
    for (var i = 0; i < n; i++) {
      final d = dims[i];
      final value = d.value.clamp(0.0, 100.0);
      final r = baseR + (value / 100) * 45;
      final start = i * arc - math.pi / 2;
      final sweep = arc - 0.12; // 留缝

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round
        ..color = d.color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        start + 0.06,
        sweep,
        false,
        paint,
      );
    }

    // 中心：主导（强度最高）
    final dominant = dims.reduce((a, b) => a.value >= b.value ? a : b);

    final tp1 = TextPainter(
      text: TextSpan(
        text: dominant.label,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: dominant.color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp1.paint(canvas, center - Offset(tp1.width / 2, tp1.height));

    final tp2 = TextPainter(
      text: TextSpan(
        text: '${dominant.value.round()}',
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
        text: n > 4 ? '最近情绪词' : '当前情绪',
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
  bool shouldRepaint(covariant _MoodRingPainter oldDelegate) {
    if (oldDelegate.dims.length != dims.length) return true;
    for (var i = 0; i < dims.length; i++) {
      if (oldDelegate.dims[i].label != dims[i].label ||
          oldDelegate.dims[i].value != dims[i].value) {
        return true;
      }
    }
    return false;
  }
}

// =====================================================================
// 🌌 关系图 Tab：你是中心，周围是相关的人事物（8-07 01:13 用户）
// =====================================================================
class _UniverseTab extends StatefulWidget {
  const _UniverseTab({
    required this.records,
    required this.memoryCount,
    this.onMemoryCountChanged,
  });

  /// 全部关系记录（谁→谁→什么+原话+时间+归属）
  final List<RelationRecord> records;
  final int memoryCount;
  final VoidCallback? onMemoryCountChanged;

  @override
  State<_UniverseTab> createState() => _UniverseTabState();
}

class _UniverseTabState extends State<_UniverseTab> {
  /// 当前中心实体（默认"用户"——你是这张网的中心）
  String _center = '用户';

  /// 归属筛选：null=全部 / '共同' / '专属'（某个男主）
  String? _ownerFilter;

  List<RelationRecord> get _filtered {
    final list = widget.records;
    if (_ownerFilter == null) return list;
    if (_ownerFilter == '共同') {
      return list.where((r) => r.characterId == null || r.characterId!.isEmpty).toList();
    }
    return list.where((r) => r.characterId != null && r.characterId!.isNotEmpty).toList();
  }

  /// 实体详情弹窗：记录汇总 + 可继续进入下一层
  void _showEntityDetail(String entity, List<RelationRecord> records) {
    final themeRecords = records;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFDF7F9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部：实体名 + 进入按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFC896B4).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.public,
                      color: Color(0xFFC896B4),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entity,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF6A4A5A),
                          ),
                        ),
                        Text(
                          '${themeRecords.length} 条记录',
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (entity != _center)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFC896B4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.zoom_in, size: 16),
                      label: const Text('进入'),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        setState(() => _center = entity);
                      },
                    ),
                ],
              ),
            ),
            const Divider(color: Color(0xFFC896B4)),
            // 记录列表
            Expanded(
              child: themeRecords.isEmpty
                  ? Center(
                      child: Text(
                        '还没有记录',
                        style: TextStyle(
                          fontSize: 13,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      itemCount: themeRecords.length,
                      itemBuilder: (context, i) {
                        final r = themeRecords[i];
                        return _RelationCard(record: r);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Column(
      children: [
        // 归属筛选
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Row(
            children: [
              _FilterChip(
                label: '全部',
                selected: _ownerFilter == null,
                onTap: () => setState(() => _ownerFilter = null),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: '共同',
                selected: _ownerFilter == '共同',
                onTap: () => setState(() => _ownerFilter = '共同'),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: '男主专属',
                selected: _ownerFilter == '专属',
                onTap: () => setState(() => _ownerFilter = '专属'),
              ),
              const Spacer(),
              Text(
                '${filtered.length} 条关系',
                style: TextStyle(
                  fontSize: 11,
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: RelationMapView(
                records: filtered,
                centerEntity: _center,
                onEntityTap: _showEntityDetail,
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
                  label: '关系 ${filtered.length} 条',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatChip(
                  icon: Icons.star_outline,
                  color: const Color(0xFFE8D8A0),
                  label: '旧记忆 ${widget.memoryCount} 条',
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
                      builder: (_) =>
                          PatternMemoryPage(hub: ButlerModuleHub.instance),
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

/// 关系记录卡片（详情弹窗里用）：句子 + 原话 + 时间 + 归属
class _RelationCard extends StatelessWidget {
  const _RelationCard({required this.record});

  final RelationRecord record;

  @override
  Widget build(BuildContext context) {
    final color = RelationMapView.relationColor(record);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  record.sentence,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5A4A52),
                  ),
                ),
              ),
              // 归属徽章
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFC896B4).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  record.ownerLabel,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFC896B4),
                  ),
                ),
              ),
            ],
          ),
          // 原话（用户的话，一字不改）
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFDF0F5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '"',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFC896B4),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    record.quote,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF6A4A5A),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 时间 + 类型
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${record.time == null || record.time!.isEmpty ? '' : '${record.time} · '}'
              '${record.category} · ${_ago(record.createdAt)}',
              style: TextStyle(
                fontSize: 11,
                color: const Color(0xFF5A4A52).withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${(d.inDays / 30).round()} 个月前';
  }
}

/// 筛选小胶囊
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFC896B4)
              : Colors.white.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? const Color(0xFFC896B4)
                : const Color(0xFFC896B4).withValues(alpha: 0.3),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : const Color(0xFF8A7A80),
          ),
        ),
      ),
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
              const SizedBox(width: 10),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB0789A),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  side: BorderSide(
                    color: const Color(0xFFB0789A).withValues(alpha: 0.4),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PetSetupPage()),
                ),
                child: const Tooltip(
                  message: '桌宠设置',
                  child: Icon(Icons.pets, size: 20),
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
