/// Agent Debug Lab —— SharedPreferences 轨迹存储后端
///
/// app 启动时注入 TraceStore，让轨迹跨重启保留。
/// （debug_lab 保持零依赖，adapter 放 services 层）
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../butler/debug_lab/trace_store.dart';

/// SharedPreferences 后端（轨迹数据量小：摘要式 1-2KB × 50 条，够用）
class PrefsTraceStorage implements TraceStorage {
  final SharedPreferences prefs;

  PrefsTraceStorage(this.prefs);

  @override
  Future<bool> save(String key, String json) async {
    if (json.isEmpty) {
      // 空串 = 删除标记（TraceStore._trim 用）
      await prefs.remove(key);
      return true;
    }
    return prefs.setString(key, json);
  }

  @override
  Future<String?> load(String key) async => prefs.getString(key);

  @override
  Future<List<String>> keys() async =>
      prefs.getKeys().toList(growable: false);

  @override
  Future<String?> loadFixedPrompt() async =>
      prefs.getString('agent_trace_fixed_prompt');

  @override
  Future<bool> saveFixedPrompt(String value) async =>
      prefs.setString('agent_trace_fixed_prompt', value);
}
