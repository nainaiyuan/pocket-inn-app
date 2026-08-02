/// 敏感信息偏好存储（用户 17:57：发不发、记不记）
///
/// 弹窗里勾选"记住我的选择"后，格式 → 'send'（以后直接发送）/ 'block'（以后直接不发），
/// 同格式不再弹窗。
///
/// 独立于 RiskWordStore（敏感词偏好），按格式名存储，方便模块整体搬走。
library;

import 'package:shared_preferences/shared_preferences.dart';

class SensitiveInfoStore {
  SensitiveInfoStore._();
  static final SensitiveInfoStore instance = SensitiveInfoStore._();

  static const String _prefsKey = 'sensitive_format_prefs_v1';
  static const String prefSend = 'send';
  static const String prefBlock = 'block';

  Map<String, String>? _prefs;

  /// 缓存的格式偏好（格式名 → 'send'/'block'）
  Map<String, String> get cachedPrefs => _prefs ?? const {};

  Future<void> _load() async {
    if (_prefs != null) return;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _prefs = {};
    } else {
      try {
        _prefs = Map<String, String>.from(
          (raw.split('|').where((e) => e.contains('='))).fold(
                <String, String>{},
                (m, e) {
                  final kv = e.split('=');
                  m[kv[0]] = kv[1];
                  return m;
                },
              ),
        );
      } catch (_) {
        _prefs = {};
      }
    }
  }

  /// 读取格式偏好（格式名 → 'send'/'block'，未设置返回 null）
  Future<String?> getPref(String name) async {
    await _load();
    return _prefs?[name];
  }

  /// 设置格式偏好；传 null 清除
  Future<void> setPref(String name, String? value) async {
    await _load();
    final prefs = _prefs ??= {};
    if (value == null) {
      prefs.remove(name);
    } else {
      prefs[name] = value;
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _prefsKey,
      prefs.entries.map((e) => '${e.key}=${e.value}').join('|'),
    );
  }
}
