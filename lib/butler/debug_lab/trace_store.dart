/// Agent Debug Lab —— 轨迹存储（TraceStore）
///
/// 内存缓存 + JSON 持久化（可注入存储后端，默认内存实现）。
/// 参考 AI 适配层解耦模式：`TraceStorage` 接口可注入，
/// app 里接 SharedPreferences / 文件，测试里接内存。
///
/// 纯 Dart，不依赖 Flutter。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'agent_run_trace.dart';

/// 存储后端接口（可注入）
abstract class TraceStorage {
  /// 保存一条轨迹，返回是否成功
  Future<bool> save(String key, String json);

  /// 读取一条轨迹，不存在返回 null
  Future<String?> load(String key);

  /// 列出所有 key（按时间倒序）
  Future<List<String>> keys();
}

/// 内存存储（默认，测试/回放用）
/// SharedPreferences 持久化后端（8-11 21:5x 用户：要在平板上看男主每轮
/// prompt 输入/输出 → 轨迹必须落盘，不能只有内存）
class SharedPrefsTraceStorage implements TraceStorage {
  @override
  Future<String?> load(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(key);
  }

  @override
  Future<bool> save(String key, String value) async {
    final p = await SharedPreferences.getInstance();
    return p.setString(key, value);
  }

  @override
  Future<List<String>> keys() async {
    final p = await SharedPreferences.getInstance();
    return p.getKeys().where((k) => k.startsWith('agent_trace_')).toList();
  }
}

class MemoryTraceStorage implements TraceStorage {
  final Map<String, String> _data = {};
  final List<String> _order = [];

  @override
  Future<bool> save(String key, String json) async {
    if (!_data.containsKey(key)) _order.add(key);
    _data[key] = json;
    return true;
  }

  @override
  Future<String?> load(String key) async => _data[key];

  @override
  Future<List<String>> keys() async =>
      _order.reversed.toList(growable: false);
}

/// 轨迹仓库（单例，可注入后端）
class TraceStore {
  static TraceStore? _instance;
  static TraceStore get instance => _instance ??= TraceStore._();

  /// 注入存储后端（app 启动时接持久化，测试接内存）
  static void configure(TraceStorage backend) {
    _instance = TraceStore._with(backend);
  }

  TraceStore._() : _storage = MemoryTraceStorage();
  TraceStore._with(this._storage);

  final TraceStorage _storage;

  static const String _prefix = 'agent_trace_';

  /// 每个 persona 保留的最大轨迹数（防膨胀）
  static const int maxPerPersona = 50;

  String _key(String personaId, String runId) =>
      '$_prefix${personaId}_$runId';

  /// 保存轨迹
  Future<void> save(AgentRunTrace trace) async {
    await _storage.save(
      _key(trace.personaId, trace.runId),
      jsonEncode(trace.toJson()),
    );
    await _trim(trace.personaId);
    _revisionController.add(trace.runId); // 通知 UI 自动刷新（8-11 22:2x）
  }

  /// 8-11 22:2x（用户：还要我自己刷新？直接一轮一轮记录自动更新）：
  /// 新轨迹落盘信号——UI 监听它自动重读，不需要手动刷新。
  static final StreamController<String> _revisionController =
      StreamController<String>.broadcast();
  static Stream<String> get revisionStream => _revisionController.stream;

  /// 读取单条
  Future<AgentRunTrace?> load(String personaId, String runId) async {
    final raw = await _storage.load(_key(personaId, runId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return AgentRunTrace.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 某 persona 最近 N 条（倒序：最新在前）
  Future<List<AgentRunTrace>> recent(
    String personaId, {
    int limit = 20,
  }) async {
    final keys = await _storage.keys();
    final mine = keys.where((k) => k.startsWith('$_prefix${personaId}_'));
    final out = <AgentRunTrace>[];
    for (final k in mine.take(limit)) {
      final raw = await _storage.load(k);
      if (raw == null || raw.isEmpty) continue;
      try {
        out.add(AgentRunTrace.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        ));
      } catch (_) {}
    }
    return out;
  }

  /// 全部 persona 最近 N 条（倒序：最新在前）—— Debug Lab 页用
  Future<List<AgentRunTrace>> all({int limit = 50}) async {
    final keys = await _storage.keys();
    final mine = keys.where((k) => k.startsWith(_prefix)).toList()..sort();
    final out = <AgentRunTrace>[];
    for (final k in mine.reversed.take(limit)) {
      final raw = await _storage.load(k);
      if (raw == null || raw.isEmpty) continue;
      try {
        out.add(AgentRunTrace.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        ));
      } catch (_) {}
    }
    return out;
  }

  /// 清理超出上限的旧轨迹
  Future<void> _trim(String personaId) async {
    final keys = await _storage.keys();
    final mine = keys.where((k) => k.startsWith('$_prefix${personaId}_'));
    if (mine.length <= maxPerPersona) return;
    // 倒序 = 最新在前，跳过前 maxPerPersona 条删旧的
    final toDelete = mine.skip(maxPerPersona).toList();
    for (final k in toDelete) {
      await _storage.save(k, ''); // 置空标记（接口无 delete，兼容简单后端）
    }
  }
}
