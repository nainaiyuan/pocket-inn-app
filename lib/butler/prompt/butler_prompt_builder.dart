/// 管家 Prompt 拼装器 — 把所有上下文拼成一段，直接扔给男主
///
/// 这是"Prompt 模块"的拼装端：
/// ```dart
/// final result = ButlerPromptBuilder.instance.build(
///   context: pipelineContext,
///   input: maskedUserText,
/// );
/// // result.text → 拼好的上下文文本，嵌入给男主的 Prompt
/// ```
///
/// 拼装规则：
/// 1. 按优先级排序所有来源的片段
/// 2. 片段之间用空行分隔
/// 3. 每个片段标注来源（方便排查和调试）
library;

import '../../utils/debug_logger.dart';
import 'prompt_fragment.dart';
import 'prompt_source_registry.dart';

/// 管家 Prompt 拼装器（单例）
class ButlerPromptBuilder {
  static final ButlerPromptBuilder instance = ButlerPromptBuilder._();

  ButlerPromptBuilder._();

  /// 是否在片段前标注来源（调试用，默认开）
  bool showSourceLabels = true;

  /// 拼装上下文
  /// [context] 管线 ButlerContext（模块塞的数据）
  /// [input] 当前用户输入（脱敏后）
  /// 返回拼好的文本 + 片段列表
  Future<PromptBuildResult> build({
    required dynamic context,
    required String input,
  }) async {
    final fragments = <PromptFragment>[];
    final skipped = <PromptFragment>[];

    for (final source in PromptSourceRegistry.instance.all) {
      if (!source.enabled) {
        DebugLogger.log('Prompt', '跳过来源 ${source.sourceId}（已禁用）');
        continue;
      }
      try {
        final fragment = await source.buildFragment(
          context: context,
          input: input,
        );
        if (fragment != null) {
          fragments.add(fragment);
        }
      } on Object catch (error, stack) {
        skipped.add(
          PromptFragment(
            sourceId: source.sourceId,
            sourceName: source.sourceName,
            content: '',
          ),
        );
        DebugLogger.log(
          'Prompt',
          '来源 ${source.sourceId} 构建失败，已跳过: $error\n$stack',
        );
      }
    }

    fragments.sort((a, b) => a.priority.compareTo(b.priority));

    final text = _join(fragments);
    return PromptBuildResult(
      text: text,
      fragments: fragments,
      skipped: skipped,
    );
  }

  String _join(List<PromptFragment> fragments) {
    final parts = <String>[];
    for (final fragment in fragments) {
      final content = fragment.content.trim();
      if (content.isEmpty) continue;

      if (showSourceLabels) {
        parts.add('【${fragment.sourceName}】\n$content');
      } else {
        parts.add(content);
      }
    }
    return parts.join('\n\n');
  }
}
