import 'package:flutter/material.dart';

/// 手势测试页面 —— 三页连续空间（v7 触摸坐标版）
///
/// 垂直锁定时，根据触摸坐标决定哪个 ListView 可以滚动。
class GestureTestPage extends StatefulWidget {
  const GestureTestPage({super.key});
  @override
  State<GestureTestPage> createState() => _GestureTestPageState();
}

enum Panel { left, center, right }

class _GestureTestPageState extends State<GestureTestPage>
    with SingleTickerProviderStateMixin {
  static const double _sideFrac = 0.65;
  static const double _snapThr = 0.30;
  static const double _lockThr = 8.0;
  static const double _closeFactor = 2.5;

  final List<Color> _colors = [
    Colors.red.shade300,
    Colors.blue.shade300,
    Colors.green.shade300,
  ];

  // ---- 唯一状态 ----
  double _offset = 0;
  Panel _currentPanel = Panel.center;

  // ---- 拖拽 ----
  bool _dragging = false;
  double _dragBase = 0;
  Panel _startPanel = Panel.center;
  double _startX = 0, _startY = 0;
  bool _horizLocked = false;
  int _pointerId = -1;

  // ---- 垂直滚动控制 ----
  int _activeScrollPage = 1; // 0=左, 1=中, 2=右

  // ---- 动画 ----
  late AnimationController _anim;
  double _animStart = 0, _animEnd = 0;

  double get _sideW => MediaQuery.of(context).size.width * _sideFrac;

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
    _anim
      ..value = 0
      ..forward();
  }

  @override
  void dispose() {
    _anim.removeListener(_onAnimTick);
    _anim.dispose();
    super.dispose();
  }

  // ---- 手势 ----

  void _onDown(PointerDownEvent e) {
    if (_pointerId >= 0) return;
    _pointerId = e.pointer;
    _startX = e.position.dx;
    _startY = e.position.dy;

    _anim.stop();
    if (_anim.value > 0 && _anim.value < 1) {
      _offset = _animStart + (_animEnd - _animStart) * _anim.value;
    }

    _dragBase = _offset;
    _startPanel = _currentPanel;
    _dragging = false;
    _horizLocked = false;

    // ★ 根据触摸坐标预判滚动归属
    final tapX = e.position.dx;
    final screenW = MediaQuery.of(context).size.width;
    int nextScrollPage = 1;
    if (_offset > 0 && tapX < _offset) {
      nextScrollPage = 0;
    } else if (_offset < 0 && tapX > screenW + _offset) {
      nextScrollPage = 2;
    }
    if (nextScrollPage != _activeScrollPage) {
      _activeScrollPage = nextScrollPage;
      if (mounted) setState(() {});
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointerId) return;

    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_horizLocked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _horizLocked = dx.abs() > dy.abs() * 1.3;
      if (!_horizLocked) {
        // ★ 垂直锁定：确定触摸坐标对应的页面，只让该页滚动
        final tapX = e.position.dx;
        final screenW = MediaQuery.of(context).size.width;
        int nextScrollPage = 1;
        if (_offset > 0 && tapX < _offset) {
          nextScrollPage = 0;
        } else if (_offset < 0 && tapX > screenW + _offset) {
          nextScrollPage = 2;
        }
        if (nextScrollPage != _activeScrollPage) {
          _activeScrollPage = nextScrollPage;
          if (mounted) setState(() {});
        }
        return;
      }
      _dragging = true;
    }

    if (!_dragging) return;

    double factor = 1.0;
    final goingBack = (_startPanel == Panel.left && dx < 0) ||
                      (_startPanel == Panel.right && dx > 0);
    if (_startPanel != Panel.center && goingBack) {
      factor = _closeFactor;
    }

    double lo, hi;
    switch (_startPanel) {
      case Panel.left:   lo = 0; hi = _sideW; break;
      case Panel.right:  lo = -_sideW; hi = 0; break;
      case Panel.center: lo = -_sideW; hi = _sideW; break;
    }

    setState(() {
      _offset = (_dragBase + dx * factor).clamp(lo, hi);
    });
  }

  void _onUp(PointerUpEvent e) {
    if (_pointerId != e.pointer) return;
    _pointerId = -1;

    if (!_dragging) { _horizLocked = false; return; }

    _dragging = false;
    _horizLocked = false;

    double target;
    Panel nextPanel;

    switch (_startPanel) {
      case Panel.center:
        if (_offset.abs() < _sideW * _snapThr) {
          target = 0; nextPanel = Panel.center;
        } else if (_offset > 0) {
          target = _sideW; nextPanel = Panel.left;
        } else {
          target = -_sideW; nextPanel = Panel.right;
        }
        break;
      case Panel.left:
        if (_offset < _sideW * (1 - _snapThr)) {
          target = 0; nextPanel = Panel.center;
        } else {
          target = _sideW; nextPanel = Panel.left;
        }
        break;
      case Panel.right:
        if (_offset > -_sideW * (1 - _snapThr)) {
          target = 0; nextPanel = Panel.center;
        } else {
          target = -_sideW; nextPanel = Panel.right;
        }
        break;
    }

    _currentPanel = nextPanel;
    _animateTo(target);
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
            _pageWidget(0, _offset - side, side, _colors[0], '左页', 30),
            _pageWidget(1, _offset, screenW, _colors[1], '消息', 50),
            _pageWidget(2, screenW + _offset, side, _colors[2], '右页', 20),

            // 状态
            Positioned(
              top: 60, left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    'p:$_currentPanel  o:${_offset.toStringAsFixed(0)}  '
                    '${_dragging ? "拖" : _anim.isAnimating ? "动" : "停"}  '
                    '${_horizLocked ? "🔒" : "🔓"}  '
                    '滚:$_activeScrollPage',
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

  Widget _pageWidget(int index, double left, double width, Color color, String title, int count) {
    return Positioned(
      left: left, top: 0,
      width: width, bottom: 0,
      child: Container(
        color: color,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 100, bottom: 12),
              child: Text(title, style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: ListView.builder(
                // ★ 非当前触摸页面的 ListView 不让滚动
                physics: _activeScrollPage == index
                    ? const AlwaysScrollableScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                itemCount: count,
                itemBuilder: (_, i) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${title}${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
