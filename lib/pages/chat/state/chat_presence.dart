import 'package:flutter/foundation.dart';

/// 聊天拟人化状态中心 — "已读/未读/正在输入/时间戳"单独放一块，方便管理
///
/// 职责（模仿微信的聊天体验）：
/// 1. 消息时间戳：消息 id → 发送时间，气泡下方显示（今天 14:30 / 昨天 21:00 / 3月2日）
/// 2. 已读/未读：用户消息 → 男主是否已读（男主回复完成 = 全部已读）
/// 3. 正在输入：男主回复流式期间，顶部显示"正在输入…"
///
/// 用法：
/// - 加载历史消息时：`ChatPresence.instance.recordTimestamps(messages)`
/// - 用户发消息：`ChatPresence.instance.markUnread(id)`（可选，默认未读）
/// - 男主回复开始：`ChatPresence.instance.setTyping(true)`
/// - 男主回复完成：`ChatPresence.instance.setTyping(false); markAllRead()`
///
/// 是 ChangeNotifier，UI 用 ValueListenableBuilder / ListenableBuilder 监听。
class ChatPresence extends ChangeNotifier {
  ChatPresence._();

  static final ChatPresence instance = ChatPresence._();

  /// 消息 id → 发送时间
  final Map<String, DateTime> _timestamps = {};

  /// 用户消息 id → 男主是否已读（null = 非用户消息/未知）
  final Map<String, bool> _readState = {};

  /// 用户消息 id 集合（区分"男主已读用户消息"和"用户已读男主消息"两个方向）
  final Set<String> _userMsgIds = {};

  /// 男主是否正在输入
  bool _isTyping = false;

  /// 男主是否正在查看（已读但还没开始输入）
  bool _isViewing = false;

  bool get isTyping => _isTyping;
  bool get isViewing => _isViewing;

  /// 消息时间（无记录返回 null，UI 自动隐藏）
  DateTime? timestampOf(String? messageId) {
    if (messageId == null) return null;
    return _timestamps[messageId];
  }

  /// 已读状态（用户消息 = 男主是否已读；男主消息 = 用户是否已读）
  bool? isRead(String? messageId) {
    if (messageId == null) return null;
    return _readState[messageId];
  }

  /// 该消息是否是用户消息（决定已读标记的语义方向）
  bool isUserMessage(String? messageId) {
    if (messageId == null) return false;
    return _userMsgIds.contains(messageId);
  }

  /// 记录一批消息的时间戳（加载历史/发送完成后调用）
  /// [idOf] 取消息 id，[timeOf] 取消息时间
  void recordTimestamps(
    Iterable<dynamic> messages, {
    required String? Function(dynamic m) idOf,
    required DateTime? Function(dynamic m) timeOf,
  }) {
    var changed = false;
    for (final m in messages) {
      final id = idOf(m);
      final time = timeOf(m);
      if (id != null && time != null) {
        _timestamps[id] = time;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 记录一批时间戳（消息 id → 时间，数据库加载用）
  void recordTimestampsMap(Map<String, DateTime> timestamps) {
    if (timestamps.isEmpty) return;
    _timestamps.addAll(timestamps);
    notifyListeners();
  }

  /// 记录单条消息时间戳
  void recordTimestamp(String id, DateTime time) {
    _timestamps[id] = time;
    notifyListeners();
  }

  /// 标记消息未读（用户刚发出，男主还没看）
  void markUnread(String messageId) {
    _userMsgIds.add(messageId);
    _readState[messageId] = false;
    notifyListeners();
  }

  /// 标记男主消息未读（男主刚发出，用户还没看完）
  /// 8-03 18:2x：男主消息的已读 = 用户是否看完（打字机播完 = 已读）
  void markCharacterUnread(String messageId) {
    _readState[messageId] = false;
    notifyListeners();
  }

  /// 男主消息全部已读（用户浏览/历史加载后）
  void markAllCharacterRead() {
    var changed = false;
    for (final key in _readState.keys) {
      if (!_userMsgIds.contains(key) && _readState[key] == false) {
        _readState[key] = true;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 迁移已读状态：发送中的临时消息（pending_xxx）重载后变成真实消息，
  /// 把临时 id 的已读状态搬给真实 id
  void transferState(String fromId, String toId) {
    if (!_readState.containsKey(fromId)) return;
    _readState[toId] = _readState[fromId]!;
    _readState.remove(fromId);
    if (_userMsgIds.remove(fromId)) _userMsgIds.add(toId);
    notifyListeners();
  }

  /// 标记某条消息已读
  void markRead(String messageId) {
    _readState[messageId] = true;
    notifyListeners();
  }

  /// 全部已读（男主回复完成时调用）——只标用户消息。
  /// 8-03 18:2x：男主消息的已读只由"打字机播完"触发（用户看完），
  /// 不在这里批量覆盖（否则未读状态一闪而过）
  void markAllRead() {
    var changed = false;
    for (final key in _readState.keys) {
      if (_userMsgIds.contains(key) && _readState[key] == false) {
        _readState[key] = true;
        changed = true;
      }
    }
    _isViewing = false;
    if (changed) notifyListeners();
  }

  /// 男主开始回复：正在查看 → 正在输入
  void setTyping(bool typing) {
    final changed = _isTyping != typing;
    _isTyping = typing;
    if (typing) _isViewing = true;
    if (changed) notifyListeners();
  }

  /// 8-03 18:27（用户语义）："正在输出"只在男主打字时显示，
  /// 调工具/执行工具期间不显示。引用计数——
  /// 每轮生成（generateReply）前 begin，该轮文字播完（打字机 done）end；
  /// 工具轮之间不 begin → 工具阶段自动不显示
  int _typingRefs = 0;

  void beginTyping() {
    _typingRefs++;
    if (!_isTyping) {
      _isTyping = true;
      _isViewing = true;
      notifyListeners();
    }
  }

  void endTyping() {
    if (_typingRefs > 0) _typingRefs--;
    if (_typingRefs == 0 && _isTyping) {
      _isTyping = false;
      notifyListeners();
    }
  }

  /// 强制清零（整轮流程结束/异常兜底/切换角色）
  void resetTyping() {
    _typingRefs = 0;
    if (_isTyping) {
      _isTyping = false;
      notifyListeners();
    }
  }

  /// 男主开始看消息（还没输入）—— 预留：延迟模拟"先看到再打字"
  void setViewing(bool viewing) {
    final changed = _isViewing != viewing;
    _isViewing = viewing;
    if (changed) notifyListeners();
  }

  /// 清空所有状态（切换会话时调用）
  void reset() {
    _timestamps.clear();
    _readState.clear();
    _userMsgIds.clear();
    _isTyping = false;
    _isViewing = false;
    notifyListeners();
  }

  /// 微信风格时间格式化：
  /// - 今天：14:30
  /// - 昨天：昨天 21:00
  /// - 今年：3月2日 14:30
  /// - 更早：2025年12月1日 14:30
  static String formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thatDay = DateTime(time.year, time.month, time.day);
    final diffDays = today.difference(thatDay).inDays;

    final hm =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';

    if (diffDays <= 0) return hm;
    if (diffDays == 1) return '昨天 $hm';
    if (time.year == now.year) {
      return '${time.month}月${time.day}日 $hm';
    }
    return '${time.year}年${time.month}月${time.day}日 $hm';
  }
}
