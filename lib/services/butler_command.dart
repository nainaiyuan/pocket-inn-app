import '../utils/debug_logger.dart';

/// 男主指令模块 —— 男主在回复里用统一格式输出指令，管家识别处理
///
/// 指令格式：`#指令名 参数#`
///   - #记录 内容#       男主想记录用户的喜好/事实 → 弹窗审批 → 写入记忆
///   - #查记忆 关键词#    男主申请调取记忆 → 弹窗授权 → 注入下轮 prompt
///   - #定时 时间 内容#   男主设提醒（预留，后续接 cron）
///   - #帮助#            列出所有指令（命令模块，男主可自查）
///   - #model 名称 长度#  AI 回答自己的模型名和上下文窗口长度（窗口确认）
///
/// 所有指令解析后从显示文本剥离（仅管家可见，不显示给用户）。
/// 解析结果
class ParsedCommand {
  final String type;
  final String raw; // 原始指令文本（#…#）
  final String arg; // 参数（去掉指令名）
  ParsedCommand(this.type, this.raw, this.arg);

  /// 展示名（男主看得懂）
  String get label => switch (type) {
        ButlerCommandParser.cmdRecord => '记录',
        ButlerCommandParser.cmdRecall => '查记忆',
        ButlerCommandParser.cmdTimer => '定时',
        ButlerCommandParser.cmdHelp => '帮助',
        ButlerCommandParser.cmdModel => '模型窗口',
        _ => type,
      };
}

class ButlerCommandParser {
  ButlerCommandParser._();
  static final ButlerCommandParser instance = ButlerCommandParser._();

  /// 指令类型
  static const String cmdRecord = 'record'; // 记录
  static const String cmdRecall = 'recall'; // 查记忆
  static const String cmdTimer = 'timer'; // 定时（预留）
  static const String cmdHelp = 'help'; // 帮助
  static const String cmdModel = 'model'; // 窗口确认


  /// 男主可见的指令说明（#帮助# 时男主自己能看到）
  static const String helpText = '我可以用这些指令帮你做事（管家会处理，你看不到指令本身）：\n'
      '- #记录 内容#：把关于你的事记下来（你确认后才会记）\n'
      '- #查记忆 关键词#：看看我记不记得以前的事（你同意后我才看）\n'
      '- #定时 时间 内容#：到点提醒你（以后会有）\n'
      '- #帮助#：查看这个列表';

  /// 从文本中解析所有指令，返回指令列表；同时提供剥离后的显示文本
  List<ParsedCommand> parse(String text, {String? characterId}) {
    final commands = <ParsedCommand>[];
    final re = RegExp(r'#([^\n#]+)#');
    for (final m in re.allMatches(text)) {
      final inner = m.group(1)!.trim();
      if (inner.isEmpty) continue;
      // 指令名 = 第一个词
      final parts = inner.split(RegExp(r'\s+'));
      final name = parts.first;
      final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      final type = _matchType(name);
      if (type != null) {
        commands.add(ParsedCommand(type, m.group(0)!, arg));
        DebugLogger.log(
          '指令模块',
          '📮 识别到男主指令 [${_matchType(name)}] ${arg.isEmpty ? '' : '参数: $arg'}',
        );
      }
    }
    return commands;
  }

  /// 剥离所有指令，返回显示文本（男主回复 → 用户看到的干净版本）
  String strip(String text) {
    return text.replaceAll(RegExp(r'#([^\n#]+)#'), '').trim();
  }

  String? _matchType(String name) {
    switch (name) {
      case '记录':
      case '记住':
      case '记':
        return cmdRecord;
      case '查记忆':
      case '回忆':
      case '调取记忆':
        return cmdRecall;
      case '定时':
      case '提醒':
      case '计时':
        return cmdTimer;
      case '帮助':
      case '指令':
      case '命令':
        return cmdHelp;
      case 'model':
      case '模型':
        return cmdModel;
      default:
        return null;
    }
  }

  /// 处理 #model 回复（AI 回答自己的窗口长度）
  /// 格式：#model <模型名> <上下文Token数>
  bool handleModelResponse(String text, {required String characterId}) {
    final m = RegExp(r'#model\s+(\S+)\s+(\d+)', caseSensitive: false)
        .firstMatch(text);
    if (m == null) return false;
    final window = int.tryParse(m.group(2)!);
    if (window != null && window > 0) {
      DebugLogger.log('指令模块', '🎯 男主自报模型: ${m.group(1)} 窗口 $window token');
      return true;
    }
    return false;
  }
}
