import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../butler/pet/pet_models.dart';

/// 目标点选择器：模拟手机屏幕的小方块 + 横向/竖向双滑块 + 8 向快捷按钮
///
/// 用户"指哪走哪"：滑滑块选目标位置，亮点实时显示，
/// 角度/距离/时长全部由引擎自动换算，用户零配置。
class TargetPicker extends StatefulWidget {
  final PetPoint? initial;
  final ValueChanged<PetPoint> onChanged;

  const TargetPicker({this.initial, required this.onChanged});

  @override
  State<TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends State<TargetPicker> {
  late double _x;
  late double _y;

  /// 起点（预览用）：默认屏幕中央
  static const _origin = PetPoint(0.5, 0.5);

  @override
  void initState() {
    super.initState();
    _x = widget.initial?.x ?? 0.5;
    _y = widget.initial?.y ?? 0.5;
  }

  void _set(double x, double y) {
    setState(() {
      _x = x.clamp(0.02, 0.98);
      _y = y.clamp(0.02, 0.98);
    });
    widget.onChanged(PetPoint(_x, _y));
  }

  void _quick(PetMoveDir d) {
    final (vx, vy) = d.vector;
    // 朝方向走到屏幕边（边中点）
    _set(0.5 + vx * 0.45, 0.5 + vy * 0.45);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 迷你屏幕：起点灰点 → 目标亮点 + 路径线
        Center(
          child: Container(
            width: 150,
            height: 250,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F0F2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD8C8CE)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                children: [
                  // 起点
                  Positioned(
                    left: _origin.x * 150 - 4,
                    top: _origin.y * 250 - 4,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFC0B0B6),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  // 路径线（起点 → 目标）
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _PathPainter(
                          from: _origin, to: PetPoint(_x, _y)),
                    ),
                  ),
                  // 目标亮点
                  Positioned(
                    left: _x * 150 - 7,
                    top: _y * 250 - 7,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: const Color(0xFFB0789A),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x55B0789A), blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
                  // 边提示
                  const Positioned(
                    left: 6,
                    top: 4,
                    child: Text('屏幕',
                        style:
                            TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 双滑块：横向 + 竖向（竖向滑块在上 = 目标在上）
        Row(
          children: [
            const SizedBox(width: 4),
            RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: 120,
                child: Slider(
                  value: 1 - _y,
                  min: 0,
                  max: 1,
                  activeColor: const Color(0xFFB0789A),
                  onChanged: (v) => _set(_x, 1 - v),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: _x,
                min: 0,
                max: 1,
                activeColor: const Color(0xFFB0789A),
                onChanged: (v) => _set(v, _y),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('横向',
                style: TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
            Text(
              '目标：横向 ${(_x * 100).round()}% · 竖向 ${(_y * 100).round()}%',
              style: const TextStyle(fontSize: 10, color: Color(0xFF8A5A72)),
            ),
            const Text('竖向',
                style: TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
          ],
        ),
        const SizedBox(height: 8),
        // 8 向快捷：点一下 = 朝那个方向走到屏幕边
        const Text('快捷：朝这个方向走到屏幕边',
            style: TextStyle(fontSize: 10, color: Color(0xFFB0A0A6))),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final d in PetMoveDir.values)
              SizedBox(
                width: 40,
                height: 28,
                child: OutlinedButton(
                  onPressed: () => _quick(d),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    side: const BorderSide(color: Color(0xFFD8C0CA)),
                  ),
                  child: Text(d.label,
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFF8A5A72))),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('超出屏幕的位置会自动截断到屏幕边，不会跑出去',
            style: TextStyle(fontSize: 9.5, color: Color(0xFFC0B0B6))),
      ],
    );
  }
}

/// 轨迹三选：走过去 / 跳过去 / 飞过去
class TrajectorySelector extends StatelessWidget {
  final PetMoveTrajectory value;
  final ValueChanged<PetMoveTrajectory> onChanged;

  const TrajectorySelector({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('怎么过去：', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        SegmentedButton<PetMoveTrajectory>(
          segments: [
            for (final t in PetMoveTrajectory.values)
              ButtonSegment(
                value: t,
                label: Text(t.label, style: const TextStyle(fontSize: 11)),
              ),
          ],
          selected: {value},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 4),
        Text(value.hint,
            style:
                const TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
      ],
    );
  }
}

/// 起点 → 目标 路径线画笔
class _PathPainter extends CustomPainter {
  final PetPoint from;
  final PetPoint to;

  _PathPainter({required this.from, required this.to});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x88B0789A)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(from.x * size.width, from.y * size.height)
      ..lineTo(to.x * size.width, to.y * size.height);
    canvas.drawPath(path, paint);
    // 箭头
    final dx = to.x - from.x;
    final dy = to.y - from.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 0.02) {
      final ux = dx / len;
      final uy = dy / len;
      final tip = Offset(to.x * size.width, to.y * size.height);
      final back = Offset(tip.dx - ux * 10, tip.dy - uy * 10);
      final n = Offset(-uy, ux);
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(back.dx + n.dx * 4, back.dy + n.dy * 4)
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(back.dx - n.dx * 4, back.dy - n.dy * 4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PathPainter old) => old.from != from || old.to != to;
}
