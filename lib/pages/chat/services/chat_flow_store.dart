import 'context_manager.dart';

/// ChatFlowStore —— 对话流程视图（8-09 18:1x 用户设计定稿）
///
/// 每次对话 = 一个流程：用户每条消息 = 一个条目（待消），
/// 男主回复才消掉，工具调用挂到未消条目上（记录处理方式）。
/// 管家从上下文原文实时计算（零存储、零写入、男主零操作）：
/// - 用户行 → 条目（☐ 待消）
/// - 男主行 → 消条目：回复带标注（回#N）→ 精确消；无标注 → FIFO 消最老一条
/// - 工具行 → 挂到最老未消条目（✅/❌ + 摘要）
/// - 无未消条目时男主说话 → 计数（重复回复警告，防"回一和二"再演）
///
/// 每次唤醒注入完整清单：☐ 待消（还欠她的话）+ ✅ 已消（工具链 + 回复）。
/// 男主看到清单就不会弄混（知道还欠几条）、不会漏（☐ 挂着）、
/// 不会重复回（✅ 已消 + 无新消息还说话会收到警告）。
class ChatFlowStore {
  ChatFlowStore._();

  /// 清单最多显示条数（防上下文膨胀，更早的折叠）
  static const int _maxShow = 8;

  /// 从原文行构建对话条目
  /// 返回 (items, extraReplies)
  /// items: [{no, ts, userText, done, tools: List<String>, reply}]
  static (List<Map<String, dynamic>>, int) _build(List<String> raw) {
    final items = <Map<String, dynamic>>[];
    final pending = <int>[]; // 未消条目索引（FIFO）
    var userNo = 0;
    var extraReplies = 0;
    for (final line in raw) {
      if (line.startsWith('用户')) {
        userNo++;
        final idx = items.length;
        items.add({
          'no': userNo,
          'ts': _tsOf(line),
          'userText': _strip(line),
          'done': false,
          'tools': <String>[],
          'reply': '',
        });
        pending.add(idx);
      } else if (line.startsWith('工具')) {
        final brief = _toolBrief(line);
        if (brief.isEmpty) continue;
        if (pending.isNotEmpty) {
          (items[pending.first]['tools'] as List).add(brief);
        } else if (items.isNotEmpty) {
          // 无未消条目（先回后补记等）→ 挂到最后一条（记录处理过）
          (items.last['tools'] as List).add(brief);
        }
      } else if (line.startsWith('男主')) {
        final replyText = _strip(line);
        if (replyText.isEmpty) continue;
        // 标注解析：<reply>回#N、#M</reply> / "reply":"回#N" / 回待#N / 回#N
        final marked = _parseMarkedNos(replyText);
        if (marked.isNotEmpty) {
          // 精确消：按条目绝对序号
          for (final no in marked) {
            for (final it in items) {
              if (!it['done'] && it['no'] == no) {
                it['done'] = true;
                it['reply'] = replyText;
                pending.remove(items.indexOf(it));
                break;
              }
            }
          }
        } else if (pending.isNotEmpty) {
          // FIFO：消最老一条（默认男主回最老的）
          final idx = pending.removeAt(0);
          items[idx]['done'] = true;
          items[idx]['reply'] = replyText;
        } else {
          // 没有未消条目却说话 = 重复回复 / 主动说话
          extraReplies++;
        }
      }
    }
    return (items, extraReplies);
  }

  /// 解析男主回复里的消条目标注（兼容 PendingQueue 旧格式）
  /// 返回绝对序号列表（如 [7, 8]）；无标注返回空
  static List<int> _parseMarkedNos(String reply) {
    final nos = <int>{};
    // <reply>回#7、#8</reply>
    for (final m
        in RegExp(r'<reply>([\s\S]*?)</reply>', caseSensitive: false)
            .allMatches(reply)) {
      for (final n in RegExp(r'#(\d+)').allMatches(m.group(1) ?? '')) {
        nos.add(int.tryParse(n.group(1)!) ?? 0);
      }
    }
    // "reply":"回#7、#8"
    for (final m in RegExp(r'"reply"\s*:\s*"([^"]*)"').allMatches(reply)) {
      final raw = (m.group(1) ?? '').replaceAll(r'\"', '"');
      for (final n in RegExp(r'#(\d+)').allMatches(raw)) {
        nos.add(int.tryParse(n.group(1)!) ?? 0);
      }
    }
    // 旧格式：回待#7 / 回复待#7 / 回#7（纯文本标注）
    for (final m in RegExp(r'回(?:复)?\s*待?#(\d+)').allMatches(reply)) {
      nos.add(int.tryParse(m.group(1)!) ?? 0);
    }
    nos.remove(0);
    return nos.toList()..sort();
  }

