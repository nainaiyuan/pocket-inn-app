import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../butler/memory/relation_record.dart';

/// 关系图 — 8-07 01:13 用户
///
/// 用户原话："用户→家人→妈妈→喜欢/讨厌…下面有具体的话，
/// 不管是情绪、记忆、规律都可以这样记录，点开详情有后续的话的汇总。"
///
/// 中心 = 焦点实体（默认"用户"），周围一圈 = 与它直接相关的实体，
/// 连线 = 有关系。星球大小 = 出现次数，颜色 = 关系性质
/// （喜欢粉 / 讨厌橙 / 家人绿 / 宠物黄 / 其他紫）。
/// 点击实体 → 弹详情（该实体的全部记录汇总 + 可继续进入下一层）。
class RelationMapView extends StatefulWidget {
  const RelationMapView({
    super.key,
    required this.records,
    this.centerEntity = '用户',
    this.onEntityTap,
  });

  /// 全部关系记录
  final List<RelationRecord> records;

  /// 中心实体（默认"用户"——你是这张网的中心）
  final String centerEntity;

  /// 点击实体回调（默认弹详情）
  final void Function(String entity, List<RelationRecord> records)? onEntityTap;

  /// 关系性质 → 颜色
  static Color relationColor(RelationRecord r) {
    final p = r.predicate;
    if (p.contains('喜欢') ||
        p.contains('爱') ||
        p.contains('想') && !p.contains('不想')) {
      return const Color(0xFFE896B8); // 粉
    }
    if (p.contains('讨厌') || p.contains('不喜欢') || p.contains('怕')) {
      return const Color(0xFFE8A078); // 橙
    }
    if (p.contains('是') || p.contains('有')) {
      return const Color(0xFF8FC8A0); // 绿（家人/拥有）
    }
    if (p.contains('养') || p.contains('宠物')) {
      return const Color(0xFFE8D8A0); // 黄（宠物）
    }
    if (p.contains('每天') || p.contains('晚上') || p.contains('时候')) {
      return const Color(0xFF96B8E8); // 蓝（行为/规律）
    }
    return const Color(0xFFB896E8); // 紫（其他）
  }

  @override
  State<RelationMapView> createState() => _RelationMapViewState();
}

class _RelationMapViewState extends State<RelationMapView> {
  Size _size = Size.zero;

  /// 星球位置缓存（paint 时算好，点击命中用）
  final List<({Offset pos, double r, String entity})> _planets = [];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handleTap(d.localPosition),
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _RelationMapPainter(
              records: widget.records,
              centerEntity: widget.centerEntity,
              onLayout: (size, planets) {
                _size = size;
                _planets
                  ..clear()
                  ..addAll(planets);
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
        final related = widget.records
            .where((r) =>
                r.subject == planet.entity || r.object == planet.entity)
            .toList();
        widget.onEntityTap?.call(planet.entity, related);
        return;
      }
    }
  }
}

class _RelationMapPainter extends CustomPainter {
  _RelationMapPainter({
    required this.records,
    required this.centerEntity,
    required this.onLayout,
  });

  final List<RelationRecord> records;
  final String centerEntity;

  final void Function(
    Size size,
    List<({Offset pos, double r, String entity})> planets,
  ) onLayout;

