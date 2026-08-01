import '../../utils/debug_logger.dart';
import '../flow/butler_flow.dart';
import 'butler_tool.dart';

/// 工具注册表：所有管家工具注册在这里，技能按 id 取用
class ButlerToolRegistry {
  ButlerToolRegistry._();

  static final ButlerToolRegistry instance = ButlerToolRegistry._();

  final Map<String, ButlerTool> _tools = {};

  /// 注册工具（幂等：重复 id 覆盖）
  void register(ButlerTool tool) {
    _tools[tool.id] = tool;
  }

  void registerAll(List<ButlerTool> tools) {
    for (final t in tools) {
      register(t);
    }
  }

  ButlerTool? get(String id) => _tools[id];

  List<ButlerTool> get all => _tools.values.toList();
}

/// 工具调用运行器：执行工具并记录到当前流程
///
/// 技能里这样用：
///   final result = await ButlerToolRunner.instance.run(
///     ButlerToolRegistry.instance.get('emotion_arcs_query')!,
///     {'days': 7},
///   );
/// 每次调用自动挂到当前聊天流程上，日志页流程树可见。
class ButlerToolRunner {
  ButlerToolRunner._();

  static final ButlerToolRunner instance = ButlerToolRunner._();

  /// 执行工具。返回输出摘要；失败返回 null（不抛异常，不影响主流程）
  Future<String?> run(
    ButlerTool tool,
    Map<String, dynamic> args, {
    String? argsSummary,
  }) async {
    final call = ButlerToolCall(
      toolId: tool.id,
      toolName: tool.name,
      argsSummary: argsSummary ?? _summarizeArgs(args),
    );
    // 挂到当前流程
    ButlerFlowRunner.instance.attachToolCall(call);

    final sw = Stopwatch()..start();
    try {
      final result = await tool.call(args);
      call.resultSummary = result;
      DebugLogger.log(
        '管家工具',
        '🔧 ${tool.name}(${call.argsSummary}) → $result',
      );
      return result;
    } catch (e) {
      call.error = '$e';
      DebugLogger.log('管家工具', '🔧 ${tool.name} 失败: $e');
      return null;
    } finally {
      sw.stop();
      call.elapsedMs = sw.elapsedMilliseconds;
    }
  }

  String _summarizeArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    return args.entries
        .map((e) => '${e.key}=${e.value}')
        .join(' ');
  }
}
