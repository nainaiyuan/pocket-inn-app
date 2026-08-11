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

/// 结束检查退出信号解析（8-08 18:1x GPT 意见：续话=一次检查机会，
/// 男主必须能明确说"我没有事情做了"）。
/// 返回：true=无需继续（need_continue:false / next_action:null/none/无），
/// false=需要继续（need_continue:true），null=没输出信号（保持现状）。
/// 兼容 JSON 字段（{"need_continue": false}）、标签块（<sys>need_continue:false</sys>）、
/// 纯文本（need_continue:false）三种形态。
bool? parseExitSignal(String raw) {
  if (raw.isEmpty) return null;
  final t = raw.toLowerCase();
  // ① 显式继续/结束判定（优先级高：男主说"需要继续"就是继续）
  final nc =
      RegExp(r'"?need_continue"?\s*[:：]?\s*(true|false)').firstMatch(t);
  if (nc != null) return nc.group(1) == 'false';
  // ② 下一步动作为空 → 结束
  if (RegExp(r'"?next_action"?\s*[:：]\s*("?null"?|none|无|空)').hasMatch(t)) {
    return true;
  }
  // ③ 固定结束指令（8-11 21:58 用户：英文指令，一个就够——
  // end_flow，避免中文和内容冲突；兼容旧引导的「消大流程」/旧中文）
  // 8-11 23:5x（用户：男主把 end_flow 拼成 end_fow → 没结束被反复唤醒）：
  // 常见拼写变体容错（end_fow / endflow 都认，避免男主手滑白忙一轮）
  if (RegExp(r'end_?f(?:lo)?w', caseSensitive: false).hasMatch(t) ||
      t.contains('消大流程') ||
      t.contains('大流程也结束了')) {
    return true;
  }
  return null;
}

/// 结尾命令的 next_action 值解析（8-10 00:5x 用户：男主消掉大流程
/// 自带结尾命令——merge = 与后续大流程合二为一）。
/// 返回 action 值（小写，如 'merge'），没输出则 null。
/// 兼容 JSON 字段（{"next_action": "merge"}）、标签块、纯文本。
String? parseNextAction(String raw) {
  if (raw.isEmpty) return null;
  final m = RegExp(r'"?next_action"?\s*[:：]\s*"([^"]+)"').firstMatch(raw);
  if (m == null) return null;
  return m.group(1)!.trim().toLowerCase();
}

/// 退出标记从显示文本剥离（防纯文本路径把 need_continue/next_action 漏给用户看）。
/// JSON 块路径（parseStructuredOutput）已自动丢弃未知字段，这里是兜底——
/// 只剥"裸标记"（不在 JSON 对象里的），JSON 对象里的字段不碰。
String stripExitSignal(String text) {
  var t = text.replaceAll(
    RegExp(
      r'\{\s*"?need_continue"?\s*[:：]\s*(true|false)\s*,?\s*\}',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(
    RegExp(
      r'\{\s*"?next_action"?\s*[:：]\s*("?null"?|none|无|空)\s*,?\s*\}',
      caseSensitive: false,
    ),
    '',
  );
  // 8-11 21:58：固定结束指令 end_flow 从显示文本剥离
  // （男主写在 sys 字段或文本里，都不能漏给用户看）
  t = t.replaceAll(
    RegExp(r'\{\s*"?end_flow"?\s*[:：]\s*(true|false)\s*,?\s*\}',
        caseSensitive: false),
    '',
  );
  t = t.replaceAll(RegExp(r'end_flow', caseSensitive: false), '');
  // 裸标记（前面不是 { 、 或 " → 不在 JSON 对象里）
  t = t
      .replaceAll(
        RegExp(r'(?<![{,"])"?need_continue"?\s*[:：]\s*(true|false)',
            caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'(?<![{,"])"?next_action"?\s*[:：]\s*("?null"?|none|无|空)',
            caseSensitive: false),
        '',
      );
  return t.trim();
}
