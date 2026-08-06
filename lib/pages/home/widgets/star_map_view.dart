import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../butler/patterns/pattern_engine.dart';

/// 星球图（规律·记忆可视化）— 8-07 00:58 用户
///
/// 星空背景 + 中心大星球（代表你/管家）+ 椭圆轨道上的规律星球：
/// - 规律星球大小 = 出现次数（count）
/// - 规律星球颜色 = 主导情绪偏移（喜悦粉 / 依恋紫 / 悲伤蓝 / 愤怒橙）
/// - 点击星球 → 弹出规律详情
/// - 背景散布记忆小星星（数量 = 记忆条数，静态点缀）
class StarMapView extends StatefulWidget {
  const StarMapView({
    super.key,
    required this.patterns,
    required this.memoryCount,
    this.onPatternTap,
  });

  /// 已确认的规律
  final List<PatternStats> patterns;

  /// 记忆条数（背景星星数）
  final int memoryCount;

  /// 点击规律星球回调（默认弹详情）
  final void Function(PatternStats)? onPatternTap;

  /// 规律主导情绪 → 颜色
  static Color patternColor(PatternStats p) {
    final shifts = {
      '喜悦': p.shiftJoy,
      '依恋': p.shiftAttachment,
      '悲伤': p.shiftSad,
      '愤怒': p.shiftAnger,
    };
    final dominant = shifts.entries.reduce(
      (a, b) => a.value.abs() > b.value.abs() ? a : b,
    );
    switch (dominant.key) {
      case '喜悦':
        return const Color(0xFFE896B8); // 粉
      case '依恋':
        return const Color(0xFFB896E8); // 紫
      case '悲伤':
        return const Color(0xFF96B8E8); // 蓝
      case '愤怒':
        return const Color(0xFFE8A078); // 橙
    }
    return const Color(0xFFC896B4);
  }

  /// 规律主导情绪 → 中文标签
  static String patternMood(PatternStats p) {
    final shifts = {
      '喜悦': p.shiftJoy,
      '依恋': p.shiftAttachment,
      '悲伤': p.shiftSad,
      '愤怒': p.shiftAnger,
    };
    final dominant = shifts.entries.reduce(
      (a, b) => a.value.abs() > b.value.abs() ? a : b,
    );
    return dominant.value.abs() < 5 ? '平静' : dominant.key;
  }

  @override
  State<StarMapView> createState() => _StarMapViewState();
}

class _StarMapViewState extends State<StarMapView> {
  /// 画布尺寸（paint 时更新，命中检测用）
  Size _size = Size.zero;

  /// 星球位置缓存（paint 时算好，点击命中用）
  final List<({Offset pos, double r, PatternStats p})> _planets = [];

  /// 记忆星星位置（paint 时生成一次，静态）
  final List<({Offset pos, double r, double alpha})> _stars = [];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handleTap(d.localPosition),
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _StarMapPainter(
              patterns: widget.patterns,
              memoryCount: widget.memoryCount,
              onLayout: (size, planets, stars) {
                _size = size;
                _planets
                  ..clear()
                  ..addAll(planets);
                _stars
                  ..clear()
                  ..addAll(stars);
              },
            ),
          ),
        );
      },
    );
  }

  void _handleTap(Offset pos) {
    for (final planet in _planets) {
      if ((pos - planet.pos).distance <= planet.r + 10) {
        widget.onPatternTap?.call(planet.p);
        return;
      }
    }
  }
}

class _StarMapPainter extends CustomPainter {
  _StarMapPainter({
    required this.patterns,
    required this.memoryCount,
    required this.onLayout,
  });

  final List<PatternStats> patterns;
  final int memoryCount;

  /// 布局回调：把算好的星球/星星位置传回 State（命中检测用）
  final void Function(
    Size size,
    List<({Offset pos, double r, PatternStats p})> planets,
    List<({Offset pos, double r, double alpha})> stars,
  ) onLayout;

  @override
  void paint(Canvas canvas, Size size) {
    final planets = <({Offset pos, double r, PatternStats p})>[];
    final stars = <({Offset pos, double r, double alpha})>[];

    // ---------- 星空背景 ----------
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF1A1430), // 深蓝紫
          Color(0xFF2A1B3D),
          Color(0xFF3A2240),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    // 背景小星星（固定种子，稳定布局）
    final rand = math.Random(42);
    for (var i = 0; i < 60; i++) {
      final pos = Offset(
        rand.nextDouble() * size.width,
        rand.nextDouble() * size.height,
      );
      final r = 0.6 + rand.nextDouble() * 1.4;
      final alpha = 0.15 + rand.nextDouble() * 0.5;
      stars.add((pos: pos, r: r, alpha: alpha));
      canvas.drawCircle(
        pos,
        r,
        Paint()..color = Colors.white.withValues(alpha: alpha),
      );
    }

    // ---------- 中心星球 ----------
    final center = Offset(size.width / 2, size.height / 2 - 8);
    final centerR = math.min(size.width, size.height) * 0.16;

