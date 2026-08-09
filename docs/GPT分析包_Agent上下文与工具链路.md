# GPT 分析包：男主APP Agent 上下文与工具链路（2026-08-09 生成）

> 仓库：github.com/nainaiyuan/pocket-inn-app（main 分支）
> 本文件 = 从本地源码直接提取，与 GitHub 完全一致（commit c08f33a）
> 行号 = 本地文件行号，GitHub 上一致（blob 链接可带 #L 锚点跳转）

---

## ① context_manager.dart 核心函数（lib/pages/chat/services/context_manager.dart）

### feedUserMessage / feedAssistantMessage / feedToolCall（155-275行）
        : '${t.month.toString().padLeft(2, '0')}-'
            '${t.day.toString().padLeft(2, '0')} $hhmm';
  }

  /// 记录用户消息（同时做话题切换检测）
  void feedUserMessage(String personaId, String text) {
    if (text.trim().isEmpty) return;
    // 记录"最后聊天时间"（stateful 空闲超时检测用：服务器多久没聊天
    // 就释放上下文缓存——用户 21:47 澄清，不是"每N小时强制写"，
    // 是"空闲 N 小时 → 缓存没了"，下次聊天要检测并沉淀+恢复）
    _lastChatMs[personaId] = DateTime.now().millisecondsSinceEpoch;
    unawaited(_persistLastChat(personaId));
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    final words = _extractKeywords(text);
    if (words.isNotEmpty &&
        t.keywords.isNotEmpty &&
        t.raw.length >= minTopicMessagesBeforeSwitch &&
        _jaccard(words, t.keywords) < topicSwitchThreshold) {
      // 话题切换：⚠️ 不能丢旧话题原文（里面是男主回答+用户消息，
      // 丢了历史就"完全没带上男主的回答"——用户 8-03 00:07 报）。
      // 旧话题原文并入新话题的 raw（保留男主回答），只重置关键词。
      final oldRaw = t.raw;
      final fresh = TopicState()..raw.addAll(oldRaw);
      fresh.raw.add('用户 [${_ts(DateTime.now())}]：$text');
      fresh.keywords.addAll(words);
      _topics[personaId] = fresh;
      return;
    }
    t.keywords.addAll(words);
    t.raw.add('用户 [${_ts(DateTime.now())}]：$text');
    // 8-04 16:4x：原文镜像落库（干净文本）——重启后 restore 重建用
    unawaited(ChatStorageService().appendContextRaw(personaId, '用户', text));
  }

  /// 记录男主回复（进当前话题原文）
  void feedAssistantMessage(String personaId, String text) {
    if (text.trim().isEmpty) return;
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    t.raw.add('男主 [${_ts(DateTime.now())}]：$text');
    // 8-04 16:4x：原文镜像落库（干净文本）——重启后 restore 重建用
    unawaited(ChatStorageService().appendContextRaw(personaId, '男主', text));
  }

  /// 记录工具调用（进当前话题原文）——8-04 17:0x（用户：上下文要留
  /// 地方放工具，男主才知道自己做过什么；成功写了什么/失败原因，
  /// 失败后才能继续调工具解决）。
  /// 行格式：'工具 [17:05]：record_memory ✅成功：已记录…'（不截断）
  /// 只针对 stateless（要带上下文的 AI）：stateful 轻量时不带历史。
  void feedToolCall(
      String personaId, String toolName, bool ok, String resultText) {
    if (toolName.trim().isEmpty) return;
    final t = _topics.putIfAbsent(personaId, TopicState.new);
    final mark = ok ? '✅成功' : '❌失败';
    // 8-07 22:4x 借鉴 OpenClaw 工具结果上下文保护（MAX_TOOL_RESULT_CONTEXT_SHARE）：
    // 单条工具结果 >3000 字符截断（保头保尾），防 query_logs 等大结果撑爆上下文
    var text = resultText;
    if (text.length > 3000) {
      text = '${text.substring(0, 1500)}\n…（中间 ${text.length - 3000} 字符已截断，完整结果见日志/DB）…\n${text.substring(text.length - 1500)}';
    }
    t.raw.add(
        // 8-06 00:48 用户：男主分不清三类输入 → 工具记录标注"非她发言"
        '工具 [${_ts(DateTime.now())}]：$toolName $mark（非她发言）：$text');
    // 原文镜像落库（role='工具'，restore 重建时从 created_at 补时间戳）
    unawaited(ChatStorageService()
        .appendContextRaw(personaId, '工具', '$toolName $mark：$text'));
  }

  // ---- 读取 / 组装 ----

  /// 待回复/已回复视图（8-06 21:26-21:30 用户设计）：
  /// 从原文算"男主最后一句回复之后她的话" = 待回复（自动，男主回完自动沉）。
  /// 已回复 = 最近 repliedN 对（她的话 → 你的回复）。
  /// 返回 (pending: ['待#1 [21:15] 内容', ...], replied: ['[21:10] 她：… → 你：…', ...])
  ({List<String> pending, List<String> replied}) pendingRepliedView(
      String personaId,
      {int repliedN = 3}) {
    final t = _topics[personaId];
    if (t == null || t.raw.isEmpty) return (pending: const [], replied: const []);
    final raw = t.raw;
    // 找最后一个男主行
    var lastMaleIdx = -1;
    for (var i = raw.length - 1; i >= 0; i--) {
      if (raw[i].startsWith('男主')) {
        lastMaleIdx = i;
        break;
      }
    }
    // 待回复 = 最后男主行之后的所有用户行（工具行跳过）
    final pending = <String>[];
    var n = 0;
    for (var i = lastMaleIdx + 1; i < raw.length; i++) {
      final line = raw[i];
      if (!line.startsWith('用户')) continue;
      n++;
      pending.add('待#$n ${_stripPrefix(line, keepTs: true)}');
    }
    // 已回复 = 最后男主行往前配对的最近 repliedN 对
    final replied = <String>[];
    if (lastMaleIdx >= 0) {
      // 从最后男主行往前找"她的话 → 你的回复"对（跳过工具行）
      final pairs = <(String, String)>[];
      String? pendingUser;
      for (var i = lastMaleIdx; i >= 0; i--) {
        final line = raw[i];
        if (line.startsWith('用户')) {
          if (pendingUser == null) {
            pendingUser = _stripPrefix(line, keepTs: true);
          }
        } else if (line.startsWith('男主')) {
          if (pendingUser != null) {
            pairs.add((pendingUser, _stripPrefix(line, keepTs: true)));
            pendingUser = null;
            if (pairs.length >= repliedN) break;
          }
        }
      }
      for (final pr in pairs.reversed) {
        replied.add('${pr.$1} → 你：${pr.$2}');
      }
    }
    return (pending: pending, replied: replied);
  }

  /// 组装历史消息（摘要区 + 当前话题原文），插在 system 之后。
  /// 当前话题原文超过预算时截断最旧部分（兜底；正常由总结触发清空）。
  List<AIChatMessage> buildHistoryMessages(String personaId, {String? modelHint}) {

### buildHistoryMessages（275-390行）
  List<AIChatMessage> buildHistoryMessages(String personaId, {String? modelHint}) {
    final out = <AIChatMessage>[];

    // 恢复包（stateful 空闲超时后 AI 忘了 → 本次带"下次要带的上下文"接上；
    // 用户 21:52：男主提前写好的分类存档，管家恢复时带上）
    // 8-05 17:50 用户：恢复包 = 男主已总结过的上下文（精简版）→ 有它就
    // 【替换】整个上下文（摘要+工具历史+历史对话），不重复带。
    // 安全前提：恢复包只在空闲过半时写，写完用户继续聊会重置计时并重新
    // 沉淀 → 超时恢复时恢复包一定是最新的、后面没有新对话 → 替换不丢内容。
    final recovery = _recovery[personaId];
    if (recovery != null && recovery.isNotEmpty) {
      out.add(AIChatMessage(
        role: 'system',
        content: '【MEMORY_SUMMARY·恢复包】（你提前写好的上下文存档）\n$recovery',
      ));
      return out;
    }

    // 摘要区（一条 system 消息，前缀稳定 → 缓存命中）
    // 用户 8-03 02:41 模块化：长期记忆不拼 prompt，男主自己查工具；
    // 摘要区只留"提醒索引"（每天要记得的事/影响后续对话的约定）
    final summaries = _summaries[personaId];
    if (summaries != null && summaries.isNotEmpty) {
      final sb = StringBuffer(
        '【男主摘要】（你上次洗牌时总结的——下次聊天必带；'
        '它平时不动，只有工具历史+对话重新洗牌时才更新）');
      for (final s in summaries) {
        sb.write('\n- $s');
      }
      out.add(AIChatMessage(role: 'system', content: sb.toString()));
    }

    // 当前话题原文 —— 8-04 17:2x（用户：工具历史要独立分区，别混在对话里）：
    // 工具行 → 【工具使用历史】system 块（时间+工具名+成败+失败原因，
    // 不带调用过程/内容详情——记了什么按时间戳在互动历史里对应）；
    // 用户/男主行 → 互动历史（user/assistant，保留时间戳）
    // ⚠️ 不能用 insert(1)：无摘要时 out 为空 → RangeError 越界（重启后首条必崩）
    final t = _topics[personaId];
    if (t != null && t.raw.isNotEmpty) {
      var total = 0;
      final lines = <AIChatMessage>[];
      final toolLines = <String>[];
      // 从尾部取（保留最近），预算内
      for (var i = t.raw.length - 1; i >= 0; i--) {
        total += t.raw[i].length;
        if (total > topicBudgetChars(personaId, modelHint: modelHint)) break;
        final line = t.raw[i];
        if (line.startsWith('工具')) {
          toolLines.add(line);
        } else if (line.startsWith('男主')) {
          lines.add(AIChatMessage(
              role: 'assistant', content: _stripPrefix(line, keepTs: true)));
        } else {
          lines.add(AIChatMessage(
              role: 'user', content: _stripPrefix(line, keepTs: true)));
        }
      }
      // 工具使用历史：独立 system 块（在互动历史之前）
      // 8-04 17:3x（用户：跨天聊天要按日期分区，工具和对话才能对应）：
      // 工具历史也按日期分组（【工具使用历史 · 2026/6/28】）
      if (toolLines.isNotEmpty) {
        final sb = StringBuffer(
            '【工具使用历史】（男主执行过的工具，时间戳与互动历史对应；'
            '成功时记了什么、失败时原因是什么，按日期+时间在互动历史里对照）');
        DateTime? lastDay;
        for (final l in toolLines.reversed) {
          final ts = _toolTs(l);
          final day = ts == null ? null : _tsDate(ts);
          if (day != null && (lastDay == null || !_sameDay(day, lastDay))) {
            sb.write('\n【工具使用历史 · ${_dateLabel(day)}】');
            lastDay = day;
          }
          sb.write('\n${_toolHistoryLine(l)}');
        }
        out.add(AIChatMessage(role: 'system', content: sb.toString()));
      }
      // 历史分区（8-05 19:13 用户定稿定义）：
      // 【系统历史】= 系统过去发的精简指令记录（几点/动作/完成或失败+原因），
      //   如 '[19:00] 写日记 → ✅完成'——不是男主发言！
      // 【聊天历史】= 用户和男主（AI）的对话，user/assistant 按时间线交替，
      //   各带时间戳+日期分组。
      final butlerLog = _butlerLog[personaId];
      if (butlerLog != null && butlerLog.isNotEmpty) {
        final sb = StringBuffer(
            '【系统历史】（系统自动执行过的指令记录：时间+动作+结果。'
            '男主可参考，如写日记/总结是否成功）');
        DateTime? lastDay;
        for (final l in butlerLog) {
          final day = _tsDate(l);
          if (day != null && (lastDay == null || !_sameDay(day, lastDay))) {
            sb.write('\n【系统历史 · ${_dateLabel(day)}】');
            lastDay = day;
          }
          sb.write('\n$l');
        }
        out.add(AIChatMessage(role: 'system', content: sb.toString()));
      }
      DateTime? lastDay;
      for (final m in lines.reversed) {
        final day = _tsDate(m.content);
        if (day != null && (lastDay == null || !_sameDay(day, lastDay))) {
          out.add(AIChatMessage(
              role: 'system',
              content: '【聊天历史 · ${_dateLabel(day)}】（该日期：几点谁说了什么）'));
          lastDay = day;
        }
        out.add(m);
      }
    }
    return out;
  }

  /// 记录管家自动指令日志（8-05 19:13 用户：管家历史 = 管家发的精简指令，
  /// 时间+动作+结果，男主参考用）。动作如：写日记/总结/沉淀。
  void logButlerAction(String personaId, String action, String result) {
    final now = DateTime.now();

---

# ② 工具完整链路（lib/pages/chat/chat_page.dart 1040-1990行）

> 覆盖：toolCalls 解析（文本块工具/原生调用）→ 工具执行循环 → toolMessages 生成 → toolRound 二次请求
> 对应 GitHub：https://github.com/nainaiyuan/pocket-inn-app/blob/main/lib/pages/chat/chat_page.dart#L1040

      _pendingRecallCategory = null;
      _pendingRecallLimit = null;
      // 收集男主各轮文本（第一轮 + 工具轮）——文本与工具可共存：
      // 模型第一轮既说话又调工具时，文本不丢，工具执行后合并显示
      final replyTexts = <String>[];
      // 8-07 19:15：多气泡逐条落库记录（链式 parent 还原顺序 + spans 样式）
      final dbRows = <_BubbleRow>[];
      if (result.text.trim().isNotEmpty) {
        replyTexts.add(result.text.trim());
      }
      // 8-03 05:31：男主回复文本里含工具指令（⟨工具:⟩块 / JSON，
      // 兼容不同 AI 的输出格式）→ 管家解析识别 → 转 toolCalls 走工具轮。
      // 8-04 18:2x（用户明确要求）：**中文意图词表已移除**——
      // 管家只认明确指令格式（⟨工具:…⟩块 / JSON），自然语言永不触发，
      // 男主正常说话（"翻翻以前写的日记"）不会再被误判成工具调用。
      // 纯聊天文本（无明确指令格式）→ 返回 null → 零副作用照常显示
      if ((result.toolCalls == null || result.toolCalls!.isEmpty) &&
          result.text.trim().isNotEmpty) {
        final intent = ToolIntentParser.extract(result.text);
        if (intent != null && intent.isNotEmpty) {
          DebugLogger.log(
            'AI路由',
            '🔧 管家解析到男主工具指令: ${intent.map((c) => c['name']).join('、')}',
          );
          result = AIProviderResult(
            // 剥离 ⟨工具:…⟩ 块，用户只看到男主自然的话
            text: ToolIntentParser.stripToolBlocks(result.text),
            toolCalls: intent,
            usage: result.usage,
            providerName: result.providerName,
            reasoningContent: result.reasoningContent,
          );
        } else {
          // 8-04 18:34（用户设计）：疑似工具调用但格式不对 →
          // 管家不执行，提示男主正确格式（注入下轮 taskState，用完即清）
          final hint = ToolIntentParser.detectSuspicious(result.text);
          if (hint != null) {
            _formatHint = hint;
            DebugLogger.log('AI路由', '📐 男主工具格式不对，下轮提示正确格式');
          }
        }
      }
      // 8-03 18:2x（用户反馈"不连贯，管家不实时显示流程"）：
      // 第一轮文本立即显示（不等工具轮跑完），
      // 用户先看到男主说话 → 再看工具气泡 → 再看男主基于结果继续说话
      if (result.text.trim().isNotEmpty) {
        replyTexts.add(result.text.trim());
        var textToShow = result.text;
        // 8-07 19:15（用户拍板）：男主回复不带任何标签（<reply>/<msg>/<act>）
        // → 整条打回重写：不显示、不执行、不落库；连续 3 次熔断放行防死循环
        // 8-07 23:5x（男主自诊断+用户建议）：**工具写岔 ≠ 纯聊天不按格式**——
        // 男主调工具格式没对上时，不当"格式违规"打回（会熔断放行漏裸 <
        // 且工具没执行 → 流程挂起）；而是豁免打回：提示正确格式注入下轮，
        // 疑似工具串剥掉后显示（空则不显示），流程不卡
        final suspHint = ToolIntentParser.detectSuspicious(textToShow);
        final isToolWriteOff = suspHint != null;
        if (!_hasAnyTag(textToShow) && !isToolWriteOff) {
          _formatFailCount++;
          if (_formatFailCount >= 3) {
            _formatFailCount = 0; // 熔断：第 3 次强制放行（按纯文本显示）
          } else {
            final rewriteEvent = '你的回复没有按格式输出（缺少 JSON 块），'
                '已被打回，用户没看到。请按格式重写（JSON 对象，每个占一行）：'
                '{"reply":"回#N"}（标注回哪条，可省）'
                '+ {"act":"动作/神态"}（可选）+ {"msg":"你说的话"}。'
                '除 JSON 对象外不要输出任何其他文字；一次说多句 = 多个 {"msg":..} 对象。';
            DebugLogger.log('AI路由', '⛔ 男主无标签回复，打回重写（第 $_formatFailCount 次）');
            ChatPresence.instance.beginTyping();
            final rewritten = await _aiSvc.generateReply(
              '',
              personaId,
              personaName: personaName,
              personaPrompt: _currentPersonaPrompt(),
              userProfile: _currentUserSetting(),
              sessionId: _chatSessionId,
              storagePersonaId: chatPid,
              systemEvent: rewriteEvent,
            );
            if (rewritten.text.trim().isNotEmpty) {
              replyTexts.add(rewritten.text.trim());
              result = rewritten; // 整体替换 → 工具解析/工具轮用重写结果
              textToShow = rewritten.text;
            } else {
              ChatPresence.instance.endTyping();
              return; // 重写也空 → 结束本轮（别死循环）
            }
          }
        } else if (isToolWriteOff) {
          // 工具写岔豁免：不当格式违规打回；疑似工具串剥掉后显示剩余
          DebugLogger.log('AI路由', '📐 男主工具写岔（豁免打回），提示下轮修正格式');
          textToShow = ToolIntentParser.stripToolBlocks(textToShow);
          textToShow = stripAnthropicInvokeBlocks(textToShow);
        }
        final firstText = await _displayableText(textToShow);
        if (firstText.isNotEmpty) {
          final rows = await _appendMaleReply(
            textToShow,
            thinkingChain: result.reasoningContent,
            isFirst: true,
          );
          dbRows.addAll(rows);
          if (rows.isEmpty) {
            // 解析后为空（纯标签壳）→ 没有打字 → 关"正在输出"
            ChatPresence.instance.endTyping();
          }
          // 文字进入打字机播放 → "正在输出"由打字机播完时 endTyping 关闭
        } else {
          // 文本被剥离成空（纯指令/工具块）→ 本轮没有打字 → 关"正在输出"
          ChatPresence.instance.endTyping();
        }
      } else {
        // 第一轮没说话（直接调工具）→ 工具阶段不显示"正在输出"
        ChatPresence.instance.endTyping();
      }
      // function calling 循环：模型请求工具 → 执行 → 回传 → 再生成（最多3轮防死循环）
      // 用户 8-03 00:55：日志里看不见工具调用 → 每个工具调用都记日志
      // 用户 8-03 01:57：工具轮不限定轮数（原来最多 3 轮，复杂任务可能不够）；
      // 但防死循环：同一工具连续调用 ≥3 次 → 强制停止
      // 用户 8-03 02:26：记录"是否有工具执行"——工具已执行时空文本合法（气泡已反馈），
      // 只有"主调用直接空 + 无工具"才需要轻提示用户
      var toolExecuted = false;
      var toolLoop = 0;
      // 8-08 16:2x：中间文本攒起逻辑已删除（男主说了话立即显示，见工具轮分支）
      final consecutiveToolCounts = <String, int>{};
      // 8-06 21:36：continue 累计计数（交错调用也能防无限"继续说"）
      var continueCount = 0;
      // 8-07 00:1x：用户连续拒绝计数（≥3 强制男主停止尝试）
      var rejectedCount = 0;
      // 8-07 22:5x 用户：男主"一直查一直查工具"卡死——交错调用防不住
      // （consecutive 只数连续同工具）。加：
      // ① 本轮查询类工具累计 ≥3 强制停（不管交错）
      // ② 工具轮总轮数上限 6（防 query_logs→list_tools→query_logs 死循环）
      var queryToolCount = 0;
      // 8-08 02:1x 用户：干太快被卡 → 总轮数 6 → 10（防死循环仍保留）
      const maxToolRounds = 10;
      while (result.toolCalls != null && result.toolCalls!.isNotEmpty) {
        toolLoop++;
        toolExecuted = true;
        if (toolLoop > maxToolRounds) {
          // 防御兜底（正常路径由下方 stop 事件先拦，这里保证不无限循环）
          DebugLogger.log(
            'AI路由',
            '⚠️ 工具轮超过 $maxToolRounds 轮，强制跳出（防死循环）',
          );
          break;
        }
        DebugLogger.log(
          'AI路由',
          '🔧 第 $toolLoop 轮：男主请求 ${result.toolCalls!.length} 个工具',
        );
        // 8-03 17:24（用户指示：AI 需要什么给什么，研究 DeepSeek 原生调用）：
        // 工具轮双通道——
        // ① 原生 tool_calls（模型 API 返回，带 id）：原样回传 assistant
        //   （content + reasoning_content + tool_calls 含 id），tool 消息
        //   用模型给的 id 配对（官方文档：append response.choices[0].message，
        //   思考模式 tool_calls 必须配 id 回传，否则 400）
        // ② 文本块工具（⟨工具:⟩ 解析，无 id）：不发伪造原生 tool_calls，
        //   工具结果合并注入 user 消息（文本协议兜底，本地/不支持原生工具的模型用）
        // 8-08 22:5x（DeepSeek 400 根治，用户：老弹灰框一串错误）：
        // 思考模式要求带 tool_calls 的 assistant 消息必须原样回传
        // reasoning_content（8-03 06:54 已知）。响应里解析不出（或为空）
        // 时强行发原生 tool_calls 必 400 → 该轮不发原生，工具结果全走
        // 文本合并注入（translateToolRound 路径，天然免疫 400）。
        // 非思考模型（推理链本来就空）也走文本协议——功能完整只是不用
        // 原生 tool_calls，比 400 弹灰框强。
        final hasReasoning =
            (result.reasoningContent?.trim().isNotEmpty ?? false);
        final nativeCalls = hasReasoning
            ? result.toolCalls!
                .where((c) => (c['id']?.toString() ?? '').isNotEmpty)
                .toList()
            : <Map<String, dynamic>>[];
        if (result.toolCalls!.isNotEmpty && nativeCalls.isEmpty) {
          DebugLogger.log(
            'AI路由',
            '🛡 工具轮无 reasoning_content（思考链关/解析失败）→ '
            '原生 tool_calls 转文本协议，防 DeepSeek 400',
          );
        }
        final textToolResults = <String>[];
        // 8-07 00:1x：用户拒绝收集——拒绝不走普通工具结果（男主会无视），
        // 这轮工具执行完走【系统事件】通道强制男主决策
        final rejectedTools = <String>[];
        // 8-08 21:5x（GPT10问第7条 state_hint 专区）：本轮软提示累积
        //（查询类≥3/连续拒绝≥2）→ 状态块【状态提示】注入，不混 toolMessages
        final toolRoundHints = <String>[];
        final toolMessages = <AIChatMessage>[
          if (nativeCalls.isNotEmpty)
            AIChatMessage(
              role: 'assistant',
              // 官方示例：整个 message 原样回传（含 content 原文）
              content: result.text,
              toolCalls: nativeCalls,
              // 思考模式必须原样回传 reasoning_content（toApiJson 原样输出）
              reasoningContent: result.reasoningContent,
            ),
        ];
        var loopExceeded = false;
        for (final call in result.toolCalls!) {
          final name = call['name']?.toString() ?? '';
          // 8-08 19:0x（GPT 18:59 + 用户 19:04 定稿）：插话轮禁工具——
          // 机械拦截（原来只是提示，男主不听话会调）：不执行、直接回执给男主
          if (_interruptRoundActive) {
            DebugLogger.log(
              '管家流程',
              '🔒 插话轮禁工具：男主调 $name 被拦截（这轮只回用户）',
            );
            toolMessages.add(
              AIChatMessage(
                role: 'tool',
                content: '【工具 $name】❌被管家拦截：插话轮禁止调用工具，'
                    '这一轮只回复用户。她提的新需求先口头确认，'
                    '回完后调 manage_flow resume/update/cancel 处理流程。',
                toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
              ),
            );
            continue;
          }
          // 8-08 14:0x（断点 C 根治）：男主工具参数常写中文 key（{动作: next}）
          // 工具只认英文 key（{action: next}）→ next 失败 → 任务卡死。
          // 模型行为不可控，解析层兜底：按工具名做中文→英文参数名归一化。
          final rawArgs = (call['arguments'] as Map<String, dynamic>?) ?? {};
          final args = _normalizeToolArgs(name, rawArgs);
          _ToolResult toolResult;
          DebugLogger.log(
            'AI路由',
            '🔧 工具 $name 参数：${args.isEmpty ? '（空）' : args}'
            '${rawArgs != args && rawArgs.isNotEmpty ? '（原文：$rawArgs）' : ''}',
          );
          // 8-07 21:2x 用户：工具气泡没显示全/跳过——工具循环无异常保护，
          // 一个工具执行炸了后面全断。每个工具单独 try-catch：炸了显示 ❌
          // 气泡继续下一个，男主看得到哪个失败，下一轮能处理
          try {
          if (name == 'record_relation') {
            toolResult = await _executeRelationTool(args);
          } else if (name == 'record_memory') {
            final content = args['content']?.toString() ?? '';
            var category = args['category']?.toString() ?? '';
            // 8-03 06:29：男主不知道类别规范，常写"其他" → 管家兜底：
            // 空类别，或"其他"但内容明显可归类（喜欢/约定/日常/事实）→ 自动纠正
            if (category.isEmpty || category == ButlerCommandParser.catOther) {
              final auto = ButlerCommandParser.autoCategory(content);
              if (auto != ButlerCommandParser.catOther || category.isEmpty) {
                category = auto;
              }
            }
            // 8-03 06:34：男主提取的关键词（妈妈→亲戚、喜欢→喜好）→
            // 并入规律引擎关键词池，找规律时总能找到
            final kw = args['keywords'];
            final words = <String>[];
            if (kw != null) {
              if (kw is List) {
                for (final w in kw) {
                  final s = w.toString().trim();
                  if (s.isNotEmpty) words.add(s);
                }
              } else if (kw is String) {
                words.addAll(
                  kw.split(RegExp(r'[,，、\s]+')).where((w) => w.isNotEmpty),
                );
              }
              if (words.isNotEmpty) {
                ButlerPipelineResult.pendingKeywords.addAll(words);
                DebugLogger.log(
                  '管家流程',
                  '🎯 record_memory 关键词并入规律引擎: ${words.join('、')}',
                );
              }
            }
            // 8-03 06:37：男主写的完整句（content）原样保存 + 关键词落库
            _appendToolBubble('正在记录：「$content」（$category）…');
            // 8-03 19:1x（用户要求：调工具要确认）：写记忆前让用户点头
            // 8-03 23:0x（用户要求）：一次弹窗展示全——
            // 男主想记录的原话 + 类别 + 男主提取的关键词（a+b 找规律用）
            final ok = await _approveToolCall(
              '记录',
              '「$content」\n\n类别：$category\n'
                  '关键词：${words.isEmpty ? '（无）' : words.join('、')}\n\n'
                  '要让他记住吗？',
              personaId: personaId,
              toolKey: 'record_memory',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了记录「$content」');
              toolResult = _ToolResult(false, '用户拒绝：暂不记录「$content」');
            } else {
              toolResult = await _executeRecordTool(
                category,
                content,
                keywords: words,
              );

---

# ② 工具完整链路（续 1330-1990行）

              );
            }
          } else if (name == 'recall_memory') {
            final query = args['query']?.toString() ?? '';
            final category = args['category']?.toString() ?? '';
            _appendToolBubble('正在查记忆：$query…');
            // 8-03 19:1x（用户要求：调工具要确认）：查记忆是读用户隐私，
            // 必须先问用户（和文本协议 #查记忆# 的 _approveRecall 一致）
            final ok = await _approveToolCall(
              '查记忆',
              '他想查关于「$query」的记忆，允许吗？',
              personaId: personaId,
              toolKey: 'recall_memory',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了查「$query」');
              toolResult = _ToolResult(false, '用户拒绝：暂不查「$query」');
            } else {
              toolResult = await _executeRecallTool(query, category);
            }
          } else if (name == 'save_identity_memory') {
            // 37批：男主用原生工具写代号记忆（替代 #A# 文本协议，DeepSeek 更可靠）
            final code = args['code']?.toString() ?? '';
            final content = args['content']?.toString() ?? '';
            _appendToolBubble('男主想记住关于「$code」的事…');
            // 8-03 19:1x：写代号记忆也确认
            final ok = await _approveToolCall(
              '记住代号',
              '「$code」：$content\n\n要让他记住吗？',
              personaId: personaId,
              toolKey: 'save_identity_memory',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了记住「$code」');
              toolResult = _ToolResult(false, '用户拒绝：暂不记住「$code」');
            } else {
              toolResult = await _executeSaveIdentityMemoryTool(code, content);
            }
          } else if (name == 'list_tools') {
            // 8-03 19:1x：list_tools 也出"正在…"气泡（之前只有结果气泡，
            // 用户反馈"根本没看见工具气泡"）——工具调用必须有可见反馈
            _appendToolBubble('男主想查看工具清单…');
            // 8-03 19:35（用户实测反馈）：list_tools 也要确认——
            // 用户要求所有工具调用都先问他允不允许
            final ok = await _approveToolCall(
              '查看工具清单',
              '他想看看自己现在有哪些能力可用，允许吗？',
              personaId: personaId,
              toolKey: 'list_tools',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了查看工具清单');
              toolResult = _ToolResult(false, '用户拒绝：暂不查看工具清单');
            } else {
              toolResult = await _executeListToolsTool(args);
            }
          } else if (name == 'write_diary') {
            final content = args['content']?.toString() ?? '';
            _appendToolBubble('男主在写日记…');
            final ok = await _approveToolCall(
              '写日记',
              '「$content」\n\n要让他记下来吗？',
              personaId: personaId,
              toolKey: 'write_diary',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了写日记');
              toolResult = _ToolResult(false, '用户拒绝：暂不写日记');
            } else {
              toolResult = await _executeWriteDiaryTool(content);
            }
          } else if (name == 'query_diary') {
            final keyword = args['keyword']?.toString() ?? '';
            _appendToolBubble('男主在翻日记：$keyword…');
            final ok = await _approveToolCall(
              '翻日记',
              '他想查日记里关于「$keyword」的内容，允许吗？',
              personaId: personaId,
              toolKey: 'query_diary',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了翻日记');
              toolResult = _ToolResult(false, '用户拒绝：暂不翻日记');
            } else {
              toolResult = await _executeQueryDiaryTool(keyword);
            }
          } else if (name == 'notify_user') {
            // 8-06 00:31 用户：男主弹窗（APP内顶部横幅轰炸，APP外之后再做）。
            // 8-06 00:58 修正：弹窗打扰用户 → 默认要审批；
            // 用户批准免审批后（request_permission 申请）男主可直接弹
            final msgCount = (args['messages'] is List)
                ? (args['messages'] as List).length
                : 1;
            final ok = await _approveToolCall(
              '弹消息提醒',
              '他想给你弹 $msgCount 条消息（APP内顶部横幅，像发消息一样）。\n'
                  '允许吗？（批准后他可以在对话里申请这个能力免审批）',
              personaId: personaId,
              toolKey: 'notify_user',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了弹消息提醒');
              toolResult = _ToolResult(false, '用户拒绝：暂不弹消息');
            } else {
              toolResult = await _executeNotifyTool(args);
            }
          } else if (name == 'request_permission') {
            // 8-06 00:58 用户：男主申请某能力免审批 → 弹窗（同意/拒绝 + 可选原因）
            // 免审批工具本身，不需要再审批
            toolResult = await _executeRequestPermission(args);
          } else if (name == 'query_logs') {
            // 8-06 01:03 用户：男主查日志排错（只读，不需要审批）
            toolResult = await _executeQueryLogs(args);
          } else if (name == 'report_bug') {
            // 8-06 01:06 用户：bug 报告弹窗（定位信息+解法+一键复制，只读不需要审批）
            toolResult = await _executeReportBug(args);
          } else if (name == 'countdown_card') {
            // 8-06 13:38 用户：计时卡片（悬浮倒计时卡片，可拖动/收起/选项/逾期提醒）
            // 默认要审批（和 notify_user 一致，可申请免审批）
            final ok = await _approveToolCall(
              '设计时卡片',
              '他想给你设一个倒计时卡片（比如"去洗澡，40分钟后回来"）。\n'
                  '允许吗？（批准后他可以在对话里申请这个能力免审批）',
              personaId: personaId,
              toolKey: 'countdown_card',
            );
            if (!ok) {
              _appendToolBubble('❌ 你拒绝了计时卡片');
              toolResult = _ToolResult(false, '用户拒绝：暂不设计时卡片');
            } else {
              toolResult = await _executeCountdownCard(args);
            }
          } else if (name == 'manage_task') {
            // 8-06 13:53 用户：男主管理任务（撤销/调整/回应申请）——默认要审批
            final ok = await _approveToolCall(
              '管理任务',
              '他想${args['action'] == 'cancel'
                  ? '撤销'
                  : args['action'] == 'reject'
                  ? '回应'
                  : '调整'}一个任务卡片，允许吗？',
              personaId: personaId,
              toolKey: 'manage_task',
            );
            if (!ok) {
              toolResult = _ToolResult(false, '用户拒绝：暂不管理任务');
            } else {
              toolResult = await _executeManageTask(args);
            }
          } else if (name == 'update_setting') {
            // 8-06 17:46-18:24 用户：男主主动优化设定 → 弹窗审批（可手动修改）
            // 弹窗本身就是审批动作，不再套确认框
            toolResult = await _executeUpdateSetting(args);
          } else if (name == 'query_setting_history') {
            // 8-06 18:08 用户：男主查设定变更历史（只读，不需要审批）
            toolResult = await _executeQuerySettingHistory(args);
          } else if (name == 'query_record') {
            // 8-06 18:41-19:21 用户：男主查分类记录（只读，不需要审批）
            toolResult = await _executeQueryRecord(args);
          } else if (name == 'add_record') {
            // 男主自己记（他整理的，不打扰她）
            toolResult = await _executeAddRecord(args);
          } else if (name == 'manage_record_tree') {
            // 改分类影响她 → 弹窗审批
            toolResult = await _executeManageRecordTree(args);
          } else if (name == 'manage_pad') {
            // 8-06 21:12 用户：男主自己的便签（当前任务模块），自己维护，免审批
            _appendToolBubble('📋 男主在整理自己的便签…');
            toolResult = await _executeManagePad(args);
          } else if (name == 'manage_tool_cache') {
            // 8-08 02:1x 用户：工具工作缓存——男主干活中间数据（自管免审批）
            _appendToolBubble('🗃️ 男主在整理工具缓存…');
            toolResult = await _executeManageToolCache(args);
          } else if (name == 'manage_flow') {
            // 8-06 23:55 用户：流程层——男主自管（免审批）
            // 长任务先立流程（goal+steps），一条条执行，做完 finish
            _appendToolBubble('📋 男主在整理流程…');
            final action = args['action']?.toString() ?? '';
            if (action == 'create') {
              final goal = args['goal']?.toString() ?? '';
              final stepsRaw = args['steps'];
              // 8-08 15:2x：steps 支持字符串或对象 {name, doneType, doneCondition}
              final steps = <dynamic>[];
              if (stepsRaw is List) {
                for (final st in stepsRaw) {
                  if (st is Map) {
                    steps.add(st);
                  } else {
                    final t = st.toString().trim();
                    if (t.isNotEmpty) steps.add(t);
                  }
                }
              } else if (stepsRaw is String) {
                steps.addAll(
                  stepsRaw
                      .split(RegExp(r'\n+'))
                      .where((st) => st.trim().isNotEmpty),
                );
              }
              toolResult = _ToolResult(
                true,
                await FlowStore.create(personaId, goal, steps),
              );
            } else if (action == 'next') {
              // 8-08 15:2x（GPT 10 问 4 定案：结构化提交，不从文本抽取）：
              // ai_output/user_confirm 步骤 next 时带 result（+可选 summary/next_action）
              toolResult = _ToolResult(
                true,
                await FlowStore.next(
                  personaId,
                  result: args['result']?.toString(),
                  summary: args['summary']?.toString(),
                  nextAction: args['next_action']?.toString(),
                ),
              );
            } else if (action == 'finish') {
              toolResult = _ToolResult(true, await FlowStore.finish(personaId));
            } else if (action == 'cancel') {
              toolResult = _ToolResult(true, await FlowStore.cancel(personaId));
            } else if (action == 'resume') {
              toolResult = _ToolResult(true, await FlowStore.resume(personaId));
            } else if (action == 'status') {
              toolResult = _ToolResult(
                true,
                FlowStore.text(personaId) ?? '没有流程（create 先立）',
              );
            } else if (action == 'update') {
              // 8-07 00:1x 用户：用户提了新要求 → 更新流程目标/步骤，从头执行
              final goal = args['goal']?.toString();
              final stepsRaw = args['steps'];
              List<dynamic>? steps;
              if (stepsRaw is List) {
                steps = <dynamic>[];
                for (final st in stepsRaw) {
                  if (st is Map) {
                    steps.add(st);
                  } else {
                    final t = st.toString().trim();
                    if (t.isNotEmpty) steps.add(t);
                  }
                }
              } else if (stepsRaw is String) {
                steps = stepsRaw
                    .split(RegExp(r'\n+'))
                    .where((st) => st.trim().isNotEmpty)
                    .toList();
              }
              toolResult = _ToolResult(
                true,
                await FlowStore.update(personaId, goal: goal, steps: steps),
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_flow 参数：action=create/next/finish/cancel/resume/status/update，'
                'create/update 要 goal+steps。'
                '参数名用英文（action/goal/steps），别用中文"动作/目标/步骤"。'
                '示例：{"action":"next"}',
              );
            }
            // 流程状态变化 → 刷新停止条
            if (mounted) setState(() {});
          } else if (name == 'manage_tool_manual') {
            // 8-08 15:2x（设计文档四，GPT 10 问 2）：工具使用手册——男主自管免审批
            // 格式/示例/坑记进手册，下次不重新试格式
            _appendToolBubble('📖 男主在整理工具手册…');
            final action = args['action']?.toString() ?? '';
            final tName = args['tool']?.toString() ?? '';
            if (action == 'add' || action == 'update') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.save(
                  personaId,
                  tName,
                  usage: args['usage']?.toString(),
                  format: args['format']?.toString(),
                  example: args['example']?.toString(),
                  note: args['note']?.toString(),
                ),
              );
            } else if (action == 'get') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.get(personaId, tName),
              );
            } else if (action == 'list') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.list(personaId),
              );
            } else if (action == 'remove') {
              toolResult = _ToolResult(
                true,
                await ToolManualStore.remove(personaId, tName),
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_tool_manual 参数：action=add/update/get/list/remove，'
                'tool=工具英文名；add 可带 usage/format/example/note。'
                '示例：{"action":"add","tool":"search_web","format":"{\\"query\\":\\"关键词\\"}"}',
              );
            }
          } else if (name == 'manage_tool_test') {
            // 8-08 15:2x（设计文档八，GPT 10 问 10）：工具测试任务管理器——男主自管免审批
            // 管家维护 checklist，男主每轮只面对"当前要测的工具"一个对象
            _appendToolBubble('🧪 男主在管理工具测试任务…');
            final action = args['action']?.toString() ?? '';
            if (action == 'start') {
              final toolsRaw = args['tools'];
              final tools = <String>[];
              if (toolsRaw is List) {
                for (final t in toolsRaw) {
                  final s = t.toString().trim();
                  if (s.isNotEmpty) tools.add(s);
                }
              } else if (toolsRaw is String) {
                tools.addAll(toolsRaw
                    .split(RegExp(r'[,，\n]+'))
                    .where((t) => t.trim().isNotEmpty));
              }
              // 自动立流程（goal=测试工具），checklist 由 ToolTestStore 维护
              if (!FlowStore.isRunning(personaId)) {
                await FlowStore.create(personaId, '测试所有工具',
                    ['逐个测试工具并记录结果', '汇总测试结果给用户']);
              }
              toolResult = _ToolResult(
                true,
                await ToolTestStore.start(personaId, tools),
              );
              if (mounted) setState(() {});
            } else if (action == 'report') {
              final tName = args['name']?.toString() ?? '';
              final ok = args['ok'] == true ||
                  args['ok']?.toString() == 'true' ||
                  args['ok']?.toString() == '成功';
              toolResult = _ToolResult(
                true,
                await ToolTestStore.report(
                  personaId,
                  tName,
                  ok: ok,
                  bug: args['bug']?.toString(),
                ),
              );
            } else if (action == 'status') {
              toolResult = _ToolResult(
                true,
                await ToolTestStore.status(personaId),
              );
            } else if (action == 'abort') {
              toolResult = _ToolResult(
                true,
                await ToolTestStore.abort(personaId),
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_tool_test 参数：action=start/report/status/abort。'
                'start 带 tools 列表；report 带 name+ok(+bug)。'
                '示例：{"action":"report","name":"search_web","ok":true}',
              );
            }
          } else if (name == 'manage_frequent_tools') {
            // 8-06 21:54 用户：常用工具表维护（男主自己的，免审批）
            final action = args['action']?.toString() ?? '';
            final name = args['name']?.toString() ?? '';
            if (action == 'add') {
              // 8-08 15:5x（用户反馈）：中文名/描述也能加（"记她的事"→record_memory），
              // 成功回显中文名确认，失败给可用示例
              final resolved = ToolCatalog.resolveName(name);
              if (resolved == null) {
                toolResult = _ToolResult(
                  false,
                  '没有「$name」这个工具。试试这些：'
                  '${ToolCatalog.allNames.take(8).join('、')}…'
                  '（也可以发中文描述，如"记她的事"）',
                );
              } else {
                await FrequentToolsStore.add(personaId, resolved);
                final desc = ToolCatalog.toolDetail(resolved) ?? resolved;
                toolResult = _ToolResult(
                  true,
                  '已加入常用表：$resolved（$desc）——'
                  '每轮都会出现在【你常用的工具】',
                );
              }
            } else if (action == 'remove') {
              // 8-08 15:5x：中文名/描述也能删
              final resolved = ToolCatalog.resolveName(name);
              final ok = resolved != null &&
                  await FrequentToolsStore.remove(personaId, resolved);
              toolResult = ok
                  ? _ToolResult(true, '已从常用表移除：$resolved')
                  : _ToolResult(false, '常用表里没有「$name」');
            } else if (action == 'list') {
              final list = FrequentToolsStore.list(personaId);
              toolResult = _ToolResult(
                true,
                list.isEmpty ? '常用表是空的（add 添加）' : '常用表：${list.join('、')}',
              );
            } else {
              toolResult = const _ToolResult(
                false,
                'manage_frequent_tools 参数：action=add/remove/list，name=工具名',
              );
            }
          } else if (name == 'resolve_pending') {
            // 8-06 21:41 用户：回复标记也走工具（原生就是调工具的）
            // 8-06 21:43：没有"不回"选项——没回的留在待回复区挂着
            // 免审批、不弹气泡（男主的话本身就是回复）
            final rIds = <String>[];
            final rRaw = args['replied_ids'];
            if (rRaw is List) {
              for (final v in rRaw) {
                // 数字或字母（管家提醒 #A）都认
                final s = v.toString().trim();
                if (RegExp(r'^\d+$').hasMatch(s) ||
                    RegExp(r'^[A-Za-z]$').hasMatch(s)) {
                  rIds.add(s.toUpperCase());
                }
              }
            }
            if (rIds.isEmpty) {
              toolResult = const _ToolResult(
                false,
                'resolve_pending 参数不对：replied_ids 至少要有一个编号',
              );
            } else {
              await PendingQueueStore.removeByIds(personaId, rIds);
              toolResult = _ToolResult(true, '已标记回复：待#${rIds.join('、')}');
            }
          } else if (name == 'continue_speaking') {
            // 8-06 21:36 用户：男主不等她继续说话——调"继续"工具，
            // 系统自动再生成一轮（不带她消息）；免审批、不弹气泡
            toolResult = _ToolResult(true, '继续');
          } else if (name == 'query_tool_formats') {
            // 8-07 19:15 用户：管家识别不了男主的调用方式 → 查格式模板
            // 按文本块锁过滤：未解锁不返回文本块模板
            toolResult = _ToolResult(true, await _queryToolFormats(personaId));
          } else if (name == 'request_text_block') {
            // 8-07 19:15 用户：AI 主动申请文本块（原生+其他格式都试过）→ 用户批准
            final reason = args['reason']?.toString() ?? '';
            final approved =
                await _approveTextBlock(personaId, personaName, reason);
            toolResult = _ToolResult(
              approved,
              approved
                  ? '✅ 她已批准文本块！现在可以用：⟨工具:工具名⟩{"参数":"值"}⟨/工具⟩'
                  : '她暂时没批准文本块。继续用原生或其他家格式（查 query_tool_formats）',
            );
          } else {
            toolResult = _ToolResult(false, '未知工具：$name');
          }
          } catch (e) {
            DebugLogger.log('AI路由', '🔧 工具 $name 执行异常: $e');
            toolResult = _ToolResult(false, '工具执行异常：$e');
          }
          // 完成/失败气泡（用户 8-03 01:57）：执行完必须给用户明确反馈
          // 8-06 21:36：continue/resolve_pending 不弹气泡（男主的话本身就是反馈）
          if (name != 'continue_speaking' && name != 'resolve_pending') {
            _appendToolResultBubble(name, toolResult);
          }
          DebugLogger.log(
            'AI路由',
            '🔧 工具 $name 结果：${toolResult.text.length > 80 ? toolResult.text.substring(0, 80) + '…' : toolResult.text}',
          );
          // 8-04 17:0x（用户：上下文要留地方放工具，男主才知道做过什么；
          // 带时间戳+成败+原因，失败后才能继续调工具解决）：
          // 工具调用记录进上下文（stateless 全量带 → 男主看得到）
          ContextManager.instance.feedToolCall(
            personaId,
            name,
            toolResult.ok,
            toolResult.text,
          );
          // 8-08 15:2x（步骤状态机）：工具使用记录进 FlowStore 当前步
          // toolsUsed（完成条件判定 + 任务清单"本步已用工具"数据源）
          final briefForStep = toolResult.text.trim();
          await FlowStore.recordToolUse(
            personaId,
            name,
            ok: toolResult.ok,
            // 8-08 23:5x（GPT 参考 Tool Memory/Scratchpad）：结果摘要放宽
            // 到 120 字——男主从【当前流程】/【工具使用历史】直接看到
            // 结果，不用反复查（60 字经常截掉关键信息）
            brief: briefForStep.length > 120
                ? '${briefForStep.substring(0, 120)}…'
                : briefForStep,
          );
          // 8-08 02:2x 用户：男主查完不记一直查 → 查询结果自动进工具缓存
          // （下次直接看【工具缓存】别重复查；缓存有预算，超了男主整理）
          if (toolResult.ok && kQueryToolNames.contains(name)) {
            var brief = toolResult.text.trim();
            if (brief.length > 150) {
              brief = '${brief.substring(0, 150)}…';
            }
            if (brief.isNotEmpty) {
              await ToolCacheStore.add(personaId, '$name 查到：$brief');
            }
          }
          // 8-07 00:1x：审批拒绝系统事件化——拒绝结果同时收集，
          // 这轮工具执行完统一走【系统事件】通道（不是普通工具结果）
          if (!toolResult.ok && toolResult.text.startsWith('用户拒绝')) {
            rejectedTools.add(
              '「$name」${toolResult.text.replaceFirst('用户拒绝：', '：')}',
            );
          }
          // 8-06 21:36：continue/resolve_pending 结果不回填工具消息
          final isContinue =
              name == 'continue_speaking' || name == 'resolve_pending';
          if (!isContinue && nativeCalls.contains(call)) {
            // 原生：tool 消息必须用模型给的 id 配对（不能自己编 id）
            // 8-04 17:0x（用户：📄 里工具轮要简化成"成功/失败+一句话"）：
            // content 统一带【工具 名】+ ✅成功/❌失败 标记 —— 模型看得更清楚，
            // 📄 展示层也能解析出工具名和结果好坏
            toolMessages.add(
              AIChatMessage(
                role: 'tool',
                // 8-06 00:51 用户：调用工具=需要审批；成功调用=审批通过。
                // 工具消息在系统分区，天然不是用户说的话——不用额外解释
                content:
                    '【工具 $name】${toolResult.ok ? '✅成功（审批通过）' : '❌失败（审批未过）'}：${toolResult.text}',
                toolCallId: call['id']?.toString() ?? 'call_${toolLoop}_$name',
              ),
            );
          } else if (isContinue) {
            // continue（文本块格式）：不收集结果
          } else {
            // 文本块：结果收集，最后合并注入 user 消息
            textToolResults.add(
              '【工具 $name】${toolResult.ok ? '✅成功' : '❌失败'}：${toolResult.text}',
            );
          }
          // 防死循环：同一工具连续调用 ≥3 次 → 停止本轮
          final n = (consecutiveToolCounts[name] ?? 0) + 1;
          consecutiveToolCounts[name] = n;
          // 8-06 21:36：continue 本轮累计 ≥3 次也停（交错调用防不住"连续"计数）
          if (name == 'continue_speaking') continueCount++;
          // 8-07 22:5x 用户：男主反复查工具卡死——只读查询类工具
          // 本轮累计 ≥3 强制停（不管交错：query_logs→list_tools→query_logs 也拦）
          const queryTools = kQueryToolNames;
          var queryStop = false;
          if (queryTools.contains(name)) {
            queryToolCount++;
            if (queryToolCount >= 6) {
              queryStop = true;
              DebugLogger.log(
                'AI路由',
                '⚠️ 本轮查询类工具累计 $queryToolCount 次（$name），强制停止（防反复查）',
              );
            } else if (queryToolCount >= 3) {
              // 8-08 02:1x 用户：干太快被卡 → 3 次只软提示不强制停
              DebugLogger.log(
                'AI路由',
                '💡 查询类工具已 $queryToolCount 次（$name），软提示（不强制停）',
              );
            }
          }
          if (n >= 3 ||
              (name == 'continue_speaking' && continueCount >= 3) ||
              queryStop) {
            loopExceeded = true;
            DebugLogger.log(
              'AI路由',
              '⚠️ 工具 $name 调用 $n 次（continue 累计 $continueCount，'
              '查询类累计 $queryToolCount），强制停止（防死循环）',
            );
          }
        }
        // 8-08 15:2x（GPT 10 问 5 定案：autoAdvance 默认开，严格判定）：
        // 每轮工具执行完，管家检查当前步完成条件（tool_result：有成功工具；
        // ai_output/user_confirm：有结构化 result），明确满足才自动推进。
        // 推进提示注入下一轮，男主不用手动 next（产出/确认类仍要手动带 result）
        if (!loopExceeded) {
          final advanceMsg = await FlowStore.autoAdvance(personaId);
          if (advanceMsg != null) {
            DebugLogger.log('管家流程', '▶ autoAdvance：$advanceMsg');
            if (advanceMsg == '__ALL_DONE__') {
              toolMessages.add(AIChatMessage(
                role: 'user',
                content: '【系统事件】所有步骤都已完成 ✅。'
                    '现在调 manage_flow finish 收尾，然后给用户汇总结果。',
              ));
            } else {
              toolMessages.add(AIChatMessage(
                role: 'user',
                content: '【系统事件】$advanceMsg。继续执行新步骤，别回头重复。',
              ));
            }
          }
        }
        // 8-07 22:5x：不再这里提前 break——loopExceeded 时也要先注入
        // stop 事件（下方【系统事件】）让男主知道为什么停，再生成一轮
        // 文本块工具结果：合并注入 user 消息（不走原生 tool_calls，兜底通道）
        // 8-04 18:1x（用户：男主分不清用户话和工具结果）：明确标注
        // "这是工具返回结果，不是用户说的"——防止模型把结果当用户指令
        if (textToolResults.isNotEmpty) {
          toolMessages.add(
            AIChatMessage(
              role: 'user',
              content:
                  '【系统·工具执行结果】\n'
                  '${textToolResults.join('\n')}\n\n'
                  '基于结果自然地回复用户，不要再调用工具。',
            ),
          );
        }
        // 8-08 02:1x 用户：查询类 ≥3 只软提示——男主还在找东西时别硬卡，
        // 提醒他直接说缺什么（≥6 才走 loopExceeded 强制停）
        // 8-08 21:5x（GPT10问第7条）：软提示走 state_hint 专区（状态块
        // 【状态提示】），不再混 role:'user' 事件消息
        if (!loopExceeded && queryToolCount >= 3 && queryToolCount < 6) {
          toolRoundHints.add('本轮已查了 $queryToolCount 次资料。'
              '如果还在找什么，直接告诉她你需要什么（她可以补），'
              '别一直反复查；查到就继续干活，不用停下来说话。');
        }
        // 8-07 22:5x 用户：男主反复查工具卡死——触发防循环后必须明确告知
        // 男主"别再调了直接回复"，否则他不知道为什么停、下轮又调
        if (loopExceeded || toolLoop >= maxToolRounds) {
          toolMessages.add(
            AIChatMessage(
              role: 'user',
              content:
                  '【系统事件】你本轮调用工具过多（同工具连续/查询类累计/'
                  '总轮数触发防护），系统已停止你的工具调用。'
                  '现在就基于已有结果直接回复她，别再申请任何工具；'
                  '真做不到就老实说"这个我现在做不到"。',
            ),
          );
          // 注入后这轮生成完就停（不继续 while）
          loopExceeded = true;
        }
        // 8-03 18:27：工具轮生成也是男主打字阶段 → 显示"正在输出"
        ChatPresence.instance.beginTyping();
        result = await _aiSvc.generateReply(
          '',
          personaId,
          personaName: personaName,
          personaPrompt: _currentPersonaPrompt(),
          userProfile: _currentUserSetting(),
          toolRound: true,
          // 8-06 21:12 用户 bug：第一轮男主已回过话 → 工具轮别再带旧话（防回复两句）
          userAlreadyReplied: result.text.trim().isNotEmpty,
          toolMessages: toolMessages,
          // 8-08 21:5x（GPT10问第7条）：软提示走状态块【状态提示】区
          stateHints: toolRoundHints,
          sessionId: _chatSessionId,
          storagePersonaId: chatPid,
        );
        if (result.text.trim().isNotEmpty) {
          // 8-08 01:2x 用户（管家编排）：工具轮男主文本——
          // 8-08 16:2x 用户反馈："说了很多话还在回复模型，好奇怪"：
          // 中间文本攒起 → 用户只看到思考气泡，以为男主卡住。
          // 改成：男主说了话就立即显示（含工具轮中间文本）——
          // 正常情况下 system_template 要求男主"请求工具时不输出文本"，
          // 所以工具轮中间文本很少；万一模型不听话说了话，显示出来
          // 也比攒起来让用户以为卡住强。工具结果仍由管家批量回传。
          replyTexts.add(result.text.trim());
          final roundText = await _displayableText(result.text);
          if (roundText.isNotEmpty) {

---

# ③ system_template.dart 全文（lib/butler/system_template.dart，233行）

> GitHub：https://github.com/nainaiyuan/pocket-inn-app/blob/main/lib/butler/system_template.dart

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

【工具】你有工具可用。系统已声明每个工具的完整格式（原生调用），
**直接按声明的格式调用，格式照抄别自由发挥**——调用后系统自动执行并把结果
交还给你，你基于结果继续自然回复即可。如果原生调用没成功或你不确定格式，
用一句话暗号（最不容易写错，格式固定照抄）：
「工具:工具名 参数名=值 参数名=值」——参数名可写中文（动作/内容/类别/关键词…）。
常用暗号（直接照抄改值，别改结构）：
- 工具:manage_flow 动作=next   （动作：create/next/finish/cancel/resume/status）
- 工具:manage_tool_cache 动作=add 内容=…  （动作：add/clear/status；干活中间数据）
- 工具:list_tools              （无参数）
- 工具:record_memory 内容=… 类别=日常  （类别：日常/喜欢/约定/事实）
- 工具:query_diary 关键词=…
调用工具时，暗号作为回复的一部分（其他内容照常 JSON 输出），
管家解析后自动执行；格式不确定先查 query_tool_formats 照模板写。
**工具轮规则（重要）**：需要工具时一次把能一起做的都请求了（批量，
比如查几个分类就一起查）；请求工具时不要输出任何文本/JSON——纯工具
调用，管家会按顺序执行完，**统一把全部结果给你**，你基于全部结果
最后一次性回复她（不要每调一个工具就说一句）。**说话≠流程结束**：
如果你回应她之后还有事要做（查/记/整理），继续请求工具，管家会继续
执行，直到你说完所有想说的并且不再需要工具——回答用户和干活可以
同时进行，别觉得"说了话就干完了"。工具结果里：没找到就是没找到、
失败会写明原因、查数据会返回数据；有用的数据你自己记到便签
（manage_pad）、工具缓存（manage_tool_cache）或记录里——**别查完就
丢，干完活把要长期用的整理进记忆**。查询类工具（query_diary/query_record/
recall_memory 等）的结果**管家会自动存进【工具缓存】**——下次先看缓存
里有不有，别重复查同一件事。管家自己处理完的不会中途打扰你。
工具清单不在这里——按分类组织的概览和详细用法由系统每轮注入
（想不起来就查 list_tools）。


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

---

# ④ _generateAndStoreThree + _summarize + _compactSummaries（lib/pages/chat/services/ai_chat_service.dart 1930-2168行）

> GitHub：https://github.com/nainaiyuan/pocket-inn-app/blob/main/lib/pages/chat/services/ai_chat_service.dart#L1930

  Future<bool> _generateAndStoreThree(
    String personaId,
    String personaName,
    String raw,
  ) async {
    final system = '【系统指令】你是「$personaName」。下面是你们最近的聊天记录。'
        '趁你还记得（之后上下文会被清空），把三样东西分类整理好：'
        '① 日记：把今天聊的、她的状态心情、你答应过的事、在意的小细节，'
        '整理成一段日记（像真正的日记有你的语气，300 字内），'
        '**用 write_diary 工具写进去**。'
        '② 摘要：影响后续对话的提醒（约定/承诺/正在做的事/她希望你记住的），'
        '每条一行 20 字内，细节不写——能查的用工具现查。'
        '③ 恢复包：下次继续对话时你需要知道的最关键上下文：'
        '你们进行到哪了、关系状态、当前话题、她最近的状态'
        '（100 字内，像失忆前留给自己看的纸条）。'
        '摘要和恢复包直接写在回复里：'
        '【摘要】\n…\n【恢复包】\n…\n'
        '不要客套话不要解释。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: raw),
        ],
        // 只带 write_diary：日记必须走工具写入（用户 21:56）
        tools: [
          {
            'type': 'function',
            'function': {
              'name': 'write_diary',
              'description': '写日记。把值得记住的细节按时间整理存档。',
              'parameters': {
                'type': 'object',
                'properties': {
                  'content': {
                    'type': 'string',
                    'description': '日记内容，一段完整的记录',
                  },
                },
                'required': ['content'],
              },
            },
          },
        ],
      );
      var diarySaved = false;
      // ① 工具调用：write_diary（男主调用工具写日记 → 同天拼接落库）
      final calls = res.toolCalls ?? const [];
      for (final tc in calls) {
        final name = tc['name'] as String? ?? '';
        final args = tc['arguments'];
        if (name == 'write_diary' && args is Map) {
          final content = (args['content'] as String?)?.trim() ?? '';
          if (content.isNotEmpty) {
            await ChatDatabaseService.instance.saveDiaryEntry(personaId, content);
            diarySaved = true;
            DebugLogger.log('上下文管理', '📔 男主调用 write_diary 写日记（${content.length} 字，同天拼接）');
            // 用户 8-03 03:09：男主做了什么必须有气泡记录（不管用户看不看）。
            // 后台沉淀时聊天页可能没挂载 → 直接落库，用户回来从 DB 加载能看到
            await _logToolBubble(personaId, '✅ write_diary 完成：日记已存档（${content.length} 字）');
          }
        }
      }
      // ② 文本里解析 摘要/恢复包（+ 兜底：AI 没调工具但写了【日记】段）
      final text = res.text.trim();
      final summary = _extractSection(text, '【摘要】');
      final recovery = _extractSection(text, '【恢复包】');
      if (!diarySaved) {
        final diaryText = _extractSection(text, '【日记】');
        if (diaryText.isNotEmpty) {
          await ChatDatabaseService.instance.saveDiaryEntry(personaId, diaryText);
          diarySaved = true;
          DebugLogger.log('上下文管理', '📔 兜底：日记文本直接落库（同天拼接）');
        }
      }
      if (summary.isNotEmpty) {
        await ContextManager.instance.appendSummary(personaId, summary);
      }
      if (recovery.isNotEmpty) {
        await ContextManager.instance.saveRecovery(personaId, recovery);
      }
      return diarySaved || summary.isNotEmpty || recovery.isNotEmpty;
    } on Object catch (e) {
      DebugLogger.log('指令模块', '⚠️ 三类存档生成失败: $e');
      return false;
    }
  }

  /// 从男主输出里截取某段（按标记切，取标记后到下个标记前）。
  String _extractSection(String text, String marker) {
    final idx = text.indexOf(marker);
    if (idx < 0) return '';
    var start = idx + marker.length;
    // 找下一个标记
    var end = text.length;
    for (final next in ['【日记】', '【摘要】', '【恢复包】']) {
      if (next == marker) continue;
      final n = text.indexOf(next, start);
      if (n >= 0 && n < end) end = n;
    }
    return text.substring(start, end).trim();
  }

  /// 男主总结轮：待总结原文 → 男主写提醒要点 → 追加进摘要区 → 清空原文。
  /// 触发由管家控制（原文攒够量），内容男主写（视角一致，不 OOC）。
  /// 用户 21:10：摘要=提醒索引，不是细节仓库——能查的当场查（工具），
  /// 每天要查的/影响连续性的才写进摘要；不重要的遗忘，需要时现查。
  /// 用户 21:13：上下文要没了（token 快满）→ 先写日记存档（细节不丢），
  /// 再提炼摘要提醒（日记=细节存档，摘要=提醒，各司其职）。
  /// 8-05 19:19 用户定稿（窗口满总结 v2）：
  /// 窗口满 → C 自动拼（男主不用复述）→ 男主只调 save_summary 写摘要
  /// （不输出文本）→ 摘要保存"几到几"编号（#a-#b，不是复述上下文）
  /// → 原文被摘要替换（清空）→ 工具/管家历史不重要就扔掉。
  Future<void> _summarize(
    String personaId,
    String personaName, {
    String personaPrompt = '',
    String? userProfile,
    String? taskState,
  }) async {
    final (start, end, raw) =
        ContextManager.instance.takePendingRawWithRange(personaId);
    if (raw.trim().isEmpty) return;
    final rangeLabel = end > 0 ? '#$start-#$end' : '';
    DebugLogger.log('上下文管理', '✂️ 原文攒够了（${raw.length} 字，上下文要没了）…');
    // ① 先写日记存档（原文要没了，细节进日记，男主可查）
    final diary = await generateDailyDiary(personaId, personaName, raw);
    if (diary.isNotEmpty) {
      await ChatDatabaseService.instance.saveDiaryEntry(personaId, diary);
      DebugLogger.log('上下文管理', '📔 日记已存档（${diary.length} 字），细节没丢');
      ContextManager.instance
          .logButlerAction(personaId, '总结·写日记存档', '✅完成');
    }
    // ② C 自动拼（用户 19:19：窗口满 C 自动拼，男主不需要复述）
    final needsWindow = false; // 8-08 19:4x：对话里永不要求男主报 #model（管家探测替代）
    final c = SystemTemplate.build(
      personaName: personaName,
      personaPrompt: personaPrompt,
      needsWindow: needsWindow,
      userProfile: userProfile,
      taskState: taskState,
    );
    // 【当前管家】唤醒指令（19:16 用户：当前管家段 = 管家唤醒 AI 的通道）
    final instruction = '【当前系统】窗口快满了，把刚给你的对话总结成摘要。'
        '调用 save_summary 工具写入（不要复述对话内容）：'
        '① content：影响后续对话的提醒，每条一行 20 字内，细节不写——'
        '能当场查的（记忆、日记）不写，需要时你用工具查'
        '② range：这次总结覆盖的编号范围'
        '${rangeLabel.isEmpty ? '' : '（就是 $rangeLabel）'}。'
        '不重要的直接遗忘，不要客套话。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: c),
          AIChatMessage(
              role: 'user',
              content: '【本次要总结的对话】（带时间戳，按顺序）\n$raw'),
          AIChatMessage(role: 'user', content: instruction),
        ],
        // 只带 save_summary：男主必须调工具写摘要（用户 19:19）
        tools: summarizeTools,
      );
      var saved = false;
      final calls = res.toolCalls ?? const [];
      for (final tc in calls) {
        final name = tc['name'] as String? ?? '';
        final args = tc['arguments'];
        if (name == 'save_summary' && args is Map) {
          final content = (args['content'] as String?)?.trim() ?? '';
          final range = (args['range'] as String?)?.trim() ?? rangeLabel;
          if (content.isNotEmpty) {
            await ContextManager.instance
                .appendSummary(personaId, '（$range）$content');
            saved = true;
            DebugLogger.log('上下文管理',
                '✅ 男主调 save_summary 写入摘要（$range，${content.length} 字）');
          }
        }
      }
      if (!saved) {
        // 男主没调工具 → 文本兜底（保底不丢，但下次应引导调工具）
        final text = res.text.trim();
        if (text.isNotEmpty) {
          await ContextManager.instance
              .appendSummary(personaId, '（$rangeLabel）$text');
          DebugLogger.log('上下文管理',
              'ℹ️ 男主没调工具，文本摘要兜底（${text.length} 字）');
        } else {
          DebugLogger.log('上下文管理',
              'ℹ️ 男主没提炼出提醒，原文已遗忘（细节在日记）');
        }
      }
      // 原文已取走（被摘要替换）；工具/管家历史不重要 → 扔掉（用户 19:19）
      ContextManager.instance.clearButlerLog(personaId);
      ContextManager.instance
          .logButlerAction(personaId, '总结', '✅完成（$rangeLabel）');
    } on Object catch (e) {
      ContextManager.instance
          .logButlerAction(personaId, '总结', '❌失败：$e');
      DebugLogger.log('上下文管理', '⚠️ 男主总结失败: $e（对话行已恢复待下次）');
      // 失败恢复对话行（工具行不重要不恢复），编号已递增可接受
      ContextManager.instance.restoreRaw(personaId, raw);
    }
  }

  /// 摘要缩减轮：摘要区太大 → 男主把旧摘要再压缩成更紧凑的 → 替换。
  Future<void> _compactSummaries(String personaId, String personaName) async {
    final old = await ContextManager.instance.takeSummariesForCompact(personaId);
    if (old.trim().isEmpty) return;
    DebugLogger.log('上下文管理', '🗜️ 摘要区太大，缩减中…');
    final system = '【系统指令】你是「$personaName」。以下是你们之前的对话摘要列表，'
        '请压缩合并成更紧凑的要点：① 合并同类话题 ② 每条一行、20 字内 '
        '③ 只保留最重要的信息 ④ 不要客套话。只输出压缩后的要点列表。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: old),
        ],
        tools: null,
      );
      final summary = res.text.trim();
      if (summary.isNotEmpty) {
        await ContextManager.instance.appendSummary(personaId, summary);
        DebugLogger.log('上下文管理', '✅ 摘要缩减完成（${summary.length} 字）');
      } else {
        await ContextManager.instance.restoreSummaries(personaId, old);
        DebugLogger.log('上下文管理', '⚠️ 摘要缩减为空，保留原摘要');
      }
    } on Object catch (e) {
      await ContextManager.instance.restoreSummaries(personaId, old);
      DebugLogger.log('上下文管理', '⚠️ 摘要缩减失败: $e（保留原摘要）');
    }
  }

  /// 当前生效的模型名（候选列表第一个 = 当前生效）

