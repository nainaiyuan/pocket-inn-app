/// AI 模块键值存储接口（2026-08-04 解耦：持久化可替换）。
///
/// 探测缓存（CapabilityCache）通过本接口读写，不直接依赖
/// shared_preferences：
/// - 默认实现 [SharedPrefsAiStore]（Flutter 通用插件，开箱即用）
/// - 未来搬到纯 Dart 服务端/其他框架时，注入自己的实现
///   （文件 / Memory / Redis…），模块逻辑零改动。
library;

import 'package:shared_preferences/shared_preferences.dart';

abstract class AiKeyValueStore {
  Future<String?> getString(String key);

  Future<void> setString(String key, String value);
}

/// shared_preferences 实现（默认）。
class SharedPrefsAiStore implements AiKeyValueStore {
  const SharedPrefsAiStore();

  @override
  Future<String?> getString(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }
}
