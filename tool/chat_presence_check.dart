// ChatPresence 快速验证（纯 Dart，无需 Flutter SDK 也能跑部分逻辑）
// 用法: dart run tool/chat_presence_check.dart
import 'dart:io';

void main() {
  // 由于 ChatPresence 依赖 flutter foundation（ChangeNotifier），
  // 这里只验证纯逻辑部分：时间格式化
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 14, 30);

  // 模拟 ChatPresence.formatTime
  String formatTime(DateTime time) {
    final today0 = DateTime(now.year, now.month, now.day);
    final thatDay = DateTime(time.year, time.month, time.day);
    final diffDays = today0.difference(thatDay).inDays;
    final hm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    if (diffDays <= 0) return hm;
    if (diffDays == 1) return '昨天 $hm';
    if (time.year == now.year) return '${time.month}月${time.day}日 $hm';
    return '${time.year}年${time.month}月${time.day}日 $hm';
  }

  final cases = [
    (today, '14:30'),
    (now.subtract(const Duration(days: 1)), '昨天 ${now.subtract(const Duration(days: 1)).hour.toString().padLeft(2, '0')}:00'),
    (DateTime(now.year, 3, 2, 9, 5), '3月2日 09:05'),
    (DateTime(2024, 12, 1, 8, 0), '2024年12月1日 08:00'),
  ];

  var pass = 0;
  for (final (input, expected) in cases) {
    final got = formatTime(input);
    final ok = got == expected;
    if (ok) {
      pass++;
    } else {
      stdout.writeln('FAIL: ${input.toIso8601String()} → "$got" 期望 "$expected"');
    }
  }
  stdout.writeln('时间格式化: $pass/${cases.length} 通过');
  exit(pass == cases.length ? 0 : 1);
}
