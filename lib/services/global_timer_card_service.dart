import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart' show appNavigatorKey;

/// ⏱ 全局计时卡片服务（8-06 13:38 用户）
///
/// 男主调 countdown_card 工具 → 屏幕固定悬浮卡片：
/// - 卡面自由编辑（男主写的一句话/提醒的事，如"现在去洗澡，40分钟后回来"）
/// - 倒计时显示（mm:ss）
/// - 可拖动（按住卡片移动）、可收起（缩到屏幕角落小圆片，点一下展开）
/// - 选项按钮（男主自己填，如「再给我五分钟」「已经洗好了」）
///   - action=extend：点了一下自动延长 N 分钟
///   - action=finish：点了一下结束卡片
///   - action=message：纯消息，结果回给男主
/// - 到期 → 回调 [onExpire]（chat_page 里决定要不要弹窗问用户/多久唤醒男主）
class GlobalTimerCardService {
  GlobalTimerCardService._();
  static final GlobalTimerCardService instance = GlobalTimerCardService._();

  OverlayEntry? _entry;
  Offset _pos = const Offset(24, 90); // 初始：左上角偏下
  bool _collapsed = false;
  bool _expired = false;

  Timer? _tick;
  DateTime? _endAt;
  String _title = '';
  List<CardOption> _options = const [];
  void Function(String label, String action, int? extendMinutes)? _onOption;
  VoidCallback? _onExpire;

  /// 当前是否有卡片在显示
  bool get isActive => _entry != null;

  /// 剩余秒数（过期=0）
  int get remainingSeconds {
    if (_endAt == null) return 0;
    final s = _endAt!.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  /// 显示计时卡片
  void showCard({
    required String title,
    required int minutes,
    List<CardOption> options = const [],
    void Function(String label, String action, int? extendMinutes)? onOption,
    VoidCallback? onExpire,
  }) {
    _remove();
    _title = title;
    _options = options;
    _onOption = onOption;
    _onExpire = onExpire;
    _expired = false;
    _collapsed = false;
    _endAt = DateTime.now().add(Duration(minutes: minutes));
    final overlay = appNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _TimerCardWidget(service: this));
    _entry = entry;
    overlay.insert(entry);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _entry?.markNeedsBuild();
      if (remainingSeconds <= 0 && !_expired) {
        _expired = true;
        _onExpire?.call();
      }
    });
  }

  /// 收起（缩到角落小圆片）
  void collapse() {
    _collapsed = true;
    _entry?.markNeedsBuild();
  }

  /// 展开
  void expand() {
    _collapsed = false;
    _entry?.markNeedsBuild();
  }

  /// 结束卡片（移除）
  void finish({String? reason}) {
    _tick?.cancel();
    _remove();
    _onOption = null;
    _onExpire = null;
  }

  /// 延长倒计时
  void extend(int minutes) {
    if (_endAt == null) return;
    _expired = false;
    _endAt = _endAt!.add(Duration(minutes: minutes));
    _entry?.markNeedsBuild();
  }

  /// 用户点了某个选项（由卡片 UI 调）
  void onOptionTap(CardOption opt) {
    if (opt.action == 'extend' && opt.minutes != null) {
      extend(opt.minutes!);
    } else if (opt.action == 'finish') {
      final cb = _onOption;
      final label = opt.label;
      finish();
      cb?.call(label, 'finish', null);
      return;
    }
    _onOption?.call(opt.label, opt.action, opt.minutes);
  }

  /// 拖动更新位置（由卡片 UI 调，clamp 在屏幕内）
  void moveTo(Offset pos, Size screen) {
    _pos = Offset(
      pos.dx.clamp(0, screen.width - 160),
      pos.dy.clamp(0, screen.height - 80),
    );
    _entry?.markNeedsBuild();
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }
}

/// 卡片选项（男主在 countdown_card 里填）
class CardOption {
  final String label; // 选项文字，如「再给我五分钟」
  final String action; // extend=延长 / finish=结束 / message=纯消息
  final int? minutes; // action=extend 时的延长分钟数

  const CardOption({
    required this.label,
    this.action = 'message',
    this.minutes,
  });

  factory CardOption.fromJson(Map<String, dynamic> json) {
    return CardOption(
      label: json['label']?.toString() ?? '选项',
      action: json['action']?.toString() ?? 'message',
      minutes: (json['minutes'] as num?)?.toInt(),
    );
  }
}

/// 悬浮卡片本体
class _TimerCardWidget extends StatefulWidget {
  final GlobalTimerCardService service;
  const _TimerCardWidget({required this.service});

  @override
  State<_TimerCardWidget> createState() => _TimerCardWidgetState();
}

class _TimerCardWidgetState extends State<_TimerCardWidget> {
  String get _mmss {
    final s = widget.service.remainingSeconds;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.service;
    final screen = MediaQuery.of(context).size;
    return Positioned(
      left: svc._pos.dx,
      top: svc._pos.dy,
      child: GestureDetector(
        // 按住卡片可拖动
        onPanUpdate: (d) => svc.moveTo(
            svc._pos + d.delta, screen),
        child: svc._collapsed
            ? _collapsedChip(svc)
            : _fullCard(svc),
      ),
    );
  }

  // 收起状态：角落小圆片，只显示剩余时间
  Widget _collapsedChip(GlobalTimerCardService svc) {
    return GestureDetector(
      onTap: svc.expand,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFC896B4),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFC896B4).withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer_outlined, color: Colors.white, size: 16),
            const SizedBox(width: 4),
            Text(
              _mmss,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 展开状态：完整卡片
  Widget _fullCard(GlobalTimerCardService svc) {
    final expired = svc._expired;
    return Container(
      width: 230,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF7F9),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: (expired ? const Color(0xFFE8A0B8) : const Color(0xFFC896B4))
              .withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFC896B4).withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶栏：男主名 + 收起按钮
          Row(
            children: [
              const Icon(Icons.timer_outlined,
                  color: Color(0xFFC896B4), size: 16),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '男主',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A52),
                  ),
                ),
              ),
              GestureDetector(
                onTap: svc.collapse,
                child: const Icon(Icons.remove_circle_outline,
                    color: Color(0xFF8A7A80), size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 卡面内容（男主自由编辑的话）
          Text(
            svc._title,
            style: const TextStyle(fontSize: 14, height: 1.4, color: Color(0xFF3A2E33)),
          ),
          const SizedBox(height: 10),
          // 倒计时
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: expired
                  ? const Color(0xFFF7EAF1)
                  : Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                expired ? '时间到啦 ⏰' : _mmss,
                style: TextStyle(
                  fontSize: expired ? 15 : 26,
                  fontWeight: FontWeight.w800,
                  color: expired ? const Color(0xFFD98A9E) : const Color(0xFF6A4A52),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          // 选项按钮（男主填的）
          if (svc._options.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final opt in svc._options) ...[
              GestureDetector(
                onTap: () => svc.onOptionTap(opt),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7EAF1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    opt.label,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF6A4A52)),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
