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

/// 说话停止意图识别（8-08 17:4x 用户："我只是说话让它停止，它听不懂"）。
/// 用户说"停/别说了/别管了/够了/晚安"等 → 等同按⏹停止（停续话/续跑/唤醒）。
/// 保守匹配：带问号（吗/？/?）的消息不可能是停止指令，直接排除；
/// 只匹配明确祈使短语，避免误伤"我不要吃火锅"这类正常消息。
bool isStopIntent(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  // 问句不是停止指令（"你睡了吗"含"睡了"、"停止键在哪"含"停止"）
  if (t.contains('吗') ||
      t.contains('？') ||
      t.contains('?') ||
      t.contains('在哪') ||
      t.contains('哪里')) {
    return false;
  }
  // 反义：不要停/别停/继续 = "别停，继续说"，不是停止指令
  if (t.contains('不要停止') || t.contains('别停止') || t.contains('继续')) {
    return false;
  }
  const stopPhrases = [
    // 明确祈使：别 X
    '别说了', '别讲了', '别发了', '别吵了', '别闹了', '别管了', '别弄了', '别搞了',
    '别回了', '别回复', '别说话', '别出声', '别叫了', '别烦', '别念了',
    // 不要 X
    '不要再', '不要说了', '不要发了', '不要吵', '不要闹', '不要管', '不要弄', '不要搞',
    // 命令/受够了
    '闭嘴', '住口', '够了', '消停', '安静',
    // 停下
    '停下', '停止', '停一下', '先停', '停吧',
    // 不用了
    '不用了', '不用管', '不用再', '不需要了',
    // 结束对话（男主说完别自动续话）
    '晚安', '我睡了', '睡觉了', '去睡了', '先睡了', '要睡了', '准备睡了', '睡吧', '不聊了',
  ];
  for (final p in stopPhrases) {
    if (t.contains(p)) return true;
  }
  // 纯"停"单字祈使
  if (t == '停' || t == '停！' || t == '停!') return true;
  return false;
}

/// 复读判定（8-08 17:4x 用户："他重复说最后的总结"）。
/// 新文本和上轮文本相同 / 互相包含（长文本）/ 开头 20 字一致
/// （LLM 复读总结时开头往往相同）→ 判为复读，不再唤醒男主。
bool isRepeatText(String a, String b) {
  if (a == b) return true;
  if (a.length >= 8 && b.contains(a)) return true;
  if (b.length >= 8 && a.contains(b)) return true;
  if (a.length >= 20 &&
      b.length >= 20 &&
      a.substring(0, 20) == b.substring(0, 20)) {
    return true;
  }
  return false;
}
