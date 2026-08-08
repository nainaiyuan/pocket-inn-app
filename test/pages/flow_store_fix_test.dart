import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pocket_inn/services/flow_store.dart';

/// 8-08 19:4x 回归测试：BUG-1/2/3/4 + paused_by_user 状态机。
/// 教训（18:55）：验证中心用例必须独立脚本实测过再提交。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pid = '__fix_verify__';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FlowStore.clear(pid);
  });

  test('BUG-1: next 最后一步自动收尾（status=done，不再卡 running）', () async {
    await FlowStore.create(pid, '收尾测试', [
      {'name': '步骤A', 'doneType': 'ai_output'},
      {'name': '步骤B', 'doneType': 'ai_output'},
    ]);
    await FlowStore.next(pid, result: 'A 的产出');
    expect(FlowStore.isRunning(pid), isTrue);
    await FlowStore.next(pid, result: 'B 的产出');
    final f = await FlowStore.get(pid);
    expect(f?['status'], 'done');
    expect(FlowStore.isRunning(pid), isFalse);
  });

  test('BUG-2: summary 完成态不再显示越界进度', () async {
    await FlowStore.create(pid, '收尾测试', [
      {'name': '步骤A', 'doneType': 'ai_output'},
      {'name': '步骤B', 'doneType': 'ai_output'},
    ]);
    await FlowStore.next(pid, result: 'A 的产出');
    await FlowStore.next(pid, result: 'B 的产出');
    final sm = FlowStore.summary(pid);
    expect(sm, isNotNull);
    expect(sm!.contains('已完成'), isTrue);
    expect(sm.contains('第 3/2 步'), isFalse);
  });

  test('BUG-3: update 后第 1 步状态重置为 running（直接改 f.steps）', () async {
    await FlowStore.create(pid, '旧流程', ['步骤A', '步骤B']);
    await FlowStore.next(pid, result: 'A'); // 走到第 2 步
    await FlowStore.update(pid, steps: ['步骤X', '步骤Y']);
    final f = await FlowStore.get(pid);
    final steps = (f?['steps'] as List?) ?? [];
    expect((steps[0] as Map)['status'], 'running');
    expect((steps[1] as Map)['status'], 'pending');
    expect(f?['currentStep'], 0);
  });

  test('BUG-4: done 后 update → 回 running（新任务能跑）', () async {
    await FlowStore.create(pid, '旧流程', [
      {'name': '步骤A', 'doneType': 'ai_output'},
    ]);
    await FlowStore.next(pid, result: 'A');
    expect((await FlowStore.get(pid))?['status'], 'done');
    await FlowStore.update(pid, goal: '新任务', steps: [
      {'name': '步骤C', 'doneType': 'ai_output'},
    ]);
    expect(FlowStore.isRunning(pid), isTrue);
    await FlowStore.next(pid, result: 'C');
    expect((await FlowStore.get(pid))?['status'], 'done');
  });

  test('paused_by_user 状态机：插话暂挂 → resume → cancel', () async {
    await FlowStore.create(pid, '测试流程', ['步骤A']);
    expect(FlowStore.isActive(pid), isTrue);
    // 插话暂挂
    final r1 = await FlowStore.pauseByUser(pid, userMessage: '插话测试');
    expect(r1.contains('已暂挂'), isTrue);
    var f = await FlowStore.get(pid);
    expect(f?['status'], 'paused_by_user');
    expect(FlowStore.isRunning(pid), isFalse);
    expect(FlowStore.isActive(pid), isTrue);
    // 重复暂挂 → 拒绝
    final r2 = await FlowStore.pauseByUser(pid);
    expect(r2.contains('不在执行中'), isTrue);
    // resume
    await FlowStore.resume(pid);
    expect(FlowStore.isRunning(pid), isTrue);
    // cancel
    await FlowStore.cancel(pid);
    expect(FlowStore.isActive(pid), isFalse);
    // cancelled 再 resume → 拒绝
    final r3 = await FlowStore.resume(pid);
    expect(r3.contains('不在暂停状态'), isTrue);
  });

  test('tool_result 步骤无工具时 next 被拒，且提示可改 ai_output', () async {
    await FlowStore.create(pid, '测试流程', ['步骤A']);
    final r = await FlowStore.next(pid, result: '没工具也提交');
    expect(r.contains('还没成功执行任何工具'), isTrue);
    expect(r.contains('ai_output'), isTrue); // 提示男主可改产出类型
  });
}