  /// 注入文本（对话流程清单；无内容返回 null）
  static String? buildText(String personaId) {
    final raw = ContextManager.instance.rawLines(personaId);
    if (raw.isEmpty) return null;
    final (items, extraReplies) = _build(raw);
    if (items.isEmpty) return null;
    // 只显示最近 _maxShow 条
    final show = items.length > _maxShow
        ? items.sublist(items.length - _maxShow)
        : items;
    final hidden = items.length - show.length;
    final sb = StringBuffer();
    sb.writeln('【对话流程】（本次对话：✅=已回 ☐=还没回——先回 ☐ 的；✅ 的已处理完，别重复回）');
    if (hidden > 0) sb.writeln('（更早 $hidden 条已处理）');
    for (final it in show) {
      final no = it['no'];
      final ts = (it['ts'] as String?)?.isNotEmpty == true
          ? '[${it['ts']}] '
          : '';
      final mark = it['done'] ? '✅' : '☐';
      final tools = (it['tools'] as List).cast<String>();
      final reply = (it['reply'] as String?)?.trim() ?? '';
      var line = '$mark #$no $ts她：${it['userText']}';
      if (it['done']) {
        final toolPart = tools.isEmpty
            ? ''
            : '（${tools.join('；')}）';
        final replyPart = reply.isEmpty ? '' : '→ 你回：$reply';
        line += '$toolPart$replyPart';
      } else if (tools.isNotEmpty) {
        line += '（处理中：${tools.join('；')}）';
      }
      sb.writeln(line);
    }
    final pendingCount = items.where((it) => !it['done']).length;
    if (pendingCount > 0) {
      sb.writeln('提示：还有 $pendingCount 条没回，优先回她。'
          '一次回多条可标注 {"reply":"回#N、#M"} 一起消；'
          '决定不回的不用消，挂着等她问。');
    } else if (extraReplies > 0) {
      sb.writeln('提示：你回复后没有新的用户消息，又说了 $extraReplies 次话——'
          '确认不是重复回复；没有新事就直接输出退出标记 {"need_continue": false}，'
          '别再唤醒自己。');
    }
    return sb.toString();
  }

  /// 检查轮简报（唤醒提醒里用）：'还有 2 条没回：…' / '已全部回应'
  static String? checkBrief(String personaId) {
    final raw = ContextManager.instance.rawLines(personaId);
    if (raw.isEmpty) return null;
    final (items, _) = _build(raw);
    final pending = items.where((it) => !it['done']).toList();
    if (pending.isEmpty) return null;
    final briefs = pending
        .take(3)
        .map((it) => '#${it['no']}「${it['userText']}」')
        .join('、');
    final more = pending.length > 3 ? ' 等${pending.length}条' : '';
    return '还有 ${pending.length} 条没回：$briefs$more——先回她，回完再结束；'
        '回多条可标注 {"reply":"回#N、#M"} 一起消。';
  }

  // ---- 行解析 ----

  static String _tsOf(String line) {
    final m = RegExp(r'\[([^\]]+)\]').firstMatch(line);
    return m?.group(1) ?? '';
  }

  /// 去前缀：'用户 [18:00]：我喜欢猫' → '我喜欢猫'
  static String _strip(String line) {
    final idx = line.indexOf('：');
    return idx < 0 ? line : line.substring(idx + 1).trim();
  }

  /// 工具行摘要：'工具 [18:00]：record_memory ✅成功（非她发言）：已记录…'
  /// → 'record_memory ✅ 已记录…'（截断 60 字）
  static String _toolBrief(String line) {
    final idx = line.indexOf('：');
    if (idx < 0) return '';
    var s = line.substring(idx + 1).trim();
    s = s.replaceFirst('（非她发言）', '').replaceFirst('成功', '✅').replaceFirst('失败', '❌');
    if (s.isEmpty) return '';
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }
}
