import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 完整 prompt 记录（8-12 01:5x 用户：每轮 prompt 全部直接记录到文件，
/// 随时能翻能复制，不用靠日志/不用复制给管家）。
/// 文件：{doc}/_data/agent_prompt_log.txt（追加模式，不截断）。
/// 8-12 02:0x（用户：固定的没必要重复记）：固定设定只记一次
/// （内容变了才重记），每轮只记动态块（工作区/待办/历史等变化部分）。
class PromptLog {
  static const String _fileName = 'agent_prompt_log.txt';

  /// 上次写过的固定设定（内容变了才重写；内存态，重启后第一轮重记一次）
  static String? _lastFixed;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/_data');
    if (!d.existsSync()) d.createSync(recursive: true);
    return File('${d.path}/$_fileName');
  }

  /// 轮输入：时间戳 + 轮类型 + 她的话 + 动态块（固定设定只记一次）
  static Future<void> appendInput({
    required String personaName,
    required bool isToolRound,
    required String userInput,
    String? fixedBlock,
    required List<String> dynamicBlocks,
  }) async {
    try {
      final f = await _file();
      final sb = StringBuffer();
      // 固定设定：首次或内容变化才写（带标记，方便找）
      if (fixedBlock != null && fixedBlock.trim().isNotEmpty) {
        if (_lastFixed != fixedBlock) {
          sb.writeln('════════════════════════════════════════════');
          sb.writeln('【固定设定·只记一次】${_lastFixed == null ? '（首次）' : '（内容已变化，重记）'}');
          sb.writeln(fixedBlock);
          _lastFixed = fixedBlock;
        }
      }
      sb.writeln('════════════════════════════════════════════');
      sb.writeln(
          '[${DateTime.now().toString().substring(0, 19)}] ${isToolRound ? '🔧工具轮' : '💬用户轮'} $personaName');
      if (userInput.trim().isNotEmpty) {
        sb.writeln('她：$userInput');
      }
      sb.writeln('── 男主收到的输入（动态块，固定设定见上方只记一次段）──');
      for (final b in dynamicBlocks) {
        sb.writeln(b);
        sb.writeln('────');
      }
      await f.writeAsString(sb.toString(), mode: FileMode.append);
    } catch (_) {
      // 记录失败不影响主流程
    }
  }

  /// 轮输出：男主回复命令 + 工具调用
  static Future<void> appendReply({
    String? modelText,
    List<String>? toolCallBriefs,
  }) async {
    try {
      final f = await _file();
      final sb = StringBuffer();
      if (toolCallBriefs != null && toolCallBriefs.isNotEmpty) {
        sb.writeln('🛠 工具调用：${toolCallBriefs.join('；')}');
      }
      if (modelText != null && modelText.trim().isNotEmpty) {
        sb.writeln('➡️ 男主回复：${modelText.trim()}');
      }
      if (sb.isNotEmpty) {
        await f.writeAsString(sb.toString(), mode: FileMode.append);
      }
    } catch (_) {}
  }

  /// 读全文
  static Future<String> readAll() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return '（还没有记录）';
      return await f.readAsString();
    } catch (_) {
      return '（读取失败）';
    }
  }

  /// 文件大小（字节）
  static Future<int> size() async {
    try {
      final f = await _file();
      return f.existsSync() ? await f.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// 清空
  static Future<void> clear() async {
    try {
      final f = await _file();
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
