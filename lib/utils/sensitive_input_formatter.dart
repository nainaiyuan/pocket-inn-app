import 'package:flutter/services.dart';

/// 敏感信息输入拦截 — 身份证/手机号/银行卡/邮箱格式直接不让输入
///
/// 用户（16:56）：各种地方（聊天输入、写记忆等）输入类似格式 → 直接阻止，
/// 省得用户往哪里把这些东西塞进去。
///
/// 用法：TextField(inputFormatters: [SensitiveInfoFormatter()])
/// 或黑名单模式：SensitiveInfoFormatter(blockList: true) 拦截所有命中格式
class SensitiveInfoFormatter extends TextInputFormatter {
  /// 身份证：17 位数字 + 数字/X
  static final RegExp _idCard = RegExp(r'\b\d{17}[\dXx]\b');

  /// 手机号：1 开头 11 位
  static final RegExp _phone = RegExp(r'\b1[3-9]\d{9}\b');

  /// 邮箱
  static final RegExp _email = RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b');

  /// 银行卡：16-19 位数字
  static final RegExp _bankCard = RegExp(r'\b\d{16,19}\b');

  static final List<RegExp> _patterns = [_idCard, _phone, _email, _bankCard];

  /// 命中的格式名（供 UI 提示）
  static String? matchName(String text) {
    if (_idCard.hasMatch(text)) return '身份证号';
    if (_phone.hasMatch(text)) return '手机号';
    if (_email.hasMatch(text)) return '邮箱';
    if (_bankCard.hasMatch(text)) return '银行卡号';
    return null;
  }

  /// 是否包含敏感格式
  static bool containsSensitive(String text) =>
      _patterns.any((p) => p.hasMatch(text));

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // 新输入里出现敏感格式 → 拒绝（保留旧值，输入不进去）
    if (newValue.text.isNotEmpty &&
        _patterns.any((p) => p.hasMatch(newValue.text))) {
      return oldValue;
    }
    return newValue;
  }
}
