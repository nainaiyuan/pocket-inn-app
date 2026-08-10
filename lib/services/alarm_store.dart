/// 定时任务存储（alarms）—— 8-10 用户：男主用工具写定时任务，
/// 本地自动保存，到点触发才提醒男主（插到当前流程步骤后面）。
///
/// 规则：
/// - 时间格式 HH:mm（24小时），date 空 = 每天重复，有 date（yyyy-MM-dd）= 一次性
/// - 到点触发（检查器每分钟查一次）→ 插入流程步骤 + 一次性任务标记 done
/// - 男主可写/查/删（manage_schedule 工具），不用审批（男主自管）
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 定时任务
class AlarmItem {
  AlarmItem({
    required this.id,
    required this.time,
    required this.text,
    this.date = '',
    this.done = false,
  });

  final int id;
  final String time; // HH:mm
  final String text; // 提醒内容
  final String date; // ''=每天重复；yyyy-MM-dd=一次性
  bool done; // 已触发（一次性任务用）

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time,
        'text': text,
        'date': date,
        'done': done,
      };

  factory AlarmItem.fromJson(Map<String, dynamic> j) => AlarmItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        time: j['time']?.toString() ?? '',
        text: j['text']?.toString() ?? '',
        date: j['date']?.toString() ?? '',
        done: j['done'] == true,
      );
}

/// 定时任务存储：SharedPreferences 持久化，单例
class AlarmStore {
  AlarmStore._();

  static final AlarmStore instance = AlarmStore._();

  static const _key = 'alarms_v1';

  List<AlarmItem>? _cache;

  Future<List<AlarmItem>> _load() async {
    if (_cache != null) return _cache!;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) {
      _cache = <AlarmItem>[];
      return _cache!;
    }
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => AlarmItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      _cache = list;
      return list;
    } catch (e) {
      _cache = <AlarmItem>[];
      return _cache!;
    }
  }

  Future<void> _save(List<AlarmItem> list) async {
    _cache = list;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  /// 全部未完成的定时任务（按时间排序）
  Future<List<AlarmItem>> pending() async {
    final list = await _load();
    list.sort((a, b) => a.time.compareTo(b.time));
    return list.where((e) => !e.done).toList();
  }

  /// 新增定时任务，返回新任务
  Future<AlarmItem> add(String time, String text, {String date = ''}) async {
    final list = await _load();
    final id = list.isEmpty
        ? 1
        : list.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;
    final item = AlarmItem(id: id, time: time, text: text, date: date);
    list.add(item);
    await _save(list);
    return item;
  }

  /// 删除定时任务
  Future<bool> delete(int id) async {
    final list = await _load();
    final before = list.length;
    list.removeWhere((e) => e.id == id);
    if (list.length == before) return false;
    await _save(list);
    return true;
  }

  /// 标记已触发（一次性任务）
  Future<void> markDone(int id) async {
    final list = await _load();
    for (final e in list) {
      if (e.id == id) e.done = true;
    }
    await _save(list);
  }
}
