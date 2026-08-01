import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../butler/memory/emotion_arc.dart';
import '../butler/modules/butler_module_hub.dart';
import '../butler/patterns/pattern_engine.dart';
import '../butler/storage/storage_registry.dart';
import '../services/character_service.dart';

/// 情感基线页 — 用户的整体情绪画像（不是"输入一句话"）
///
/// 四个区块：
/// 1. 整体基线 — 你和男主聊天时的"正常"情绪状态（滚动平均）
/// 2. 月度趋势 — 最近几个月情绪怎么变（按弧线事件聚合）
/// 3. 触发因素 — 聊到什么关键词组合时情绪会怎么变（规律引擎）
/// 4. 最近事件 — 最近几次明显的情绪波动
class MoodAnalysisPage extends StatefulWidget {
  const MoodAnalysisPage({super.key});

  @override
  State<MoodAnalysisPage> createState() => _MoodAnalysisPageState();
}

class _MoodAnalysisPageState extends State<MoodAnalysisPage> {
  List<EmotionArc> _arcs = [];
  Map<String, String> _leadNames = {};
  bool _loading = true;
  String? _filterCharacterId; // null = 全部

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final arcs = await StorageRegistry.instance.emotionArcs.loadAll();
    // 男主 id → 名字
    final names = <String, String>{};
    try {
      final leads = await CharacterService().loadAllSummaries();
      for (final lead in leads) {
        names[lead.id] = lead.name;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _arcs = arcs;
      _leadNames = names;
      _loading = false;
    });
  }

  String _leadName(String? id) {
    if (id == null) return '未知男主';
    return _leadNames[id] ?? id;
  }

  List<EmotionArc> get _filteredArcs => _filterCharacterId == null
      ? _arcs
      : _arcs.where((a) => a.characterId == _filterCharacterId).toList();

  @override
  Widget build(BuildContext context) {
    final engine = ButlerModuleHub.instance.sharedPatternEngine;
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '情感基线',
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
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFC896B4)))
          : RefreshIndicator(
              color: const Color(0xFFC896B4),
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                children: [
                  _HintCard(
                    text:
                        '这是管家记住的"你"：和男主聊天时的整体情绪状态、变化趋势、什么会触发你的情绪波动。聊得越多越准。',
                  ),
                  const SizedBox(height: 14),
                  // 男主筛选
                  _LeadFilterChips(
                    arcs: _arcs,
                    leadNames: _leadNames,
                    selected: _filterCharacterId,
                    onChanged: (id) => setState(() => _filterCharacterId = id),
                  ),
                  const SizedBox(height: 14),
                  // 1. 整体基线
                  _BaselineCard(engine: engine),
                  const SizedBox(height: 14),
                  // 2. 月度趋势
                  _TrendCard(arcs: _filteredArcs),
                  const SizedBox(height: 14),
                  // 3. 触发因素
                  _TriggersCard(engine: engine),
                  const SizedBox(height: 14),
                  // 4. 最近情绪事件
                  _RecentArcsCard(arcs: _filteredArcs, leadName: _leadName),
                ],
              ),
            ),
    );
  }
}

// ==================== 提示卡 ====================

class _HintCard extends StatelessWidget {
  final String text;

  const _HintCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFC896B4).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.auto_awesome, color: Color(0xFFC896B4), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: const Color(0xFF6A4A5A).withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 男主筛选 ====================

class _LeadFilterChips extends StatelessWidget {
  final List<EmotionArc> arcs;
  final Map<String, String> leadNames;
  final String? selected;
  final ValueChanged<String?> onChanged;

  const _LeadFilterChips({
    required this.arcs,
    required this.leadNames,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final ids = <String>{};
    for (final arc in arcs) {
      if (arc.characterId != null) ids.add(arc.characterId!);
    }
    if (ids.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          ChoiceChip(
            label: const Text('全部', style: TextStyle(fontSize: 12)),
            selected: selected == null,
            selectedColor: const Color(0xFFC896B4).withValues(alpha: 0.3),
            onSelected: (_) => onChanged(null),
          ),
          for (final id in ids) ...[
            const SizedBox(width: 6),
            ChoiceChip(
              label: Text(
                leadNames[id] ?? id,
                style: const TextStyle(fontSize: 12),
              ),
              selected: selected == id,
              selectedColor: const Color(0xFFC896B4).withValues(alpha: 0.3),
              onSelected: (_) => onChanged(id),
            ),
          ],
        ],
      ),
    );
  }
}

// ==================== 1. 整体基线 ====================

class _BaselineCard extends StatelessWidget {
  final PatternEngine? engine;

  const _BaselineCard({required this.engine});

