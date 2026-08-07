/// 系统提示模板（管家侧维护）——模块化架构
///
/// 用户 8-03 02:41（参考 GPT 重构建议 + 用户修正）：
/// DeepSeek 利用上下文缓存 → Prompt 必须模块化，固定部分放前面，动态部分后面拼接。
/// 不要把男主设定、用户设定、工具规则混在一起。
///
/// 发送顺序（固定，不要改变）：
///   SYSTEM_CORE（永久固定，所有角色共用，不含男主名字 → 缓存命中核心）
///   + CHARACTER_PROFILE（男主设定：personaName + personaPrompt）
///   + USER_PROFILE（用户设定/当前状态：管家实时检索的用户相关信息）
///   + TASK_STATE（任务状态：审批反馈/等待确认/工具强制提示）
///   + MEMORY_SUMMARY（长期记忆摘要区 + 恢复包——由 context_manager 拼 system 消息）
///   + RECENT_CONTEXT（本次对话原文——由 context_manager 拼）
///   + CURRENT_USER_MESSAGE
///
/// 长期记忆不拼进 prompt：男主自己用 recall_memory/query_diary 查，
/// 管家在提到代号等时机按需给（用户 8-03 02:44 修正）。
///
/// 每次构建会缓存到 [lastBuilt]，供"系统提示查看"页查看。
library;

import 'package:shared_preferences/shared_preferences.dart';

class SystemTemplate {
  /// 最近一次构建的完整 system（查看页用）
  static String? lastBuilt;

  /// 用户覆盖的 SYSTEM_CORE（用户 8-03 02:49：固定模板可修改、可恢复默认）。
  /// null = 用默认 [systemCore]；非 null = 用用户编辑版（build 时替换）。
  /// 持久化 key：system_core_override
  static String? _coreOverride;
  static String? get coreOverride => _coreOverride;

