import 'package:flutter/material.dart';

/// 陪伴三页 —— 左「他」/ 中「我们」/ 右「你」
///
/// 8-05 23:36 用户：基于手势测试页（三页连续空间 v8）搭骨架，
/// 延续聊天页粉系风格，内容先占位，后续优化加东西。
/// 手势逻辑完全沿用（拖拽 / 锁定 / 动画 / physics 实时推算）。
class CompanionPage extends StatefulWidget {
  /// 8-05 23:45：设定右页入口（聊天页 onMenuTap 被设计感按钮顶替后，
  /// 从这里的小齿轮回到聊天页并打开设定右页）。
  final VoidCallback? onOpenSettings;

  const CompanionPage({super.key, this.onOpenSettings});
  @override
  State<CompanionPage> createState() => _CompanionPageState();
}

enum Panel { left, center, right }

class _CompanionPageState extends State<CompanionPage>
    with SingleTickerProviderStateMixin {
  static const double _sideFrac = 0.65;
  static const double _snapThr = 0.30;
  static const double _lockThr = 8.0;
  static const double _closeFactor = 2.5;

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
    setState(() {}); // 刷新 physics
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointerId) return;

    final dx = e.position.dx - _startX;
    final dy = e.position.dy - _startY;

    if (!_horizLocked) {
      if (dx.abs() < _lockThr && dy.abs() < _lockThr) return;
      _horizLocked = dx.abs() > dy.abs() * 1.3;
      if (!_horizLocked) {
        // ★ 垂直锁定：刷新 physics（实时推算不依赖变量，但需触发 build）
        setState(() {});
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

    if (!_dragging) { _horizLocked = false; setState(() {}); return; }

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

  // ---- 实时推算当前触摸点落在哪页 ----
  int _calcScrollPage() {
    // 无触控时，按 currentPanel 决定
    if (_pointerId < 0) {
      switch (_currentPanel) {
        case Panel.left:   return 0;
        case Panel.right:  return 2;
        case Panel.center: return 1;
      }
    }
    return _calcScrollPageByPos(_startX);
  }

  int _calcScrollPageByPos(double tapX) {
    if (_offset > 0 && tapX < _offset) return 0;
    if (_offset < 0 && tapX > MediaQuery.of(context).size.width + _offset) return 2;
    return 1;
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final side = screenW * _sideFrac;

    return Material(
      color: const Color(0xFFFDF7F9),
      child: SizedBox.expand(
        child: Stack(
          children: [
            _pageWidget(
              0, _offset - side, side,
              '他', Icons.person_outline,
              const [
                ('💭', '他今天的状态', '安静地等着你'),
                ('🎵', '他喜欢的事', '还没聊到'),
                ('📌', '他记得的事', '你们的故事会记在这里'),
                ('🍵', '小习惯', '慢慢发现中'),
              ],
            ),
            _pageWidget(
              1, _offset, screenW,
              '我们', Icons.favorite_outline,
              const [
                ('💞', '亲密度', '正在慢慢熟悉'),
                ('📖', '回忆', '第一次聊天，就在这里'),
                ('🔗', '你们的规律', '聊得多了才会显现'),
              ],
            ),
            _pageWidget(
              2, screenW + _offset, side,
              '你', Icons.self_improvement,
              const [
                ('🌤', '你的心情', '情绪会记在这里'),
                ('💡', '你在意的事', '从聊天里慢慢懂你'),
                ('📝', '你的喜好', '还没有记录'),
              ],
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

  Widget _pageWidget(
    int index,
    double left,
    double width,
    String title,
    IconData icon,
    List<(String, String, String)> cards,
  ) {
    // ★ 实时推算，不依赖变量
    final isActive = _calcScrollPage() == index;
    final isCenter = index == 1;
    return Positioned(
      left: left, top: 0,
      width: width, bottom: 0,
      child: Container(
        color: isCenter
            ? const Color(0xFFFDF7F9)
            : (index == 0
                ? const Color(0xFFF7EAF1) // 左·粉
                : const Color(0xFFF0E8F6)), // 右·浅紫
        child: Stack(
          children: [
            // 页面标题
            Positioned(
              top: MediaQuery.of(context).padding.top + 48,
              left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: const Color(0xFFC896B4).withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 16, color: const Color(0xFFC896B4)),
                      const SizedBox(width: 6),
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6A4A52),
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 中页右上角：设计感按钮（✦ 渐变圆钮）→ 回聊天页；
            // 旁边小齿轮 → 回聊天页并打开设定右页（原三个点的功能）
            if (isCenter) ...[
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 16,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFD9A0C0), Color(0xFFC896B4)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFC896B4).withValues(alpha: 0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.auto_awesome,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              if (widget.onOpenSettings != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  right: 68,
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).maybePop();
                      widget.onOpenSettings!();
                    },
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFC896B4).withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Icon(
                        Icons.settings_outlined,
                        size: 18,
                        color: Color(0xFF8A7A80),
                      ),
                    ),
                  ),
                ),
            ],

            // 卡片列表
            Positioned(
              top: MediaQuery.of(context).padding.top + 110,
              left: 0, right: 0, bottom: 0,
              child: ListView.builder(
                physics: isActive
                    ? const AlwaysScrollableScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: cards.length,
                itemBuilder: (_, i) {
                  final (emoji, name, hint) = cards[i];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFC896B4).withValues(alpha: 0.15),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF5A4A52),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hint,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: const Color(0xFF8A7A80)
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
