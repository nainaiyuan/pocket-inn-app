/// 检索调度全流程测试 — 预设数据 → 跑管线 → 验证 Prompt 上下文
///
/// 场景：
/// 1. 预设规律：提到「加班+累」→ 烦躁偏移（3次样本确认）
/// 2. 预设记忆：用户喜欢美式咖啡
/// 3. 预设要素：用户是程序员
/// 4. 用户说 A（单关键词"加班"）→ 应命中规律
/// 5. 用户说 A+B（"加班好累"）→ 应命中规律（组合匹配更准）
/// 6. 用户说"喝咖啡" → 应命中记忆
/// 7. 完整链路：管线 → context.fragments → PromptBuilder → 男主 Prompt 包含上下文
///
/// 跑法：flutter test test/butler_retrieval_flow_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:pocket_inn/butler/memory/emotion_arc.dart';
import 'package:pocket_inn/butler/memory/user_element.dart';
import 'package:pocket_inn/butler/memory/user_element_engine.dart';
import 'package:pocket_inn/butler/memory/user_element_store.dart';
import 'package:pocket_inn/butler/memory/user_memory.dart';
import 'package:pocket_inn/butler/modules/butler_module_hub.dart';
import 'package:pocket_inn/butler/modules/pipeline_runner.dart';
import 'package:pocket_inn/butler/modules/retrieval_module.dart';
import 'package:pocket_inn/butler/patterns/pattern_engine.dart';
import 'package:pocket_inn/butler/prompt/butler_prompt_builder.dart';
import 'package:pocket_inn/butler/prompt/prompt_source_registry.dart';

void main() {
  late PatternEngine patternEngine;
  late UserMemoryManager memoryManager;
  late UserElementStore elementStore;
  late UserElementEngineForTest elementEngine;

  setUp(() async {
    elementStore = UserElementStore();
    await elementStore.init();

    patternEngine = PatternEngine(elementStore);
    memoryManager = UserMemoryManager();
    elementEngine = UserElementEngineForTest(elementStore);

    // ===== 预设规律：加班+累 → 烦躁（3 次样本，确认规律）=====
    // 先喂 5 次普通对话让基线可靠（样本>=5），
    // 这样后面的「加班+累」弧线才会被判定为显著偏离，生成规律
    for (var i = 0; i < 5; i++) {
      await patternEngine.addArc(EmotionArc(
        id: 'arc_common_$i',
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
    // 再 3 次「加班+累」→ 烦躁偏离（烦躁 70 vs 基线 ~15 → 显著偏离）
    for (var i = 0; i < 3; i++) {
      await patternEngine.addArc(EmotionArc(
        id: 'arc_ot_$i',
        time: DateTime.now().subtract(Duration(days: i)),
        triggerKeywords: ['加班', '累'],
        topic: '工作',
        startMood: {'喜悦': 50, '烦躁': 10},
        peakMood: {'喜悦': 20, '烦躁': 70},
        endMood: {'喜悦': 35, '烦躁': 45},
        returnedToBaseline: true,
        durationMinutes: 30,
      ));
    }

    // ===== 预设记忆 =====
    memoryManager.add(UserMemory(
      id: 'mem_coffee',
      subject: '我',
      action: '喜欢喝美式咖啡',
      category: '喜好',
      tags: ['咖啡', '美式'],
    ));
    memoryManager.add(UserMemory(
      id: 'mem_cat',
      subject: '我',
      action: '养了一只叫团团的猫',
      category: '宠物',
      tags: ['猫', '团团'],
    ));
  });

  group('六路检索调度 — 规律命中', () {
    test('说"加班"（单关键词）→ 命中规律', () async {
      final contexts = await patternEngine.getMatchingContexts('今天又要加班');
      expect(contexts, isNotEmpty);
      expect(contexts.join(), contains('加班'));
      expect(contexts.join(), contains('规律'));
    });

    test('说"加班好累"（A+B 组合）→ 命中规律且更准', () async {
      final contexts = await patternEngine.getMatchingContexts('加班好累啊');
      expect(contexts, isNotEmpty);
      // 第一条是基线，规律在后面（基线段插在最前）
      final patternCtx = contexts.skip(1).join();
      expect(patternCtx, contains('加班'));
      expect(patternCtx, contains('累'));
      expect(patternCtx, contains('规律'));
    });
  });

  group('六路检索调度 — 记忆命中', () {
    test('说"喝咖啡" → 命中记忆', () {
      final memories = memoryManager.search('咖啡');
      expect(memories, isNotEmpty);
      expect(memories.first.action, contains('美式'));
    });

    test('说"我的猫" → 命中宠物记忆', () {
      final memories = memoryManager.search('猫');
      expect(memories, isNotEmpty);
      expect(memories.first.action, contains('团团'));
    });
  });

  group('完整链路 — 管线 → Prompt 拼装', () {
    test('说"加班好累" → 男主 Prompt 里有规律上下文', () async {
      // 用注入检索组件的 Hub
      final hub = ButlerModuleHub(enableDbRetrieval: false,
        patternEngine: patternEngine,
        memoryManager: memoryManager,
        elementEngine: elementEngine,
        // 不注入 insightEngine / recentRecordsLoader → 跳过那两路
      );

      // 跑管线
      final result = await hub.pipeline.runOutgoing(
        userId: 'u1',
        characterId: 'c1',
        sessionId: 's1',
        text: '今天加班好累啊',
      );

      // 没被拦截
      expect(result.blocked, isFalse);
      // 情绪分析模块跑过
      expect(result.hasFragments, isTrue);

      // 拼装男主 Prompt
      final promptResult = await ButlerPromptBuilder.instance.build(
        context: result.context,
        input: '今天加班好累啊',
      );

      // 检索片段进了 Prompt
      expect(promptResult.text, contains('【规律】'));
      expect(promptResult.text, contains('加班'));
    });

    test('说"想喝咖啡" → 男主 Prompt 里有记忆上下文', () async {
      final hub = ButlerModuleHub(enableDbRetrieval: false,
        patternEngine: patternEngine,
        memoryManager: memoryManager,
        elementEngine: elementEngine,
      );

      final result = await hub.pipeline.runOutgoing(
        userId: 'u1',
        characterId: 'c1',
        sessionId: 's1',
        text: '有点困，想喝咖啡',
      );

      expect(result.blocked, isFalse);

      final promptResult = await ButlerPromptBuilder.instance.build(
        context: result.context,
        input: '有点困，想喝咖啡',
      );

      expect(promptResult.text, contains('【记忆】'));
      expect(promptResult.text, contains('美式'));
    });
  });
}

/// 测试专用 UserElementEngine（避免 ONNX 初始化）
class UserElementEngineForTest extends UserElementEngine {
  UserElementEngineForTest(super.store);

  @override
  Future<List<UserElement>> search(String query, {int maxResults = 5}) async {
    // 内存版：关键词匹配（不依赖 ONNX）
    final all = await store.getAllActive();
    final q = query.toLowerCase();
    final matched = all.where((e) => e.content.toLowerCase().contains(q)).toList();
    return matched.take(maxResults).toList();
  }
}
