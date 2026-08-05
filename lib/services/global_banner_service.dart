import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart' show appNavigatorKey;

/// 📬 全局顶部横幅服务（8-06 00:31 用户：男主弹窗——APP 内、接近顶部、
/// 像小情侣消息轰炸一样一条条弹；APP 外系统通知之后再做）。
///
/// 用法：
///   GlobalBannerService.instance.showBurst(
///     title: '沈星回',
///     messages: ['在干嘛呀', '想你了', '回来聊聊天嘛'],
///     interval: const Duration(seconds: 15),
///     onTap: () => GlobalBannerService.instance.openChat(),
///   );
///
/// 实现：OverlayEntry 插在全局 navigator overlay 上 → 任何页面都能看到；
/// 队列逐条弹（上一条滑出后，间隔 interval 再弹下一条）。
class GlobalBannerService {
  GlobalBannerService._();
  static final GlobalBannerService instance = GlobalBannerService._();

  /// 跳回聊天页的回调（HomePage 注册：popUntil 回 home + 切聊天 tab）
  VoidCallback? onOpenChat;

  /// 用户当前是否在聊天页（HomePage 切 tab 时同步，notify_user 超时唤醒判断）
  bool userOnChat = false;

  /// 打开聊天页（横幅点击）
  void openChat() {
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    // 回到根路由（HomePage）再切聊天 tab；已在本页则无事发生
    nav.popUntil((r) => r.isFirst);
    onOpenChat?.call();
  }

  // ---- 队列 ----
  final List<_BannerTask> _queue = [];
  bool _showing = false;
  OverlayEntry? _current;
  Timer? _dismissTimer;
  Timer? _nextTimer;

  /// 弹一组消息（消息轰炸）：messages 逐条弹。
  /// [interval]：男主显式填的间隔（null = 用默认并随条数自适应——
  /// 8-06 00:40 用户：默认 4 秒；很多条时自动加速，别让人等太久）。
  /// [title] = 男主名字（横幅标题）；[onTap] = 点横幅（默认 openChat）。
  void showBurst({
    required String title,
    required List<String> messages,
    Duration? interval,
    VoidCallback? onTap,
  }) {
    final list = messages.where((m) => m.trim().isNotEmpty).toList();
    if (list.isEmpty) return;
    final n = list.length;
    // 自适应：默认间隔 4s；条数越多越快（N>5 后每多一条 -0.5s，下限 1s）
    final effInterval = interval ??
        Duration(
          milliseconds: (n <= 5 ? 4000 : (4000 - (n - 5) * 500)).clamp(1000, 4000),
        );
    // 展示时长同理：默认 6s，条数多时缩到最短 2s（快进，别堵在后面）
    final effDisplay = Duration(
      milliseconds: (n <= 5 ? 6000 : (6000 - (n - 5) * 500)).clamp(2000, 6000),
    );
    _queue.add(_BannerTask(
      title: title,
      messages: list,
      interval: effInterval,
      display: effDisplay,
      onTap: onTap ?? openChat,
    ));
    _drain();
  }

  /// 清空队列 + 关掉正在显示的横幅（用户回到聊天页时调用，别继续轰炸）
  void cancelAll() {
    _queue.clear();
    _nextTimer?.cancel();
    _dismissTimer?.cancel();
    _removeCurrent();
  }

  void _drain() {
    if (_showing || _queue.isEmpty) return;
    _showing = true;
    final task = _queue.removeAt(0);
    _playTask(task, 0);
  }

  void _playTask(_BannerTask task, int index) {
    if (index >= task.messages.length) {
      // 这一组弹完 → 下一组（间隔也遵守，别无缝衔接显得急）
      _nextTimer = Timer(task.interval, () {
        _showing = false;
        _drain();
      });
      return;
    }
    final text = task.messages[index];
    _showOne(task.title, text, task.onTap);
    // 停留展示时长后滑出 → 间隔 interval → 下一条（时长都按条数自适应过）
    _dismissTimer = Timer(task.display, () {
      _removeCurrent();
      _nextTimer = Timer(task.interval, () => _playTask(task, index + 1));
    });
  }

  // ---- 单条横幅 ----
  void _showOne(String title, String message, VoidCallback onTap) {
    _removeCurrent();
    final overlay = appNavigatorKey.currentState?.overlay;
    if (overlay == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _BannerWidget(
      title: title,
      message: message,
      onTap: () {
        _removeCurrent();
        onTap();
      },
    ));
    _current = entry;
    overlay.insert(entry);
  }

  void _removeCurrent() {
    _current?.remove();
    _current = null;
  }

  /// 当前有没有在弹（超时唤醒判断用）
  bool get isShowing => _showing || _current != null || _queue.isNotEmpty;
}

class _BannerTask {
  final String title;
  final List<String> messages;
  final Duration interval;
  final Duration display;
  final VoidCallback onTap;

  _BannerTask({
    required this.title,
    required this.messages,
    required this.interval,
    required this.display,
    required this.onTap,
  });
}

/// 横幅本体：顶部滑入的圆角卡片（男主头像圆 + 名字 + 气泡消息）
class _BannerWidget extends StatefulWidget {
  final String title;
  final String message;
  final VoidCallback onTap;

  const _BannerWidget({
    required this.title,
    required this.message,
    required this.onTap,
  });

  @override
  State<_BannerWidget> createState() => _BannerWidgetState();
}

class _BannerWidgetState extends State<_BannerWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..forward();
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1.4),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0, left: 12, right: 12,
      child: SafeArea(
        child: SlideTransition(
          position: _slide,
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFC896B4).withValues(alpha: 0.30),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: Border.all(
                  color: const Color(0xFFC896B4).withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 男主头像圆（暂用名字首字，后续接真实头像）
                  Container(
                    width: 38,
                    height: 38,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFFD9A0C0), Color(0xFFC896B4)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      widget.title.isEmpty ? '他' : widget.title.characters.first,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6A4A52),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.35,
                            color: Color(0xFF3A2E33),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 微信提醒式：右上角"现在"
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 6),
                    child: Text(
                      '现在',
                      style: TextStyle(
                        fontSize: 10,
                        color: const Color(0xFF8A7A80).withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
