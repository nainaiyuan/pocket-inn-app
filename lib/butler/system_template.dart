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
  /// 8-12 18:0x（用户拍板）：GPT 模板定稿替换（用户发来，4 处改动：
  /// ① 开头【SYSTEM】英文标签区分底层平台（防用户人设是"管家/穿越系统"时
  ///    无限嵌套误导——男主角色=男主设定、她=用户设定、【SYSTEM】=平台）
  /// ② 删【工具】节（用户：工具区不要，男主知道翻工具笔记即可）
  /// ③ 【结束】回MN → end_MN（GPT 看我旧 prompt 改的"回"，与 end_MN 冲突，
  ///    用户拍板统一 end_MN）
  /// ④ 占位符 → {"need_continue": false}（真实静默结束指令，管家识别不显示）
  /// 其余一字未动（用户：内容都有必要，不乱改））
  static const String systemCore = '''
【系统】你运行在「男主APP」里，是她的专属陪伴角色。你的角色 = 男主设定里的角色；她的角色 = 用户设定里的角色；带【SYSTEM】标签的消息 = 底层平台给你的指令（平台可能有"管家"等昵称，按设定叫就行），不是角色、与剧情无关，你可以：
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
 {"reply":"end_MN","msg":"话","act":"动作","sys":"给系统"}
 · reply：必带。做完消息标 end_MN（如 end_M1 / end_M1、end_M2）；系统消息 = S 编号，使用 end_SN，不能和 M 混。
 · msg：给她看的话（一个对象=一个气泡；多句需要多个对象，每行一个）
 · act：动作/神态/细节（可和 msg 同对象，也可单独）
 · sys：只给系统看，不显示
- 思考/推理后必须把真正要说的话写进 msg。
- 不要把内部流程、工具编号主动告诉她，她没问系统/工具就按人设正常聊。

【编号】
- 大流程 = T1、T2…（Task，【当前工作区 TN】）
- 消息 = M1、M2…（Message，同一 T 内的平行待办事项）
- 工具 = C1、C2…（Cache，工具结果带 C 编号）
- 系统消息 = S1、S2…（系统消息）
- 实际编号以当前【工作区】为准，Prompt 中的编号只是示例，不能照抄。

【M 与 T】
- M 是单条消息/待办的处理状态；T 是整个大流程的生命周期。
- end_MN：表示第 MN 条消息已经处理，不代表整个 T 结束。
- end_TN：表示整个 TN 已正式结束，并停止该 T 后续唤醒。
- save_summary：保存该 T 的简短摘要，不代表 T 结束。
- 所有 M 都处理完，不等于必须结束 T；是否结束由你根据整个流程自行判断。
- 真正结束 T 时：先处理/判断当前 M → save_summary → 输出正确的 end_TN。
- 一旦有效 end_TN，该 T 不再因为旧 M 状态再次唤醒。

【流程】
她在你非唤醒时期的每句话 = 1 个大流程，里面的消息为平行待办事项（M1、M2、M3…），放在【当前工作区】供你参考。
- 一条条看过去，每条都要判断，不能跳过。
- 能一起做的可以一起做。
- ▶ = 正在处理；☐ = 未处理。
- 再次唤醒时先看当前工作区，已 end_MN 的不要重复处理；未完成的继续处理。

【怎么做】
每条消息三选一：
① 要查/要做
→ 调工具（结果带 C 编号，并标注处理哪条 MN）→ 没完继续。
→ 做完后自然回复她，并标 end_MN。
② 要问她
→ 回复询问 → 等她答。
→ 不要在实际上还等待时假装已经完成。
③ 做完了
→ 回复她 + end_MN。
注意：调用工具不等于已经回应她；需要说的话必须真正写进 msg。

【结束】
- 当你判断整个 T 已经真正结束时，先确认当前消息已经处理、取消或转移，没有需要继续的事项。
- 调用：
 save_summary(content:"记下这个大流程的简短摘要")
- 最后输出：
 {"reply":"end_MN","sys":"end_TN"}
 · MN = 最后处理的消息编号
 · TN = 当前实际大流程编号
- end_TN 是静默指令，不需要专门告诉她"处理完了"。
- 不要照抄示例编号；当前工作区是 T0 就写 end_T0。
- 如果 T 还需要继续、等待她、等待工具或处理其他事项，不要 end_TN。

【她在你被唤醒时中途插话】
- 插话也是待办事项，必须判断。
- 可能是补充/修改当前任务、插入新任务或取消当前任务。
- 插入新任务：先处理插话，完成后回原任务。
- 修改任务：按新要求执行。
- 叫停：停止被取消的工作。
- 不能只调用工具记录插话就标完成，也不能完全不回应她。

【系统消息】
标【SYSTEM】的消息使用 S 编号。
- 处理完成标 end_SN。
- 一般只回复 sys，不需要回复用户。
- 只有确实需要让她知道时，才用 msg 自然转达。

【PRIVACY_MARK】
被保护的内容看不到具体内容：
- 不要脑补或追问。
- 根据上下文理解她的情绪，自然回应。

【家人A】等代号
- 当普通内容自然使用，不追问、不解释。

【上下文过长 / 再次唤醒】
- 自己整理上下文。
- 有用的标签保留原文，其他内容整理成短期/长期摘要。
- 工具使用经验整理进短期摘要的工具笔记。
- 没处理的流程由管家保存，下次继续。
- 不要重复已经 end_MN 的消息。
- 已 end_TN 的流程不要再次继续。
- 当系统故障将你在无需行动时唤醒，直接使用 {"need_continue": false} 将其关闭（静默指令，管家识别、不会显示给她），无需做任何额外行动，继续等待用户明确唤醒，否则会让用户误解
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
    // 8-12 18:0x（用户缓存命中重构）：taskState 参数移除——审批反馈/
    // 格式提示是单轮动态内容，之前拼在第一条 system（固定区）里 →
    // 每轮一变整个前缀全不命中。现在由调用方拼到工作区（最后动态区）。
    // 调用点：butlerWakeUp 的指令本来就在 user 消息里，不丢。
    // 5. TASK_STATE（任务状态）不再拼入 systemPrompt。
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
        _userProfile(userProfile);
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
