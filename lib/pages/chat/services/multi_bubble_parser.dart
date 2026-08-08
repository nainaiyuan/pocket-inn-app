import 'dart:convert';
import 'dart:math' as math;

/// 多气泡解析器（8-07 用户设计定稿）
///
/// 男主回复格式：
///   `<reply>回#1</reply>`      ← 回复标注（管家剥掉消除待回复，不在这里解析）
///   `<act>动作神态</act>`       ← 顶层独立动作气泡
///   `<msg>话<act>动作</act>话</msg>` ← 对话气泡，块内动作混排
///
/// 规则：
///   1. 按原文顺序切块（msg / act / 裸文本兜底）
///   2. msg 块内再切 <act> → spans（text 段 + act 段混排）
///   3. 空标签丢弃；裸文本（trim 非空）兜底成 msg 块（内容永不丢）
///   4. 未闭合/写错标签 → 匹配不上 → 当裸文本
///   5. 不处理嵌套；大小写不敏感

/// 气泡内片段类型
enum SpanKind { text, act }

/// 8-08 22:5x（用户：JSON 块附近乱七八糟的文字，浪费 token 还看不见）：
/// 剥掉所有结构化块（JSON 数组/对象、旧标签 msg/act/reply/sys），返回
/// 剩余文本。非空 = 男主输出里带了杂散文字 → chat_page 借此提醒男主按格式。
/// （⟨工具:⟩块在 ToolIntentParser.stripToolBlocks 已剥，这里只管 JSON/标签）
/// 8-08 22:5x：JSON 剥除用平衡扫描（_jsonObjRe 非贪婪会把
/// {"name":..,"arguments":{}} 截成残渣），字符串里的括号不误伤；
/// 没闭合的 {/[ 不剥（残留 → 算杂散 → 提醒男主写岔了）。
String stripStructuredBlocks(String raw) {
  var t = raw;
  for (final re in [_msgRe, _actRe, _replyTagRe, _sysTagRe]) {
    t = t.replaceAll(re, '');
  }
  final sb = StringBuffer();
  var i = 0;
  while (i < t.length) {
    final ch = t[i];
    if (ch == '{' || ch == '[') {
      final end = _matchBalanced(t, i);
      if (end > i) {
        i = end;
        continue;
      }
    }
    sb.write(ch);
    i++;
  }
  return sb.toString().trim();
}

