import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 手势测试页面 —— 三页连续空间（最小修复版）
///
/// 纯色测试，不接入任何聊天逻辑。
class GestureTestPage extends StatefulWidget {
  const GestureTestPage({super.key});

  @override
  State<GestureTestPage> createState() => _GestureTestPageState();
}

class _GestureTestPageState extends State<GestureTestPage>
    with TickerProviderStateMixin {
  static const double _sideFrac = 0.65;
  final List<Color> _colors = [
    Colors.red.shade300,
    Colors.blue.shade300,
    Colors.green.shade300,
  ];
  final List<String> _labels = ['左页', '聊天页', '右页'];

  // ---- 手势状态 ----
  double _startX = 0, _startY = 0;
  bool _locked = false;
  bool _horiz = false;
  bool _wasHoriz = false;
  int _pointerId = -1;

  // ---- 偏移 ----
  double _offset = 0;
  double _dragStartOffset = 0; // 手指按下时的当前偏移（基准）
  int _snapTarget = 0;
  late AnimationController _anim;

  static const double _snapThr = 0.40;
  static const double _lockThr = 8.0;

  double get _sideW => MediaQuery.of(context).size.width * _sideFrac;

  double get _currentOffset {
    if (_locked && _horiz) return _offset; // 拖拽中
    return _snapTarget * _sideW * _anim.value; // 动画中或静止
  }

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() { if (mounted) setState(() {}); });
  }

  void _snapTo(int t) { _snapTarget = t; _anim.forward(from: 0); }

  void _snapBack() {
    _snapTarget = 0;
    _anim.value = _offset.abs() / _sideW;
    _anim.reverse().then((_) { if (mounted) setState(() { _offset = 0; }); });
  }

  // ---- 手势 ----

  void _onDown(PointerDownEvent e) {
    if (_pointerId >= 0) return;
    _pointerId = e.pointer;
    _startX = e.position.dx;
    _startY = e.position.dy;
    _locked = false;
    _horiz = false;
    _wasHoriz = false;
    _dragStartOffset = _currentOffset; // ★ 记录按下时的真实偏移
    _anim.stop();
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointerId) return; // ★ 过滤非当前 pointer

    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_locked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _locked = true;
      _horiz = dx.abs() > dy.abs() * 1.3;
      if (_horiz) {
        _wasHoriz = true;
        _offset = _dragStartOffset; // 从按下时的位置开始
      }
      return;
    }

    if (!_horiz) return;

    // ★ 从 _dragStartOffset 累加 dx，不依赖 _snapTarget
    _offset = (_dragStartOffset + (e.position.dx - _startX)).clamp(-_sideW, _sideW);
    if (mounted) setState(() {});
  }

  void _onUp(PointerUpEvent e) {
    if (_pointerId != e.pointer) return;
    _pointerId = -1;

    if (!_wasHoriz) {
      _locked = false;
      _horiz = false;
      _wasHoriz = false;
      return;
    }

    final sideW = _sideW;
    final absOff = _offset.abs();
    final isLeft = _offset > 0;

    if (_snapTarget == 0) {
      if (absOff > sideW * _snapThr) {
        _snapTo(isLeft ? 1 : -1);
      } else {
        _snapBack();
      }
    } else {
      if ((_snapTarget == 1 && _offset < sideW * (1 - _snapThr)) ||
          (_snapTarget == -1 && _offset > -sideW * (1 - _snapThr))) {
        _snapBack();
      } else {
        _snapTo(_snapTarget);
        _offset = _snapTarget * sideW;
      }
    }

    _locked = false;
    _horiz = false;
    _wasHoriz = false;
  }

  @override
  void dispose() { _anim.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sideFrac;
    final off = _currentOffset;

    return Material(
      color: Colors.white,
      child: SizedBox.expand( // ★ 确保 Stack 铺满
        child: Stack(
          children: [
            // 左页
            Positioned(
              left: off - sideW, top: 0,
              width: sideW, bottom: 0, // ★ bottom:0 确保高度
              child: Container(
                color: _colors[0],
                alignment: Alignment.center,
                child: Text(_labels[0], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            // 中间页
            Positioned(
              left: off, top: 0,
              width: screenW, bottom: 0,
              child: Container(
                color: _colors[1],
                alignment: Alignment.center,
                child: Text(_labels[1], style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            // 右页
            Positioned(
              left: screenW + off, top: 0,
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
                    'offset: ${(_locked && _horiz ? _offset : off).toStringAsFixed(0)}  '
                    'snap: $_snapTarget  '
                    '${_horiz ? "水平" : _locked ? "垂直" : "等待"}  '
                    '${_locked ? "🔒" : "🔓"}',
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
