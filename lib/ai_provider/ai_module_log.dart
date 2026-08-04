/// AI 模块日志（2026-08-04 解耦：模块不再直接依赖项目 DebugLogger）。
///
/// ai_provider 模块内部统一走本类输出日志：
/// - 未装配时：print 到控制台（纯 Dart，零插件依赖，搬到哪都能跑）
/// - App 启动时：`AiModuleLog.configure(DebugLogger.log)` 接入项目日志系统
/// - 未来搬到其他项目：configure 自己的日志实现即可，模块代码零改动
library;

typedef AiLogSink = void Function(String tag, String message);

class AiModuleLog {
  AiModuleLog._();

  static AiLogSink? _sink;

  /// 装配项目日志实现（app 启动时调用一次；传 null 恢复默认 print）。
  static void configure(AiLogSink? sink) => _sink = sink;

  static void log(String tag, String message) {
    final sink = _sink;
    if (sink != null) {
      sink(tag, message);
      return;
    }
    // ignore: avoid_print
    print('[$tag] $message');
  }
}