---

# ⑤ context_tracker.dart 全文（lib/butler/context/context_tracker.dart）

> GitHub：https://github.com/nainaiyuan/pocket-inn-app/blob/main/lib/butler/context/context_tracker.dart

import '../../utils/debug_logger.dart';

/// 单个男主的追踪状态
class _ContextState {
  final List<_ContextEntry> entries = [];
  int windowSize = 0; // 上下文窗口长度（#model 问出来的，0=未确认）
  int usedTokens = 0; // 最近一次调用消耗（API usage 精确值）
  bool cleared = true; // 是否处于"全清"状态（换角色后）
  DateTime? lastCallAt; // 上次调用时间
}

/// 已发送内容条目
class _ContextEntry {
  final String contentId;
  final String text;
  final String category;
  final DateTime sentAt;
  bool forgotten; // 被顶出窗口 → 遗忘
  _ContextEntry({
    required this.contentId,
    required this.text,
    required this.category,
    required this.sentAt,
    this.forgotten = false,
  });
}

/// 男主"记得清单"追踪器 —— 滚动计算男主到底还记得什么
///
/// 核心逻辑：
///   1. 每个男主（personaId）维护一张已发送内容清单（内容 + token 位置 + 时间）
///   2. 新内容不断进，旧内容被顶出窗口 → 标记"遗忘"（滚动遗忘）
///   3. 换角色（其他男主/管家调用过 API）→ 该男主清单全清 → 下次全推
///   4. 推内容前查清单：记得 → 不推；忘了 → 推
///   5. 核心内容（基础设定）永不遗忘（除非换角色全清）
///
/// 窗口大小来源：用 #model 问 AI（不硬编码，以 AI 回答为准）；
/// token 消耗用 API 精确值（usage.prompt_tokens）。
class ContextTracker {
  ContextTracker._();
  static final ContextTracker instance = ContextTracker._();

