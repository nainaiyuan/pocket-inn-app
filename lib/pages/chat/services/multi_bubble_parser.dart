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
List<BubblePart> parseMultiBubbles(String raw) {
  if (raw.trim().isEmpty) return const [];

  // 收集所有标签块（带位置），按原文顺序合并
  final blocks = <_Block>[];
  for (final m in _msgRe.allMatches(raw)) {
    blocks.add(_Block(m.start, m.end, _BlockKind.msg, m.group(1) ?? ''));
  }
  for (final m in _actRe.allMatches(raw)) {
    blocks.add(_Block(m.start, m.end, _BlockKind.act, m.group(1) ?? ''));
  }
  blocks.sort((a, b) => a.start.compareTo(b.start));

  // 合并：标签块 + 标签外的裸文本（兜底成 msg）
  final merged = <_Block>[];
  var cursor = 0;
  for (final b in blocks) {
    if (b.start > cursor) {
      final bare = raw.substring(cursor, b.start);
      if (bare.trim().isNotEmpty) {
        merged.add(_Block(cursor, b.start, _BlockKind.bare, bare));
      }
    }
    merged.add(b);
    cursor = math.max(cursor, b.end);
  }
  if (cursor < raw.length) {
    final bare = raw.substring(cursor);
    if (bare.trim().isNotEmpty) {
      merged.add(_Block(cursor, raw.length, _BlockKind.bare, bare));
    }
  }

  // 转成 BubblePart
  final result = <BubblePart>[];
  for (final b in merged) {
    switch (b.kind) {
      case _BlockKind.msg:
        final spans = _splitMsgSpans(b.content);
        if (spans.isEmpty) continue; // 空标签丢弃
        result.add(BubblePart(BubbleKind.msg, spans));
      case _BlockKind.act:
        final t = b.content.trim();
        if (t.isEmpty) continue; // 空标签丢弃
        result.add(BubblePart(BubbleKind.act, [BubbleSpan(SpanKind.act, t)]));
      case _BlockKind.bare:
        final t = b.content.trim();
        if (t.isEmpty) continue;
        result.add(BubblePart(BubbleKind.msg, [BubbleSpan(SpanKind.text, t)]));
    }
  }
  return result;
}

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

enum _BlockKind { msg, act, bare }

class _Block {
  final int start;
  final int end;
  final _BlockKind kind;
  final String content;
  const _Block(this.start, this.end, this.kind, this.content);
}
