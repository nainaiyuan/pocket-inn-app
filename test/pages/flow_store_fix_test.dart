import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pocket_inn/models/chat_message.dart';
import 'package:pocket_inn/pages/chat/services/multi_bubble_parser.dart';
import 'package:pocket_inn/pages/chat/widgets/tool_group_card.dart';
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

  // ── 8-08 20:2x 工具卡聚合（GPT 定稿规则）──
  ChatMessage toolMsg(String text) =>
      ChatMessage(id: 't_$text', text: '[tool] $text', isMe: false);

  test('聚合：连续 tool 合并成 1 个卡', () {
    final out = groupToolMessages([
      toolMsg('正在查记忆…'),
      toolMsg('✅ 查到 3 条'),
      toolMsg('正在写便签…'),
    ]);
    expect(out.whereType<ToolGroupData>().length, 1);
    expect(out.whereType<ToolGroupData>().first.msgs.length, 3);
  });

  test('聚合：用户消息切断（不跨用户消息）', () {
    final out = groupToolMessages([
      toolMsg('正在查记忆…'),
      ChatMessage(id: 'u1', text: '用户插话', isMe: true),
      toolMsg('正在写便签…'),
    ]);
    expect(out.whereType<ToolGroupData>().length, 2);
  });

  test('聚合：act 动作气泡切断（不并入工具卡）', () {
    final out = groupToolMessages([
      toolMsg('正在查记忆…'),
      ChatMessage(id: 'a1', text: '[act] 他微微一笑', isMe: false),
      toolMsg('正在写便签…'),
    ]);
    expect(out.whereType<ToolGroupData>().length, 2);
  });

  test('聚合：男主文本回复切断', () {
    final out = groupToolMessages([
      ChatMessage(id: 'm1', text: '男主说话', isMe: false),
      toolMsg('正在查记忆…'),
      toolMsg('✅ 完成'),
    ]);
    expect(out.whereType<ToolGroupData>().length, 1);
    expect(out.whereType<ToolGroupData>().first.msgs.length, 2);
  });

  test('聚合：空列表 → 0', () {
    expect(groupToolMessages([]), isEmpty);
  });

  // ── 8-08 21:0x 旧数据自愈（用户：暂停的 5/4、停止条不收回去）──
  // 老版本（≤70f52c3）next() 最后一步只 currentStep=len 不设 done →
  // running + cur>=len 残留 → 读进来必须自愈成 done
  Map<String, dynamic> oldFlow({required int cur, required String status}) => {
        'goal': '旧流程',
        'currentStep': cur,
        'status': status,
        'steps': [
          {'name': 'A', 'status': 'done'},
          {'name': 'B', 'status': 'done'},
        ],
      };

  test('自愈：旧数据 running+cur==len → 读成 done', () async {
    SharedPreferences.setMockInitialValues({
      'flow___heal1__': jsonEncode(oldFlow(cur: 2, status: 'running')),
    });
    final f = await FlowStore.get('__heal1__');
    expect(f?['status'], 'done');
    expect(FlowStore.isRunning('__heal1__'), isFalse);
  });

  test('自愈：paused_by_user+cur==len → 读成 done（暂停也收尾）', () async {
    SharedPreferences.setMockInitialValues({
      'flow___heal2__': jsonEncode(oldFlow(cur: 2, status: 'paused_by_user')),
    });
    final f = await FlowStore.get('__heal2__');
    expect(f?['status'], 'done');
  });

  test('自愈：cancelled+cur==len → 保持 cancelled（取消是终态）', () async {
    SharedPreferences.setMockInitialValues({
      'flow___heal3__': jsonEncode(oldFlow(cur: 2, status: 'cancelled')),
    });
    final f = await FlowStore.get('__heal3__');
    expect(f?['status'], 'cancelled');
  });

  test('自愈：cur>len 越界 → 修正为 len + done', () async {
    SharedPreferences.setMockInitialValues({
      'flow___heal4__': jsonEncode(oldFlow(cur: 5, status: 'running')),
    });
    final f = await FlowStore.get('__heal4__');
    expect(f?['currentStep'], 2);
    expect(f?['status'], 'done');
  });

  // ── 8-08 21:3x 文本化工具调用泄漏（用户：男主气泡"工具:xxx关键词=yyy"）──
  test('剥工具行：纯工具调用行 → 空', () {
    expect(stripToolTextLines('工具:query_tool_formats关键词=notify_user'), '');
    expect(
      stripToolTextLines('工具：query_tool_formats 关键词：notify_user'),
      '',
    );
  });

  test('剥工具行：混合文本只剥工具行', () {
    expect(
      stripToolTextLines('好的，马上\n工具:query_tool_formats关键词=countdown_card'),
      '好的，马上',
    );
  });

  test('剥工具行：不误伤正常文本', () {
    expect(stripToolTextLines('这个工具:xxx 很好用'), '这个工具:xxx 很好用');
    expect(stripToolTextLines('她说工具:锤子 敲一下'), '她说工具:锤子 敲一下');
  });
}