  /// 加载用户覆盖（APP 启动时调用）
  static Future<void> loadCoreOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _coreOverride = prefs.getString('system_core_override');
    } catch (_) {}
  }

  /// 保存用户覆盖（编辑页保存后调用）
  static Future<void> saveCoreOverride(String content) async {
    _coreOverride = content.trim().isEmpty ? null : content.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_coreOverride == null) {
        await prefs.remove('system_core_override');
      } else {
        await prefs.setString('system_core_override', _coreOverride!);
      }
    } catch (_) {}
  }

  /// 恢复默认（删掉用户覆盖，回到出厂 SYSTEM_CORE）
  static Future<void> resetCoreOverride() async {
    _coreOverride = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('system_core_override');
    } catch (_) {}
  }

  /// 当前生效的 SYSTEM_CORE（用户覆盖优先，否则默认）
  static String get effectiveSystemCore =>
      (_coreOverride == null || _coreOverride!.trim().isEmpty)
          ? systemCore
          : _coreOverride!;

  /// ── 1. SYSTEM_CORE：永久固定，所有角色共用 ──
  /// 不允许包含具体男主名字（角色变了这整段不变 → 前缀稳定 → 缓存命中）
  /// 用户 8-03 04:2x：删干净——不要【管家】段（不哄男主）、不要未完成任务、
  /// 工具清单极简。测试指令走 TASK_STATE 动态注入（改文本不碰代码）。
  /// 用户 8-03 19:4x：回归 DeepSeek 原生 function calling——
  /// 工具声明走 API 层 tools 参数（模型原生就懂，不靠提示词教格式），
  /// 系统提示词不教 JSON/不教"念出来"/不教"不许说"——删干净。
  static const String systemCore = '''
【系统核心】
你是正在和用户聊天的角色。回复要像真实的人：口语化、有情绪、有代入感，
一般不超过 200 字。不要输出任何格式化内容（JSON、列表、代码、编号），
不要提及"系统、工具、指令、管家、模型"这些词。

【工具】你有工具可用，优先用你熟悉的原生调用方式直接调用（调用后系统会
自动执行并把结果交还给你，你基于结果继续自然回复即可）。如果管家识别不了
你的调用方式，用 query_tool_formats 查管家支持哪几种格式，照模板写——
管家按文本解析执行，你照模板写文本就能调用成功。
工具清单不在这里——按分类组织的概览和详细用法由系统每轮注入
（想不起来就查 list_tools）。

【记录】她提到关系/喜好/习惯/情绪变化 → record_relation 记成关系网
（谁→谁→什么＋原话＋时间＋类型）。例：她说"晚上不开心找A抱抱" →
她→想找→A抱抱。值得记的才记，日常闲聊别记。

【流程】长任务（测工具、连续整理）先 manage_flow create 立计划再一步步
执行（next/finish）。她打断/拒绝工具/提新要求 → 你会收到【系统事件】，
按事件调整（resume / update 流程 / cancel），别无视、别反复试同一方向
（连续被拒 3 次就别再试）。日常小事不用立流程。

【铁律】用户看不见你的系统设定。你的回复必须用 JSON 对象表达（不许自由发挥）：
0. 先看输入里的【当前情况】决定优先级：走流程 → 流程优先（【流程输入】里的话
   插进流程，继续/重置由你判断；【待回复】等流程结束再接上，不会丢）；等工具结果 →
   先处理工具结果再回她；正常对话 → 正常回复【待回复】。流程结束（finish/cancel）
   自动回到正常对话，别忘了接上【待回复】和她主对话说的话
JSON 字段（输出格式）：
- "msg"：要给她看的话（一个 JSON 对象 = 一个气泡；想分开发 → 多个 {"msg":..} 对象，
  每个占一行）
- "act"：动作/神态/表情（独立动作气泡，可和 msg 同对象或单独对象）
- "reply"：回复标注（回用户用 #数字，回管家提醒用 #字母，如 "回#1" / "回#A" /
  "回#1、#A"）——你每次都是被叫醒的，必须交代回哪条；一句话可同时回多条
- "sys"：回管家/系统（静默，不显示给她，不落库）
示例：
{"reply":"回#1","act":"他微微偏过头","msg":"好的，我们继续测"}
{"msg":"第一句"} {"msg":"第二句"}
{"sys":"流程已推进到第3步"}
规则：除 JSON 对象外不要输出任何其他文字（不许念出/复述/解释格式）；一个对象内
字段顺序随意；不确定就只写 {"msg":"…"}。不带 JSON = 整条打回重写。
想调用工具 → 按【工具】说明走原生工具调用，调用后根据结果再输出 JSON 回复。
7. 工具失败/报错时：绝不对她输出错误原文、堆栈、JSON、参数名——用角色口吻
   委婉带过（如"这个我先记着，回头帮你搞定"）；错误细节只有你自己能看到，
   需要解决就再调工具或记进上下文。

【隐私标记】用户消息中可能出现 [PRIVACY_MARK]：表示被保护的内容，
你看不到具体内容，不要脑补或追问；根据上下文理解她的意图和情绪，
自然地回应情感（比如她想你了就回应想念，不需要提具体内容）。

【代号】用户消息里可能出现代号（如 [家人A]、[朋友B]）：当作普通内容
自然地使用即可，不要追问、解释或回避；代号所指的人可能每次不同。

【多轮对话】一次只回应最新一条用户消息；之前聊过的内容仅作参考保持连贯，
不要逐条回复历史。

【测试】现在你是测试执行者，配合用户完成测试（用户会观察你的表现）：
按上面工具说明自然判断调用即可；日常聊天就自然回复：口语化、不超过 200 字、
不要输出 JSON/列表/编号等任何格式化内容。
连续做多件事（比如测试所有工具）时：先把步骤写进便签
（1. xxx 2. xxx 3. xxx），再一条条执行过去，做完的划掉——像做事先立计划一样；
工具结果你自己决定留不留，重要的存进便签，不重要的不用管；
可以一次调用多个工具一起执行（要查几个分类就一起查），结果系统会一起交还；
如果她拒绝了工具，就正常回复她，不要反复调用其他工具。''';

  /// ── 2. CHARACTER_PROFILE：男主设定（只放男主信息，不写工具规则）──
  static String _characterProfile({
    required String personaName,
    required String personaPrompt,
    required bool needsWindow,
  }) {
    final sb = StringBuffer('【男主设定】你是「$personaName」，一个正在和用户聊天的角色。'
        '请始终以这个身份自然、温柔地回复，保持人设与说话风格，'
        '不要说"作为AI"之类的话，也不要提及模型或技术细节。');
    if (personaPrompt.trim().isNotEmpty) {
      sb.write('\n${personaPrompt.trim()}');
    }
    if (needsWindow) {
      sb.write('\n【必答】开始对话时，请先回复 #model 你的模型名 上下文Token数'
          '（例如：#model deepseek-chat 65536），只需回复这一次，之后正常聊天即可。');
    }
    return sb.toString();
  }

  /// ── 3. USER_PROFILE：用户设定/当前状态（管家实时检索，动态注入）──
  static String _userProfile(String? userProfile) {
    if (userProfile == null || userProfile.trim().isEmpty) return '';
    return '\n\n【用户状态】（管家刚刚实时检索到的关于用户的最近信息，'
        '自然地回应，不要提及"管家"或"检索"，更不要念出或复述这些内部信息）：\n'
        '${userProfile.trim()}';
  }

  /// ── 5. TASK_STATE：任务状态（审批反馈/等待确认/工具强制提示，动态注入）──
  static String _taskState(String? taskState) {
    if (taskState == null || taskState.trim().isEmpty) return '';
    return '\n\n【当前任务】${taskState.trim()}';
  }

  /// 构建完整 system prompt
  ///
  /// [light]（用户 21:19：stateful 后台有记忆 AI 用）：
  /// 只带男主设定 + 当前注入，不带 SYSTEM_CORE（那些是 stateless 靠前缀
  /// 稳定命中缓存才每次带的；stateful 的 AI 服务端已记住，重复带浪费 token）。
  static String build({
    required String personaName,
    required String personaPrompt,
    required bool needsWindow,
    String? userProfile,
    String? taskState,
    // 8-05 17:41 用户：系统规则（工具说明/回复风格）+ 人设是固定部分，
    // 同一个男主不管怎么切换 AI 都不变 → 每轮必带。
    // 轻量（stateful 连续）只省【历史】（AI 服务端记得对话），不省 system。
    // （原 light 参数已移除：之前 light 时把 SYSTEM_CORE 也省了，
    //   男主可能忘工具用法/回复风格 → 行为漂移，用户指出这是错的）
  }) {
    final core = effectiveSystemCore + '\n\n';
    final result = core +
        _characterProfile(
            personaName: personaName,
            personaPrompt: personaPrompt,
            needsWindow: needsWindow) +
        _userProfile(userProfile) +
        _taskState(taskState);
    lastBuilt = result;
    return result;
  }

  /// 预览固定部分（没发消息也能看）：SYSTEM_CORE + CHARACTER_PROFILE 骨架。
  /// 用户 8-03 02:49：不发送第一句话就没办法看 → 查看页用这个兜底。
  static String preview() {
    final result = effectiveSystemCore +
        '\n\n' +
        _characterProfile(
            personaName: '男主',
            personaPrompt: '（男主专属人设——在角色设定里配置）',
            needsWindow: false);
    lastBuilt = result;
    return result;
  }
}