/// 从 [start]（'{' 或 '['）扫描到配对的闭合符，返回结束位置（不含）。
/// 字符串内容里的括号/转义不计数；没闭合返回 -1。
int _matchBalanced(String s, int start) {
  final open = s[start];
  final close = open == '{' ? '}' : ']';
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (inStr) {
      if (esc) {
        esc = false;
        continue;
      }
      if (c == r'\') {
        esc = true;
        continue;
      }
      if (c == '"') inStr = false;
      continue;
    }
    if (c == '"') {
      inStr = true;
      continue;
    }
    if (c == open) {
      depth++;
    } else if (c == close) {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return -1;
}

/// 8-08 21:3x（用户：男主气泡输出"工具:query_tool_formats关键词=notify_user"）：
/// DeepSeek 把工具调用文本化泄漏进回复（工具:名 关键词=值）——整行剥掉。
/// 只认行首"工具:"+工具名特征，不误伤"这个工具:xxx 很好用"（行首非工具:）。
/// 8-08 22:2x（用户：思考链里"工具:弹窗通知内容-测试弹窗通知！"）：工具名
/// 支持中文（弹窗通知/发计时卡片），参数前缀支持 内容/关键词/参数 + =或:或-
/// （DeepSeek 文本化格式多样）。'工具:list_tools' 纯暗号也剥（显示层，
/// 执行走 ToolIntentParser，不受影响）；'工具:锤子 敲一下'（名后自然话）不剥。
/// 供 bare 块解析、chat_page _displayableText（渐进显示）、思考链落库共用。
String stripToolTextLines(String t) {
  final lines = t.split('\n').where((ln) {
    final s = ln.trim();
    if (s.isEmpty) return false;
    return !RegExp(
      r'^工具[:：]\s*[\w\u4e00-\u9fa5]+(\s*(内容|关键词|参数)[:：=]?.*)?$',
    ).hasMatch(s);
  }).join('\n').trim();
  return lines;
}

/// 气泡内一个片段
class BubbleSpan {
  final SpanKind kind;
  final String text;
  const BubbleSpan(this.kind, this.text);

  Map<String, dynamic> toJson() => {'kind': kind.index, 'text': text};

  factory BubbleSpan.fromJson(Map<String, dynamic> json) => BubbleSpan(
        SpanKind.values[(json['kind'] as int?) ?? 0],
        json['text'] as String? ?? '',
      );
}

/// 气泡类型
enum BubbleKind { msg, act }

/// 一个气泡（msg = 对话气泡，spans 可混合；act = 独立动作气泡）
class BubblePart {
  final BubbleKind kind;
  final List<BubbleSpan> spans;

  /// 气泡纯文本（标签剥掉后的完整可读文本）
  String get text => spans.map((s) => s.text).join();

  const BubblePart(this.kind, this.spans);
}

final RegExp _msgRe = RegExp(r'<msg>([\s\S]*?)</msg>', caseSensitive: false);
final RegExp _actRe = RegExp(r'<act>([\s\S]*?)</act>', caseSensitive: false);
final RegExp _actInnerRe =
    RegExp(r'<act>([\s\S]*?)</act>', caseSensitive: false);

/// 解析男主回复 → 气泡列表
///
/// 返回空列表 = 没有气泡（纯空白或只有标签壳）——调用方按"无标签"处理
/// 8-07 21:52 用户：日志增强——纯 Dart 解析器用钩子（Flutter 侧注入 DebugLogger）
void Function(String tag, String msg)? multiBubbleLogSink;

List<BubblePart> parseMultiBubbles(String raw) =>
    parseStructuredOutput(raw).bubbles;

/// msg 块内切 <act> → spans（话段 + 动作段按原文顺序）
List<BubbleSpan> _splitMsgSpans(String content) {
  final spans = <BubbleSpan>[];
  var cursor = 0;
  for (final m in _actInnerRe.allMatches(content)) {
    if (m.start > cursor) {
      final t = content.substring(cursor, m.start);
      if (t.trim().isNotEmpty) spans.add(BubbleSpan(SpanKind.text, t));
    }
    final actText = (m.group(1) ?? '').trim();
    if (actText.isNotEmpty) spans.add(BubbleSpan(SpanKind.act, actText));
    cursor = m.end;
  }
  if (cursor < content.length) {
    final t = content.substring(cursor);
    if (t.trim().isNotEmpty) spans.add(BubbleSpan(SpanKind.text, t));
  }
  return spans;
}

enum _BlockKind { msg, act, bare, jsonObj, jsonArr, skip }

class _Block {
  final int start;
  final int end;
  final _BlockKind kind;
  final String content;
  const _Block(this.start, this.end, this.kind, this.content);
}

// ============================================================
// 8-07 23:3x JSON 化（用户："是不是应该按照json的格式把我们的<…>包进去，
// AI应该都认JSON吧"）——男主输出协议升级：
//   JSON 块（新）：{"msg":"话"} {"act":"动作"} {"reply":"回#1"} {"sys":"静默"}
//     多气泡 = 多个 JSON 对象（可换行/空格分隔），或数组 [{"msg":"a"},{"msg":"b"}]
//   HTML 标签（旧）：<msg>..</msg> <act>..</act> 等（双兼容保留，功能不退化）
// 解析策略：JSON 优先（模型遵循度最高），旧标签兜底，裸文本永不丢。
// ============================================================

/// 结构化输出解析结果（JSON 化后的统一出口）
class StructuredOutput {
  /// 气泡列表（msg = 对话气泡 / act = 独立动作气泡；reply/sys 不产生气泡）
  final List<BubblePart> bubbles;

  /// 男主回复标注（JSON "reply" 字段值，如 "回#1、#A"；旧 <reply> 标签同收）
  final String replyText;

  /// 静默内容（JSON "sys" 字段值；旧 <sys> 标签同收）——不显示不落库
  final String sysText;

  /// 是否带结构化格式（JSON 块或标签块）——打回判断用
  final bool hasFormat;

  const StructuredOutput({
    required this.bubbles,
    required this.replyText,
    required this.sysText,
    required this.hasFormat,
  });
}

final RegExp _jsonArrRe = RegExp(r'\[[\s\S]*?\]');
final RegExp _jsonObjRe = RegExp(r'\{[\s\S]*?\}');
final RegExp _replyTagRe =
    RegExp(r'<reply>([\s\S]*?)</reply>', caseSensitive: false);
final RegExp _sysTagRe = RegExp(r'<sys>([\s\S]*?)</sys>', caseSensitive: false);

/// 统一解析男主原始输出 → 结构化结果（JSON 块 + 旧标签双兼容）
StructuredOutput parseStructuredOutput(String raw) {
  if (raw.trim().isEmpty) {
    return const StructuredOutput(
        bubbles: [], replyText: '', sysText: '', hasFormat: false);
  }

  final replyParts = <String>[];
  final sysParts = <String>[];
  final blocks = <_Block>[]; // 复用旧 _Block（kind: msg/act/bare + 新增 json）

  // ① JSON 数组块（整体解析，内部对象不再单独匹配）
  for (final m in _jsonArrRe.allMatches(raw)) {
    blocks.add(_Block(m.start, m.end, _BlockKind.jsonArr, m.group(0) ?? ''));
  }
  // ② JSON 对象块（跳过落在数组内的）
  for (final m in _jsonObjRe.allMatches(raw)) {
    final insideArr = blocks.any((b) =>
        b.kind == _BlockKind.jsonArr && m.start >= b.start && m.end <= b.end);
    if (insideArr) continue;
    blocks.add(_Block(m.start, m.end, _BlockKind.jsonObj, m.group(0) ?? ''));
  }
  // ③ 旧标签块（msg/act）
  for (final m in _msgRe.allMatches(raw)) {
    blocks.add(_Block(m.start, m.end, _BlockKind.msg, m.group(1) ?? ''));
  }
  for (final m in _actRe.allMatches(raw)) {
    blocks.add(_Block(m.start, m.end, _BlockKind.act, m.group(1) ?? ''));
  }
  // ④ reply/sys 标签：只收集值，不产生气泡
  for (final m in _replyTagRe.allMatches(raw)) {
    final v = (m.group(1) ?? '').trim();
    if (v.isNotEmpty) replyParts.add(v);
    blocks.add(_Block(m.start, m.end, _BlockKind.skip, ''));
  }
  for (final m in _sysTagRe.allMatches(raw)) {
    final v = (m.group(1) ?? '').trim();
    if (v.isNotEmpty) sysParts.add(v);
    blocks.add(_Block(m.start, m.end, _BlockKind.skip, ''));
  }
  blocks.sort((a, b) => a.start.compareTo(b.start));

  // 合并：结构化块 + 块外裸文本（兜底成 msg，内容永不丢）
  // 8-08 22:2x（自检"JSON 周围杂散文本"失败）：有结构化块时块外裸文本
  // 是杂散（"思考一下{...}完毕"的"思考一下/完毕"）→ 丢弃；纯文本
  //（无任何结构化块）才兜底成 msg。旧标签 reply/sys 是 skip 块不算结构化。
  final hasStructured =
      blocks.any((b) => b.kind != _BlockKind.bare && b.kind != _BlockKind.skip);
  final merged = <_Block>[];
  var cursor = 0;
  for (final b in blocks) {
    if (b.start > cursor) {
      final bare = raw.substring(cursor, b.start);
      if (bare.trim().isNotEmpty && !hasStructured) {
        merged.add(_Block(cursor, b.start, _BlockKind.bare, bare));
      }
    }
    merged.add(b);
    cursor = math.max(cursor, b.end);
  }
  if (cursor < raw.length && !hasStructured) {
    final bare = raw.substring(cursor);
    if (bare.trim().isNotEmpty) {
      merged.add(_Block(cursor, raw.length, _BlockKind.bare, bare));
    }
  }

  // 转成气泡
  final bubbles = <BubblePart>[];
  var hasFormat = false;
  for (final b in merged) {
    switch (b.kind) {
      case _BlockKind.jsonArr:
        hasFormat = true;
        final decoded = _tryDecode(b.content);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              _jsonMapToBubbles(item, bubbles, replyParts, sysParts);
            }
          }
        }
      case _BlockKind.jsonObj:
        hasFormat = true;
        final decoded = _tryDecode(b.content);
        if (decoded is Map<String, dynamic>) {
          _jsonMapToBubbles(decoded, bubbles, replyParts, sysParts);
        }
      case _BlockKind.msg:
        hasFormat = true;
        final spans = _splitMsgSpans(b.content);
        if (spans.isNotEmpty) {
          bubbles.add(BubblePart(BubbleKind.msg, spans));
        }
      case _BlockKind.act:
        hasFormat = true;
        final t = b.content.trim();
        if (t.isNotEmpty) {
          bubbles.add(BubblePart(BubbleKind.act, [BubbleSpan(SpanKind.act, t)]));
        }
      case _BlockKind.skip:
        hasFormat = true; // reply/sys 标签也算带格式
      case _BlockKind.bare:
        var t = b.content.trim();
        if (t.isEmpty) continue;
        // 剥孤立/残留的已知标签（只认完整标签名，不误伤 "<3"）
        t = t
            .replaceAll(
              RegExp(r'</?(msg|act|reply|sys|flow|user|tool|quote)[^>]*>',
                  caseSensitive: false),
              '',
            )
            // 8-08 00:2x：标签形态兜底（模型自创 <tool_call>/<|im_start|>
            // 半截标签全清；"<3" 数字开头不误伤）
            .replaceAll(
              RegExp(r'<(?:[a-zA-Z_/|\u4e00-\u9fa5][^>]*)>'),
              '',
            )
            .trim();
        if (t.isEmpty) continue;
        // 8-08 21:0x（用户：男主气泡输出"工具:query_tool_formats关键词=notify_user"）：
        // DeepSeek 把工具调用文本化泄漏进回复（工具:名 关键词=值）——整行剥掉。
        // 只认行首"工具:"+工具名特征，不误伤"这个工具:xxx 很好用"（行首非工具:）
        final lines = t.split('\n').where((ln) {
          final s = ln.trim();
          if (s.isEmpty) return false;
          return !RegExp(
            r'^工具[:：]\s*[\w_]+(\s*(关键词|参数)[:：]\s*[^\s，。；;]+)?\s*$',
          ).hasMatch(s);
        }).join('\n').trim();
        t = lines;
        if (t.isEmpty) continue;
        // 8-08 21:0x（用户：男主气泡输出"工具:query_tool_formats关键词=notify_user"）：
        // DeepSeek 文本化工具调用泄漏 → 整行剥掉（公共函数，渐进显示同用）
        t = stripToolTextLines(t);
        if (t.isEmpty) continue;
        // 8-08 21:0x（用户：调工具时男主有思考没说话 → 出现"<"单独气泡）：
        // 剥完还剩纯标签残渣（无闭合 > 的 <thinking/< 等）→ 丢弃整块；
        // 带数字的（<3 表情）和带正文的（x < y）不误伤
        if (RegExp(r'^<[a-zA-Z_/|]*$').hasMatch(t)) continue;
        bubbles.add(BubblePart(BubbleKind.msg, [BubbleSpan(SpanKind.text, t)]));
    }
  }

  multiBubbleLogSink?.call(
    '多气泡',
    '🧩 解析 ${bubbles.length} 块'
    '（${bubbles.map((b) => b.kind.name).join('+')}）'
    '${hasFormat ? ' 带格式' : ' 纯文本'}'
    '${replyParts.isEmpty ? '' : ' reply=${replyParts.join('、')}'}',
  );
  return StructuredOutput(
    bubbles: bubbles,
    replyText: replyParts.join('、'),
    sysText: sysParts.join('\n'),
    hasFormat: hasFormat,
  );
}

/// JSON 对象 → 气泡/标注（按字段在对象里的出现顺序；reply/sys 只收集不显示）
void _jsonMapToBubbles(
  Map<String, dynamic> map,
  List<BubblePart> bubbles,
  List<String> replyParts,
  List<String> sysParts,
) {
  for (final entry in map.entries) {
    final key = entry.key.toLowerCase();
    final value = entry.value;
    switch (key) {
      case 'msg':
        final t = value?.toString() ?? '';
        if (t.trim().isNotEmpty) {
          bubbles.add(BubblePart(BubbleKind.msg, [
            BubbleSpan(SpanKind.text, t),
          ]));
        }
      case 'act':
        final t = value?.toString() ?? '';
        if (t.trim().isNotEmpty) {
          bubbles.add(
              BubblePart(BubbleKind.act, [BubbleSpan(SpanKind.act, t)]));
        }
      case 'reply':
        final v = value?.toString() ?? '';
        if (v.trim().isNotEmpty) replyParts.add(v.trim());
      case 'sys':
        final v = value?.toString() ?? '';
        if (v.trim().isNotEmpty) sysParts.add(v.trim());
    }
  }
}

Object? _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}
