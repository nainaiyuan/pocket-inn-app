import '../modules/butler_module_hub.dart';
import '../storage/storage_registry.dart';
import '../../utils/debug_logger.dart';
import 'butler_skill.dart';

/// 情绪状态洞察技能
///
/// 用户提到"心情/情绪/心态/状态"时触发：
/// 管家实时检索情感基线（整体） + 近 7 天情绪弧线 + 确认规律（触发因素），
/// 生成一段"情绪洞察"注入 Prompt —— 男主回复时自然接住用户的情绪状态。
///
/// 例：用户说"我今天心情好差" → 男主会知道"她最近聊到妈妈时烦躁会上升"，
/// 而不是干巴巴回一句"怎么了"。
class MoodStatusSkill extends ButlerSkill {
  @override
  String get id => 'mood_status';

  @override
  String get name => '情绪状态洞察';

  @override
  String get description =>
      '用户提到心情、情绪、心态、状态时触发：检索情感基线和触发因素，生成洞察注入男主回复';

  @override
  List<String> get triggers => ['心情', '情绪', '心态', '烦不烦', '最近怎么'];

  @override
  int get priority => 10;

  @override
  Future<ButlerSkillResult> execute(ButlerSkillContext ctx) async {
    try {
      final engine = ButlerModuleHub.instance.sharedPatternEngine;
      final sb = StringBuffer('【情绪洞察·管家实时检索】');

      // 1. 整体基线（top3）
      final baseline = engine?.baseline.allValues ?? const <String, double>{};
      if (baseline.isNotEmpty) {
        final top = baseline.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        sb.write('用户近期整体情绪：'
            '${top.take(3).map((e) => '${e.key} ${e.value.round()}').join('、')}；');
      }

      // 2. 近 7 天弧线（高频情绪）
      try {
        final arcs = await StorageRegistry.instance.emotionArcs.loadAll();
        final recent = arcs
            .where((a) =>
                a.time.isAfter(DateTime.now().subtract(const Duration(days: 7))))
            .toList();
        if (recent.isNotEmpty) {
          final agg = <String, double>{};
          for (final a in recent) {
            a.peakMood.forEach((k, v) => agg[k] = (agg[k] ?? 0) + v);
          }
          agg.forEach((k, v) => agg[k] = v / recent.length);
          final top = agg.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          sb.write('近 7 天有 ${recent.length} 次情绪记录，'
              '高频情绪：${top.take(3).map((e) => '${e.key} ${e.value.round()}').join('、')}；');
        }
      } catch (_) {}

      // 3. 触发因素（确认规律中偏移 ≥5 的，最近 30 天）
      try {
        final patterns = (engine?.confirmedPatterns ?? const [])
            .where((p) =>
                p.confirmed &&
                p.lastSeen
                    .isAfter(DateTime.now().subtract(const Duration(days: 30))))
            .toList()
          ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
        final meaningful = patterns
            .where((p) => [
                  p.shiftAnger,
                  p.shiftSad,
                  p.shiftJoy,
                  p.shiftAttachment,
                ].any((s) => s.abs() >= 5))
            .take(2)
            .toList();
        if (meaningful.isNotEmpty) {
          sb.write('触发因素：');
          sb.write(meaningful.map((p) {
            final shifts = <String>[];
            void add(double v, String name) {
              if (v.abs() >= 5) {
                shifts.add('${v > 0 ? '$name↑' : '$name↓'}${v.abs().round()}');
              }
            }

            add(p.shiftAnger, '生气');
            add(p.shiftSad, '悲伤');
            add(p.shiftJoy, '开心');
            add(p.shiftAttachment, '依恋');
            return '聊到「${p.keywords.join('、')}」时${shifts.join('，')}（已确认 ${p.count} 次）';
          }).join('；'));
        }
      } catch (_) {}

      if (sb.length <= 10) {
        return const ButlerSkillResult();
      }
      DebugLogger.log('管家流程', '🎯 技能【$name】命中，已生成情绪洞察');
      return ButlerSkillResult(promptInjection: sb.toString());
    } catch (e) {
      DebugLogger.log('管家流程', '技能【$name】执行失败: $e');
      return const ButlerSkillResult();
    }
  }
}
