import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/debug_logger.dart';

/// 📋 卡片任务模型 + 存储（8-06 13:45-13:53 用户：任务系统 v2）
///
/// 计时/互动卡片结束或完成后 → 变成一条任务记录：
/// - 发起者（哪个 AI/角色）+ 分类（AI 自己写：查岗/约定/问答…）
/// - 状态：active 进行中 / done 已完成 / cancelled 已撤销
/// - 卡片与任务列表共享同一数据源 → 天然双向同步
class CardTask {
  final String id;
  String initiator; // 发起者（哪个 AI/角色），如「沈星回」
  String category; // 分类（AI 写），如「查岗」「约定」「问答」
  String title; // 卡面内容（AI 自由编辑）
  int? minutes; // 倒计时分钟（null = 纯选择卡片无倒计时）
  List<Map<String, dynamic>> options; // 选项（label/action/minutes）
  bool allowRequest; // 是否开放「申请调整」入口（男主判断给不给）
  String status; // active / done / cancelled
  DateTime createdAt;
  DateTime? endAt; // 倒计时结束时间
  String? result; // 用户最终选择/结果
  String? requestReason; // 用户申请调整的理由

  CardTask({
    required this.id,
    required this.initiator,
    required this.category,
    required this.title,
    this.minutes,
    this.options = const [],
    this.allowRequest = false,
    this.status = 'active',
    required this.createdAt,
    this.endAt,
    this.result,
    this.requestReason,
  });

  bool get isActive => status == 'active';
  bool get isDone => status == 'done';
  bool get isCancelled => status == 'cancelled';

  /// 是否已到期（有倒计时且过了结束时间且还 active）
  bool get isExpired {
    if (endAt == null || status != 'active') return false;
    return DateTime.now().isAfter(endAt!);
  }

  /// 剩余秒数（active 且有倒计时）
  int get remainingSeconds {
    if (endAt == null || status != 'active') return 0;
    final s = endAt!.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'initiator': initiator,
        'category': category,
        'title': title,
        'minutes': minutes,
        'options': options,
        'allowRequest': allowRequest,
        'status': status,
        'createdAt': createdAt.toIso8601String(),
        'endAt': endAt?.toIso8601String(),
        'result': result,
        'requestReason': requestReason,
      };

  factory CardTask.fromJson(Map<String, dynamic> j) => CardTask(
        id: j['id']?.toString() ?? '',
        initiator: j['initiator']?.toString() ?? '',
        category: j['category']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        minutes: (j['minutes'] as num?)?.toInt(),
        options: (j['options'] as List?)?.cast<Map<String, dynamic>>() ?? const [],
        allowRequest: j['allowRequest'] == true,
        status: j['status']?.toString() ?? 'active',
        createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        endAt: j['endAt'] != null ? DateTime.tryParse(j['endAt'].toString()) : null,
        result: j['result']?.toString(),
        requestReason: j['requestReason']?.toString(),
      );
}

/// 任务存储：SharedPreferences 持久化，单例
class CardTaskStore {
  CardTaskStore._();
  static final CardTaskStore instance = CardTaskStore._();

  static const _key = 'card_tasks_v1';
  List<CardTask> _tasks = [];
  bool _loaded = false;

  List<CardTask> get tasks => List.unmodifiable(_tasks);

  Future<void> _ensure() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        _tasks = (jsonDecode(raw) as List)
            .map((e) => CardTask.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        _tasks = [];
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(_tasks.map((t) => t.toJson()).toList()));
  }

  Future<List<CardTask>> load() async {
    await _ensure();
    return List.unmodifiable(_tasks);
  }

  Future<CardTask?> byId(String id) async {
    await _ensure();
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> add(CardTask task) async {
    await _ensure();
    _tasks.insert(0, task);
    await _persist();
    DebugLogger.log('任务', '📇 新增「${task.title}」（${task.status}）');
  }

  Future<void> update(String id, void Function(CardTask) mutate) async {
    await _ensure();
    for (final t in _tasks) {
      if (t.id == id) {
        mutate(t);
        break;
      }
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    await _ensure();
    _tasks.removeWhere((t) => t.id == id);
    await _persist();
    DebugLogger.log('任务', '🗑 删除任务 $id');
  }

  Future<void> removeDone() async {
    await _ensure();
    _tasks.removeWhere((t) => t.status != 'active');
    await _persist();
    DebugLogger.log('任务', '🧹 清理已完成任务');
  }

  static String newId() => 'task_${DateTime.now().microsecondsSinceEpoch}';
}
