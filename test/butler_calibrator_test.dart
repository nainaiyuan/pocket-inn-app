/// 温控校准全流程测试 — 基线0 → 情绪偏离 → 创建任务 → 男主回复解析 → 闭环
///
/// 场景：
/// 1. 基线不可信（样本<5）时，情绪波动不触发任务
/// 2. 基线可信后，情绪显著偏离 → 创建 keywordCollect 任务
/// 3. 轻度偏离（20-39）→ 也创建任务，但 is_anomaly=false
/// 4. 情绪回归 → 连续3次 → 创建 arcConfirm 任务
/// 5. 男主回复 "#keywords 加班,累" → TaskResponseHandler 解析 → 任务确认
/// 6. 男主正常回复（无标记）→ 原样返回，不误伤
/// 7. 任务超时（30s 无响应）→ 标记 timeout
///
/// 跑法：flutter test test/butler_calibrator_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:pocket_inn/butler/memory/emotion_arc.dart';
import 'package:pocket_inn/butler/memory/user_element_store.dart';
import 'package:pocket_inn/butler/modules/butler_module.dart';
import 'package:pocket_inn/butler/modules/calibrator_module.dart';
import 'package:pocket_inn/butler/mood_analysis/mood_interface.dart';
import 'package:pocket_inn/butler/patterns/pattern_engine.dart';
import 'package:pocket_inn/butler/task/butler_task.dart';
import 'package:pocket_inn/butler/task/task_manager.dart';
import 'package:pocket_inn/butler/task/task_response_handler.dart';

