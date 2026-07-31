/// 管线执行器 — 按顺序跑所有模块
///
/// 职责：
/// 1. 用户发消息 → 依次跑 guard → analyze → persist 模块
/// 2. 任一模块返回 blocked → 立即停止，消息不发给男主
/// 3. 模块抛异常 → 记日志，跳过该模块，消息照常（管家可以笨，不能卡）
/// 4. 收集所有模块的 fragments → 供 Prompt 拼装
library;

import '../../utils/debug_logger.dart';
import 'butler_module.dart';
import 'module_registry.dart';

/// 管线执行结果
class PipelineResult {
  /// 最终文本（经过所有模块处理）
  final String text;

  /// 是否被拦截
  final bool blocked;

  /// 拦截原因
  final String? blockReason;

  /// 上下文（含所有模块产出的 fragments 和 data）
  final ButlerContext context;

  /// 实际执行的模块数
  final int executedModules;

  /// 失败的模块数
  final int failedModules;

  const PipelineResult({
    required this.text,
    required this.blocked,
    required this.blockReason,
    required this.context,
    required this.executedModules,
    required this.failedModules,
  });

  /// 是否有模块产出了 Prompt 片段
  bool get hasFragments => context.fragments.isNotEmpty;
}

/// 管线执行器
class PipelineRunner {
  final ModuleRegistry _registry;

  PipelineRunner({ModuleRegistry? registry})
    : _registry = registry ?? ModuleRegistry.instance;

  /// 处理用户 → 男主的消息
  Future<PipelineResult> runOutgoing({
    required String userId,
    required String characterId,
    required String sessionId,
    required String text,
  }) async {
    final context = ButlerContext(
      userId: userId,
      characterId: characterId,
      sessionId: sessionId,
    );

    var currentText = text;
    var executed = 0;
    var failed = 0;

    for (final module in _registry.all) {
      if (!module.isActive) continue;

      try {
        final result = await module.onUserMessage(context, currentText);
        result.attachOriginal(currentText);
        executed++;

        // 收集片段和数据
        for (final fragment in result.contextFragments) {
          context.addFragment(source: module.name, content: fragment);
        }
        for (final entry in result.data.entries) {
          context.setData(entry.key, entry.value);
        }

        // 拦截 → 立即停止
        if (result.blocked) {
          context.blocked = true;
          context.blockReason = result.blockReason;
          return PipelineResult(
            text: currentText,
            blocked: true,
            blockReason: result.blockReason,
            context: context,
            executedModules: executed,
            failedModules: failed,
          );
        }

        currentText = result.text;
      } on Object catch (error, stack) {
        failed++;
        DebugLogger.log(
          '管线',
          '模块 ${module.id} 异常，已跳过: $error\n$stack',
        );
      }
    }

    return PipelineResult(
      text: currentText,
      blocked: context.blocked,
      blockReason: context.blockReason,
      context: context,
      executedModules: executed,
      failedModules: failed,
    );
  }

  /// 处理男主 → 用户的回复
  Future<PipelineResult> runIncoming({
    required String userId,
    required String characterId,
    required String sessionId,
    required String text,
  }) async {
    final context = ButlerContext(
      userId: userId,
      characterId: characterId,
      sessionId: sessionId,
    );

    var currentText = text;
    var executed = 0;
    var failed = 0;

    for (final module in _registry.all) {
      if (!module.isActive) continue;

      try {
        final result = await module.onAssistantReply(context, currentText);
        result.attachOriginal(currentText);
        executed++;

        for (final entry in result.data.entries) {
          context.setData(entry.key, entry.value);
        }

        currentText = result.text;
      } on Object catch (error, stack) {
        failed++;
        DebugLogger.log(
          '管线',
          '模块 ${module.id} 回复处理异常，已跳过: $error\n$stack',
        );
      }
    }

    return PipelineResult(
      text: currentText,
      blocked: false,
      blockReason: null,
      context: context,
      executedModules: executed,
      failedModules: failed,
    );
  }

  /// 对话结束（5分钟无消息）
  Future<void> runConversationEnd({
    required String userId,
    required String characterId,
    required String sessionId,
    required ConversationEndInfo info,
  }) async {
    final context = ButlerContext(
      userId: userId,
      characterId: characterId,
      sessionId: sessionId,
    );

    for (final module in _registry.all) {
      if (!module.isActive) continue;
      try {
        await module.onConversationEnd(context, info);
      } on Object catch (error, stack) {
        DebugLogger.log(
          '管线',
          '模块 ${module.id} 对话结束处理异常: $error\n$stack',
        );
      }
    }
  }
}
