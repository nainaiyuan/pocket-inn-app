/// 管家模块体系自检脚本 — 纯 Dart 直接运行
///
/// 跑法：cd flutter_app && dart run tool/butler_module_check.dart
///
/// 不依赖 Flutter SDK / pub 解析，直接 import 源码验证：
/// 1. 禁区拦截（身份证/手机号）
/// 2. 情绪分析（关键词版）
/// 3. 管线执行器（顺序、拦截即停、异常跳过）
/// 4. Prompt 拼装器（排序、来源标注、禁用跳过）
/// 5. 模块注册（Hub 默认 3 模块）

import 'dart:io';

import 'package:pocket_inn/butler/modules/blocklist_module.dart';
import 'package:pocket_inn/butler/modules/butler_module.dart';
import 'package:pocket_inn/butler/modules/butler_module_hub.dart';
import 'package:pocket_inn/butler/modules/mask_module.dart';
import 'package:pocket_inn/butler/modules/mood_module.dart';
import 'package:pocket_inn/butler/modules/module_registry.dart';
import 'package:pocket_inn/butler/modules/pipeline_runner.dart';
import 'package:pocket_inn/butler/prompt/butler_prompt_builder.dart';
import 'package:pocket_inn/butler/prompt/prompt_fragment.dart';
import 'package:pocket_inn/butler/prompt/prompt_source_registry.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool condition, [String? detail]) {
  if (condition) {
    _passed++;
    stdout.writeln('  ✅ $name');
  } else {
    _failed++;
    stdout.writeln('  ❌ $name${detail != null ? ' — $detail' : ''}');
  }
}

Future<void> main() async {
  stdout.writeln('=== 管家模块体系自检 ===\n');

  // ===== 1. 禁区拦截 =====
  stdout.writeln('【1. 禁区拦截】');
  {
    final module = BlocklistModule();
    final idResult = await module.onUserMessage(
      _ctx(),
      '我的身份证号是 11010119900307888X，你记一下',
    );
    _check('拦截身份证号', idResult.blocked, 'blocked=${idResult.blocked}');

    final phoneResult = await module.onUserMessage(
      _ctx(),
      '我电话是13812345678，晚上联系',
    );
    _check('拦截手机号', phoneResult.blocked, 'blocked=${phoneResult.blocked}');

    final normal = await module.onUserMessage(_ctx(), '今天天气不错');
    _check('正常消息放行', !normal.blocked && normal.text == '今天天气不错');
  }

  // ===== 2. 情绪分析 =====
  stdout.writeln('\n【2. 情绪分析】');
  {
    final module = MoodModule();
    final happy = await module.onUserMessage(_ctx(), '今天好开心呀哈哈');
    _check(
      '识别开心情绪',
      happy.contextFragments.isNotEmpty &&
          happy.contextFragments.first.contains('情绪'),
      'fragments=${happy.contextFragments}',
    );
    _check('产出结构化 mood_result', happy.data['mood_result'] != null);

    final calm = await module.onUserMessage(_ctx(), '嗯好的知道了');
    _check('平静消息不报错', calm.text == '嗯好的知道了');
  }

  // ===== 3. 假面层 =====
  stdout.writeln('\n【3. 假面层】');
  {
    final module = MaskModule();
    final result = await module.onUserMessage(_ctx(), '普通消息');
    _check('默认配置下运行不报错', result.text.isNotEmpty);
  }

  // ===== 4. 管线执行器 =====
  stdout.writeln('\n【4. 管线执行器】');
  {
    final registry = ModuleRegistry();
    registry.register(MoodModule());
    registry.register(BlocklistModule());
    final pipeline = PipelineRunner(registry: registry);

    final result = await pipeline.runOutgoing(
      userId: 'u1',
      characterId: 'c1',
      sessionId: 's1',
      text: '我今天超级开心哈哈',
    );
    _check(
      '多模块顺序执行',
      !result.blocked && result.executedModules >= 2,
      'executed=${result.executedModules}',
    );
    _check('收集情绪片段', result.hasFragments);

    final blocked = await pipeline.runOutgoing(
      userId: 'u1',
      characterId: 'c1',
      sessionId: 's1',
      text: '我手机号13812345678',
    );
    _check('禁区拦截立即停止', blocked.blocked && blocked.blockReason != null);
  }

  // 异常跳过
  {
    final registry = ModuleRegistry();
    registry.register(_CrashModule());
    registry.register(BlocklistModule());
    final pipeline = PipelineRunner(registry: registry);
    final result = await pipeline.runOutgoing(
      userId: 'u1',
      characterId: 'c1',
      sessionId: 's1',
      text: '正常消息',
    );
    _check(
      '异常模块被跳过，消息照常',
      !result.blocked && result.text == '正常消息' && result.failedModules == 1,
      'failed=${result.failedModules}',
    );
  }

  // ===== 5. Prompt 拼装器 =====
  stdout.writeln('\n【5. Prompt 拼装器】');
  {
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
    _check('片段按优先级排序', result.fragments.first.sourceId == 'test_high');
    _check('标注来源', result.text.contains('【高优先级】'));
    _check('内容完整', result.text.contains('高优先级内容'));

    PromptSourceRegistry.instance.unregister('test_low');
    PromptSourceRegistry.instance.unregister('test_high');

    // 禁用来源
    PromptSourceRegistry.instance.register(_TestSource(
      sourceId: 'test_disabled',
      sourceName: '禁用源',
      content: '不应出现',
      priority: 10,
      enabled: false,
    ));
    final disabledResult = await ButlerPromptBuilder.instance.build(
      context: _ctx(),
      input: '测试',
    );
    _check('禁用的来源被跳过', disabledResult.fragments.isEmpty);
    PromptSourceRegistry.instance.unregister('test_disabled');
  }

  // ===== 6. 模块注册 =====
  stdout.writeln('\n【6. 模块注册】');
  {
    final hub = ButlerModuleHub();
    _check('Hub 注册了 3 个模块', hub.count == 3, 'count=${hub.count}');
    _check('禁区模块在', hub.module<BlocklistModule>('blocklist') != null);
    _check('情绪模块在', hub.module<MoodModule>('mood') != null);
    _check('假面模块在', hub.module<MaskModule>('mask') != null);
  }

  // ===== 汇总 =====
  stdout.writeln('\n=== 结果：$_passed 通过，$_failed 失败 ===');
  exit(_failed == 0 ? 0 : 1);
}

ButlerContext _ctx() => ButlerContext(
  userId: 'u1',
  characterId: 'c1',
  sessionId: 's1',
);

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