    // 光晕
    canvas.drawCircle(
      center,
      centerR * 1.9,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFC896B4).withValues(alpha: 0.35),
            const Color(0xFFC896B4).withValues(alpha: 0.0),
          ],
        ).createShader(
          Rect.fromCircle(center: center, radius: centerR * 1.9),
        ),
    );

    // 星球本体（粉紫渐变 + 高光）
    canvas.drawCircle(
      center,
      centerR,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.4, -0.4),
          colors: [
            Color(0xFFF0C8DC),
            Color(0xFFC896B4),
            Color(0xFF8A5A78),
          ],
        ).createShader(
          Rect.fromCircle(center: center, radius: centerR),
        ),
    );

    // 高光点
    canvas.drawCircle(
      center + Offset(-centerR * 0.35, -centerR * 0.35),
      centerR * 0.18,
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );

    // 中心文字"我"
    final tp = TextPainter(
      text: const TextSpan(
        text: '我',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      center - Offset(tp.width / 2, tp.height / 2),
    );

    // ---------- 轨道 ----------
    final orbitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.12);

    // 三条椭圆轨道（旋转不同角度）
    for (var i = 0; i < 3; i++) {
      final rx = math.min(size.width, size.height) *
          (0.32 + i * 0.16);
      final ry = rx * 0.42;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(i * 0.5); // 每条轨道倾斜一点
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: rx * 2,
          height: ry * 2,
        ),
        orbitPaint,
      );
      canvas.restore();
    }

    // ---------- 规律星球 ----------
    if (patterns.isNotEmpty) {
      final maxCount = patterns
          .map((p) => p.count)
          .reduce((a, b) => math.max(a, b))
          .toDouble();
      final golden = 2.399963; // 黄金角，分布均匀

      for (var i = 0; i < patterns.length; i++) {
        final p = patterns[i];
        final angle = i * golden;
        final orbit = i % 3; // 循环分配 3 条轨道
        final rx = math.min(size.width, size.height) * (0.32 + orbit * 0.16);
        final ry = rx * 0.42;
        final x = math.cos(angle) * rx;
        final y = math.sin(angle) * ry;

        // 旋转轨道角（与画轨道一致）
        final rot = orbit * 0.5;
        final cosR = math.cos(rot);
        final sinR = math.sin(rot);
        final rx2 = x * cosR - y * sinR;
        final ry2 = x * sinR + y * cosR;

        final pos = center + Offset(rx2, ry2);
        // 大小 = count 归一化 9~24px
        final r = 9 + (p.count / maxCount) * 15;
        final color = StarMapView.patternColor(p);

        // 光晕
        canvas.drawCircle(
          pos,
          r * 1.7,
          Paint()
            ..shader = RadialGradient(
              colors: [
                color.withValues(alpha: 0.4),
                color.withValues(alpha: 0.0),
              ],
            ).createShader(Rect.fromCircle(center: pos, radius: r * 1.7)),
        );

        // 星球本体
        canvas.drawCircle(
          pos,
          r,
          Paint()
            ..shader = RadialGradient(
              center: Alignment(-0.4, -0.4),
              colors: [
                Colors.white.withValues(alpha: 0.9),
                color,
                Color.lerp(color, const Color(0xFF3A2240), 0.5)!,
              ],
            ).createShader(Rect.fromCircle(center: pos, radius: r)),
        );

        // 高光
        canvas.drawCircle(
          pos + Offset(-r * 0.3, -r * 0.3),
          r * 0.22,
          Paint()..color = Colors.white.withValues(alpha: 0.6),
        );

        // 标签（关键词组合）
        final label = p.keywords.join(' · ');
        final tp2 = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.75),
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 90);
        tp2.paint(
          canvas,
          pos + Offset(-tp2.width / 2, r + 4),
        );

        planets.add((pos: pos, r: r, p: p));
      }
    }

    // ---------- 记忆小星星（顶部飘散，随记忆数） ----------
    final mRand = math.Random(7);
    for (var i = 0; i < memoryCount.clamp(0, 30); i++) {
      final pos = Offset(
        mRand.nextDouble() * size.width,
        mRand.nextDouble() * size.height * 0.55, // 上半区，避开轨道
      );
      final r = 1.5 + mRand.nextDouble() * 2.5;
      final alpha = 0.35 + mRand.nextDouble() * 0.4;
      final twinkle = 0.7 + 0.3 * math.sin(i * 1.7); // 闪烁感
      canvas.drawCircle(
        pos,
        r,
        Paint()
          ..color = const Color(0xFFF0D8E8).withValues(alpha: alpha * twinkle),
      );
      // 十字光芒
      canvas.drawLine(
        pos - Offset(r * 3, 0),
        pos + Offset(r * 3, 0),
        Paint()
          ..strokeWidth = 0.7
          ..color = const Color(0xFFF0D8E8).withValues(alpha: alpha * 0.4),
      );
      canvas.drawLine(
        pos - Offset(0, r * 3),
        pos + Offset(0, r * 3),
        Paint()
          ..strokeWidth = 0.7
          ..color = const Color(0xFFF0D8E8).withValues(alpha: alpha * 0.4),
      );
    }

    // ---------- 底部说明 ----------
    final hint = TextPainter(
      text: TextSpan(
        text: patterns.isEmpty
            ? '还没有规律，聊得多了管家会帮你发现 ✨'
            : '点一点星球看规律详情 · 亮星 = 出现多',
        style: TextStyle(
          fontSize: 11,
          color: Colors.white.withValues(alpha: 0.4),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    hint.paint(
      canvas,
      Offset(
        (size.width - hint.width) / 2,
        size.height - hint.height - 14,
      ),
    );

    onLayout(size, planets, stars);
  }

  @override
  bool shouldRepaint(covariant _StarMapPainter oldDelegate) {
    return oldDelegate.patterns != patterns ||
        oldDelegate.memoryCount != memoryCount;
  }
}
