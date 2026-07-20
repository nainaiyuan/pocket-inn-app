import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 可拖拽悬浮导航球
///
/// - 满屏任意拖动
/// - 点击展开/收起扇形菜单
/// - 展开后拖拽主球，子球自适应重排
/// - 当前页面页签高亮显示（不展示在菜单中）
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

  // 位置（相对屏幕）
  Offset _position = const Offset(0, 0);
  bool _dragMoved = false;

  // 动画
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
    widget.onPageSelected(index);
    _animCtrl.reverse().then((_) => setState(() => _isOpen = false));
  }

  List<_MenuItemPos> _calcItems(Size screen) {
    final cx = _position.dx + _orbSize / 2;
    final cy = _position.dy + _orbSize / 2;
    const margin = 60.0;

    // 其他页签（排除当前页）
    final others = <int>[];
    for (var i = 0; i < widget.pageCount; i++) {
      if (i != widget.currentIndex) others.add(i);
    }

    // 算各方向的可用空间
    final r = screen.width - cx - margin;
    final l = cx - margin;
    final b = screen.height - cy - margin;
    final t = cy - margin;

    // 半径：取最大空间的1/3，再限制范围
    final maxSpace = [r, l, b, t].reduce((a, b) => a > b ? a : b);
    final radius = (maxSpace * 0.45).clamp(55.0, 120.0);

    final n = others.length;
    if (n == 0) return [];

    // 菜单项均匀分布在主球周围
    // 起始角度：根据主球位置自适应
    double startAngle = 0;
    if (cx < screen.width / 2 && cy < screen.height / 2) {
      // 左上角 → 向右下展开
      startAngle = math.pi / 4;
    } else if (cx >= screen.width / 2 && cy < screen.height / 2) {
      // 右上角 → 向左下展开
      startAngle = 3 * math.pi / 4;
    } else if (cx < screen.width / 2 && cy >= screen.height / 2) {
      // 左下角 → 向右上展开
      startAngle = -math.pi / 4;
    } else {
      // 右下角 → 向左上展开
      startAngle = -3 * math.pi / 4;
    }

    final totalAngle = ((n - 1) * 55.0).clamp(0, 180);
    final step = n > 1 ? totalAngle / (n - 1) : 0.0;

    return List.generate(n, (i) {
      final angle = startAngle + step * i + (n % 2 == 0 ? 0 : -step / 2);
      return _MenuItemPos(
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
        final screen = Size(constraints.maxWidth, constraints.maxHeight);
        if (_position == Offset.zero) {
          _position = Offset(
            screen.width - _orbSize - 20,
            screen.height - 160,
          );
        }
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // 透明点击层（菜单打开时拦截触控）
            if (_isOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => _toggle(),
                  behavior: HitTestBehavior.translucent,
                ),
              ),

            // 导航球容器
            Positioned(
              left: _position.dx,
              top: _position.dy,
              child: Column(
                children: [
                  // 菜单项（展开在主球周围）
                  if (_isOpen || _animCtrl.isAnimating)
                    ..._buildMenuItems(screen),

                  // 主球
                  GestureDetector(
                    onTap: _toggle,
                    onPanStart: (_) => _dragMoved = false,
                    onPanUpdate: (details) {
                      _dragMoved = true;
                      final margin = 20.0;
                      setState(() {
                        _position = Offset(
                          (_position.dx + details.delta.dx)
                              .clamp(margin, screen.width - _orbSize - margin),
                          (_position.dy + details.delta.dy)
                              .clamp(margin, screen.height - _orbSize - margin),
                        );
                      });
                    },
                    onPanEnd: (_) {
                      if (!_dragMoved) _toggle();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      width: _orbSize,
                      height: _orbSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isOpen
                            ? Colors.white.withValues(alpha: 0.8)
                            : Colors.white.withValues(alpha: 0.6),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.5),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFC896B4)
                                .withValues(alpha: _isOpen ? 0.2 : 0.1),
                            blurRadius: 16,
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
                              .withValues(alpha: 0.12),
                        ),
                        child: Icon(
                          widget.pageIcons[widget.currentIndex],
                          size: 20,
                          color: widget.pageColors[widget.currentIndex],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildMenuItems(Size screen) {
    final items = _calcItems(screen);
    return items.map((item) {
      final anim = _menuAnim.value;
      final ox = (item.dx * anim).clamp(-200.0, 200.0);
      final oy = (item.dy * anim).clamp(-200.0, 200.0);
      final scale = 0.5 + anim * 0.5;

      return Positioned(
        left: _orbSize / 2 - _menuItemSize / 2 + ox,
        top: _orbSize / 2 - _menuItemSize / 2 + oy,
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
                  color: Colors.white.withValues(alpha: 0.55),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFC896B4).withValues(alpha: 0.08),
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
                    color: widget.pageColors[item.index].withValues(alpha: 0.1),
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

class _MenuItemPos {
  final int index;
  final double dx;
  final double dy;
  _MenuItemPos({required this.index, required this.dx, required this.dy});
}