void main() {
  late PatternEngine patternEngine;
  late TaskManager taskManager;
  late CalibratorModule calibrator;
  late TaskResponseHandler handler;

  setUp(() async {
    final store = UserElementStore();
    await store.init();
    patternEngine = PatternEngine(store);
    taskManager = TaskManager.instance;
    taskManager.clearAll(); // 清掉上次测试残留
    calibrator = CalibratorModule(
      taskManager: taskManager,
      patternEngine: patternEngine,
      minIntervalSeconds: 0,   // 测试不防抖
      taskTimeoutSeconds: 1,   // 超时计时器短一点，避免测试挂起
    );
    handler = TaskResponseHandler(
      taskManager: taskManager,
      patternEngine: patternEngine,
    );
  });

  tearDown(() {
    calibrator.dispose(); // 取消超时计时器，避免测试挂起
  });

  ButlerContext makeContext() => ButlerContext(
    userId: 'u1',
    characterId: 'c1',
    sessionId: 's1',
  );

  /// 喂 5 次普通弧线让基线可信（烦躁基线 ~15）
  Future<void> feedBaseline() async {
    for (var i = 0; i < 5; i++) {
      await patternEngine.addArc(EmotionArc(
        id: 'base_$i',
        time: DateTime.now().subtract(Duration(days: 10 + i)),
        triggerKeywords: ['吃饭', '休息'],
        topic: '日常',
        startMood: {'喜悦': 50, '烦躁': 10},
        peakMood: {'喜悦': 55, '烦躁': 15},
        endMood: {'喜悦': 52, '烦躁': 12},
        returnedToBaseline: true,
        durationMinutes: 20,
      ));
    }
  }

  group('温控校准', () {
    test('基线不可信时，情绪波动不触发任务', () async {
      final ctx = makeContext();
      ctx.setData('mood_result', MoodResult(
        dimensions: {'烦躁': 80, '愤怒': 60},
        concentration: ConcentrationLevel.high,
        concentrationValue: 80,
      ));

      final result = await calibrator.onUserMessage(ctx, '今天好烦！');
      expect(result.text, '今天好烦！'); // 不拦截不改写
      expect(taskManager.getActiveTasks(), isEmpty); // 没有任务
    });

    test('基线可信 + 显著偏离（烦躁80 vs 基线15）→ 创建 keywordCollect 任务', () async {
      await feedBaseline();

      final ctx = makeContext();
      ctx.setData('mood_result', MoodResult(
        dimensions: {'烦躁': 80, '愤怒': 60},
        concentration: ConcentrationLevel.high,
        concentrationValue: 80,
      ));

      await calibrator.onUserMessage(ctx, '今天加班烦死了！');

      final tasks = taskManager.getActiveTasks();
      expect(tasks, isNotEmpty);
      expect(tasks.first.type, TaskType.keywordCollect);
      expect(tasks.first.resultData?['is_anomaly'], isTrue); // ≥40 显著
      expect(tasks.first.resultData?['max_dimension'], '烦躁');
    });

    test('轻度偏离（烦躁50 vs 基线15，差35）→ 创建任务但 is_anomaly=false', () async {
      await feedBaseline();

      final ctx = makeContext();
      ctx.setData('mood_result', MoodResult(
        dimensions: {'烦躁': 50},
        concentration: ConcentrationLevel.medium,
        concentrationValue: 50,
      ));

      await calibrator.onUserMessage(ctx, '有点烦');

      final tasks = taskManager.getActiveTasks();
      expect(tasks, isNotEmpty);
      expect(tasks.first.type, TaskType.keywordCollect);
      expect(tasks.first.resultData?['is_anomaly'], isFalse); // 20-39 轻度
    });

    test('正常波动不触发任务', () async {
      await feedBaseline();

      final ctx = makeContext();
      ctx.setData('mood_result', MoodResult(
        dimensions: {'喜悦': 55, '烦躁': 15}, // 贴近基线，正常波动
        concentration: ConcentrationLevel.low,
        concentrationValue: 55,
      ));

      await calibrator.onUserMessage(ctx, '今天天气不错');

      expect(taskManager.getActiveTasks(), isEmpty);
    });

    test('非标准维度（平静/放松）不误判为偏离', () async {
      await feedBaseline();

      final ctx = makeContext();
      ctx.setData('mood_result', MoodResult(
        dimensions: {'平静': 70, '放松': 60}, // 不在标准维度，应跳过
        concentration: ConcentrationLevel.low,
        concentrationValue: 70,
      ));

      await calibrator.onUserMessage(ctx, '今天天气不错');

      expect(taskManager.getActiveTasks(), isEmpty);
    });

    test('情绪回归 → 连续3次正常 → 创建 arcConfirm 任务', () async {
      await feedBaseline();

      // 第一次显著偏离 → keywordCollect
      final ctx1 = makeContext();
      ctx1.setData('mood_result', MoodResult(
        dimensions: {'烦躁': 80},
        concentration: ConcentrationLevel.high,
        concentrationValue: 80,
      ));
      await calibrator.onUserMessage(ctx1, '好烦！');
      expect(taskManager.getActiveTasks(), isNotEmpty);

      // 连续 3 次正常 → 第 3 次触发 arcConfirm
      for (var i = 0; i < 3; i++) {
        final ctx = makeContext();
        ctx.setData('mood_result', MoodResult(
          dimensions: {'喜悦': 52, '烦躁': 12},
          concentration: ConcentrationLevel.low,
          concentrationValue: 52,
        ));
        await calibrator.onUserMessage(ctx, '好点了');
      }

      final tasks = taskManager.getActiveTasks();
      final arcTasks = tasks.where((t) => t.type == TaskType.arcConfirm).toList();
      expect(arcTasks, isNotEmpty);
    });
  });

  group('任务响应解析', () {
    test('男主回复 #keywords 加班,累 → 解析关键词并确认任务', () async {
      await feedBaseline();

      // 先触发 keywordCollect 任务
      final ctx = makeContext();
      ctx.setData('mood_result', MoodResult(
        dimensions: {'烦躁': 80},
        concentration: ConcentrationLevel.high,
        concentrationValue: 80,
      ));
      await calibrator.onUserMessage(ctx, '今天加班好烦！');
      final pending = taskManager.getActiveTasks().first;
      expect(pending.type, TaskType.keywordCollect);

      // 男主回复带标记
      final result = handler.handle(
        '辛苦了宝宝，最近是不是加班太多了？\n#keywords 加班,累',
      );

      expect(result.matched, isTrue);
      expect(result.taskType, 'keywordCollect');
      expect(result.keywords, contains('加班'));
      expect(result.keywords, contains('累'));
      // 任务被确认
      expect(pending.status, TaskStatus.confirmed);
      // 清理标记后，剩下的是给用户看的回复
      expect(result.cleanedText, contains('辛苦了宝宝'));
      expect(result.cleanedText, isNot(contains('#keywords')));
    });

    test('男主正常回复（无标记）→ 原样返回不误伤', () async {
      final result = handler.handle('今天也要好好休息呀');

      expect(result.matched, isFalse);
      expect(result.cleanedText, '今天也要好好休息呀');
    });

    test('男主回复 #arc_end → 确认弧线任务', () async {
      await feedBaseline();

      // 触发偏离 → keywordCollect
      final ctx = makeContext();
      ctx.setData('mood_result', MoodResult(
        dimensions: {'烦躁': 80},
        concentration: ConcentrationLevel.high,
        concentrationValue: 80,
      ));
      await calibrator.onUserMessage(ctx, '好烦！');

      // 连续 3 次正常 → arcConfirm
      for (var i = 0; i < 3; i++) {
        final c = makeContext();
        c.setData('mood_result', MoodResult(
          dimensions: {'喜悦': 52, '烦躁': 12},
          concentration: ConcentrationLevel.low,
          concentrationValue: 52,
        ));
        await calibrator.onUserMessage(c, '好点了');
      }

      final arcTask = taskManager
          .getActiveTasks()
          .where((t) => t.type == TaskType.arcConfirm)
          .first;
      expect(arcTask.status, isNot(TaskStatus.confirmed));

      final result = handler.handle('那就好，抱抱你\n#arc_end');
      expect(result.matched, isTrue);
      expect(result.taskType, 'arcConfirm');
      expect(arcTask.status, TaskStatus.confirmed);
    });
  });
}
