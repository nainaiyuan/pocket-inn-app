/// parse_utils.dart —— 公共解析工具（8-08 16:3x）
///
/// 从 chat_page 私有方法提取（_parseMinutesArg/_parseSecondsArg/标签形态剥离），
/// 让"修复验证中心"自测页能直接调用验证，避免同一逻辑维护两份。
library;

/// 时长解析（分钟）：支持纯数字（=分钟）与带单位写法。
/// - 30 / '90' → 30 / 90（纯数字=分钟）
/// - '30分钟' / '30分' / '30min' → 30
/// - '1小时' / '1时' / '1h' → 60
/// - '2小时30分钟' → 150
/// - '45秒' → 1（不足 1 分钟向上取整）
/// - 解析不了 → null
int? parseMinutesArg(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  final s = v.toString().trim().toLowerCase();
  if (s.isEmpty) return null;
  final pureNum = RegExp(r'^(\d+)$').firstMatch(s);
  if (pureNum != null) return int.parse(pureNum.group(1)!); // 纯数字=分钟
  final hm = RegExp(r'^(\d+)\s*(小时|时|h)\s*(\d+)\s*(分钟|分|min|mins?)$')
      .firstMatch(s);
  if (hm != null) {
    return int.parse(hm.group(1)!) * 60 + int.parse(hm.group(3)!);
  }
  final h = RegExp(r'^(\d+(?:\.\d+)?)\s*(小时|时|h)$').firstMatch(s);
  if (h != null) return (double.parse(h.group(1)!) * 60).round();
  final m = RegExp(r'^(\d+(?:\.\d+)?)\s*(分钟|分|min|mins?)$').firstMatch(s);
  if (m != null) return double.parse(m.group(1)!).round();
  final sec = RegExp(r'^(\d+)\s*(秒|s)$').firstMatch(s);
  if (sec != null) return (int.parse(sec.group(1)!) / 60).ceil();
  return null;
}

/// 秒数解析（interval_seconds 用）：
/// - 30 → 30（纯数字=秒）
/// - '4秒' / '4s' → 4
/// - '2分钟' / '2min' → 120
/// - '1小时' → 3600
/// - 解析不了 → null
int? parseSecondsArg(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  final s = v.toString().trim().toLowerCase();
  if (s.isEmpty) return null;
  final pureNum = RegExp(r'^(\d+)$').firstMatch(s);
  if (pureNum != null) return int.parse(pureNum.group(1)!); // 纯数字=秒
  final sec = RegExp(r'^(\d+)\s*(秒|s)$').firstMatch(s);
  if (sec != null) return int.parse(sec.group(1)!);
  final m = RegExp(r'^(\d+(?:\.\d+)?)\s*(分钟|分|min|mins?)$').firstMatch(s);
  if (m != null) return (double.parse(m.group(1)!) * 60).round();
  final h = RegExp(r'^(\d+(?:\.\d+)?)\s*(小时|时|h)$').firstMatch(s);
  if (h != null) return (double.parse(h.group(1)!) * 3600).round();
  return null;
}

/// 标签形态剥离（8-08 00:2x 借鉴参考：输出给用户前清所有 <…> 标签形态）。
/// 只认"< 后跟字母/下划线/中文/竖线"的标签形态（模型自创 <tool_call>、
/// <|im_start|>、半截 <invoke 都能清）；"<3"（数字开头）、"a<b" 不误伤。
/// 显示层兜底——JSON 化后男主正常输出已无标签，这是防"模型自创标签"漏网。
final RegExp tagShapeRe = RegExp(r'<(?:[a-zA-Z_/|\u4e00-\u9fa5][^>]*)>');

String stripTagShapes(String text) => text.replaceAll(tagShapeRe, '');
