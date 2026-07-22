import 'dart:io';
import 'package:flutter/foundation.dart';

/// 调试日志引擎 — 写入文件，方便用户复制日志给 AI 分析
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._();
  factory DebugLogger() => _instance;
  DebugLogger._();

  static const String _logPath = '/storage/emulated/0/Android/data/com.example.app/files/debug_log.txt';

  static bool _ready = false;
  static final List<String> _pending = [];
  static int _seq = 0;
  static Stopwatch? _watch;

  /// 初始化（应 APP 启动时调用一次）
  static Future<void> init() async {
    _watch = Stopwatch()..start();
    try {
      final f = File(_logPath);
      await f.parent.create(recursive: true);
      await f.writeAsString('');
      _ready = true;
      // 刷 pending
      if (_pending.isNotEmpty) {
        await f.writeAsString(_pending.join('\n'));
        _pending.clear();
      }
    } catch (_) {}
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
