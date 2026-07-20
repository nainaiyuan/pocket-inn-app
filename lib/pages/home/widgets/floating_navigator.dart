import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 可拖拽悬浮导航球
///
/// - 满屏任意拖动
/// - 点击展开/收起扇形菜单
/// - 菜单展开时，菜单项在主球周围均匀分布
/// - 当前页面页签不显示在菜单中
class FloatingNavigator extends StatefulWidget {
  final int pageCount;
  final int currentIndex;
  final List<IconData> pageIcons;
  final List<Color> pageColors;
  final ValueChanged<int> onPageSelected;

  const FloatingNavigator({
    super.key,
    required this.pageCount,
    required this.currentIndex,
    required this.pageIcons,
    required this.pageColors,
    required this.onPageSelected,
  });

  @override
  State<FloatingNavigator> createState() => _FloatingNavigatorState();
}

class _FloatingNavigatorState extends State<FloatingNavigator>
    with SingleTickerProviderStateMixin {
  bool _isOpen = false;
  Offset _position = const Offset(0, 0);
  bool _dragMoved = false;
  Size _screenSize = Size.zero;

  late AnimationController _animCtrl;
  late Animation<double> _menuAnim;

  static const double _orbSize = 56;
  static const double _menuItemSize = 44;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _menuAnim = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    HapticFeedback.lightImpact();
    if (_isOpen) {
      _animCtrl.reverse().then((_) => setState(() => _isOpen = false));
    } else {
      setState(() => _isOpen = true);
      _animCtrl.forward();
    }
  }

  void _selectPage(int index) {
    // 先显式关闭再切换
    _animCtrl.reset();
    setState(() => _isOpen = false);
    widget.onPageSelected(index);
  }

  List<_MenuItemInfo> _getMenuItems() {
    final others = <int>[];
    for (var i = 0; i < widget.pageCount; i++) {
      if (i != widget.currentIndex) others.add(i);
    }
    if (others.isEmpty) return [];

    final cx = _position.dx + _orbSize / 2;
    final cy = _position.dy + _orbSize / 2;
    const margin = 60.0;

    final r = _screenSize.width - cx - margin;
    final l = cx - margin;
    final b = _screenSize.height - cy - margin;
    final t = cy - margin;
    final maxSpace = [r, l, b, t].reduce((a, b) => a > b ? a : b);
    final radius = (maxSpace * 0.45).clamp(55.0, 120.0);

    final n = others.length;

    // 起始角度根据主球位置自适应
    double startAngle = math.pi / 4;
    if (cx >= _screenSize.width / 2 && cy < _screenSize.height / 2) {
      startAngle = 3 * math.pi / 4;
    } else if (cx < _screenSize.width / 2 && cy >= _screenSize.height / 2) {
      startAngle = -math.pi / 4;
    } else if (cx >= _screenSize.width / 2 && cy >= _screenSize.height / 2) {
      startAngle = -3 * math.pi / 4;
    }

    final totalAngle = ((n - 1) * 55.0).clamp(0, 180);
    final step = n > 1 ? totalAngle / (n - 1) : 0.0;

    return List.generate(n, (i) {
      final angle = startAngle + step * i + (n % 2 == 0 ? 0 : -step / 2);
      return _MenuItemInfo(
        index: others[i],
        dx: math.cos(angle) * radius,
        dy: math.sin(angle) * radius,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _screenSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (_position == Offset.zero && _screenSize.width > 0) {
          _position = Offset(
            _screenSize.width - _orbSize - 20,
            _screenSize.height - 160,
          );
        }

        return SizedBox(
          width: _screenSize.width,
          height: _screenSize.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // ===== 菜单打开时的透明拦截层（最底层） =====
              if (_isOpen)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _toggle,
                    behavior: HitTestBehavior.translucent,
                  ),
                ),

              // ===== 主导航球（中间层） =====
              Positioned(
                left: _position.dx,
                top: _position.dy,
                child: GestureDetector(
                  onTap: () {
                    if (!_dragMoved) _toggle();
                  },
                  onPanStart: (_) => _dragMoved = false,
                  onPanUpdate: (details) {
                    _dragMoved = true;
                    final margin = 20.0;
                    setState(() {
                      _position = Offset(
                        (_position.dx + details.delta.dx)
                            .clamp(margin, _screenSize.width - _orbSize - margin),
                        (_position.dy + details.delta.dy)
                            .clamp(margin, _screenSize.height - _orbSize - margin),
                      );
                    });
                  },
                  onPanEnd: (_) {
                    if (_isOpen) _dragMoved = false;
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    width: _orbSize,
                    height: _orbSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isOpen
                          ? Colors.white.withValues(alpha: 0.85)
                          : Colors.white.withValues(alpha: 0.7),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFC896B4).withValues(alpha: 0.15),
                          blurRadius: 12,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.pageColors[widget.currentIndex]
                            .withValues(alpha: 0.15),
                      ),
                      child: Icon(
                        widget.pageIcons[widget.currentIndex],
                        size: 20,
                        color: widget.pageColors[widget.currentIndex],
                      ),
                    ),
                  ),
                ),
              ),

              // ===== 菜单项（最上层，在主球之上） =====
              if (_isOpen) ..._buildMenuItems(),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildMenuItems() {
    final items = _getMenuItems();
    final anim = _menuAnim.value;
    final scale = 0.5 + anim * 0.5;

    return items.map((item) {
      final ox = item.dx * anim;
      final oy = item.dy * anim;
      final itemLeft = _position.dx + _orbSize / 2 - _menuItemSize / 2 + ox;
      final itemTop = _position.dy + _orbSize / 2 - _menuItemSize / 2 + oy;

      return Positioned(
        left: itemLeft,
        top: itemTop,
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: anim,
            child: GestureDetector(
              onTap: () => _selectPage(item.index),
              child: Container(
                width: _menuItemSize,
                height: _menuItemSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.7),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFC896B4).withValues(alpha: 0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.pageColors[item.index].withValues(alpha: 0.12),
                  ),
                  child: Icon(
                    widget.pageIcons[item.index],
                    size: 16,
                    color: widget.pageColors[item.index].withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }
}

class _MenuItemInfo {
  final int index;
  final double dx;
  final double dy;
  _MenuItemInfo({required this.index, required this.dx, required this.dy});
}
