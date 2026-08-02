/// 敏感信息格式检测模块（用户 17:57：专门弄一个模块，以后哪里需要往哪里搬）
///
/// 职责：识别疑似敏感信息格式（手机号/身份证/银行卡/长数字串/邮箱），
/// 提供检测、挖空、输入拦截统一入口。
///
/// 规则设计（用户 17:57）：
/// - 不只标准手机号——"只要弄到了什么类似的格式"（11 位数字等）都算疑似
/// - 检测到 → 发送前弹窗问"发不发、记不记"
///
/// 用法：
/// - 发送前检测：SensitiveInfoDetector.detect(text) → 命中格式名列表
/// - 挖空：SensitiveInfoDetector.mask(text) → (挖空后文本, 命中格式名)
/// - 输入拦截：SensitiveInfoDetector.containsSensitive(text)
library;

/// 敏感格式规则（高优先级先检测，检测后挖掉，避免低优先级重复命中）
class SensitiveFormatRule {
  final String name; // 展示名（弹窗/提示用）
  final String hint; // 提示语（"疑似敏感信息"）
  final String pattern; // 正则源文本（使用时 RegExp(pattern)）
  final bool highPriority; // true=先检测并挖掉，避免被"疑似长数字"重复命中

  const SensitiveFormatRule({
    required this.name,
    required this.hint,
    required this.pattern,
    this.highPriority = false,
  });
}

/// 隐私挖空标记（与敏感词共用）
const String privacyMark = '[PRIVACY_MARK]';

class SensitiveInfoDetector {
  /// 规则表（顺序=优先级）：
  /// 1. 手机号：1[3-9] 开头 11 位（标准）
  /// 2. 身份证（含 X 尾号）：17 位数字 + 数字/X
  /// 3. 邮箱
  /// 4. 疑似长数字串：11-19 位连续数字（覆盖银行卡、11 位数字、
  ///    身份证数字部分等"类似格式"——用户 17:57：都要弹窗确认）
  static const List<SensitiveFormatRule> rules = [
    SensitiveFormatRule(
      name: '手机号',
      hint: '疑似手机号',
      pattern: r'\b1[3-9]\d{9}\b',
      highPriority: true,
    ),
    SensitiveFormatRule(
      name: '身份证号',
      hint: '疑似身份证号',
      pattern: r'\b\d{17}[\dXx]\b',
      highPriority: true,
    ),
    SensitiveFormatRule(
      name: '邮箱',
      hint: '疑似邮箱',
      pattern: r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b',
      highPriority: true,
    ),
    SensitiveFormatRule(
      name: '疑似长数字',
      hint: '疑似敏感信息（长数字）',
      pattern: r'\b\d{11,19}\b',
    ),
  ];

  /// 检测命中哪些格式（高优先级规则先挖掉，避免重复命中）
  static List<String> detect(String text) {
    if (text.isEmpty) return const [];
    final matched = <String>{};
    var work = text;
    for (final rule in rules) {
      final re = RegExp(rule.pattern);
      if (re.hasMatch(work)) {
        matched.add(rule.name);
        if (rule.highPriority) {
          work = work.replaceAll(re, ' '); // 挖掉，低优先级不再命中同一段
        }
      }
    }
    return matched.toList();
  }

  /// 挖空所有敏感格式 → (挖空后文本, 命中格式名)
  static (String, List<String>) mask(String text) {
    if (text.isEmpty) return (text, const []);
    var result = text;
    final matched = <String>{};
    var work = text;
    for (final rule in rules) {
      final re = RegExp(rule.pattern);
      if (re.hasMatch(work)) {
        matched.add(rule.name);
        result = result.replaceAllMapped(re, (_) => privacyMark);
        if (rule.highPriority) {
          work = work.replaceAll(re, ' ');
        }
      }
    }
    return (result, matched.toList());
  }

  /// 是否包含敏感格式（输入拦截用）
  static bool containsSensitive(String text) {
    if (text.isEmpty) return false;
    return rules.any((r) => RegExp(r.pattern).hasMatch(text));
  }

  /// 命中的格式名（输入拦截提示用：取第一条）
  static String? matchName(String text) {
    final names = detect(text);
    return names.isEmpty ? null : names.first;
  }
}
