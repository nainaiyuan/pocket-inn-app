/// 动态维度测试 — 情绪模型输出什么维度，管家就认识什么维度
///
/// 场景：
/// 1. 基线从空开始（无预设维度）
/// 2. 模型输出新维度 → 自动注册进基线
/// 3. 新维度首次出现 → 记录为基线（不触发偏离）
/// 4. 新维度再次出现且值变化 → 参与偏离检测
/// 5. 更换模型（维度体系完全不同）→ 旧维度自然衰减思路：新维度独立注册
///
/// 跑法：flutter test test/butler_dynamic_dimension_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:pocket_inn/butler/mood_analysis/mood_interface.dart';
import 'package:pocket_inn/butler/patterns/mood_baseline.dart';

void main() {
  group('动态维度', () {
    test('基线从空开始，没有预设维度', () {
      final baseline = MoodBaseline();
      expect(baseline.knownDimensions, isEmpty);
      expect(baseline.isReliable, isFalse);
    });

    test('模型输出新维度 → 自动注册进基线', () {
      final baseline = MoodBaseline();
      baseline.update({'怀旧': 60, '愧疚': 40});

      expect(baseline.knownDimensions, containsAll(['怀旧', '愧疚']));
      expect(baseline.get('怀旧'), closeTo(60, 0.001));
      expect(baseline.get('愧疚'), closeTo(40, 0.001));
    });

    test('维度随时间滚动平均（动态更新基线）', () {
      final baseline = MoodBaseline();
      baseline.update({'怀旧': 60});
      baseline.update({'怀旧': 80});

      // 滚动平均：(60 + 80) / 2 = 70
      expect(baseline.get('怀旧'), closeTo(70, 0.001));
      expect(baseline.isReliable, isFalse); // 只有 2 次样本

      baseline.update({'怀旧': 70});
      baseline.update({'怀旧': 74});
      baseline.update({'怀旧': 76});
      // 5 次样本 → 可信
      expect(baseline.isReliable, isTrue);
      // 滚动平均：60,80,70,74,76 → 依次 60,70,70,71,72
      expect(baseline.get('怀旧'), closeTo(72, 0.001));
    });

    test('新维度首次出现不触发偏离（记录为基线），第二次变化才偏离', () {
      final baseline = MoodBaseline();
      // 先喂 5 次让基线可信
      for (var i = 0; i < 5; i++) {
        baseline.update({'喜悦': 50, '烦躁': 15});
      }
      expect(baseline.isReliable, isTrue);

      // 新维度「愧疚」首次出现：基线里没有 → detectDeviation 忽略它
      var result = baseline.detectDeviation({'愧疚': 70});
      expect(result.isDeviated, isFalse);

      // 更新基线，注册「愧疚」= 70
      baseline.update({'愧疚': 70});

      // 「愧疚」再次出现且值变化 → 参与偏离检测
      result = baseline.detectDeviation({'愧疚': 30});
      expect(result.isDeviated, isTrue); // 偏离 40 → 显著
      expect(result.maxDimension, '愧疚');
      expect(result.severity, DeviationSeverity.significant);
    });

    test('维度体系完全更换（换模型）→ 新维度独立注册，旧维度不干扰', () {
      final baseline = MoodBaseline();
      // 旧模型维度
      baseline.update({'喜悦': 50, '烦躁': 15});

      // 换新模型：输出完全不同的维度体系
      baseline.update({'安心': 80, '焦虑': 20, '信任': 90});

      expect(baseline.knownDimensions,
          containsAll(['喜悦', '烦躁', '安心', '焦虑', '信任']));
      // 新维度的基线值正常
      expect(baseline.get('安心'), closeTo(80, 0.001));
      expect(baseline.get('焦虑'), closeTo(20, 0.001));
    });

    test('valance 动态计算正负', () {
      final baseline = MoodBaseline();
      baseline.update({'开心': 80, '烦躁': 20});
      expect(baseline.valence, greaterThan(0));

      baseline.update({'开心': 10, '烦躁': 90});
      expect(baseline.valence, lessThan(0));
    });
  });
}
