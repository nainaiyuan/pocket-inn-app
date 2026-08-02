/// 假面层模块 — 把敏感内容替换成男主能看的安全版本
///
/// 从 ButlerEngine 迁移过来的既有逻辑，行为不变：
/// 1. 假面层替换（真实人物 → 代号）
/// 2. 敏感词 PRIVACY_MARK 替换 + 心情标签
///
/// 这是阶段 0 的验证模块：确认管线骨架不改变现有行为。
library;

import '../butler_config.dart';
import '../mask_engine.dart';
import '../risk_filter_wordlist.dart' show RiskWord, riskWordlist, privacyMark;
import '../modules/butler_module.dart';

/// 假面层模块
class MaskModule extends ButlerModule {
  final MaskEngine maskEngine;
  final ButlerConfig _config;

  MaskModule({MaskEngine? maskEngine, ButlerConfig? config})
    : maskEngine = maskEngine ?? MaskEngine(),
      _config = config ?? ButlerConfig();

  @override
  String get id => 'mask';

  @override
  String get name => '假面层';

  @override
  String get description => '把敏感内容替换成安全版本，男主只看到代号';

  @override
  ButlerModuleStage get stage => ButlerModuleStage.guard;

  @override
  bool get enabled => _config.maskLayerEnabled || _config.keywordReplaceEnabled;

  @override
  Future<ButlerModuleResult> onUserMessage(
    ButlerContext context,
    String text,
  ) async {
    var current = text;
    final fragments = <String>[];

    // 1. 假面层替换
    if (_config.maskLayerEnabled) {
      final maskResult = maskEngine.replaceSensitive(
        text: current,
        characterId: context.characterId,
        sessionId: context.sessionId,
      );
      current = maskResult.text;
    }

    // 2. 关键词替换（PRIVACY_MARK）
    if (_config.keywordReplaceEnabled) {
      final sensitiveWords = _detectSensitiveWords(current);
      if (sensitiveWords.isNotEmpty) {
        final privacyResult = maskEngine.applyPrivacyMark(
          text: current,
          sensitiveWords: sensitiveWords,
        );
        current = privacyResult.text;

        // 3. 有替换时 → 心情标签助理解读
        final moodContext = maskEngine.buildMoodContextString(text);
        if (moodContext.isNotEmpty) {
          fragments.add(moodContext);
        }
      }
    }

    return ButlerModuleResult(text: current, contextFragments: fragments);
  }

  @override
  Future<ButlerModuleResult> onAssistantReply(
    ButlerContext context,
    String text,
  ) async {
    if (!_config.maskLayerEnabled) {
      return ButlerModuleResult.pass(text);
    }
    final restored = maskEngine.restoreSensitive(
      text: text,
      sessionId: context.sessionId,
    );
    return ButlerModuleResult(text: restored);
  }

  /// 风险词检测（与 ButlerEngine 保持一致：分级 + 搭配 + 浓度判定）
  List<RiskWord> _detectSensitiveWords(String text) {
    final hits = <RiskWord>[];
    for (final w in riskWordlist) {
      if (text.contains(w.word)) hits.add(w);
    }
    if (hits.isEmpty) return hits;
    final hardCount = hits.where((h) => h.isHard).length;
    final softCount = hits.length - hardCount;
    if (hardCount == 0 && softCount < 2) return [];
    return hits;
  }
}