  @override
  Widget build(BuildContext context) {
    final baseline = engine?.baseline.allValues ?? const <String, double>{};
    final entries = baseline.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final reliable = engine?.baseline.isReliable ?? false;

    return _Card(
      title: '整体情感基线',
      icon: Icons.equalizer,
      subtitle: reliable
          ? '你和男主聊天时的"正常"状态'
          : '样本还少，多聊几次会更准（当前为初步估计）',
      child: entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有数据。\n和男主聊几句，管家会记录你的情绪基线。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: const Color(0xFF8A7A80).withValues(alpha: 0.7),
                ),
              ),
            )
          : Column(
              children: [
                for (final e in entries.take(8)) ...[
                  _BaselineBar(label: e.key, value: e.value),
                  const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }
}

class _BaselineBar extends StatelessWidget {
  final String label;
  final double value;

  const _BaselineBar({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 100.0);
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF6A4A5A)),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: v / 100,
              minHeight: 10,
              backgroundColor: const Color(0xFFC896B4).withValues(alpha: 0.15),
              valueColor: const AlwaysStoppedAnimation(Color(0xFFC896B4)),
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${v.round()}',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              color: const Color(0xFF6A4A5A).withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== 2. 月度趋势 ====================

class _TrendCard extends StatelessWidget {
  final List<EmotionArc> arcs;

  const _TrendCard({required this.arcs});

  /// 按月聚合：返回 (月份标签, 各维度均值)
  (List<String>, List<Map<String, double>>) _aggregateByMonth() {
    final byMonth = <String, List<Map<String, double>>>{};
    for (final arc in arcs) {
      final key = '${arc.time.year}-${arc.time.month.toString().padLeft(2, '0')}';
      byMonth.putIfAbsent(key, () => []).add(arc.endMood);
    }
    final keys = byMonth.keys.toList()..sort();
    final recent = keys.length > 6 ? keys.sublist(keys.length - 6) : keys;
    final labels = <String>[];
    final avgs = <Map<String, double>>[];
    for (final key in recent) {
      final samples = byMonth[key]!;
      final avg = <String, double>{};
      final dims = <String>{};
      for (final s in samples) {
        dims.addAll(s.keys);
      }
      for (final dim in dims) {
        var sum = 0.0;
        for (final s in samples) {
          sum += s[dim] ?? 0;
        }
        avg[dim] = sum / samples.length;
      }
      labels.add('${key.split('-')[1]}月');
      avgs.add(avg);
    }
    return (labels, avgs);
  }

  @override
  Widget build(BuildContext context) {
    final (labels, avgs) = _aggregateByMonth();
    if (avgs.isEmpty) {
      return _Card(
        title: '月度趋势',
        icon: Icons.show_chart,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '还没有月度数据。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: const Color(0xFF8A7A80).withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }

    const dims = ['开心', '悲伤', '生气', '依恋'];
    const colors = [
      Color(0xFFE8A0A8),
      Color(0xFF9BB8E8),
      Color(0xFFE8B48A),
      Color(0xFFC896B4),
    ];

    return _Card(
      title: '月度趋势',
      icon: Icons.show_chart,
      subtitle: '最近 ${avgs.length} 个月的情绪平均值',
      child: Column(
        children: [
          SizedBox(
            height: 150,
            child: CustomPaint(
              size: const Size(double.infinity, 150),
              painter: _TrendPainter(
                labels: labels,
                avgs: avgs,
                dims: dims,
                colors: colors,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < dims.length; i++) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colors[i],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  dims[i],
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6A4A5A)),
                ),
                const SizedBox(width: 14),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<String> labels;
  final List<Map<String, double>> avgs;
  final List<String> dims;
  final List<Color> colors;

  _TrendPainter({
    required this.labels,
    required this.avgs,
    required this.dims,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (avgs.isEmpty) return;

    final leftPad = 24.0, bottomPad = 22.0, topPad = 8.0;
    final chartW = size.width - leftPad - 8;
    final chartH = size.height - topPad - bottomPad;

    // 网格 + Y 轴刻度
    final gridPaint = Paint()
      ..color = const Color(0xFFC896B4).withValues(alpha: 0.15)
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = topPad + chartH * i / 2;
      canvas.drawLine(
        Offset(leftPad, y),
        Offset(leftPad + chartW, y),
        gridPaint,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '${100 - i * 50}',
          style: const TextStyle(fontSize: 9, color: Color(0xFF8A7A80)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - 6));
    }

    // X 轴月份标签
    for (var i = 0; i < labels.length; i++) {
      final x = leftPad + chartW * (avgs.length == 1 ? 0.5 : i / (avgs.length - 1));
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: const TextStyle(fontSize: 9, color: Color(0xFF8A7A80)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - 16));
    }

    // 每条维度折线
    for (var d = 0; d < dims.length; d++) {
      final paint = Paint()
        ..color = colors[d]
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      Offset? prev;
      for (var i = 0; i < avgs.length; i++) {
        final v = (avgs[i][dims[d]] ?? 0).clamp(0.0, 100.0);
        final x = leftPad + chartW * (avgs.length == 1 ? 0.5 : i / (avgs.length - 1));
        final y = topPad + chartH * (1 - v / 100);
        final p = Offset(x, y);
        if (prev != null) {
          canvas.drawLine(prev, p, paint);
        }
        canvas.drawCircle(
          p,
          3,
          Paint()..color = colors[d],
        );
        prev = p;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.avgs != avgs;
}

// ==================== 3. 触发因素 ====================

class _TriggersCard extends StatelessWidget {
  final PatternEngine? engine;

  const _TriggersCard({required this.engine});

  String _shiftText(PatternStats p) {
    final parts = <String>[];
    void add(double v, String label) {
      if (v.abs() >= 5) {
        parts.add('${v > 0 ? '+' : ''}${v.round()}% $label');
      }
    }

    add(p.shiftJoy, '开心');
    add(p.shiftSad, '悲伤');
    add(p.shiftAnger, '生气');
    add(p.shiftAttachment, '依恋');
    return parts.isEmpty ? '情绪平稳' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final confirmed = engine?.confirmedPatterns ?? const <PatternStats>[];
    final pending = (engine?.patterns ?? const <PatternStats>[])
        .where((p) => !p.confirmed)
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return _Card(
      title: '触发因素',
      icon: Icons.bolt,
      subtitle: '聊到这些关键词组合时，你的情绪会怎么变',
      child: confirmed.isEmpty && pending.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有触发因素。\n多聊聊工作、家人、朋友的事，管家会慢慢发现。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: const Color(0xFF8A7A80).withValues(alpha: 0.7),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (confirmed.isNotEmpty) ...[
                  const Text(
                    '已发现',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6A4A5A),
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final p in confirmed) ...[
                    _TriggerRow(
                      keywords: p.keywords,
                      shiftText: _shiftText(p),
                      confirmed: true,
                    ),
                    const SizedBox(height: 6),
                  ],
                ],
                if (pending.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '观察中（出现够多会确认）',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8A7A80),
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final p in pending.take(6)) ...[
                    _TriggerRow(
                      keywords: p.keywords,
                      shiftText: _shiftText(p),
                      confirmed: false,
                    ),
                    const SizedBox(height: 6),
                  ],
                ],
              ],
            ),
    );
  }
}

class _TriggerRow extends StatelessWidget {
  final List<String> keywords;
  final String shiftText;
  final bool confirmed;

  const _TriggerRow({
    required this.keywords,
    required this.shiftText,
    required this.confirmed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: confirmed
            ? const Color(0xFFC896B4).withValues(alpha: 0.08)
            : const Color(0xFFC896B4).withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              keywords.join(' + '),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF5A4A52).withValues(
                  alpha: confirmed ? 1 : 0.7,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            shiftText,
            style: TextStyle(
              fontSize: 11,
              color: const Color(0xFFC896B4).withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 4. 最近情绪事件 ====================

class _RecentArcsCard extends StatelessWidget {
  final List<EmotionArc> arcs;
  final String Function(String?) leadName;

  const _RecentArcsCard({required this.arcs, required this.leadName});

  String _timeLabel(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year &&
        t.month == now.month &&
        t.day == now.day) {
      return '今天 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    return '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final recent = arcs.reversed.take(20).toList();
    return _Card(
      title: '最近情绪事件',
      icon: Icons.history,
      subtitle: '最近 ${recent.length} 次有情绪记录的聊天',
      child: recent.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有事件。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: const Color(0xFF8A7A80).withValues(alpha: 0.7),
                ),
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < recent.length; i++) ...[
                  _ArcRow(
                    arc: recent[i],
                    timeLabel: _timeLabel(recent[i].time),
                    leadName: leadName(recent[i].characterId),
                  ),
                  if (i != recent.length - 1)
                    Divider(
                      height: 14,
                      color: const Color(
                        0xFFC896B4,
                      ).withValues(alpha: 0.12),
                    ),
                ],
              ],
            ),
    );
  }
}

class _ArcRow extends StatelessWidget {
  final EmotionArc arc;
  final String timeLabel;
  final String leadName;

  const _ArcRow({
    required this.arc,
    required this.timeLabel,
    required this.leadName,
  });

  @override
  Widget build(BuildContext context) {
    final moods = arc.peakMood.entries
        .where((e) => e.value > 55)
        .take(3)
        .map((e) => '${e.key} ${e.value.round()}')
        .join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: arc.returnedToBaseline
                  ? const Color(0xFF9CC8A0)
                  : const Color(0xFFE8A0A8),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  arc.triggerKeywords.isEmpty
                      ? '（日常聊天）'
                      : '提到「${arc.triggerKeywords.join('、')}」',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5A4A52),
                  ),
                ),
                if (moods.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    moods,
                    style: TextStyle(
                      fontSize: 11,
                      color: const Color(
                        0xFF5A4A52,
                      ).withValues(alpha: 0.55),
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  '$timeLabel · $leadName · ${arc.returnedToBaseline ? '情绪已恢复' : '情绪没完全恢复'}',
                  style: TextStyle(
                    fontSize: 10,
                    color: const Color(0xFF8A7A80).withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 卡片容器 ====================

class _Card extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget child;

  const _Card({
    required this.title,
    required this.icon,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFC896B4).withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFFC896B4), size: 18),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5A4A52),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 11,
                color: const Color(0xFF8A7A80).withValues(alpha: 0.7),
              ),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
