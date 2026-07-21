import 'package:flutter/material.dart';

/// 手势测试页面 —— 三页连续空间（v4 状态机版）
///
/// 关键改进：记录页面状态（Panel），拖拽范围受起始页面限制。
/// 左 ←→ 中 ←→ 右，不允许跨页。
class GestureTestPage extends StatefulWidget {
  const GestureTestPage({super.key});
  @override
  State<GestureTestPage> createState() => _GestureTestPageState();
}

/// 三个页面位置
enum Panel { left, center, right }

class _GestureTestPageState extends State<GestureTestPage>
    with TickerProviderStateMixin {
  static const double _sideFrac = 0.65;
  static const double _snapThr = 0.30;
  static const double _lockThr = 8.0;
  static const double _closeFactor = 2.5; // 回滑加速倍数

  final List<Color> _colors = [
    Colors.red.shade300,
    Colors.blue.shade300,
    Colors.green.shade300,
  ];
  final List<String> _labels = ['左页', '聊天页', '右页'];

  // ---- 状态 ----
  Panel _currentPanel = Panel.center;
  double _offset = 0;
  double _sideW = 0;

  // ---- 拖拽 ----
  bool _dragging = false;
  double _dragStartOffset = 0;
  Panel _startPanel = Panel.center;
  double _startX = 0, _startY = 0;
  bool _horizLocked = false;
  int _pointerId = -1;

  // ---- 动画 ----
  late AnimationController _anim;
  double _animStart = 0, _animEnd = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onAnimTick);
  }

  void _onAnimTick() {
    if (_dragging) return;
    setState(() {
      _offset = _animStart + (_animEnd - _animStart) * _anim.value;
    });
  }

  void _animateTo(double target) {
    _animStart = _offset;
    _animEnd = target;
    _anim.forward(from: 0);
  }

  // ---- 获取面板对应的 offset ----
  double _panelOffset(Panel p) {
    switch (p) {
      case Panel.left: return _sideW;
      case Panel.right: return -_sideW;
      case Panel.center: return 0;
    }
  }

  // ---- 获取起始面板对应的拖拽边界 ----
  (double, double) _dragBounds(Panel start) {
    switch (start) {
      case Panel.left: return (0.0, _sideW);       // 只能往中间(0)拖
      case Panel.right: return (-_sideW, 0.0);     // 只能往中间(0)拖
      case Panel.center: return (-_sideW, _sideW); // 两边都能去
    }
  }

  // ---- 手势 ----

  void _onDown(PointerDownEvent e) {
    if (_pointerId >= 0) return;
    _pointerId = e.pointer;
    _startX = e.position.dx;
    _startY = e.position.dy;

    // ★ 冻结动画，锁定起始状态
    _anim.stop();
    if (_anim.value > 0 && _anim.value < 1) {
      _offset = _animStart + (_animEnd - _animStart) * _anim.value;
    }

    _sideW = MediaQuery.of(context).size.width * _sideFrac;
    _dragStartOffset = _offset;
    _startPanel = _currentPanel;
    _dragging = false;
    _horizLocked = false;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointerId) return;

    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_horizLocked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _horizLocked = dx.abs() > dy.abs() * 1.3;
      if (!_horizLocked) return;
      _dragging = true;
      // 继续往下，不丢第一次 dx
    }

    if (!_dragging) return;

    // ★ 回滑加速
    double factor = 1.0;
    final goingBack = (_startPanel == Panel.left && dx < 0) ||
                      (_startPanel == Panel.right && dx > 0) ||
                      false;
    if (_startPanel != Panel.center && goingBack) {
      factor = _closeFactor;
    }

    // ★ 边界约束：从哪出发，只能到哪
    final (lo, hi) = _dragBounds(_startPanel);

    setState(() {
      _offset = (_dragStartOffset + dx * factor).clamp(lo, hi);
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
    double target;
    Panel nextPanel;

    switch (_startPanel) {
      case Panel.center:
        if (absOff < sideW * _snapThr) {
          target = 0;
          nextPanel = Panel.center;
        } else if (_offset > 0) {
          target = sideW;
          nextPanel = Panel.left;
        } else {
          target = -sideW;
          nextPanel = Panel.right;
        }
        break;
      case Panel.left:
        // 从左边出发：只可能回到中间或弹回左边
        if (_offset < sideW * (1 - _snapThr)) {
          target = 0;
          nextPanel = Panel.center;
        } else {
          target = sideW;
          nextPanel = Panel.left;
        }
        break;
      case Panel.right:
        // 从右边出发：只可能回到中间或弹回右边
        if (_offset > -sideW * (1 - _snapThr)) {
          target = 0;
          nextPanel = Panel.center;
        } else {
          target = -sideW;
          nextPanel = Panel.right;
        }
        break;
    }

    _currentPanel = nextPanel;
    _animateTo(target);
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
    final side = screenW * _sideFrac;

    return Material(
      color: Colors.white,
      child: SizedBox.expand(
        child: Stack(
          children: [
            Positioned(
              left: _offset - side, top: 0,
              width: side, bottom: 0,
              child: Container(
                color: _colors[0],
                alignment: Alignment.center,
                child: Text(_labels[0], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            Positioned(
              left: _offset, top: 0,
              width: screenW, bottom: 0,
              child: Container(
                color: _colors[1],
                alignment: Alignment.center,
                child: Text(_labels[1], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            Positioned(
              left: screenW + _offset, top: 0,
              width: side, bottom: 0,
              child: Container(
                color: _colors[2],
                alignment: Alignment.center,
                child: Text(_labels[2], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),

            // 状态
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
                    'p:$_currentPanel  o:${_offset.toStringAsFixed(0)}  '
                    '${_dragging ? "拖" : _anim.isAnimating ? "动" : "停"}  '
                    '${_horizLocked ? "🔒" : "🔓"}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),

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
