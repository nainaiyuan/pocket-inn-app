import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// FlowStore —— 男主流程（Flow 层，8-06 23:55 用户定稿）
///
/// 男主做长任务（如测所有工具）时先立流程：goal + steps，然后一条条执行。
/// 流程执行中：用户消息只收集（PendingQueueStore）不传给男主，不打扰执行；
/// 用户可点"⏹ 停止"打断 → status=stopped → 系统事件告诉男主
/// "流程停在哪、用户说了什么"，男主决定继续（resume）还是先回复用户。
///
/// 状态机：running → (next 推进) → running … → finish(done) / cancel(cancelled)
///         running → stop(stopped) → resume(running) / finish / cancel
///
/// 男主自管（免审批），管家只做存储，不做任何判断。
class FlowStore {
  FlowStore._();

  static const String _prefix = 'flow_';

  static Map<String, dynamic>? _memCache;

  static String _key(String personaId) => '$_prefix$personaId';

  /// 单例缓存读（warm 后同步读，避免每轮 await）
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
        _memCache = jsonDecode(raw) as Map<String, dynamic>;
      } else {
        _memCache = null;
      }
    } catch (e) {
      _memCache = null;
    }
  }

  static Future<Map<String, dynamic>?> _read(String personaId) async {
    if (personaId.isEmpty) return null;
    await _load(personaId);
    return _memCache;
  }

  static Future<void> _write(String personaId, Map<String, dynamic>? flow) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    if (flow == null) {
      await p.remove(_key(personaId));
      _memCache = null;
    } else {
      await p.setString(_key(personaId), jsonEncode(flow));
      _memCache = flow;
    }
  }

  /// 当前流程（无则 null）
  static Future<Map<String, dynamic>?> get(String personaId) =>
      _read(personaId);

  /// 是否有正在跑的流程（running/stopped 都算"有流程"）
  static bool isActive(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return false;
    final s = f['status']?.toString() ?? '';
    return s == 'running' || s == 'stopped';
  }

  /// 是否执行中（running：用户消息只收集不传）
  static bool isRunning(String personaId) {
    final f = _memCache;
    return f != null && (f['status']?.toString() ?? '') == 'running';
  }

  /// 立流程：{goal, steps: [..]} → running，currentStep=0
  static Future<String> create(String personaId, String goal, List<String> steps) async {
    if (personaId.isEmpty) return '参数错误';
    if (goal.trim().isEmpty) return 'goal 不能为空';
    final clean = <String>[];
    for (final s in steps) {
      final t = s.trim();
      if (t.isNotEmpty) clean.add(t);
    }
    if (clean.isEmpty) return 'steps 至少要一步';
    final flow = <String, dynamic>{
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'goal': goal.trim(),
      'steps': clean,
      'currentStep': 0,
      'status': 'running',
      'stoppedNote': '',
      'createdAt': DateTime.now().toIso8601String(),
    };
    await _write(personaId, flow);
    return '流程已立：$goal（${clean.length} 步，从第 1 步开始）';
  }

  /// 完成当前步，推进到下一步；已是最后一步则提示 finish
  static Future<String> next(String personaId) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程（create 先立）';
    if (f['status'] != 'running') return '流程当前不在执行中（${f['status']}）';
    final steps = _stepsOf(f);
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    if (cur + 1 >= steps.length) {
      return '已是最后一步（${cur + 1}/${steps.length}），调 finish 结束流程';
    }
    f['currentStep'] = cur + 1;
    await _write(personaId, f);
    return '第 ${cur + 1} 步完成，现在第 ${cur + 2} 步：${steps[cur + 1]}';
  }

  /// 流程完成
  static Future<String> finish(String personaId) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    final steps = _stepsOf(f);
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    f['status'] = 'done';
    f['stoppedNote'] = '';
    await _write(personaId, f);
    return '流程完成：${f['goal']}（${steps.length} 步全部做完）';
  }

  /// 取消流程
  static Future<String> cancel(String personaId) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    f['status'] = 'cancelled';
    f['stoppedNote'] = '';
    await _write(personaId, f);
    return '流程已取消：${f['goal']}';
  }

  /// 用户打断（停止按钮）：running → stopped，记下用户消息
  static Future<String> stop(String personaId, {String? userMessages}) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    if (f['status'] != 'running') return '流程不在执行中（${f['status']}）';
    f['status'] = 'stopped';
    f['stoppedNote'] = userMessages ?? '';
    await _write(personaId, f);
    return '已停止：${f['goal']}';
  }

  /// 被打断后继续：stopped → running
  static Future<String> resume(String personaId) async {
    final f = await _read(personaId);
    if (f == null) return '没有流程';
    if (f['status'] != 'stopped') return '流程不在停止状态（${f['status']}）';
    f['status'] = 'running';
    f['stoppedNote'] = '';
    await _write(personaId, f);
    final steps = _stepsOf(f);
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    return '继续流程：${f['goal']}，第 ${cur + 1} 步：${steps[cur]}';
  }

  static List<String> _stepsOf(Map<String, dynamic> f) {
    final raw = f['steps'];
    if (raw is List) {
      return raw.map((e) => e.toString()).toList();
    }
    return <String>[];
  }

  /// 简版摘要（UI 停止条用）：'「goal」第 2/5 步'；无流程返回 null
  static String? summary(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    final goal = f['goal']?.toString() ?? '';
    return '「$goal」第 ${cur + 1}/${steps.length} 步';
  }

  /// 注入文本（每轮 prompt）：有流程才返回
  static String? text(String personaId) {
    final f = _memCache;
    if (f == null || f.isEmpty) return null;
    final status = f['status']?.toString() ?? '';
    final steps = _stepsOf(f);
    if (steps.isEmpty) return null;
    final cur = (f['currentStep'] as num?)?.toInt() ?? 0;
    final curIdx = cur.clamp(0, steps.length - 1);
    final sb = StringBuffer();
    sb.writeln('目标：${f['goal']}');
    sb.writeln('状态：${_statusText(status)}');
    for (var i = 0; i < steps.length; i++) {
      final mark = i < curIdx
          ? '✅'
          : (i == curIdx
              ? (status == 'running' ? '▶ 正在做' : '⏸ 停在这')
              : '☐');
      sb.writeln('$mark ${i + 1}. ${steps[i]}');
    }
    if (status == 'stopped' && (f['stoppedNote']?.toString() ?? '').isNotEmpty) {
      sb.writeln('（她打断时说了：${f['stoppedNote']}）');
    }
    return sb.toString();
  }

  static String _statusText(String s) {
    switch (s) {
      case 'running':
        return '执行中';
      case 'stopped':
        return '被她打断了，等她决定';
      case 'done':
        return '已完成';
      case 'cancelled':
        return '已取消';
      default:
        return s;
    }
  }
}