  @override
  void paint(Canvas canvas, Size size) {
    final planets = <({Offset pos, double r, String entity})>[];

    // ---------- 星空背景 ----------
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF1A1430),
          Color(0xFF2A1B3D),
          Color(0xFF3A2240),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    // 背景星
    final rand = math.Random(42);
    for (var i = 0; i < 60; i++) {
      final pos = Offset(
        rand.nextDouble() * size.width,
        rand.nextDouble() * size.height,
      );
      canvas.drawCircle(
        pos,
        0.6 + rand.nextDouble() * 1.4,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.15 + rand.nextDouble() * 0.5),
      );
    }

    final center = Offset(size.width / 2, size.height / 2 - 8);

    // ---------- 提取与中心直接相关的实体 ----------
    final related = <String, int>{}; // 实体 → 出现次数
    final centerRecords = records
        .where((r) => r.subject == centerEntity || r.object == centerEntity)
        .toList();
    for (final r in centerRecords) {
      final other = r.subject == centerEntity ? r.object : r.subject;
      if (other.isEmpty || other == centerEntity) continue;
      related[other] = (related[other] ?? 0) + 1;
    }

    final entityList = related.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // ---------- 中心星球 ----------
    final centerR = math.min(size.width, size.height) * 0.15;

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

    // 本体
    canvas.drawCircle(
      center,
      centerR,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.4, -0.4),
          colors: [Color(0xFFF0C8DC), Color(0xFFC896B4), Color(0xFF8A5A78)],
        ).createShader(
          Rect.fromCircle(center: center, radius: centerR),
        ),
    );

    // 中心文字（实体名，最长 4 字）
    final name = centerEntity.length > 4
        ? centerEntity.substring(0, 4)
        : centerEntity;
    final tp = TextPainter(
      text: TextSpan(
        text: name,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: centerR * 1.6);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));

    // ---------- 相关实体星球 + 连线 ----------
    if (entityList.isNotEmpty) {
      final maxCount = entityList.first.value.toDouble();
      // 黄金角分布
      final golden = 2.399963;

      for (var i = 0; i < entityList.length; i++) {
        final entity = entityList[i].key;
        final count = entityList[i].value;

        // 找到这条关系（取第一条做颜色）
        final rec = centerRecords.firstWhere(
          (r) =>
              r.subject == entity ||
              r.object == entity ||
              r.subject == centerEntity ||
              r.object == centerEntity,
          orElse: () => centerRecords.first,
        );
        final color = RelationMapView.relationColor(rec);

        final angle = i * golden + 0.4;
        final dist = math.min(size.width, size.height) *
            (0.30 + (i % 3) * 0.14);
        final pos = center +
            Offset(math.cos(angle) * dist, math.sin(angle) * dist * 0.55);

        final r = 11 + (count / maxCount) * 11;

        // 连线（中心 ↔ 实体）
        canvas.drawLine(
          center,
          pos,
          Paint()
            ..strokeWidth = 1.2
            ..color = color.withValues(alpha: 0.35),
        );

        // 光晕
        canvas.drawCircle(
          pos,
          r * 1.6,
          Paint()
            ..shader = RadialGradient(
              colors: [
                color.withValues(alpha: 0.4),
                color.withValues(alpha: 0.0),
              ],
            ).createShader(Rect.fromCircle(center: pos, radius: r * 1.6)),
        );

        // 本体
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

        // 标签（实体名）
        final tp2 = TextPainter(
          text: TextSpan(
            text: entity,
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.75),
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 80);
        tp2.paint(canvas, pos + Offset(-tp2.width / 2, r + 4));

        planets.add((pos: pos, r: r, entity: entity));
      }
    } else {
      // 空态提示
      final hint = TextPainter(
        text: TextSpan(
          text: '还没有关系记录\n聊天时男主会帮你记：谁 → 谁 → 什么 ＋ 原话',
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: size.width - 60);
      hint.paint(
        canvas,
        Offset(
          (size.width - hint.width) / 2,
          center.dy + centerR + 30,
        ),
      );
    }

    // ---------- 底部说明 ----------
    final hint2 = TextPainter(
      text: TextSpan(
        text: entityList.isEmpty
            ? ''
            : '点一点星球看详情 · 大星球 = 出现多',
        style: TextStyle(
          fontSize: 11,
          color: Colors.white.withValues(alpha: 0.4),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (hint2.width > 0) {
      hint2.paint(
        canvas,
        Offset((size.width - hint2.width) / 2, size.height - hint2.height - 14),
      );
    }

    onLayout(size, planets);
  }

  @override
  bool shouldRepaint(covariant _RelationMapPainter oldDelegate) {
    return oldDelegate.records != records ||
        oldDelegate.centerEntity != centerEntity;
  }
}
