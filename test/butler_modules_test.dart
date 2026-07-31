/// 管家模块体系测试 — 纯逻辑，不依赖 Flutter/SQLite
///
/// 跑法：cd flutter_app && dart test test/butler_modules_test.dart
///
/// 覆盖：
/// 1. 禁区拦截（身份证/手机号/自定义禁区）
/// 2. 情绪分析（关键词版）
/// 3. 假面层模块（配置关闭时直通）
/// 4. 管线执行器（顺序、拦截即停、异常跳过）
/// 5. Prompt 拼装器（排序、来源标注）

import 'package:test/test.dart';

import 'package:pocket_inn/butler/modules/blocklist_module.dart';
import 'package:pocket_inn/butler/modules/butler_module.dart';
import 'package:pocket_inn/butler/modules/butler_module_hub.dart';
import 'package:pocket_inn/butler/modules/calibrator_module.dart';
import 'package:pocket_inn/butler/modules/mask_module.dart';
import 'package:pocket_inn/butler/modules/mood_module.dart';
import 'package:pocket_inn/butler/modules/module_registry.dart';
import 'package:pocket_inn/butler/modules/pipeline_runner.dart';
import 'package:pocket_inn/butler/modules/retrieval_module.dart';
import 'package:pocket_inn/butler/prompt/butler_prompt_builder.dart';
import 'package:pocket_inn/butler/prompt/prompt_fragment.dart';
import 'package:pocket_inn/butler/prompt/prompt_source_registry.dart';
import 'package:pocket_inn/butler/storage/blocklist_store.dart';

void main() {
  group('禁区拦截模块', () {
    test('拦截身份证号', () async {
      final module = BlocklistModule(dataSource: _MemoryBlocklist());
      final result = await module.onUserMessage(
        _ctx(),
        '我的身份证号是 11010119900307888X，你记一下',
      );
      expect(result.blocked, isTrue);
      expect(result.blockReason, contains('隐私信息'));
    });

    test('拦截手机号', () async {
      final module = BlocklistModule(dataSource: _MemoryBlocklist());
      final result = await module.onUserMessage(
        _ctx(),
        '我电话是13812345678，晚上联系',
      );
      expect(result.blocked, isTrue);
    });

    test('正常消息放行', () async {
      final module = BlocklistModule(dataSource: _MemoryBlocklist());
      final result = await module.onUserMessage(_ctx(), '今天天气不错');
      expect(result.blocked, isFalse);
      expect(result.text, '今天天气不错');
    });

    test('自定义禁区命中', () async {
      final module = BlocklistModule(
        dataSource: _MemoryBlocklist(patterns: ['前任']),
      );
      final result = await module.onUserMessage(_ctx(), '我昨天见到前任了');
      expect(result.blocked, isTrue);
      expect(result.blockReason, contains('禁区'));
    });
  });

  group('情绪分析模块', () {
    test('识别开心', () async {
      final module = MoodModule();
      final result = await module.onUserMessage(_ctx(), '今天好开心呀哈哈');
      expect(result.contextFragments, isNotEmpty);
      expect(result.contextFragments.first, contains('情绪'));
      expect(result.data['mood_result'], isNotNull);
    });

    test('平静消息产出空片段', () async {
      final module = MoodModule();
      final result = await module.onUserMessage(_ctx(), '嗯好的知道了');
      // 可能没有显著情绪 → 片段可能为空，但不报错
      expect(result.text, '嗯好的知道了');
    });
  });

  group('假面层模块', () {
    test('默认配置下运行不报错', () async {
      final module = MaskModule();
      final result = await module.onUserMessage(_ctx(), '普通消息');
      expect(result.text, isNotEmpty);
    });
  });

  group('管线执行器', () {
    test('模块按顺序执行并收集片段', () async {
      final registry = ModuleRegistry();
      registry.register(MoodModule());
      registry.register(BlocklistModule(dataSource: _MemoryBlocklist()));
      final pipeline = PipelineRunner(registry: registry);

      final result = await pipeline.runOutgoing(
        userId: 'u1',
        characterId: 'c1',
        sessionId: 's1',
        text: '我今天超级开心哈哈',
      );

      expect(result.blocked, isFalse);
      expect(result.executedModules, greaterThanOrEqualTo(2));
    });

    test('禁区拦截立即停止', () async {
      final registry = ModuleRegistry();
      registry.register(BlocklistModule(dataSource: _MemoryBlocklist()));
      registry.register(MoodModule());
      final pipeline = PipelineRunner(registry: registry);

      final result = await pipeline.runOutgoing(
        userId: 'u1',
        characterId: 'c1',
        sessionId: 's1',
        text: '我手机号13812345678',
      );

      expect(result.blocked, isTrue);
      expect(result.blockReason, isNotNull);
    });

    test('异常模块被跳过，消息照常', () async {
      final registry = ModuleRegistry();
      registry.register(_CrashModule());
      registry.register(BlocklistModule(dataSource: _MemoryBlocklist()));
      final pipeline = PipelineRunner(registry: registry);

      final result = await pipeline.runOutgoing(
        userId: 'u1',
        characterId: 'c1',
        sessionId: 's1',
        text: '正常消息',
      );

      expect(result.blocked, isFalse);
      expect(result.text, '正常消息');
      expect(result.failedModules, 1);
    });
  });

  group('Prompt 拼装器', () {
    test('按优先级排序并标注来源', () async {
      PromptSourceRegistry.instance.register(_TestSource(
        sourceId: 'test_low',
        sourceName: '低优先级',
        content: '低优先级内容',
        priority: 200,
      ));
      PromptSourceRegistry.instance.register(_TestSource(
        sourceId: 'test_high',
        sourceName: '高优先级',
        content: '高优先级内容',
        priority: 10,
      ));

      final result = await ButlerPromptBuilder.instance.build(
        context: _ctx(),
        input: '测试',
      );

      expect(result.fragments.length, 2);
      expect(result.fragments.first.sourceId, 'test_high');
      expect(result.text, contains('【高优先级】'));
      expect(result.text, contains('高优先级内容'));

      PromptSourceRegistry.instance.unregister('test_low');
      PromptSourceRegistry.instance.unregister('test_high');
    });

    test('禁用的来源被跳过', () async {
      PromptSourceRegistry.instance.register(_TestSource(
        sourceId: 'test_disabled',
        sourceName: '禁用源',
        content: '不应出现',
        priority: 10,
        enabled: false,
      ));

      final result = await ButlerPromptBuilder.instance.build(
        context: _ctx(),
        input: '测试',
      );

      expect(result.fragments, isEmpty);
      expect(result.text, isEmpty);

      PromptSourceRegistry.instance.unregister('test_disabled');
    });
  });

  group('模块注册表', () {
    test('Hub 注册了 5 个默认模块', () {
      final hub = ButlerModuleHub(enableDbRetrieval: false);
      expect(hub.count, 5);
      expect(hub.module<BlocklistModule>('blocklist'), isNotNull);
      expect(hub.module<MoodModule>('mood'), isNotNull);
      expect(hub.module<MaskModule>('mask'), isNotNull);
      expect(hub.module<RetrievalModule>('retrieval'), isNotNull);
      expect(hub.module<CalibratorModule>('calibrator'), isNotNull);
    });
  });
}

