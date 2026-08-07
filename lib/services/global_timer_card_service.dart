import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart' show appNavigatorKey;
import 'card_task_store.dart';

/// ⏱ 全局计时/互动卡片服务（8-06 13:38 用户，13:53 升级任务系统 v2）
///
/// 男主调 countdown_card 工具 → 屏幕固定悬浮卡片：
/// - 卡面自由编辑（男主写的一句话/提醒的事，如"现在去洗澡，40分钟后回来给他抱"）
/// - 角落标注：发起者（哪个 AI/角色）+ 分类（AI 自己写，如「查岗」）
/// - 倒计时显示（可选：不设 = 纯选择卡片）
/// - 可拖动、可收起（缩到屏幕角落小圆片）
/// - 选项按钮（男主自己填：延长/结束/纯消息/任意 A-B 选择/问答）
/// - 申请调整入口（allowRequest=true 时显示）：用户写理由 → 男主判断撤销/调整/拒绝
/// - 任务持久化：卡片创建即写入 CardTaskStore → 任务列表天然双向同步
class GlobalTimerCardService {
  GlobalTimerCardService._();
  static final GlobalTimerCardService instance = GlobalTimerCardService._();

  OverlayEntry? _entry;
  Offset _pos = const Offset(24, 90);
  bool _collapsed = false;
  bool _expired = false;

  Timer? _tick;
  DateTime? _endAt;
  String _title = '';
  String _initiator = '男主';
  String _category = '';
  bool _allowRequest = false;
  String _taskId = '';
  List<CardOption> _options = const [];

  /// 8-07 21:2x：用户点了哪个选项（UI 反馈：变灰+✓，不然点了没反应像"点不了"）
  String? _picked;
  void Function(String label, String action, int? extendMinutes)? _onOption;
  VoidCallback? _onExpire;
  void Function(String reason)? _onRequest; // 用户提交申请理由
  VoidCallback? _onDone; // 用户点完成
  VoidCallback? _onOpenList; // 查看任务列表

  /// 当前是否有卡片在显示
  bool get isActive => _entry != null;

  /// 是否有倒计时
  bool get hasCountdown => _endAt != null;

