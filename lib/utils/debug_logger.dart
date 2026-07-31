import 'dart:io';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 调试日志引擎 — 内存缓冲区 + 文件双写
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._();
  factory DebugLogger() => _instance;
  DebugLogger._();

  static String _logPath = '';
  static bool _ready = false;
  static final List<String> _pending = [];
  static int _seq = 0;
  static Stopwatch? _watch;

  /// 内存缓冲区（最近 200 条，供页面显示）
  static final Queue<String> _buffer = Queue();
  static List<String> get recentLogs => _buffer.toList(growable: false);
  static String get recentLogsText => _buffer.join('\n');

  /// 初始化
  static Future<void> init() async {
    _watch = Stopwatch()..start();
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _logPath = '${appDir.path}/debug_log.txt';
      debugPrint('DebugLogger path: $_logPath');
      final f = File(_logPath);
      await f.parent.create(recursive: true);
      await f.writeAsString('');
      _ready = true;
      if (_pending.isNotEmpty) {
        final all = _pending.join('\n');
        await f.writeAsString(all);
        _pending.clear();
      }
    } catch (e) {
      debugPrint('DebugLogger init error: $e');
    }
  }

  /// 记录一次操作
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
      final f = File(_logPath);
      await f.writeAsString(entry, mode: FileMode.append);
    } catch (_) {}
  }
}
