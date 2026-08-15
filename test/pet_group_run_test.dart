/// 互动组运行时测试 — 纯 Dart，不依赖 Flutter/SQLite
///
/// 跑法：cd flutter_app && dart test test/pet_group_run_test.dart
///
/// 覆盖（8-15 底层引擎 v2）：
/// 1. 编队移动：带头坑走，stay 坑保持相对偏移跟随
/// 2. 待机行为：坑没任务时播 idleActionId
/// 3. 提起反应：有人被提起 → 其他坑播 heldReactionActionId（不重复触发）
/// 4. 摆放行为：坑被放下 → 播 placedActionId
/// 5. 无配置 = 老行为（零回归）
/// 6. 编队退化：带头坑被抓住 → 退化为普通步
/// 7. 剧本散场 → 全员 stop()
/// 8. 新字段 JSON 序列化往返
library;

import 'package:test/test.dart';

import 'package:pocket_inn/butler/pet/pet_group_run.dart';
import 'package:pocket_inn/butler/pet/pet_models.dart';

/// 内存演员（Pet 的替身，只记录调用）
class _FakeActor implements PetActor {
  @override
  final String id;
  @override
  bool held = false;
  @override
  PetControlOwner controlOwner = PetControlOwner.auto;
  @override
  PetPoint position;
  @override
  String? currentActionId;
  final List<String> playedActions = [];
  final List<PetPoint> moveTargets = [];
  int stopCount = 0;

  _FakeActor(this.id, this.position);

  @override
  void stopMoving() {}

  @override
  void moveTo(PetPoint target, {double duration = 1}) {
    moveTargets.add(target);
    position = target; // 简化：立即到位
  }

  @override
  void playAction(PetActionDef def, List<String> frames, {int? repeat}) {
    playedActions.add(def.id);
  }

  @override
  void stop() {
    stopCount++;
    currentActionId = null;
  }

  @override
  PetPoint clampToArea(PetPoint p) => p;
}

PetActionDef _def(String id) =>
    PetActionDef(id: id, name: id, durationSeconds: 3);

List<String> _frames(String id) => ['$id-1', '$id-2'];

/// 组一个两人互动组：A 左 B 右
({PetGroupRun run, _FakeActor a, _FakeActor b}) _twoPerson({
  PetGroupSlot? slotA,
  PetGroupSlot? slotB,
  List<PetGroupStep> steps = const [],
}) {
  final a = _FakeActor('a', const PetPoint(0.4, 0.6));
  final b = _FakeActor('b', const PetPoint(0.7, 0.6));
  final def = PetGroupDef(
    id: 'g1',
    name: '测试组',
    slots: [
      slotA ?? const PetGroupSlot(slotId: 'sA', index: 0),
      slotB ?? const PetGroupSlot(slotId: 'sB', index: 1),
    ],
    steps: steps,
    updatedAt: '',
  );
  final run = PetGroupRun(
    def: def,
    cast: [a, b],
    slots: def.slots,
    actionResolver: _def,
    framesResolver: _frames,
  );
  return (run: run, a: a, b: b);
}