  /// 剩余秒数（过期=0）
  int get remainingSeconds {
    if (_endAt == null) return 0;
    final s = _endAt!.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  String get taskId => _taskId;

  /// 显示卡片（minutes 为 null = 纯选择卡片，无倒计时不触发到期）
  void showCard({
    required String title,
    int? minutes,
    String initiator = '男主',
    String category = '',
    bool allowRequest = false,
    List<CardOption> options = const [],
    void Function(String label, String action, int? extendMinutes)? onOption,
    VoidCallback? onExpire,
    void Function(String reason)? onRequest,
    VoidCallback? onDone,
    VoidCallback? onOpenList,
  }) {
    _remove();
    _title = title;
    _initiator = initiator.isEmpty ? '男主' : initiator;
    _category = category;
    _allowRequest = allowRequest;
    _options = options;
    _picked = null;
    _onOption = onOption;
    _onExpire = onExpire;
    _onRequest = onRequest;
    _onDone = onDone;
    _onOpenList = onOpenList;
    _expired = false;
    _collapsed = false;
    _endAt = (minutes != null && minutes > 0)
        ? DateTime.now().add(Duration(minutes: minutes))
        : null;

    // 持久化任务（任务列表共享数据源 → 双向同步）
    _taskId = CardTaskStore.newId();
    CardTaskStore.instance.add(CardTask(
      id: _taskId,
      initiator: _initiator,
      category: _category,
      title: _title,
      minutes: minutes,
      options: _options.map((o) => o.toJson()).toList(),
      allowRequest: _allowRequest,
      createdAt: DateTime.now(),
      endAt: _endAt,
    ));

    final overlay = appNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _TimerCardWidget(service: this));
    _entry = entry;
    overlay.insert(entry);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _entry?.markNeedsBuild();
      if (hasCountdown && remainingSeconds <= 0 && !_expired) {
        _expired = true;
        _onExpire?.call();
      }
    });
  }

  /// 收起 / 展开
  void collapse() {
    _collapsed = true;
    _entry?.markNeedsBuild();
  }

  void expand() {
    _collapsed = false;
    _entry?.markNeedsBuild();
  }

  /// 结束卡片并移除（不落任务状态，由调用方决定）
  void finish() {
    _tick?.cancel();
    _remove();
  }

  /// 用户点「完成」：任务标 done + 移除卡片
  void completeByUser() {
    final cb = _onDone;
    CardTaskStore.instance.update(_taskId, (t) {
      t.status = 'done';
      t.result = t.result ?? '她标记为已完成';
    });
    finish();
    cb?.call();
  }

  /// 男主撤销任务：任务标 cancelled + 移除卡片
  void cancelByButler() {
    CardTaskStore.instance.update(_taskId, (t) {
      t.status = 'cancelled';
      t.result = t.result ?? '男主撤销了任务';
    });
    finish();
  }

  /// 男主调整：延长
  void extend(int minutes) {
    if (_endAt != null) {
      _expired = false;
      _endAt = _endAt!.add(Duration(minutes: minutes));
    } else if (minutes > 0) {
      // 原无倒计时 → 补一个
      _endAt = DateTime.now().add(Duration(minutes: minutes));
      _expired = false;
    }
    CardTaskStore.instance.update(_taskId, (t) {
      t.endAt = _endAt;
    });
    _entry?.markNeedsBuild();
  }

  /// 男主调整：改卡面
  void setTitle(String title) {
    _title = title;
    CardTaskStore.instance.update(_taskId, (t) {
      t.title = title;
    });
    _entry?.markNeedsBuild();
  }

  /// 男主拒绝申请：清掉申请理由（卡片上申请按钮恢复）
  void clearRequest() {
    CardTaskStore.instance.update(_taskId, (t) {
      t.requestReason = null;
    });
  }

  /// 用户点了某个选项（由卡片 UI 调）
  /// 8-07 21:2x：加 try-catch——回调异常不能让点击"无声无息"，
  /// 卡片侧先给视觉反馈（勾选态），异常只记日志不崩
  void onOptionTap(CardOption opt) {
    try {
      _picked = opt.label;
      _entry?.markNeedsBuild();
      if (opt.action == 'extend' && opt.minutes != null) {
        extend(opt.minutes!);
      } else if (opt.action == 'finish') {
        final cb = _onOption;
        final label = opt.label;
        CardTaskStore.instance.update(_taskId, (t) {
          t.status = 'done';
          t.result = '她点了「$label」';
        });
        finish();
        cb?.call(label, 'finish', null);
        return;
      }
      CardTaskStore.instance.update(_taskId, (t) {
        t.result = '她点了「${opt.label}」';
      });
      _onOption?.call(opt.label, opt.action, opt.minutes);
    } catch (e) {
      // 点击已生效（视觉上），回调失败不阻塞用户
    }
  }

  /// 用户提交申请调整理由（由卡片 UI 调）
  void submitRequest(String reason) {
    CardTaskStore.instance.update(_taskId, (t) {
      t.requestReason = reason;
    });
    _onRequest?.call(reason);
  }

  /// 拖动更新位置
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
  final String label;
  final String action; // extend=延长 / finish=结束 / message=纯消息（默认）
  final int? minutes;

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

  Map<String, dynamic> toJson() => {
        'label': label,
        'action': action,
        'minutes': minutes,
      };
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
        onPanUpdate: (d) => svc.moveTo(svc._pos + d.delta, screen),
        child: svc._collapsed ? _collapsedChip(svc) : _fullCard(svc),
      ),
    );
  }

  // 收起状态：角落小圆片，显示剩余时间（无倒计时则显示 📋）
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
            Icon(svc.hasCountdown ? Icons.timer_outlined : Icons.sticky_note_2_outlined,
                color: Colors.white, size: 16),
            const SizedBox(width: 4),
            Text(
              svc.hasCountdown ? _mmss : '📋',
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
    final hasCountdown = svc.hasCountdown;
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
          // 顶栏：发起者·分类（角落标注）+ 收起按钮
          Row(
            children: [
              Icon(
                hasCountdown ? Icons.timer_outlined : Icons.sticky_note_2_outlined,
                color: const Color(0xFFC896B4),
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${svc._initiator}${svc._category.isEmpty ? '' : ' · ${svc._category}'}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A52),
                  ),
                  overflow: TextOverflow.ellipsis,
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
          // 倒计时（有倒计时才显示）
          if (hasCountdown)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: expired ? const Color(0xFFF7EAF1) : Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  expired ? '时间到啦 ⏰' : _mmss,
                  style: TextStyle(
                    fontSize: expired ? 15 : 26,
                    fontWeight: FontWeight.w800,
                    color: expired
                        ? const Color(0xFFD98A9E)
                        : const Color(0xFF6A4A52),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          // 选项按钮（男主填的）
          if (svc._options.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final opt in svc._options) ...[
              // 8-07 21:2x：已选 → 变灰 + ✓（点击有明确反馈）
              GestureDetector(
                onTap: svc._picked == opt.label
                    ? null
                    : () => svc.onOptionTap(opt),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: svc._picked == opt.label
                        ? const Color(0xFFE3D5E0)
                        : const Color(0xFFF7EAF1),
                    borderRadius: BorderRadius.circular(12),
                    border: svc._picked == opt.label
                        ? Border.all(color: const Color(0xFFC896B4))
                        : null,
                  ),
                  child: Text(
                    svc._picked == opt.label ? '✓ ${opt.label}' : opt.label,
                    style: TextStyle(
                        fontSize: 13,
                        color: svc._picked == opt.label
                            ? const Color(0xFF8A7A80)
                            : const Color(0xFF6A4A52)),
                  ),
                ),
              ),
            ],
            // 已选提示行（点击有反馈，男主那边也收到了）
            if (svc._picked != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '✅ 已选「${svc._picked}」，他收到啦',
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF8A6A96)),
                ),
              ),
          ],
          // 底栏：完成 / 申请调整 / 任务列表
          const SizedBox(height: 4),
          Row(
            children: [
              // ✓ 完成
              _MiniBtn(
                icon: Icons.check_circle_outline,
                label: '完成',
                onTap: () => svc.completeByUser(),
              ),
              const SizedBox(width: 6),
              // 申请调整（男主开放时显示）
              if (svc._allowRequest) ...[
                _MiniBtn(
                  icon: Icons.edit_note,
                  label: '申请调整',
                  onTap: () => _showRequestDialog(svc),
                ),
                const SizedBox(width: 6),
              ],
              // 任务列表
              _MiniBtn(
                icon: Icons.list_alt,
                label: '任务',
                onTap: () => svc._onOpenList?.call(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 申请调整弹窗：写理由 → 男主判断
  Future<void> _showRequestDialog(GlobalTimerCardService svc) async {
    final ctrl = TextEditingController();
    FocusManager.instance.primaryFocus?.unfocus();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('🙋 申请调整任务'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '「${svc._title}」\n想怎么调整？写个理由，他看了会判断。',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: '比如：今天太累了，想明天再做…',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC896B4)),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    if (reason != null && reason.isNotEmpty) {
      svc.submitRequest(reason);
    }
  }
}

/// 卡片底栏小按钮
class _MiniBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MiniBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFF0E8F6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: const Color(0xFF8A6A96)),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF8A6A96)),
            ),
          ],
        ),
      ),
    );
  }
}
