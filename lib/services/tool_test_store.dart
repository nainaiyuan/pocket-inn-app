import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// ToolTestStore —— 工具测试任务管理器（8-08 15:2x，设计文档八，GPT 10 问 10）
///
/// 男主发起"测试所有工具"任务时，管家维护 checklist（机械推进），
/// 男主每轮只面对"当前要测的工具"一个对象，不会 tool discovery loop。
///
/// 与普通流程冲突（GPT 13:20 定案：不强制 finish/cancel，按优先级降级）：
/// 优先级 normal_chat > user_request > background_testing。
/// 用户聊天只是 interrupt（resume 队列机制天然支持：用户消息 → 取消调度 →
/// 用户聊完 → 续跑恢复），checklist 持久化不丢进度。
///
/// 数据结构（SharedPreferences 持久化）：
/// {
///   "task": "测试所有工具",
///   "total": 12,
///   "tested": [ {"name": "tool_a", "status": "success", "bug": null}, ... ],
///   "current": "tool_c",
///   "progress": "2/12",
///   "status": "running" | "done" | "aborted"
/// }
class ToolTestStore {
  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) => logSink?.call(tag, msg);

  ToolTestStore._();

  static const String _prefix = 'tool_test_';

  static Map<String, dynamic>? _memCache;

  static String _key(String personaId) => '$_prefix$personaId';

  /// 单例缓存读（warm 后同步读）
  static void warm(String personaId) {
    if (personaId.isEmpty) return;
    _load(personaId);
  }

  static Future<void> _load(String personaId) async {
    if (personaId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(personaId));
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        _memCache = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
      } else {
        _memCache = <String, dynamic>{};
      }
    } catch (e) {
      _memCache = <String, dynamic>{};
    }
  }

  static Future<Map<String, dynamic>?> _read(String personaId) async {
    if (personaId.isEmpty) return null;
    await _load(personaId);
    return _memCache;
  }

  static Future<void> _write(
      String personaId, Map<String, dynamic>? test) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    if (test == null) {
      await p.remove(_key(personaId));
      _memCache = null;
    } else {
      await p.setString(_key(personaId), jsonEncode(test));
      _memCache = test;
    }
  }

  /// 是否有测试任务在跑
  static bool isRunning(String personaId) {
    final t = _memCache;
    return t != null && (t['status']?.toString() ?? '') == 'running';
  }

  /// 开始测试任务：[tools] 工具英文名列表
  static Future<String> start(String personaId, List<String> tools) async {
    if (personaId.isEmpty) return '参数错误';
    final clean = tools.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    if (clean.isEmpty) return '没有工具可测';
    final test = <String, dynamic>{
      'task': '测试所有工具',
      'total': clean.length,
      'tested': <Map<String, dynamic>>[],
      'pending': clean,
      'current': clean.first,
      'progress': '0/${clean.length}',
      'status': 'running',
      'startedAt': DateTime.now().toIso8601String(),
    };
    await _write(personaId, test);
    _log('工具测试', '🧪 测试任务开始：${clean.length} 个工具，先测 ${clean.first}');
    return '测试任务已开始：共 ${clean.length} 个工具。先测 ${clean.first}'
        '（格式看【工具使用手册】或 query_tool_formats）。'
        '测完调 manage_tool_test report {"name":"...","ok":true/false,"bug":"..."}';
  }

  /// 报告一个工具测试结果 → 记录 + 自动推进 current
  static Future<String> report(String personaId, String name,
      {required bool ok, String? bug}) async {
    final test = await _read(personaId);
    if (test == null) return '没有测试任务（manage_tool_test start 先发起）';
    if (test['status'] != 'running') return '测试任务不在进行中（${test['status']}）';
    final tested = (test['tested'] as List?) ?? <Map<String, dynamic>>[];
    final pending = (test['pending'] as List?) ?? <String>[];
    // 防重复报告：已在 tested 里则更新
    final idx = tested.indexWhere((e) => (e['name'] ?? '') == name);
    final entry = <String, dynamic>{
      'name': name,
      'status': ok ? 'success' : 'failed',
      'bug': ok ? null : (bug ?? ''),
      'at': DateTime.now().toIso8601String(),
    };
    if (idx >= 0) {
      tested[idx] = entry;
    } else {
      tested.add(entry);
    }
    pending.remove(name);
    test['tested'] = tested;
    test['pending'] = pending;
    final next = pending.isNotEmpty ? pending.first : null;
    test['current'] = next;
    test['progress'] = '${tested.length}/${test['total']}';
    _log('工具测试', '🧪 ${name} ${ok ? '✅' : '❌'}${bug != null ? ' bug:$bug' : ''}'
        '（${tested.length}/${test['total']}）${next != null ? '，下一个 $next' : '，全部完成'}');
    if (next == null) {
      test['status'] = 'done';
      test['finishedAt'] = DateTime.now().toIso8601String();
      await _write(personaId, test);
      final failed = tested.where((e) => e['status'] == 'failed').toList();
      return '全部工具测试完成 🎉 成功 ${tested.length - failed.length} / '
          '失败 ${failed.length}${failed.isNotEmpty ? '：${failed.map((e) => e['name']).join('、')}' : ''}。'
          '已自动汇总（详见测试状态）';
    }
    await _write(personaId, test);
    return '${name} 已记录（${ok ? '✅ 通过' : '❌ 失败${bug != null ? '：$bug' : ''}'}）'
        '，进度 ${tested.length}/${test['total']}。下一个测 $next'
        '（格式看手册或 query_tool_formats）';
  }

  /// 中止测试任务
  static Future<String> abort(String personaId) async {
    final test = await _read(personaId);
    if (test == null) return '没有测试任务';
    test['status'] = 'aborted';
    await _write(personaId, test);
    _log('工具测试', '⏹ 测试任务中止');
    return '测试任务已中止（进度 ${test['progress']} 保留，可 start 重新发起）';
  }

  /// 状态文本
  static Future<String> status(String personaId) async {
    final test = await _read(personaId);
    if (test == null) return '没有测试任务（manage_tool_test start 发起）';
    final tested = (test['tested'] as List?) ?? <Map<String, dynamic>>[];
    final sb = StringBuffer('🧪 工具测试：${test['progress']}'
        '（${test['status'] == 'running' ? '进行中' : test['status']}）');
    for (final e in tested) {
      final ok = (e['status'] ?? '') == 'success';
      final bug = (e['bug'] ?? '').toString();
      sb.writeln('  ${ok ? '✅' : '❌'} ${e['name']}${bug.isNotEmpty ? '：$bug' : ''}');
    }
    final cur = test['current'];
    if (cur != null && test['status'] == 'running') {
      sb.writeln('当前待测：$cur');
    }
    return sb.toString().trim();
  }

  /// 注入块（【工具测试】，状态块用）：进度 + 当前测什么 + 手册提示
  static String block(String personaId) {
    final t = _memCache;
    if (t == null) return '';
    final tested = (t['tested'] as List?) ?? <Map<String, dynamic>>[];
    final cur = t['current'];
    // 8-12 03:1x（用户：当前工作区上面怎么有【工具测试】进度null——
    // 没测试任务不该注入）：没有进行中的测试且没有已测记录 → 不注入
    // （残留/从未开始的空任务不显示，男主不被无关块干扰）
    if (t['status'] != 'running' && tested.isEmpty) return '';
    final sb = StringBuffer();
    sb.writeln('【工具测试】');
    sb.writeln('进度 ${t['progress']}（${t['status'] == 'running' ? '进行中' : t['status']}）');
    if (t['status'] == 'running' && cur != null) {
      sb.writeln('当前要测：$cur（格式看【工具使用手册】或 query_tool_formats，'
          '别重新探索列表）');
      sb.writeln('测完调 manage_tool_test report {"name":"$cur","ok":true/false,"bug":"..."}');
    } else if (tested.isNotEmpty) {
      final failed = tested.where((e) => e['status'] == 'failed').toList();
      sb.writeln('已测 ${tested.length} 个，失败 ${failed.length} 个'
          '${failed.isNotEmpty ? '：${failed.map((e) => e['name']).join('、')}' : ''}');
    }
    return sb.toString().trim();
  }

  /// 清空（测试完成后可选）
  static Future<void> clear(String personaId) async {
    await _write(personaId, null);
  }
}