void main() {
  group('编队移动', () {
    test('带头坑走，stay 坑保持相对偏移跟随', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep(
            [
              const PetSlotStep(
                  slotId: 'sA',
                  moveType: PetGroupMoveType.dir,
                  moveDir: PetMoveDir.left,
                  moveDist: 0.2),
              const PetSlotStep(slotId: 'sB'),
            ],
            formationLeaderId: 'sA',
          ),
        ],
      );
      t.run.update(0.016);
      // A: dir left 0.2 → (0.4-0.2, 0.6) = (0.2, 0.6)
      expect(t.a.position, const PetPoint(0.2, 0.6));
      // B: 跟随 A + 初始偏移 (0.3, 0) → (0.5, 0.6)
      expect(t.b.moveTargets, isNotEmpty);
      final last = t.b.moveTargets.last;
      expect(last.x, closeTo(0.5, 1e-6));
      expect(last.y, closeTo(0.6, 1e-6));
    });

    test('带头坑被抓住 → 退化为普通步（不跟随）', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep(
            [
              const PetSlotStep(
                  slotId: 'sA',
                  moveType: PetGroupMoveType.dir,
                  moveDir: PetMoveDir.left,
                  moveDist: 0.2),
              const PetSlotStep(slotId: 'sB'),
            ],
            formationLeaderId: 'sA',
          ),
        ],
      );
      t.a.held = true; // 带头被用户抓住
      t.run.update(0.016);
      expect(t.b.moveTargets, isEmpty); // B 不跟随
    });
  });

  group('待机行为', () {
    test('坑没任务且 stay → 播 idleActionId', () {
      final t = _twoPerson(
        slotB: const PetGroupSlot(
            slotId: 'sB', index: 1, idleActionId: 'idleWave'),
        steps: [
          PetGroupStep([
            const PetSlotStep(
                slotId: 'sA',
                moveType: PetGroupMoveType.dir,
                moveDir: PetMoveDir.left,
                moveDist: 0.2),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.run.update(0.016);
      expect(t.b.playedActions, contains('idleWave'));
    });

    test('没配 idleActionId → 不播（老行为）', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep([
            const PetSlotStep(
                slotId: 'sA',
                moveType: PetGroupMoveType.dir,
                moveDir: PetMoveDir.left,
                moveDist: 0.2),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.run.update(0.016);
      expect(t.b.playedActions, isEmpty);
    });
  });

  group('提起反应', () {
    test('A 被提起 → B 播 heldReactionActionId', () {
      final t = _twoPerson(
        slotB: const PetGroupSlot(
            slotId: 'sB', index: 1, heldReactionActionId: 'surprised'),
        steps: [
          PetGroupStep([
            const PetSlotStep(slotId: 'sA'),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.run.update(0.016);
      expect(t.b.playedActions, isEmpty); // 还没人提起
      t.a.held = true;
      t.run.update(0.016);
      expect(t.b.playedActions, contains('surprised'));
      // 持续提着不重复触发
      final count = t.b.playedActions.length;
      t.run.update(0.016);
      t.run.update(0.016);
      expect(t.b.playedActions.length, count);
      // 放下再提起 → 可再触发
      t.a.held = false;
      t.run.update(0.016);
      t.a.held = true;
      t.run.update(0.016);
      expect(t.b.playedActions.length, count + 1);
    });

    test('没配 heldReactionActionId → 无反应', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep([
            const PetSlotStep(slotId: 'sA'),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.a.held = true;
      t.run.update(0.016);
      expect(t.b.playedActions, isEmpty);
    });
  });

  group('摆放行为', () {
    test('A 被放下（held true→false）→ A 播 placedActionId', () {
      final t = _twoPerson(
        slotA: const PetGroupSlot(
            slotId: 'sA', index: 0, placedActionId: 'spin'),
        steps: [
          PetGroupStep([
            const PetSlotStep(slotId: 'sA'),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.run.update(0.016);
      expect(t.a.playedActions, isEmpty);
      t.a.held = true;
      t.run.update(0.016);
      expect(t.a.playedActions, isEmpty); // 提着不播
      t.a.held = false;
      t.run.update(0.016);
      expect(t.a.playedActions, contains('spin'));
    });

    test('没配 placedActionId → 放下无动作', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep([
            const PetSlotStep(slotId: 'sA'),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.a.held = true;
      t.run.update(0.016);
      t.a.held = false;
      t.run.update(0.016);
      expect(t.a.playedActions, isEmpty);
    });
  });

  group('剧本生命周期', () {
    test('无配置 = 老行为（stay 不移动不播动作）', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep([
            const PetSlotStep(slotId: 'sA'),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.run.update(0.016);
      expect(t.a.moveTargets, isEmpty);
      expect(t.b.moveTargets, isEmpty);
      expect(t.a.playedActions, isEmpty);
      expect(t.b.playedActions, isEmpty);
    });

    test('一步剧本播完 → 散场全员 stop()', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep([
            const PetSlotStep(slotId: 'sA'),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      // 时长 2.5s 起，逐步推进
      for (var i = 0; i < 400; i++) {
        t.run.update(0.016);
      }
      expect(t.run.finished, isTrue);
      expect(t.a.stopCount, 1);
      expect(t.b.stopCount, 1);
    });

    test('暂停冻结计时，恢复续播', () {
      final t = _twoPerson(
        steps: [
          PetGroupStep([
            const PetSlotStep(slotId: 'sA'),
            const PetSlotStep(slotId: 'sB'),
          ]),
        ],
      );
      t.run.update(0.016);
      t.run.pause();
      for (var i = 0; i < 300; i++) {
        t.run.update(0.016);
      }
      expect(t.run.finished, isFalse); // 暂停中不推进
      t.run.resume();
      for (var i = 0; i < 400; i++) {
        t.run.update(0.016);
      }
      expect(t.run.finished, isTrue);
    });
  });

  group('JSON 序列化', () {
    test('v2 新字段往返', () {
      final slot = PetGroupSlot(
        slotId: 'sA',
        index: 0,
        idleActionId: 'idleWave',
        heldReactionActionId: 'surprised',
        placedActionId: 'spin',
      );
      final slot2 = PetGroupSlot.fromJson(slot.toJson());
      expect(slot2.idleActionId, 'idleWave');
      expect(slot2.heldReactionActionId, 'surprised');
      expect(slot2.placedActionId, 'spin');

      final step = PetGroupStep(
        [
          const PetSlotStep(
              slotId: 'sA',
              moveType: PetGroupMoveType.dir,
              moveDir: PetMoveDir.left,
              moveDist: 0.2),
        ],
        formationLeaderId: 'sA',
      );
      final step2 = PetGroupStep.fromJson(step.toJson());
      expect(step2.formationLeaderId, 'sA');
    });

    test('老数据无新字段 → 默认 null（向后兼容）', () {
      final slot = PetGroupSlot.fromJson({'s': 'sA', 'i': 0});
      expect(slot.idleActionId, isNull);
      expect(slot.heldReactionActionId, isNull);
      expect(slot.placedActionId, isNull);

      final step = PetGroupStep.fromJson({
        'slots': [
          {'s': 'sA'}
        ],
      });
      expect(step.formationLeaderId, isNull);
    });
  });
}
