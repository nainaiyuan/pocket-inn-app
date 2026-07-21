import 'package:flutter/material.dart';

/// 手势测试页面 —— 三页连续空间（v3 修复版）
class GestureTestPage extends StatefulWidget {
  const GestureTestPage({super.key});
  @override
  State<GestureTestPage> createState() => _GestureTestPageState();
}

class _GestureTestPageState extends State<GestureTestPage>
    with TickerProviderStateMixin {
  static const double _sideFrac = 0.65;
  static const double _snapThr = 0.30; // 吸附阈值降低（配合加速）
  static const double _lockThr = 8.0;

  final List<Color> _colors = [
    Colors.red.shade300,
    Colors.blue.shade300,
    Colors.green.shade300,
  ];
  final List<String> _labels = ['左页', '聊天页', '右页'];

  // ---- 唯一状态：页面偏移量 ----
  double _offset = 0;

  // ---- 拖拽状态 ----
  bool _dragging = false;
  double _dragBase = 0; // 开始拖拽时的 _offset（冻结动画后）
  double _startX = 0, _startY = 0;
  bool _horizLocked = false; // 已锁定为水平拖拽
  int _pointerId = -1;

  // ---- 动画 ----
  late AnimationController _anim;
  double _animStart = 0; // 动画起始偏移
  double _animEnd = 0;   // 动画结束偏移

  double get _sideW => MediaQuery.of(context).size.width * _sideFrac;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onAnimTick);
  }

  /// 动画 tick：从 _animStart 线性插值到 _animEnd
  void _onAnimTick() {
    if (_dragging) return; // ★ 拖拽期间不碰 _offset
    setState(() {
      _offset = _animStart + (_animEnd - _animStart) * _anim.value;
    });
  }

  /// 启动动画：从当前 _offset 到目标
  void _animateTo(double target) {
    _animStart = _offset;
    _animEnd = target;
    _anim.forward(from: 0);
  }

  /// 返回中心
  void _snapBack() {
    _animateTo(0);
  }

  // ---- 手势 ----

  void _onDown(PointerDownEvent e) {
    if (_pointerId >= 0) return;
    _pointerId = e.pointer;
    _startX = e.position.dx;
    _startY = e.position.dy;

    // ★ 冻结动画，把最后位置写入 _offset
    _anim.stop();
    // 如果动画还在跑，把当前位置刷进 _offset
    if (_anim.value > 0 && _anim.value < 1) {
      _offset = _animStart + (_animEnd - _animStart) * _anim.value;
    }

    _dragBase = _offset;
    _dragging = false;
    _horizLocked = false;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointerId) return;

    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    // 未锁定 → 判定方向
    if (!_horizLocked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _horizLocked = dx.abs() > dy.abs() * 1.3;
      if (!_horizLocked) return;
      // ★ 锁定为水平后立刻进入拖拽模式
      _dragging = true;
      // 不 return——继续往下执行，不丢掉这一次的 dx
    }

    if (!_dragging) return;

    // ★ 回滑加速：展开状态下往回收，factor 3x
    double factor = 1.0;
    final isExpanded = _dragBase.abs() > _sideW * 0.5;
    final goingBack = (_dragBase > 0 && dx < 0) || (_dragBase < 0 && dx > 0);
    if (isExpanded && goingBack) {
      // 自适应 factor：大屏(~1046px)≈2.7，小屏(~400px)≈1.6
      factor = _sideW / 250.0;
    }

    setState(() {
      _offset = (_dragBase + dx * factor).clamp(-_sideW, _sideW);
    });
  }

  void _onUp(PointerUpEvent e) {
    if (_pointerId != e.pointer) return;
    _pointerId = -1;

    if (!_dragging) {
      _horizLocked = false;
      return;
    }

    _dragging = false;
    _horizLocked = false;

    final sideW = _sideW;
    final absOff = _offset.abs();

    // 判断吸附方向（只根据 _offset 的正负）
    if (absOff < sideW * _snapThr) {
      _snapBack();
    } else {
      // 展开到对应的侧页
      final target = _offset > 0 ? sideW : -sideW;
      _animateTo(target);
    }
  }

  @override
  void dispose() {
    _anim.removeListener(_onAnimTick);
    _anim.dispose();
    super.dispose();
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sideFrac;

    return Material(
      color: Colors.white,
      child: SizedBox.expand(
        child: Stack(
          children: [
            // 左页：在中间页左边
            Positioned(
              left: _offset - sideW, top: 0,
              width: sideW, bottom: 0,
              child: Container(
                color: _colors[0],
                alignment: Alignment.center,
                child: Text(_labels[0], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            // 中间页
            Positioned(
              left: _offset, top: 0,
              width: screenW, bottom: 0,
              child: Container(
                color: _colors[1],
                alignment: Alignment.center,
                child: Text(_labels[1], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            // 右页：在中间页右边
            Positioned(
              left: screenW + _offset, top: 0,
              width: sideW, bottom: 0,
              child: Container(
                color: _colors[2],
                alignment: Alignment.center,
                child: Text(_labels[2], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),

            // 状态指示器
            Positioned(
              top: 60, left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'offset: ${_offset.toStringAsFixed(0)}  '
                    '${_dragging ? "拖拽" : _anim.isAnimating ? "动画" : "静止"}  '
                    '${_horizLocked ? "🔒" : "🔓"}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),

            // 全屏 Listener
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onDown,
                onPointerMove: _onMove,
                onPointerUp: _onUp,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