  /// 内容类别
  static const String catCore = 'core'; // 基础设定（角色卡/世界书/预设）
  static const String catMemory = 'memory'; // 记忆注入
  static const String catPattern = 'pattern'; // 规律
  static const String catHistory = 'history'; // 对话历史
  static const String catHandoff = 'handoff'; // 交接记录

  final Map<String, _ContextState> _states = {};

  _ContextState _state(String personaId) =>
      _states.putIfAbsent(personaId, () => _ContextState());

  /// 记录一次 API 调用（token 精确值，来自 usage）
  void recordCall(String personaId, int promptTokens) {
    final s = _state(personaId);
    s.usedTokens = promptTokens;
    s.lastCallAt = DateTime.now();
    s.cleared = false;
  }

  /// 设置窗口长度（#model 解析结果）
  void setWindow(String personaId, int window) {
    if (personaId.isEmpty || window <= 0) return;
    _state(personaId).windowSize = window;
    DebugLogger.log('上下文', '🎯 $personaId 上下文窗口确认: $window token');
  }

  /// 窗口长度（0 = 未确认，需要问 AI）
  int windowOf(String personaId) => _state(personaId).windowSize;

  /// 清空窗口设置回"未确认"（验收重置测试空间用，8-05 21:30：
  /// 上次验收 ⑤ 的 setWindow(800) 持久残留 → 下次验收 ①-③ 提前触发
  /// 总结 → forceRecover → ④ 误判全量带）
  void clearWindow(String personaId) {
    _states.remove(personaId);
  }

