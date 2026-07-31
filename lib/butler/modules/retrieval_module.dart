/// 检索调度模块 — 六路检索，给男主拼上下文
///
/// 用户发消息时，从六个来源检索相关信息，拼成 Prompt 片段：
/// 1. 规律引擎（关键词组合 → 情绪偏移，如"加班+累→烦躁"）
/// 2. 用户记忆（UserMemory，如"7月去过上海"）
/// 3. 用户要素（UserElement，如"喜欢喝美式"）
/// 4. 情绪基线（当前 19 维基线状态）
/// 5. 洞察引擎（话题→情绪关联）
/// 6. 最近互动（近期对话话题）
///
/// 检索结果全部走 [ButlerContext.fragments] 传给 Prompt 拼装器，
/// 男主就能"记得"之前的事、知道你一提什么就容易怎样。
library;

import '../insight/insight_engine.dart';
import '../memory/user_element_engine.dart';
import '../memory/user_memory.dart';
import '../modules/butler_module.dart';
import '../patterns/pattern_engine.dart';
import '../prompt/prompt_fragment.dart';
import '../prompt/prompt_source_registry.dart';
import '../../utils/debug_logger.dart';

/// 检索调度模块
class RetrievalModule extends ButlerModule {
  /// 规律引擎（可注入，测试用）
  final PatternEngine? patternEngine;

  /// 用户记忆管理器（可注入）
  final UserMemoryManager? memoryManager;

  /// 用户要素引擎（可注入）
  final UserElementEngine? elementEngine;

  /// 洞察引擎（可注入）
  final InsightEngine? insightEngine;

  /// 最近互动记录加载器（默认从数据库读，测试可注入）
  final Future<List<Map<String, dynamic>>> Function()? recentRecordsLoader;

  RetrievalModule({
    this.patternEngine,
    this.memoryManager,
    this.elementEngine,
    this.insightEngine,
    this.recentRecordsLoader,
  });

  @override
  String get id => 'retrieval';

  @override
  String get name => '检索调度';

  @override
  String get description => '六路检索：规律、记忆、要素、基线、洞察、近期话题 → 拼给男主当上下文';

  @override
  ButlerModuleStage get stage => ButlerModuleStage.analyze;

  @override
  Future<ButlerModuleResult> onUserMessage(
    ButlerContext context,
    String text,
  ) async {
    // 六路检索，全部收集
    final fragments = <String>[];
    DebugLogger.log('检索', '输入: "$text"');

    // ① 规律引擎 — 输入里出现已知关键词组合 → 输出情绪规律
    if (patternEngine != null) {
      try {
        final contexts = await patternEngine!.getMatchingContexts(text);
        if (contexts.isNotEmpty) {
          fragments.add('【规律】${contexts.join('；')}');
          DebugLogger.log('检索', '规律命中 ${contexts.length} 条: ${contexts.join('；')}');
        } else {
          DebugLogger.log('检索', '规律无命中');
        }
      } on Object catch (e) {
        fragments.add('【规律】检索异常: $e');
        DebugLogger.log('检索', '规律检索异常: $e');
      }
    }

    // ② 用户记忆 — 关键词匹配
    if (memoryManager != null) {
      try {
        final memories = memoryManager!.search(text);
        if (memories.isNotEmpty) {
          final top = memories.take(3).map((m) => m.toContext()).toList();
          fragments.add('【记忆】${top.join('；')}');
          DebugLogger.log('检索', '记忆命中 ${memories.length} 条: ${top.join('；')}');
        } else {
          DebugLogger.log('检索', '记忆无命中');
        }
      } on Object catch (e) {
        fragments.add('【记忆】检索异常: $e');
        DebugLogger.log('检索', '记忆检索异常: $e');
      }
    }

    // ③ 用户要素 — 语义检索
    if (elementEngine != null) {
      try {
        final results = await elementEngine!.search(text, maxResults: 3);
        if (results.isNotEmpty) {
          final top = results.map((e) => e.content).toList();
          fragments.add('【要素】${top.join('；')}');
          DebugLogger.log('检索', '要素命中 ${results.length} 条: ${top.join('；')}');
        } else {
          DebugLogger.log('检索', '要素无命中');
        }
      } on Object catch (e) {
        fragments.add('【要素】检索异常: $e');
        DebugLogger.log('检索', '要素检索异常: $e');
      }
    }

    // ④ 情绪基线 — 当前基线状态
    if (patternEngine != null) {
      try {
        final baselineCtx = patternEngine!.baseline.toContext();
        if (baselineCtx.isNotEmpty) {
          fragments.add('【基线】$baselineCtx');
        }
      } on Object catch (e) {
        fragments.add('【基线】检索异常: $e');
        DebugLogger.log('检索', '基线异常: $e');
      }
    }

    // ⑤ 洞察引擎 — 话题情绪关联
    if (insightEngine != null) {
      try {
        final topicResults = await insightEngine!.queryTopicMood(text);
        if (topicResults.isNotEmpty) {
          final top = topicResults.take(2).map((t) => '「${t.topic}」→${t.userReaction}').toList();
          fragments.add('【洞察】${top.join('；')}');
          DebugLogger.log('检索', '洞察命中 ${topicResults.length} 条: ${top.join('；')}');
        } else {
          DebugLogger.log('检索', '洞察无命中');
        }
      } on Object catch (e) {
        fragments.add('【洞察】检索异常: $e');
        DebugLogger.log('检索', '洞察检索异常: $e');
      }
    }

    // ⑥ 最近互动 — 近期话题（最近 3 条记录的 keywords）
    if (recentRecordsLoader != null) {
      try {
        final records = await recentRecordsLoader!();
        if (records.isNotEmpty) {
          final topics = records
              .take(3)
              .map((r) => (r['keywords'] as String? ?? '').trim())
              .where((k) => k.isNotEmpty)
              .toList();
          if (topics.isNotEmpty) {
            fragments.add('【近期】最近聊过：${topics.join('、')}');
            DebugLogger.log('检索', '近期话题: ${topics.join('、')}');
          }
        }
      } on Object catch (e) {
        fragments.add('【近期】检索异常: $e');
        DebugLogger.log('检索', '近期检索异常: $e');
      }
    }

    // 全部塞进 context.fragments（管线会转成 Prompt 片段）
    for (final f in fragments) {
      context.addFragment(source: name, content: f);
    }
    DebugLogger.log('检索', '共 ${fragments.length} 段上下文交给男主');

    return ButlerModuleResult.pass(text);
  }
}

/// 检索模块的 Prompt 来源 — 把检索结果拼进男主 Prompt
///
/// 实际数据由管线在 ButlerContext.fragments 里收集，
/// 这里直接从 context 读取并转成 PromptFragment。
class RetrievalPromptSource extends PromptSource {
  @override
  String get sourceId => 'retrieval';

  @override
  String get sourceName => '检索调度';

  @override
  bool get enabled => true;

  @override
  int get priority => 30;

  @override
  Future<PromptFragment?> buildFragment({
    required dynamic context,
    required String input,
  }) async {
    if (context is! ButlerContext) return null;
    if (context.fragments.isEmpty) return null;

    final contents = context.fragments
        .where((f) => f.source == '检索调度')
        .map((f) => f.content)
        .toList();
    if (contents.isEmpty) return null;

    return PromptFragment(
      sourceId: sourceId,
      sourceName: sourceName,
      content: contents.join('\n'),
      priority: priority,
    );
  }
}
