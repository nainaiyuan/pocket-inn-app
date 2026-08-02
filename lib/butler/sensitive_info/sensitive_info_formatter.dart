import 'package:flutter/services.dart';

import 'sensitive_info_detector.dart';

/// 敏感信息输入拦截（用户 17:57：模块化，哪里需要往哪里搬）
///
/// 身份证/手机号/银行卡/邮箱/11 位以上长数字 → 直接不让输入，并提示。
///
/// 用法：TextField(inputFormatters: [SensitiveInfoFormatter(onBlocked: ...)])
class SensitiveInfoFormatter extends TextInputFormatter {
  /// 拦截回调：命中敏感格式时通知 UI（弹提示，让用户知道被拦了）
  final void Function(String name)? onBlocked;

  /// 提示节流：同一格式 1.5 秒内只提示一次（连续输入不会刷屏）
  static String? _lastHintName;
  static DateTime _lastHintAt = DateTime.fromMillisecondsSinceEpoch(0);

  const SensitiveInfoFormatter({this.onBlocked});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // 新输入里出现敏感格式 → 拒绝（保留旧值，输入不进去）
    if (newValue.text.isNotEmpty &&
        SensitiveInfoDetector.containsSensitive(newValue.text)) {
      final name = SensitiveInfoDetector.matchName(newValue.text) ?? '敏感信息';
      final now = DateTime.now();
      if (onBlocked != null &&
          (name != _lastHintName ||
              now.difference(_lastHintAt).inMilliseconds > 1500)) {
        _lastHintName = name;
        _lastHintAt = now;
        onBlocked!(name);
      }
      return oldValue;
    }
    return newValue;
  }
}