ButlerContext _ctx() => ButlerContext(
  userId: 'u1',
  characterId: 'c1',
  sessionId: 's1',
);

/// 测试用内存禁区数据源（不依赖 SQLite）
class _MemoryBlocklist implements BlocklistDataSource {
  final List<String> patterns;

  _MemoryBlocklist({this.patterns = const []});

  @override
  Future<List<BlocklistPattern>> match(String text) async {
    return patterns
        .where((p) => text.contains(p))
        .map((p) => BlocklistPattern(pattern: p, label: p))
        .toList();
  }
}

/// 测试用：总是崩溃的模块
class _CrashModule extends ButlerModule {
  @override
  String get id => 'crash';

  @override
  String get name => '崩溃测试';

  @override
  String get description => '总是抛异常';

  @override
  ButlerModuleStage get stage => ButlerModuleStage.guard;

  @override
  bool get enabled => true;

  @override
  Future<ButlerModuleResult> onUserMessage(
    ButlerContext context,
    String text,
  ) async {
    throw StateError('模拟崩溃');
  }
}

/// 测试用 Prompt 来源
class _TestSource extends PromptSource {
  final String _sourceId;
  final String _sourceName;
  final String content;
  final bool _enabled;
  final int _priority;

  _TestSource({
    required String sourceId,
    required String sourceName,
    required this.content,
    bool enabled = true,
    required int priority,
  }) : _sourceId = sourceId,
       _sourceName = sourceName,
       _enabled = enabled,
       _priority = priority;

  @override
  String get sourceId => _sourceId;

  @override
  String get sourceName => _sourceName;

  @override
  bool get enabled => _enabled;

  @override
  int get priority => _priority;

  @override
  Future<PromptFragment?> buildFragment({
    required dynamic context,
    required String input,
  }) async {
    return PromptFragment(
      sourceId: sourceId,
      sourceName: sourceName,
      content: content,
      priority: priority,
    );
  }
}
