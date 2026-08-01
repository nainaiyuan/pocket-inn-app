import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// BERT 中文分词器（纯 Dart，从 tokenizer.json 解析）
///
/// 对应 HuggingFace BertTokenizer：
/// - BertNormalizer（clean_text + handle_chinese_chars，lowercase=false）
/// - BertPreTokenizer（空格/标点切分，中文逐字）
/// - WordPiece（贪心最长匹配，失败 → [UNK]）
class BertTokenizer {
  /// word → id
  final Map<String, int> _vocab;

  BertTokenizer._(this._vocab);

  static const int _clsId = 101;
  static const int _sepId = 102;
  static const int _unkId = 100;
  static const int _padId = 0;

  /// 从 tokenizer.json 字节加载
  factory BertTokenizer.fromJsonBytes(List<int> bytes) {
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final model = data['model'] as Map<String, dynamic>;
    final vocabRaw = model['vocab'] as Map<String, dynamic>;
    final vocab = <String, int>{
      for (final e in vocabRaw.entries) e.key: (e.value as num).toInt(),
    };
    return BertTokenizer._(vocab);
  }

  /// 从 assets 加载
  static Future<BertTokenizer> fromAsset(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return BertTokenizer.fromJsonBytes(data.buffer.asUint8List());
  }

  /// 编码一条文本 → (input_ids, attention_mask)
  /// maxLen 含 [CLS]/[SEP]
  ({List<int> inputIds, List<int> attentionMask}) encode(
    String text, {
    int maxLen = 128,
  }) {
    final tokens = <String>['[CLS]'];
    for (final token in _preTokenize(_cleanText(text))) {
      tokens.addAll(_wordPiece(token));
      if (tokens.length >= maxLen - 1) break;
    }
    tokens.add('[SEP]');
    if (tokens.length > maxLen) {
      tokens.removeRange(maxLen, tokens.length);
      // 截断后必须仍以 [SEP] 结尾
      tokens[maxLen - 1] = '[SEP]';
    }

    final inputIds = <int>[
      for (final t in tokens) _vocab[t] ?? _unkId,
    ];
    final padLen = maxLen - inputIds.length;
    if (padLen > 0) inputIds.addAll(List.filled(padLen, _padId));
    final attentionMask = <int>[
      for (var i = 0; i < maxLen; i++) i < tokens.length ? 1 : 0,
    ];
    return (inputIds: inputIds, attentionMask: attentionMask);
  }

  // ── 预处理 ──

  String _cleanText(String text) {
    final sb = StringBuffer();
    for (final rune in text.runes) {
      final code = rune;
      // 控制字符丢弃（除 \t \n \r）
      if (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D) {
        continue;
      }
      // 全角空格 → 半角
      if (code == 0x3000) {
        sb.write(' ');
        continue;
      }
      sb.writeCharCode(code);
    }
    return sb.toString();
  }

  /// 中文（CJK）逐字 + 标点独立 + 英文数字连续
  List<String> _preTokenize(String text) {
    final tokens = <String>[];
    final buf = StringBuffer();

    void flush() {
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
    }

    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (_isCjk(ch)) {
        flush();
        tokens.add(ch); // 中文逐字
      } else if (RegExp(r'[a-zA-Z0-9]').hasMatch(ch)) {
        buf.write(ch);
      } else if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        flush();
      } else {
        flush();
        tokens.add(ch); // 标点独立
      }
    }
    flush();
    return tokens;
  }

  /// WordPiece 贪心最长匹配
  List<String> _wordPiece(String token) {
    if (_vocab.containsKey(token)) return [token];
    final pieces = <String>[];
    var start = 0;
    while (start < token.length) {
      var end = token.length;
      String? found;
      while (end > start) {
        final sub = start == 0
            ? token.substring(start, end)
            : '##${token.substring(start, end)}';
        if (_vocab.containsKey(sub)) {
          found = sub;
          break;
        }
        end--;
      }
      if (found == null) return ['[UNK]']; // 首个字符匹配不到 → 整词 [UNK]
      pieces.add(found);
      start = end;
    }
    return pieces;
  }

  static bool _isCjk(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 0x4E00 && code <= 0x9FFF) || // 中日韩统一表意文字
        (code >= 0x3400 && code <= 0x4DBF) || // 扩展A
        (code >= 0xF900 && code <= 0xFAFF) || // 兼容表意文字
        (code >= 0x3000 && code <= 0x303F); // CJK 标点（。，！？）
  }
}
