import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 手势测试页面 —— 三页连续空间
///
/// 纯色测试，不接入任何聊天逻辑。
/// 只测：左右滑动、方向锁定、手指跟随、松手吸附。
class GestureTestPage extends StatefulWidget {
  const GestureTestPage({super.key});

  @override
  State<GestureTestPage> createState() => _GestureTestPageState();
}

class _GestureTestPageState extends State<GestureTestPage>
    with TickerProviderStateMixin {
  // 三页数据
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

  // ---- 偏移 ----
  double _offset = 0;
  int _snapTarget = 0; // 0=中间，1=左，-1=右
  late AnimationController _anim;

  // === 添加拖拽状态追踪 ===
  bool _isDragging = false;
  double _dragOffset = 0;

  static const double _snapThr = 0.40;
  static const double _lockThr = 8.0;

  // 页面宽度
  double get _sideW => MediaQuery.of(context).size.width * _sideFrac;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() { if (mounted) setState(() {}); });
  }

  double get _currentOffset {
    if (_isDragging) return _dragOffset;
    return _snapTarget * _sideW * _anim.value;
  }

  void _snapTo(int target) {
    if (target == _snapTarget) return;
    _snapTarget = target;
    _anim.forward(from: 0);
  }

  void _snapBack() {
    _snapTarget = 0;
    // 从当前位置动画回到 0
    _anim.value = _offset.abs() / _sideW;
    _anim.reverse().then((_) {
      if (mounted) setState(() { _offset = 0; _dragOffset = 0; });
    });
  }

  // ---- 手势：Listener 全屏只读 ----

  void _onDown(PointerDownEvent e) {
    _startX = e.position.dx;
    _startY = e.position.dy;
    _locked = false;
    _horiz = false;
    // _active removed;
    _wasHoriz = false;
    _isDragging = false;
    _anim.stop();
  }

  void _onMove(PointerMoveEvent e) {
    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_locked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _locked = true;
      // 带阈值：水平分量必须明显大于垂直
      _horiz = dx.abs() > dy.abs() * 1.3;
      if (_horiz) {
        _isDragging = true;
        _wasHoriz = true;
        _dragOffset = _snapTarget * _sideW;
        // _active removed;
      }
      return;
    }

    if (!_horiz) return;

    // 跟随手指
    final totalDx = e.position.dx - _startX;
    final base = _snapTarget * _sideW;
    _offset = (base + totalDx).clamp(-_sideW, _sideW);
    _dragOffset = _offset;
    if (mounted) setState(() {});
  }

  void _onUp(PointerUpEvent e) {
    if (!_wasHoriz) {
      _isDragging = false;
      // _active removed;
      _locked = false;
      _wasHoriz = false;
      return;
    }

    final sideW = _sideW;
    final absOff = _offset.abs();
    final isLeft = _offset > 0;

    if (_snapTarget == 0) {
      // 从中间开始
      if (absOff > sideW * _snapThr) {
        _snapTo(isLeft ? 1 : -1);
      } else {
        _snapBack();
      }
    } else {
      // 已展开，看是否拉过中间
      // 左展开(>0)拉到接近 0 或负 → 收回
      // 右展开(<0)拉到接近 0 或正 → 收回
      if ((_snapTarget == 1 && _offset < sideW * (1 - _snapThr)) ||
          (_snapTarget == -1 && _offset > -sideW * (1 - _snapThr))) {
        _snapBack();
      } else {
        // 弹回原展开位置
        _snapTo(_snapTarget);
        _offset = _snapTarget * sideW;
      }
    }

    _isDragging = false;
    // _active removed;
    _locked = false;
    _wasHoriz = false;
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sideW = screenW * _sideFrac;
    final off = _currentOffset;

    // 三页位置（连续空间）
    // 左页   ：left = off - sideW
    // 中间页  ：left = off
    // 右页   ：left = screenW + off
    // 这样三页形成一个连续的纸张

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // ===== 三页连续空间（按 offset 排列） =====
          // 左页
          Positioned(
            left: off - sideW,
            top: 0,
            width: sideW,
            height: double.infinity,
            child: Container(
              color: _colors[0],
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_labels[0], style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 300,
                    child: ListView.builder(
                      itemCount: 30,
                      itemBuilder: (_, i) => Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.3), borderRadius: BorderRadius.circular(8)),
                        child: Text('左页第 ${i + 1} 项', style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 中间页
          Positioned(
            left: off,
            top: 0,
            width: screenW,
            height: double.infinity,
            child: Container(
              color: _colors[1],
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_labels[1], style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 400,
                    child: ListView.builder(
                      itemCount: 50,
                      itemBuilder: (_, i) => Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.3), borderRadius: BorderRadius.circular(8)),
                        child: Text('聊天消息 ${i + 1}', style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 右页
          Positioned(
            left: screenW + off,
            top: 0,
            width: sideW,
            height: double.infinity,
            child: Container(
              color: _colors[2],
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_labels[2], style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 300,
                    child: ListView.builder(
                      itemCount: 20,
                      itemBuilder: (_, i) => Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.3), borderRadius: BorderRadius.circular(8)),
                        child: Text('右页第 ${i + 1} 项', style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ===== 当前状态指示器 =====
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'offset: ${off.toStringAsFixed(0)}  snap: $_snapTarget  '
                  '${_horiz ? "水平" : _locked ? "垂直" : "等待"}  '
                  '${_locked ? "🔒" : "🔓"}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),

          // ===== 全屏 Listener =====
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
    );
  }
}
