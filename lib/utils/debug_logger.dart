import 'dart:io';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 调试日志引擎 — 内存缓冲区 + 按天分文件双写
///
/// 8-06 01:07-01:10 用户定案：日志**长期储存**——按天分文件
/// （debug_log_YYYY-MM-DD.txt，追加模式，不再启动清空），
/// 启动时自动删超过 [retentionDays]（15）天的旧文件。
/// 男主可通过 query_logs 工具查日志（筛选关键词/级别/条数/日期）。
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._();
  factory DebugLogger() => _instance;
  DebugLogger._();

  static String _dir = '';
  static bool _ready = false;
  static final List<String> _pending = [];
  static int _seq = 0;
  static Stopwatch? _watch;

  /// 日志保留天数（8-06 01:10 用户定案：15 天绰绰有余）
  static const int retentionDays = 15;

  /// 内存缓冲区（最近 200 条，供页面显示）
  static final Queue<String> _buffer = Queue();
  static List<String> get recentLogs => _buffer.toList(growable: false);
  static String get recentLogsText => _buffer.join('\n');

  /// 当天日志文件名：debug_log_2026-08-06.txt
  static String _fileName(DateTime d) =>
      'debug_log_${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}.txt';

  static String _pathFor(DateTime d) => '$_dir/${_fileName(d)}';

  /// 初始化：建目录 + 清理超期文件 + 写启动标记（不覆盖历史日志）
  static Future<void> init() async {
    _watch = Stopwatch()..start();
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _dir = appDir.path;
      debugPrint('DebugLogger dir: $_dir');
      await Directory(_dir).create(recursive: true);
      // 8-06 01:10：启动时清理超过 15 天的日志文件
      await _cleanupOldLogs();
      _ready = true;
      final entry = '========== APP 启动 '
          '${DateTime.now().toString()} ==========\n';
      debugPrint(entry.trim());
      _buffer.add(entry.trim());
      if (_pending.isNotEmpty) {
        final all = _pending.join('\n');
        await _appendToToday(all);
        _pending.clear();
      } else {
        await _appendToToday(entry);
      }
    } catch (e) {
      debugPrint('DebugLogger init error: $e');
    }
  }

  /// 清理超过 retentionDays 天的日志文件
  static Future<void> _cleanupOldLogs() async {
    try {
      final dir = Directory(_dir);
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        // 匹配 debug_log_YYYY-MM-DD.txt
        final m = RegExp(r'^debug_log_(\d{4})-(\d{2})-(\d{2})\.txt$').firstMatch(name);
        if (m == null) continue;
        final day = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
        if (day.isBefore(cutoff)) {
          await entity.delete();
          debugPrint('DebugLogger 清理旧日志: $name');
        }
      }
    } catch (_) {}
  }

  /// 记录一次操作（追加到当天文件）
  static Future<void> log(String tag, String msg) async {
    final elapsed = _watch?.elapsedMilliseconds ?? 0;
    _seq++;
    final dt = DateTime.now();
    final line = '[${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}.${dt.millisecond.toString().padLeft(3,'0')}] '
        '[#$elapsed|$_seq] '
        '[$tag] $msg';

    debugPrint(line);
    final entry = '$line\n';

    // 内存缓冲区（保留最近 200 条）
    _buffer.add(line);
    if (_buffer.length > 200) _buffer.removeFirst();

    if (!_ready) {
      _pending.add(entry);
      return;
    }
    try {
      await _appendToToday(entry);
    } catch (_) {}
  }

  static Future<void> _appendToToday(String entry) async {
    final f = File(_pathFor(DateTime.now()));
    await f.writeAsString(entry, mode: FileMode.append);
  }

  // ---- 查询（男主 query_logs 工具用）----

  /// 查询结果：匹配行 + 总匹配数
  static ({List<String> lines, int total}) query({
    String? keyword,
    String? level,
    int limit = 15,
    String? date,
  }) {
    // 取日志源：'today'/'yesterday'/'2026-08-06' → 读对应文件；null → 内存缓冲
    List<String> source;
    if (date == null || date == 'today') {
      source = _buffer.toList(growable: false);
    } else if (date == 'yesterday') {
      source = _readFile(_pathFor(DateTime.now().subtract(const Duration(days: 1))));
    } else {
      final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
      if (m == null) return (lines: [], total: 0);
      source = _readFile(_pathFor(DateTime(
          int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!))));
    }

    final kw = keyword?.toLowerCase();
    final lv = level?.toLowerCase();
    // 级别关键词：error → 错误/失败/❌；warning → 警告/⚠️
    final levelPattern = switch (lv) {
      'error' => RegExp(r'错误|失败|❌|Exception|Error'),
      'warning' => RegExp(r'警告|⚠️|Warn'),
      _ => null,
    };

    final matched = <String>[];
    for (final line in source) {
      if (kw != null && !line.toLowerCase().contains(kw)) continue;
      if (levelPattern != null && !levelPattern.hasMatch(line)) continue;
      matched.add(line);
    }
    final total = matched.length;
    // 截断：取最后 limit 条（最近的）
    final lines = total <= limit ? matched : matched.sublist(total - limit);
    return (lines: lines, total: total);
  }

  static List<String> _readFile(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return [];
      return f.readAsLinesSync();
    } catch (_) {
      return [];
    }
  }
}
