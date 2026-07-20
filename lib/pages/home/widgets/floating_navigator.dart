import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 可拖拽悬浮导航球
///
/// - 满屏任意拖动
/// - 点击展开/收起扇形菜单
/// - 展开后拖拽主球，子球自适应重排
/// - 当前页面不显示在菜单中
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

  // 拖拽
  Offset _position = const Offset(0, 0);
  Offset _dragStart = Offset.zero;
  bool _isDragging = false;
  bool _dragMoved = false;

  // 菜单展开动画
  late AnimationController _animCtrl;
  late Animation<double> _menuAnim;

  // 主球尺寸
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
    setState(() => _isOpen = !_isOpen);
    if (_isOpen) {
      _animCtrl.forward();
    } else {
      _animCtrl.reverse();
    }
  }

  void _close() {
    if (!_isOpen) return;
    setState(() => _isOpen = false);
    _animCtrl.reverse();
  }

  void _selectPage(int index) {
    _close();
    widget.onPageSelected(index);
  }

  // ====== 计算菜单项位置 ======
  List<_MenuItemPos> _calculatePositions(Size screen) {
    final centerX = _position.dx + _orbSize / 2;
    final centerY = _position.dy + _orbSize / 2;
    const margin = 70.0;
    final otherIndices = List.generate(
      widget.pageCount,
      (i) => i,
    )..remove(widget.currentIndex);

    final right = screen.width - centerX - margin;
    final left = centerX - margin;
    final bottom = screen.height - centerY - margin;
    final top = centerY - margin;

    // 找最大空间方向
    final dirs = [
      _DirInfo(0, right),
      _DirInfo(90, bottom),
      _DirInfo(180, left),
      _DirInfo(270, top),
    ];
    dirs.sort((a, b) => b.space.compareTo(a.space));
    final primaryAngle = dirs.first.angle;

    // 半径
    final maxR = [
      right, left, bottom, top, 120.0,
    ].reduce((a, b) => a < b ? a : b).clamp(55, 120);

    final n = otherIndices.length;
    final totalAngle = (n * 45).clamp(0, 200).toDouble();
    final startAngle = primaryAngle - totalAngle / 2 + 90;
    final step = n > 1 ? totalAngle / (n - 1) : 0.0;

    return List.generate(n, (i) {
      final angle = (startAngle + step * i) * math.pi / 180;
      return _MenuItemPos(
        index: otherIndices[i],
        dx: math.cos(angle) * maxR,
        dy: math.sin(angle) * maxR,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 初始位置：靠右偏下
        if (_position == Offset.zero) {
          _position = Offset(
            constraints.maxWidth - _orbSize - 24,
            constraints.maxHeight - 120,
          );
        }
        return _buildWidget(context, constraints);
      },
    );
  }

  Widget _buildWidget(BuildContext context, BoxConstraints constraints) {
    final screen = Size(constraints.maxWidth, constraints.maxHeight);

    return GestureDetector(
      onPanStart: (details) {
        _dragStart = details.localPosition;
        _isDragging = true;
        _dragMoved = false;
      },
      onPanUpdate: (details) {
        if (!_isDragging) return;
        _dragMoved = true;
        final margin = 60.0;
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
        _isDragging = false;
        if (!_dragMoved) _toggle();
      },
      onPanCancel: () {
        _isDragging = false;
      },
      child: SizedBox(
        width: _orbSize,
        height: _orbSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // === 主球 ===
            Positioned(
              left: 0,
              top: 0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                width: _orbSize,
                height: _orbSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isOpen
                      ? Colors.white.withValues(alpha: 0.75)
                      : Colors.white.withValues(alpha: 0.6),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFC896B4).withValues(alpha: _isOpen ? 0.2 : 0.12),
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

            // === 菜单项 ===
            ..._buildMenuItems(screen),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildMenuItems(Size screen) {
    if (!_isOpen && _animCtrl.isDismissed) return [];
    final positions = _calculatePositions(screen);

    return positions.map((pos) {
      final animValue = _menuAnim.value;
      final tx = pos.dx * animValue;
      final ty = pos.dy * animValue;
      final scale = 0.5 + animValue * 0.5;
      final opacity = animValue;

      return Positioned(
        left: _orbSize / 2 - _menuItemSize / 2,
        top: _orbSize / 2 - _menuItemSize / 2,
        child: Transform.translate(
          offset: Offset(tx, ty),
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity,
              child: GestureDetector(
                onTap: () => _selectPage(pos.index),
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
                      color: widget.pageColors[pos.index].withValues(alpha: 0.1),
                    ),
                    child: Icon(
                      widget.pageIcons[pos.index],
                      size: 16,
                      color: widget.pageColors[pos.index].withValues(alpha: 0.8),
                    ),
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

class _DirInfo {
  final double angle;
  final double space;
  _DirInfo(this.angle, this.space);
}
