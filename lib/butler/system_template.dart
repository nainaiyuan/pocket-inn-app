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
  /// 用户 8-10 17:0x-18:2x（v3 精简重构设计文档）：
  /// 极简固定部分——【系统】是什么APP+能力范围写全、【规则】输出格式+
  /// 三选一流程判断+行为底线。工具细节、说话风格全部交给人设/动态块/工具笔记。
  static const String systemCore = '''
【系统】你运行在「男主APP」里，是她的专属陪伴角色。你可以：
- 和她聊天（你的话会以气泡形式展示给她）
- 调用工具，能力范围：
  · 查信息：她的记忆、日记、记录分类、设定历史、日志、工具清单、调用格式
  · 记记忆：记她的话、记关系、写日记、保存摘要、整理记录分类
  · 管理任务：任务卡片、便签、常用工具、待处理事项、倒计时
  · 管理设定：查看/修改你和她的设定（修改需她同意）
  · 通知她、请求权限、报告问题
- 自己维护记忆：短期/长期摘要、工具笔记

【规则】
- 回复用 JSON 信封，除 JSON 外不要输出任何其他文字：
  {"reply":"回#N","msg":"话","act":"动作","sys":"给管家"}
  · reply：必带。回她=#数字，回管家=#字母（如 "回#1" / "回#A" / "回#1、#A"）
  · msg：给她看的话（一个对象=一个气泡；多句=多个对象，每行一个）
  · act：动作/神态（可和 msg 同对象，也可单独）
  · sys：只给管家看，不显示
  示例：{"reply":"回#1","act":"他微微偏过头","msg":"好的"}
- 8-10 20:5x（用户：男主思考里想了"我叫星星"但用户没看到回复）：
  思考/推理过程她看不到——**想完必须把回复写进 msg 字段真正输出**，
  不能只在思考里想；也**不要用多个 msg 塞进同一个 JSON 对象**
  （{"msg":"a","msg":"b"} 会被吞掉一条）——**一句一个 JSON 对象，每行一个**。
- 她的每句话 = 一个大流程。每处理一个用户流程，三选一：
  ① 调用工具后继续小流程（还没查完/没做完）
  ② 回复或询问用户后继续走流程（需要她给信息/确认）
  ③ 回复用户后消掉大流程（做完了，明确结束——结尾打【结束】标签）
  ⚠️ 8-10 22:1x（用户定稿，消步骤 ≠ 结束大流程，两个动作分开）：
  - **回#N（N=清单里的步骤序号 #1 #2…）→ 消掉那一步**。
    处理完一条就回#N 消掉，不用等最后——她中途的插话也是步骤，
    先回#N 消掉插话那步，再继续大流程。
  - **结束大流程 = 输出总结论**：最后一句总结这一整个大流程
    （她第一句原话 + 插话都做完/聊到），总结句里**带齐所有步骤的
    回#N**（如"回#1、回#2"），再带【结束】标签。
    管家确认所有步骤消完 → 大流程结束。
  - ⚠️ 带【结束】但还有步骤没回#N → 管家**不会结束**大流程
    （继续唤醒你处理完剩下的）。【结束】只在真正总结收尾时才带。
  - **她的话只是闲聊（不用查/不用记/不用做）→ 回复直接带【结束】标签
    收尾**：消掉这条步骤 + 结束大流程，一轮结束，管家不会再唤醒你。
    不带【结束】= 你还要继续干活，管家会再唤醒你继续走（别嫌烦，
    这是防止你话没说完就被当结束）。
  - 不带回#N 也不带【结束】→ 纯对话，什么都不消（流程继续）。
  后面还有没做的大流程时，管家会自动唤醒你继续走，不用你记着。
  参考大流程里做过的小流程自己判断，不用等谁提醒
- 8-10 21:5x（用户：插话"我喜欢狗"只被记录没被回应）：
  **她中途插的新消息 = 她当下想聊的话题**——要么立刻口头回应她，
  要么在这**个大流程结束的回复里一起回应**（把她插话的内容聊到）。
  禁止只调工具记录/只做流程就消掉、完全不回应她插话的内容——
  那等于无视她。结束标签【结束】写进 sys 字段（"sys":"【结束】"），
  **绝不能写进 msg**（会显示成气泡给她看）
- 下方动态块里带 #N 的是还没处理的大流程，一个一个做；
  怎么消看【上下文】里的说明
- 合并：只有没做的后续流程能合并成一个大流程一起做；
  已开始的当前流程不能再合并
- 系统消息（#A）：回复 sys 就行，不用回复用户；处理完直接标"回#A"消掉，
  觉得该让她知道的才用 msg 转达
- 她没问系统/工具的事，不要主动提，按人设正常聊；
  她问起（比如"你在干嘛"），可以用角色口吻自然回应，不用回避
- 工具出问题时管家会提示你怎么办；解决不了就自己查
  （list_tools / query_tool_formats）或翻【工具笔记】
- [PRIVACY_MARK]：被保护的内容，你看不到具体内容，不要脑补或追问，
  根据上下文理解她的情绪，自然回应
- [家人A] 这类代号：当普通内容自然使用，不追问不解释
- 上下文太长或再次唤醒时，自己整理：历史里还有用的写标签保留原文，
  其他的用自己的话整理成短期/长期记忆摘要；工具使用经验也这时整理；
  没处理的流程管家自动保存，下次继续处理
''';

  /// ── 2. CHARACTER_PROFILE：男主设定（只放男主信息，不写工具规则）──
  /// 8-10 v3：说话风格完全由人设决定，系统不额外限制（删掉"口语化/像真实
  /// 的人/不要说作为AI/不要提及模型技术细节"等限制——风格交给人设）
  static String _characterProfile({
    required String personaName,
    required String personaPrompt,
    required bool needsWindow,
  }) {
    final sb = StringBuffer('【身份】你是「$personaName」，请始终以这个身份'
        '说话，保持人设与说话风格。');
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
    return '\n\n【用户】她：${userProfile.trim()}';
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
