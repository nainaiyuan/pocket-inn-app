import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 8-15 04:5x 占位立绘（纯程序绘制，零素材依赖）
///
/// 乙游立绘 = 角色大图 + 表情切换。真素材（用户上传 OC 立绘）到位前，
/// 先用 Q 版占位：圆脸 + 刘海 + 8 种表情（眼睛/嘴巴形状变体）。
/// AI 输出 expression=smile → 切到对应表情。
///
/// 表情名（与 PetCommand.expression 约定一致）：
/// normal / smile / happy / sad / angry / surprised / embarrassed / crying
class PlaceholderPortrait extends StatelessWidget {
  final String expression;
  final double size;

  const PlaceholderPortrait({
    super.key,
    this.expression = 'normal',
    this.size = 300,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _PortraitPainter(expression),
    );
  }
}

/// 表情名 → 中文标签（立绘模式底部按钮用）
const Map<String, String> kExpressionLabels = {
  'normal': '平常',
  'smile': '微笑',
  'happy': '开心',
  'sad': '难过',
  'angry': '生气',
  'surprised': '惊讶',
  'embarrassed': '害羞',
  'crying': '哭泣',
};

class _PortraitPainter extends CustomPainter {
  final String expression;
  _PortraitPainter(this.expression);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;

    // 背景（柔和渐变，突出立绘）
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFDF0F5), Color(0xFFF2DCE8)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bg);

    // 身体（简单 Q 版：圆肩）
    final body = Paint()..color = const Color(0xFF8E5B77);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.28, h * 0.62, w * 0.44, h * 0.38),
        const Radius.circular(40),
      ),
      body,
    );
    // 衣领
    final collar = Paint()..color = const Color(0xFFFDF6F9);
    canvas.drawPath(
      Path()
        ..moveTo(cx, h * 0.66)
        ..lineTo(w * 0.38, h * 0.80)
        ..lineTo(cx, h * 0.78)
        ..lineTo(w * 0.62, h * 0.80)
        ..close(),
      collar,
    );

    // 头
    final skin = Paint()..color = const Color(0xFFF6D8C8);
    canvas.drawOval(
      Rect.fromLTWH(w * 0.26, h * 0.12, w * 0.48, h * 0.48),
      skin,
    );

    // 刘海
    final hair = Paint()..color = const Color(0xFF5A4049);
    canvas.drawArc(
      Rect.fromLTWH(w * 0.24, h * 0.08, w * 0.52, h * 0.44),
      math.pi,
      math.pi,
      true,
      hair,
    );
    // 刘海两撮
    canvas.drawCircle(Offset(w * 0.40, h * 0.26), w * 0.07, hair);
    canvas.drawCircle(Offset(w * 0.60, h * 0.26), w * 0.07, hair);

    // 表情
    _paintFace(canvas, w, h);
  }

  void _paintFace(Canvas canvas, double w, double h) {
    final eyeL = Offset(w * 0.40, h * 0.36);
    final eyeR = Offset(w * 0.60, h * 0.36);
    final eyePaint = Paint()
      ..color = const Color(0xFF4A333C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.02
      ..strokeCap = StrokeCap.round;

    final mouthPaint = Paint()
      ..color = const Color(0xFFB0606A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.02
      ..strokeCap = StrokeCap.round;

    switch (expression) {
      case 'smile':
        // 弯眼 + 微笑
        _drawArcEye(canvas, eyeL, w, true);
        _drawArcEye(canvas, eyeR, w, true);
        canvas.drawArc(
            Rect.fromCenter(
                center: Offset(w * 0.5, h * 0.50), width: w * 0.16, height: w * 0.10),
            0.15 * math.pi, 0.7 * math.pi, false, mouthPaint);
        break;
      case 'happy':
        // 大弯眼 + 开口笑（填色）
        _drawArcEye(canvas, eyeL, w, true);
        _drawArcEye(canvas, eyeR, w, true);
        canvas.drawArc(
            Rect.fromCenter(
                center: Offset(w * 0.5, h * 0.52), width: w * 0.20, height: w * 0.14),
            0, math.pi, true,
            Paint()..color = const Color(0xFFB0606A));
        break;
      case 'sad':
        // 垂眼 + 撇嘴
        _drawArcEye(canvas, eyeL, w, false);
        _drawArcEye(canvas, eyeR, w, false);
        canvas.drawArc(
            Rect.fromCenter(
                center: Offset(w * 0.5, h * 0.52), width: w * 0.12, height: w * 0.08),
            math.pi, 0.7 * math.pi, false, mouthPaint);
        break;
      case 'angry':
        // 皱眉（斜线）+ 倒嘴
        canvas.drawLine(eyeL + Offset(-w * 0.04, -w * 0.02),
            eyeL + Offset(w * 0.04, w * 0.02), eyePaint);
        canvas.drawLine(eyeR + Offset(w * 0.04, -w * 0.02),
            eyeR + Offset(-w * 0.04, w * 0.02), eyePaint);
        _drawDotEye(canvas, eyeL, w);
        _drawDotEye(canvas, eyeR, w);
        canvas.drawArc(
            Rect.fromCenter(
                center: Offset(w * 0.5, h * 0.54), width: w * 0.14, height: w * 0.08),
            math.pi, 0.8 * math.pi, false, mouthPaint);
        break;
      case 'surprised':
        // 大圆眼 + O 嘴
        _drawRoundEye(canvas, eyeL, w, 0.035);
        _drawRoundEye(canvas, eyeR, w, 0.035);
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(w * 0.5, h * 0.52), width: w * 0.08, height: w * 0.10),
            mouthPaint);
        break;
      case 'embarrassed':
        // 斜眼 + 波浪嘴 + 浓腮红
        canvas.drawLine(eyeL + Offset(-w * 0.03, -w * 0.02),
            eyeL + Offset(w * 0.04, w * 0.02), eyePaint);
        canvas.drawLine(eyeR + Offset(w * 0.03, -w * 0.02),
            eyeR + Offset(-w * 0.04, w * 0.02), eyePaint);
        _drawBlush(canvas, w, h, 0.08);
        final wave = Path()
          ..moveTo(w * 0.42, h * 0.52)
          ..quadraticBezierTo(w * 0.46, h * 0.55, w * 0.50, h * 0.52)
          ..quadraticBezierTo(w * 0.54, h * 0.49, w * 0.58, h * 0.52);
        canvas.drawPath(wave, mouthPaint);
        break;
      case 'crying':
        // 闭眼（向下弧）+ 泪滴 + 撇嘴
        _drawArcEye(canvas, eyeL, w, false);
        _drawArcEye(canvas, eyeR, w, false);
        final tear = Paint()..color = const Color(0xFF7FB4D8);
        canvas.drawOval(
            Rect.fromCenter(
                center: eyeR + Offset(w * 0.06, h * 0.06),
                width: w * 0.035,
                height: w * 0.06),
            tear);
        canvas.drawArc(
            Rect.fromCenter(
                center: Offset(w * 0.5, h * 0.54), width: w * 0.14, height: w * 0.08),
            math.pi, 0.8 * math.pi, false, mouthPaint);
        break;
      default:
        // normal：圆点眼 + 平嘴线
        _drawDotEye(canvas, eyeL, w);
        _drawDotEye(canvas, eyeR, w);
        canvas.drawLine(Offset(w * 0.44, h * 0.51), Offset(w * 0.56, h * 0.51),
            mouthPaint);
    }

    // 腮红（除 crying 外都有，淡淡的）
    if (expression != 'crying') {
      _drawBlush(canvas, w, h, 0.05);
    }
  }

  void _drawDotEye(Canvas canvas, Offset c, double w) {
    canvas.drawCircle(c, w * 0.025, Paint()..color = const Color(0xFF4A333C));
  }

  void _drawRoundEye(Canvas canvas, Offset c, double w, double r) {
    final p = Paint()
      ..color = const Color(0xFF4A333C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.018;
    canvas.drawCircle(c, w * r, p);
    canvas.drawCircle(c, w * 0.012, Paint()..color = const Color(0xFF4A333C));
  }

  void _drawArcEye(Canvas canvas, Offset c, double w, bool up) {
    final p = Paint()
      ..color = const Color(0xFF4A333C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.022
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
        Rect.fromCenter(
            center: c, width: w * 0.09, height: w * 0.05),
        up ? math.pi : 0, math.pi, false, p);
  }

  void _drawBlush(Canvas canvas, double w, double h, double alpha) {
    final blush = Paint()
      ..color = const Color(0x55E88A9A)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.03);
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(w * 0.34, h * 0.44),
            width: w * 0.09,
            height: w * 0.05),
        blush);
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(w * 0.66, h * 0.44),
            width: w * 0.09,
            height: w * 0.05),
        blush);
  }

  @override
  bool shouldRepaint(covariant _PortraitPainter old) =>
      old.expression != expression;
}
