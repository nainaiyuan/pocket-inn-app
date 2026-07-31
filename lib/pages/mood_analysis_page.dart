import 'package:flutter/material.dart';

import '../butler/mood_analysis/mood_analyzer_impl.dart';
import '../butler/mood_analysis/mood_interface.dart';

/// 情绪分析页 — 输入一句话，实时看情绪（图形化）
///
/// 用户看不懂维度数值，只看图：
/// - 横向条形图显示各情绪强度
/// - 情绪强烈时高亮提示
class MoodAnalysisPage extends StatefulWidget {
  const MoodAnalysisPage({super.key});

  @override
  State<MoodAnalysisPage> createState() => _MoodAnalysisPageState();
}

class _MoodAnalysisPageState extends State<MoodAnalysisPage> {
  final TextEditingController _controller = TextEditingController();
  final IMoodAnalyzer _analyzer = MoodAnalyzerImpl();
  MoodResult? _result;
  bool _analyzed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _analyze() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _result = _analyzer.analyze(text);
      _analyzed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '情绪分析',
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
      body: Column(
        children: [
          // 输入区
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC896B4).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        color: Color(0xFFC896B4),
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '输入一句话，看看管家怎么理解你的情绪。\n比如"今天加班好累，烦死了"',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: Color(0xFF5A4A52),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onSubmitted: (_) => _analyze(),
                        decoration: InputDecoration(
                          hintText: '说点什么…',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: const Color(
                              0xFF5A4A52,
                            ).withValues(alpha: 0.3),
                          ),
                          filled: true,
                          fillColor: Colors.white,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 52,
                      height: 44,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFC896B4),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: _analyze,
                        child: const Icon(Icons.auto_awesome, size: 20),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 结果区
          Expanded(
            child: !_analyzed
                ? const _EmptyHint()
                : _result == null
                ? const _EmptyHint()
                : _ResultView(result: _result!),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.sentiment_satisfied_alt_outlined,
            size: 52,
            color: const Color(0xFFC896B4).withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            '分析结果会显示在这里',
            style: TextStyle(
              fontSize: 13,
              color: const Color(0xFF5A4A52).withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  final MoodResult result;

  const _ResultView({required this.result});

  @override
  Widget build(BuildContext context) {
    // 取显著的维度（>5），按强度排序
    final dims = result.dimensions.entries.where((e) => e.value > 5).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final strong = dims.isNotEmpty ? dims.first : null;
    final color = _moodColor(strong?.key ?? '');

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        // 主导情绪卡片
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                color.withValues(alpha: 0.15),
                color.withValues(alpha: 0.05),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Text(
                strong == null ? '平静' : _emoji(strong.key),
                style: const TextStyle(fontSize: 40),
              ),
              const SizedBox(height: 6),
              Text(
                strong == null ? '情绪平稳' : '主要是「${strong.key}」',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5A4A52),
                ),
              ),
              if (strong != null) ...[
                const SizedBox(height: 4),
                Text(
                  '强度 ${strong.value.round()}%',
                  style: TextStyle(
                    fontSize: 13,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
                  ),
                ),
              ],
              if (result.isAnomaly) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE07A7A).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '⚠ 偏离日常基线',
                    style: TextStyle(fontSize: 11, color: Color(0xFFE07A7A)),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 情绪分布条形图
        const Text(
          '情绪分布',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF5A4A52),
          ),
        ),
        const SizedBox(height: 10),
        for (final dim in dims.take(6)) ...[
          _BarRow(label: dim.key, value: dim.value),
          const SizedBox(height: 8),
        ],
        if (dims.isEmpty)
          Text(
            '没有明显情绪信号',
            style: TextStyle(
              fontSize: 12,
              color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
            ),
          ),
      ],
    );
  }

  static Color _moodColor(String mood) {
    if (mood.contains('开心') || mood.contains('高兴') || mood.contains('喜悦')) {
      return const Color(0xFFF0A868);
    }
    if (mood.contains('生气') || mood.contains('烦躁') || mood.contains('愤怒')) {
      return const Color(0xFFE07A7A);
    }
    if (mood.contains('悲伤') || mood.contains('难过') || mood.contains('低落')) {
      return const Color(0xFF8AA8D8);
    }
    if (mood.contains('依恋') || mood.contains('想你') || mood.contains('爱')) {
      return const Color(0xFFC896B4);
    }
    if (mood.contains('疲惫') || mood.contains('累')) {
      return const Color(0xFFA0A8B8);
    }
    if (mood.contains('恐惧') || mood.contains('害怕')) {
      return const Color(0xFFB8A0D8);
    }
    return const Color(0xFFC896B4);
  }

  static String _emoji(String mood) {
    if (mood.contains('开心') || mood.contains('高兴') || mood.contains('喜悦'))
      return '😄';
    if (mood.contains('生气') || mood.contains('烦躁') || mood.contains('愤怒'))
      return '😠';
    if (mood.contains('悲伤') || mood.contains('难过') || mood.contains('低落'))
      return '😢';
    if (mood.contains('依恋') || mood.contains('想你') || mood.contains('爱'))
      return '🥰';
    if (mood.contains('疲惫') || mood.contains('累')) return '😪';
    if (mood.contains('恐惧') || mood.contains('害怕')) return '😨';
    if (mood.contains('无聊')) return '😑';
    return '😊';
  }
}

class _BarRow extends StatelessWidget {
  final String label;
  final double value;

  const _BarRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final color = _ResultView._moodColor(label);
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF5A4A52)),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (value / 100).clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 32,
          child: Text(
            '${value.round()}',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }
}