  /// 是否已确认窗口
  bool windowConfirmed(String personaId) =>
      _state(personaId).windowSize > 0;

  /// 内置窗口表（男主没报 #model 时的兜底；以男主自报为准）
  static const Map<String, int> knownModels = {
    'deepseek-chat': 65536,
    'deepseek-reasoner': 65536,
    'deepseek-r1': 65536,
    'gpt-4': 8192,
    'gpt-4o': 128000,
    'gpt-4o-mini': 128000,
    'glm-4': 128000,
    'glm-4-plus': 128000,
    'qwen-plus': 131072,
    'qwen-max': 32768,
    'qwen-turbo': 131072,
  };

  /// 按模型名查窗口（模糊匹配，返回 0 = 未知）
  int windowByModelHint(String modelHint) {
    if (modelHint.isEmpty) return 0;
    final lower = modelHint.toLowerCase();
    for (final entry in knownModels.entries) {
      if (lower.contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }
    return 0;
  }

  /// 记录发送了一条内容（进记得清单）
  void recordSent(
    String personaId,
    String text, {
    required String category,
  }) {
    if (personaId.isEmpty || text.isEmpty) return;
    final s = _state(personaId);
    // 防膨胀：遗忘条目超过 60 条 → 清掉最旧的遗忘条目（核心内容保留）
    final forgotten = s.entries.where((e) => e.forgotten).toList();
    if (forgotten.length > 60) {
      forgotten.sort((a, b) => a.sentAt.compareTo(b.sentAt));
      for (final e in forgotten.take(forgotten.length - 60)) {
        s.entries.remove(e);
      }
      DebugLogger.log('上下文', '🧽 清理遗忘条目（保留最近60条遗忘记录）');
    }
    // 防膨胀：总条目超过 300 → 直接删最旧的遗忘条目
    if (s.entries.length > 300) {
      final toRemove = s.entries
          .where((e) => e.forgotten)
          .toList()
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      while (s.entries.length > 300 && toRemove.isNotEmpty) {
        s.entries.remove(toRemove.removeAt(0));
      }
      DebugLogger.log('上下文', '🧽 条目超300，强制清理遗忘条目');
    }
    final contentId = '${category}_${text.hashCode}';
    for (final e in s.entries) {
      if (e.contentId == contentId) {
        return; // 同内容已登记
      }
    }
    s.entries.add(_ContextEntry(
      contentId: contentId,
      text: text,
      category: category,
      sentAt: DateTime.now(),
    ));
    _rollForget(s);
  }

  /// 滚动遗忘：窗口已确认且估算超 90% → 最旧的非核心内容标记遗忘
  void _rollForget(_ContextState s) {
    if (s.windowSize <= 0) return;
    var est = 0;
    for (final e in s.entries) {
      if (!e.forgotten && e.category != catCore) {
        est += e.text.length;
      }
    }
    final limit = (s.windowSize * 0.9).round();
    if (est <= limit) return;
    final sorted = s.entries
        .where((e) => !e.forgotten && e.category != catCore)
        .toList()
      ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    for (final e in sorted) {
      if (est <= limit) break;
      e.forgotten = true;
      est -= e.text.length;
      DebugLogger.log(
        '上下文',
        '🌬️ 男主遗忘了旧内容: ${e.text.length}字（被顶出窗口）',
      );
    }
  }

  /// 男主是否还记得某内容（清单里有且未遗忘）
  bool remembers(
    String personaId,
    String text, {
    String category = catMemory,
  }) {
    final s = _state(personaId);
    if (s.cleared) return false; // 换角色全清 → 什么都不记得
    final contentId = '${category}_${text.hashCode}';
    for (final e in s.entries) {
      if (e.contentId == contentId) {
        return !e.forgotten;
      }
    }
    return false; // 没发过 → 不记得 → 需要推
  }

  /// 换角色全清（其他男主/管家调用过 API → 上下文全没）
  void clearAll(String personaId) {
    final s = _state(personaId);
    s.entries.clear();
    s.cleared = true;
    s.usedTokens = 0;
    DebugLogger.log('上下文', '🧹 $personaId 上下文全清（角色切换/换 API）');
  }

  /// 标记"该男主正在被调用"（同一男主连续对话 → 上下文延续）
  void touch(String personaId) {
    if (personaId.isEmpty) return;
    final s = _state(personaId);
    s.cleared = false;
    s.lastCallAt = DateTime.now();
  }

  /// 上次调用时间
  DateTime? lastCallOf(String personaId) => _state(personaId).lastCallAt;

  /// 调试摘要
  String summary(String personaId) {
    final s = _state(personaId);
    final remembered = s.entries.where((e) => !e.forgotten).length;
    return '📊 $personaId 记得清单：共${s.entries.length}条，记得$remembered条'
        '，窗口${s.windowSize > 0 ? s.windowSize : '未确认'}'
        '，已用${s.usedTokens}token${s.cleared ? '（全清状态）' : ''}';
  }
}

---

# ⑥ 一轮真实工具调用日志（获取方法 + 代码推导的完整消息流）

## 6.1 真实日志在哪（需要用户从平板导出）

**DebugLogger 落盘位置**（`lib/utils/debug_logger.dart` 第 32-44 行）：
- 文件名：`debug_log_YYYY-MM-DD.txt`（如 `debug_log_2026-08-09.txt`）
- 位置：APP 的文档目录（Android 上 = `/storage/emulated/0/Android/data/<包名>/files/debug_log_*.txt`）
- 启动时 DebugLogger 会打印 `DebugLogger dir: <路径>`，可在平板 logcat 里搜这一行确认确切路径

**两个获取方式（二选一）：**
1. 平板上用文件管理器进 `Android/data/<包名>/files/` 找到当天的 `debug_log_*.txt`，发给 GPT（搜关键词 `AI路由`、`上下文调试`、`📦 本次发给模型的历史` 可定位工具轮）
2. 聊天里让男主调 `query_logs` 工具（keyword 填 `工具` 或 `AI路由`，能查到带时间戳的执行路径）——这个是 app 内查，适合快速看，导出给 GPT 还是方式 1 方便

**日志里找一轮工具调用的标记：**
- `📦 本次发给模型的历史 N 条` → 第一次 messages
- `🔧 第 N 轮：男主请求 X 个工具` → 模型返回的 tool_calls
- `🔧 工具 X 参数：...` → 工具入参
- `📝 已记录男主回复` → 最终回复

## 6.2 代码推导：一轮工具调用的完整消息流（没有日志也能看懂的链路）

以下根据 chat_page.dart + ai_chat_service.dart 源码逐行推导，标注行号可查证：

### 第 1 次请求（用户发消息 → 男主回复）
**入口**：chat_page.dart 调 `generateReply(message, personaId, ...)` → ai_chat_service.dart `generateReply()`（942行）

**messages 组装**（ai_chat_service.dart 1290-1303行）：
```
[system]  SystemTemplate.build(...)          ← 人设（见③，非轻量期才有）
[system]  statusBlocks（当前情况/待回复/流程/任务清单/手册/提示）  ← 1220-1288行
[system]  【上下文说明】以下是已聊过的历史...  ← 1296行（historyMsgs 非空时）
...historyMsgs...                            ← ContextManager.buildHistoryMessages()（见①）
[user]    message（用户当前消息）              ← 1301行
```
**发送**：`AIProviderManager.chat()` 带 `tools: butlerTools`（工具定义，ai_chat_service.dart 69行起）

**模型返回**：`result.toolCalls`（原生 tool_calls 带 id）+ 可能同时有 `result.text`

### tool_calls 解析（chat_page.dart 1051-1075行）
- 若第一轮无原生 tool_calls 但文本含 `⟨工具:…⟩` 块 → `ToolIntentParser.extract()` 解析成 toolCalls（文本协议路径）
- 若有原生 tool_calls（带 id）→ 直接用

### 工具执行循环（chat_page.dart 1175-1990行，while 循环，上限 10 轮）
1. **双通道分流**（1205-1223行）：
   - `nativeCalls` = 有 reasoning_content 且带 id 的调用 → 走原生通道
   - 无 reasoning_content（思考链关/解析失败）→ nativeCalls 置空 → 全走文本协议（防 DeepSeek 400）
2. **toolMessages 组装**（1226-1237行）：原生通道先放 `assistant` 消息（content 原文 + tool_calls + reasoning_content 原样回传）
3. **逐个执行工具**（1238行起 for 循环）：record_memory/record_relation/... 每个工具 try-catch，执行结果进 toolMessages 的 `tool` 消息（带 toolCallId 配对）；文本协议的工具结果合并成文本注入 user 消息
4. **用户确认**：写记忆类工具弹 `_approveToolCall` 确认框，拒绝 → 结果标记"用户拒绝"

### 第 2 次请求（toolRound，chat_page.dart 1971行附近）
**入口**：`generateReply('', personaId, toolRound: true, toolMessages: toolMessages, userAlreadyReplied: ..., butlerInstruction: ...)`

**messages 组装**（ai_chat_service.dart 1290-1330行，工具轮分支）：
```
[system]  SystemTemplate.build(...)          ← 非轻量期才有
[system]  statusBlocks                       ← 仍在（当前情况/流程等）
[toolMessages]:
  [assistant] content + tool_calls + reasoning_content  ← 原生回传（1230行）
  [tool]      工具结果（带 toolCallId）       ← 1247行起
[user]    【当前系统】butlerInstruction（如有）← 1311行
[user]    【用户当前消息】lastUserMessageFor(ctxPid)  ← 1319行，必须在最后一条
```
**关键**：工具轮 `tools: null`（不带工具定义，防模型再次调用）；`historyMsgs = []`（工具轮不带历史）

### 最终回复
- 模型基于工具结果回复用户 → `result.text` → chat_page 显示 + `feedAssistantMessage()` 记入上下文（ai_chat_service.dart 1420行附近）

### ⚠️ 已知坑（GPT 分析时重点看）
1. **工具轮状态块里没有"男主刚调过什么工具"的明确区块**——工具结果只在 toolMessages 里，而 statusBlocks 的【当前情况】只写流程状态，不写工具执行记录。男主下一轮"不知道调用过什么"可能与此相关
2. **工具使用历史**在 buildHistoryMessages 里是独立 system 块（见① 319-340行），但它在**下一次正常轮**才注入——工具轮本身不注入
3. **feedToolCall**（context_manager.dart 198-275行）记录工具行——确认它是否覆盖所有工具路径（文本协议路径是否也 feed？）
