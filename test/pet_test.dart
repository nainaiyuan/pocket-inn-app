/// 桌宠模块测试 — 纯逻辑，不依赖 Flutter/SQLite
///
/// 跑法：cd flutter_app && dart test test/pet_test.dart
///
/// 覆盖：
/// 1. 帧播放器（循环/单次/来回/重复次数）
/// 2. 命名位置坐标
/// 3. 场景：多小人共存、动作播放、移动插值、转头往回走
/// 4. 组合动作（顺序执行、说话步骤、完成后回待机）
/// 5. 互动事件总线（男主"看得见"）
/// 6. 投喂 + 好感度（内存存储）
/// 7. 组合动作 JSON 序列化往返

import 'package:test/test.dart';

import 'package:pocket_inn/butler/pet/pet_engine.dart';
import 'package:pocket_inn/butler/pet/pet_event_bus.dart';
import 'package:pocket_inn/butler/pet/pet_feed.dart';
import 'package:pocket_inn/butler/pet/pet_models.dart';
import 'package:pocket_inn/butler/pet/pet_scene.dart';

/// 内存帧源（模拟用户放了一摞图）
class _MemoryFrameSource implements PetFrameSource {
  final Map<String, List<String>> frames;

  _MemoryFrameSource(this.frames);

  @override
  Future<List<String>> framesFor(String actionId) async =>
      frames[actionId] ?? const [];

  @override
  Future<bool> hasAction(String actionId) async =>
      frames.containsKey(actionId);
}

/// 内存好感度存储
class _MemoryAffectionStore implements PetAffectionStore {
  final Map<String, int> _values = {};

  @override
  Future<int> getAffection(String petId) async => _values[petId] ?? 0;

  @override
  Future<int> addAffection(String petId, int delta) async {
    _values[petId] = (_values[petId] ?? 0) + delta;
    return _values[petId]!;
  }
}

void main() {
  group('帧播放器', () {
    test('loop 模式循环播放', () {
      final player = PetAnimPlayer(
        frames: ['a', 'b', 'c'],
        fps: 10,
        loop: PetAnimLoop.loop,
      );
      expect(player.currentFrame, 'a');
      player.update(0.1); // 1 帧
      expect(player.currentFrame, 'b');
      player.update(0.1);
      expect(player.currentFrame, 'c');
      player.update(0.1);
      expect(player.currentFrame, 'a'); // 循环回来
      expect(player.finished, isFalse);
    });

    test('once 模式播完即止', () {
      final player = PetAnimPlayer(
        frames: ['a', 'b', 'c'],
        fps: 10,
        loop: PetAnimLoop.once,
      );
      player.update(0.1);
      player.update(0.1);
      player.update(0.1);
      expect(player.currentFrame, 'c');
      expect(player.finished, isTrue);
    });

    test('pingpong 模式来回播放', () {
      final player = PetAnimPlayer(
        frames: ['a', 'b', 'c'],
        fps: 10,
        loop: PetAnimLoop.pingpong,
      );
      player.update(0.1);
      expect(player.currentFrame, 'b');
      player.update(0.1);
      expect(player.currentFrame, 'c');
      player.update(0.1);
      expect(player.currentFrame, 'b'); // 往回
      player.update(0.1);
      expect(player.currentFrame, 'a');
    });

    test('maxLoops 限制循环次数后 finished', () {
      final player = PetAnimPlayer(
        frames: ['a', 'b'],
        fps: 10,
        loop: PetAnimLoop.loop,
        maxLoops: 2,
      );
      // 2 帧 × 2 圈 = 4 次推进
      for (var i = 0; i < 4; i++) {
        player.update(0.1);
      }
      expect(player.finished, isTrue);
    });

    test('空帧列表不崩溃', () {
      final player = PetAnimPlayer(frames: [], fps: 10);
      player.update(1.0);
      expect(player.currentFrame, isNull);
      expect(player.finished, isFalse);
    });
  });

  group('命名位置', () {
    test('center 是屏幕中间', () {
      expect(PetSpot.center.x(), 0.5);
      expect(PetSpot.center.y(), 0.5);
    });
    test('leftThird 是 1/3 处', () {
      expect(PetSpot.leftThird.x(), closeTo(1 / 3, 0.001));
      expect(PetSpot.leftThird.y(), 0.5);
    });
    test('rightThird 是 2/3 处', () {
      expect(PetSpot.rightThird.x(), closeTo(2 / 3, 0.001));
    });
    test('PetPoint 插值', () {
      final p = const PetPoint(0, 0).lerp(const PetPoint(1, 0), 0.5);
      expect(p.x, 0.5);
      expect(p.y, 0);
    });
  });

  group('场景与小人', () {
    late PetScene scene;

    setUp(() {
      scene = PetScene(
        frames: _MemoryFrameSource({
          'idle': ['f_idle_1', 'f_idle_2', 'f_idle_3', 'f_idle_4'],
          'walk': ['f_walk_1', 'f_walk_2', 'f_walk_3', 'f_walk_4', 'f_walk_5', 'f_walk_6'],
          'jump': ['f_jump_1', 'f_jump_2', 'f_jump_3', 'f_jump_4', 'f_jump_5', 'f_jump_6'],
        }),
      );
    });

    test('内置动作模板齐全', () {
      expect(PetBuiltinActions.all.length, greaterThanOrEqualTo(8));
      expect(PetBuiltinActions.byId('walk'), isNotNull);
      expect(PetBuiltinActions.byId('spin'), isNotNull);
    });

    test('创建两个小人互不干扰', () {
      final a = scene.createPet(id: 'male_lead', name: '沈星回');
      final b = scene.createPet(id: 'user_pet', name: '用户小人');
      expect(scene.pets.length, 2);
      expect(scene.petById('male_lead'), same(a));
      expect(scene.petById('user_pet'), same(b));

      a.moveTo(const PetPoint(0.9, 0.5), duration: 2);
      scene.update(0.1);
      expect(a.position.x, greaterThan(0.5));
      expect(b.position.x, 0.5); // b 没动
    });

    test('移动插值到达目标并自动转向', () {
      final pet = scene.createPet(id: 'p1');
      pet.moveTo(const PetPoint(0.9, 0.5), duration: 1);
      // 走完全程
      for (var i = 0; i < 20; i++) {
        scene.update(0.1);
      }
      expect(pet.position.x, closeTo(0.9, 0.01));
      expect(pet.position.y, closeTo(0.5, 0.01));
      expect(pet.facing, PetFacing.right); // 向右走 → 朝右
      expect(pet.moving, isFalse);
    });

    test('向左走自动朝左', () {
      final pet = scene.createPet(id: 'p2', position: const PetPoint(0.8, 0.5));
      pet.moveTo(const PetPoint(0.2, 0.5), duration: 1);
      for (var i = 0; i < 20; i++) {
        scene.update(0.1);
      }
      expect(pet.facing, PetFacing.left);
    });

    test('转头往回走：先到目标再回原点', () {
      final pet = scene.createPet(id: 'p3', position: const PetPoint(0.2, 0.5));
      pet.moveTo(const PetPoint(0.8, 0.5), duration: 1, turnBack: true);
      // 走完去程 + 回程
      for (var i = 0; i < 40; i++) {
        scene.update(0.1);
      }
      expect(pet.position.x, closeTo(0.2, 0.01)); // 回到原点
      expect(pet.moving, isFalse);
    });

    test('播放动作后帧推进', () async {
      final pet = scene.createPet(id: 'p4');
      await scene.preloadFrames('jump'); // APP 启动时 preloadAll 等效
      scene.playAction('p4', 'jump');
      expect(pet.state, PetState.acting);
      expect(pet.currentFrame, 'f_jump_1');
      scene.update(0.1);
      expect(pet.currentFrame, 'f_jump_2');
    });

    test('preloadFrames 自动数帧', () async {
      await scene.preloadFrames('walk');
      final def = scene.actionDefs['walk']!;
      expect(def.hasFrames, isTrue);
      expect(def.frameCount, 6);
    });

    test('无图时用占位帧兜底不崩溃', () {
      final pet = scene.createPet(id: 'p5');
      scene.playAction('p5', 'spin'); // spin 没有真实帧
      expect(pet.currentFrame, startsWith('placeholder:spin'));
      scene.update(0.1); // 不崩溃
    });
  });

  group('组合动作', () {
    late PetScene scene;

    setUp(() {
      scene = PetScene(
        frames: _MemoryFrameSource({
          'walk': List.generate(6, (i) => 'w$i'),
          'jump': List.generate(6, (i) => 'j$i'),
          'spin': List.generate(8, (i) => 's$i'),
        }),
      );
      scene.createPet(id: 'p1');
    });

    test('顺序执行：说话 → 动作 → 移动', () {
      final spoken = <String>[];
      scene.petById('p1')!.onSpeak = (_, text) => spoken.add(text);

      scene.saveActivity(PetActivityDef(
        id: 'greeting',
        name: '打招呼',
        steps: [
          const PetActivityStep(actionId: 'speak', text: '你好呀'),
          const PetActivityStep(actionId: 'jump'),
          PetActivityStep(
            actionId: 'moveTo',
            targetSpot: PetSpot.center,
            durationSec: 1,
          ),
        ],
      ));

      final run = scene.runActivity('p1', 'greeting');
      expect(run, isNotNull);
      expect(scene.petById('p1')!.state, PetState.activity);

      // 说话立即触发
      expect(spoken, ['你好呀']);

      // 跳（6 帧 @12fps = 0.5s）
      for (var i = 0; i < 8; i++) {
        scene.update(0.1);
      }
      // 移动 1 秒
      for (var i = 0; i < 12; i++) {
        scene.update(0.1);
      }
      expect(scene.petById('p1')!.state, PetState.idle); // 完成后回待机
      expect(scene.petById('p1')!.position.x, closeTo(0.5, 0.01));
    });

    test('repeat 重复播放后进入下一步', () {
      scene.saveActivity(PetActivityDef(
        id: 'spin2',
        name: '转两圈',
        steps: [
          const PetActivityStep(actionId: 'spin', repeat: 2),
          const PetActivityStep(actionId: 'speak', text: '转完啦'),
        ],
      ));
      final spoken = <String>[];
      scene.petById('p1')!.onSpeak = (_, text) => spoken.add(text);

      scene.runActivity('p1', 'spin2');
      // spin 8 帧 @15fps，2 圈 = 16 帧 ≈ 1.07s
      for (var i = 0; i < 30; i++) {
        scene.update(0.1);
      }
      expect(spoken, ['转完啦']);
      expect(scene.petById('p1')!.state, PetState.idle);
    });

    test('活动步骤 JSON 序列化往返', () {
      final def = PetActivityDef(
        id: 'x',
        name: '测试',
        steps: [
          const PetActivityStep(
            actionId: 'moveTo',
            targetSpot: PetSpot.leftThird,
            durationSec: 2.5,
            turnBack: true,
          ),
          const PetActivityStep(actionId: 'speak', text: '嗨'),
        ],
      );
      final restored = PetActivityDef.fromJson(def.toJson());
      expect(restored.id, 'x');
      expect(restored.steps.length, 2);
      expect(restored.steps[0].targetSpot, PetSpot.leftThird);
      expect(restored.steps[0].durationSec, 2.5);
      expect(restored.steps[0].turnBack, isTrue);
      expect(restored.steps[1].text, '嗨');
    });
  });

  group('互动事件总线', () {
    test('事件发出并可订阅', () {
      final bus = PetEventBus();
      final received = <PetInteractionEvent>[];
      final sub = bus.stream.listen(received.add);

      bus.emit(PetInteractionEvent(
        type: PetInteractionType.tap,
        petId: 'male_lead',
        intensity: 0.3,
      ));
      bus.emit(PetInteractionEvent(
        type: PetInteractionType.feed,
        petId: 'male_lead',
        feedItemId: 'fish',
        affectionDelta: 2,
      ));

      expect(received.length, 2);
      expect(received[0].type, PetInteractionType.tap);
      expect(received[1].affectionDelta, 2);
      expect(bus.recent.length, 2);
      expect(bus.recentSummary(), contains('投喂'));

      sub.cancel();
      bus.dispose();
    });

    test('事件摘要包含关键信息', () {
      final bus = PetEventBus();
      bus.emit(PetInteractionEvent(
        type: PetInteractionType.pet,
        petId: 'user_pet',
        intensity: 0.9,
      ));
      final summary = bus.recentSummary();
      expect(summary, contains('抚摸'));
      expect(summary, contains('user_pet'));
    });
  });

  group('投喂与好感度', () {
    test('投喂增加好感度并发出事件', () async {
      final store = _MemoryAffectionStore();
      final events = PetEventBus();
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.createPet(id: 'p1');

      final feed = PetFeedSystem(scene: scene, events: events, store: store);
      final result = await feed.feed('p1', 'fish');

      expect(result.success, isTrue);
      expect(result.affectionBefore, 0);
      expect(result.affectionAfter, 2);
      expect(events.recent.last.type, PetInteractionType.feed);
      expect(events.recent.last.affectionDelta, 2);
    });

    test('投喂不存在的小人或食物返回失败', () async {
      final store = _MemoryAffectionStore();
      final events = PetEventBus();
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.createPet(id: 'p1');

      final feed = PetFeedSystem(scene: scene, events: events, store: store);
      final badPet = await feed.feed('ghost', 'fish');
      expect(badPet.success, isFalse);
      final badFood = await feed.feed('p1', 'dragon');
      expect(badFood.success, isFalse);
    });

    test('好感度等级描述', () {
      expect(PetFeedSystem.affectionLevel(0), '陌生');
      expect(PetFeedSystem.affectionLevel(5), '初识');
      expect(PetFeedSystem.affectionLevel(50), '亲近');
      expect(PetFeedSystem.affectionLevel(120), '羁绊');
    });
  });

  group('占位帧', () {
    test('占位帧标识解析', () {
      final parsed = PetPlaceholderFrames.parse('placeholder:jump:2:6');
      expect(parsed, isNotNull);
      expect(parsed!.$1, 'jump');
      expect(parsed.$2, 2);
      expect(parsed.$3, 6);
    });

    test('弹跳曲线两端为 0', () {
      expect(PetPlaceholderFrames.bounce(0, 6), closeTo(0, 0.001));
      expect(PetPlaceholderFrames.bounce(5, 6), closeTo(0, 0.001));
      expect(PetPlaceholderFrames.bounce(3, 6), greaterThan(0.5));
    });
  });

  group('移动组（走+跑绑定）', () {
    test('慢速移动用走路动画', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final walk = scene.resolveMoveAnim(null, 0.2);
      expect(walk.id, 'walk');
    });

    test('快速移动用跑步动画', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final run = scene.resolveMoveAnim(null, 0.9);
      expect(run.id, 'run');
    });

    test('自定义移动组只有走时永远用走', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.registerMoveGroup(const PetMoveGroupDef(
        id: 'g1',
        name: '慢走组',
        walkActionId: 'walk',
      ));
      expect(scene.resolveMoveAnim('g1', 2.0).id, 'walk');
    });

    test('移动组持久化恢复', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.registerMoveGroup(const PetMoveGroupDef(
        id: 'g2',
        name: '快跑组',
        walkActionId: 'walk',
        runActionId: 'run',
      ));
      final restored = PetMoveGroupDef.fromJson(
          scene.moveGroups['g2']!.toJson());
      expect(restored.id, 'g2');
      expect(restored.runActionId, 'run');
    });
  });

  group('活动区域', () {
    test('bottom 区域：目标被约束在下半屏', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(id: 'p1', name: '底区小人');
      pet.area = PetArea.bottom;
      pet.moveTo(const PetPoint(0.5, 0.1)); // 想跑到屏幕上方
      pet.update(10); // 走完
      expect(pet.position.y, greaterThanOrEqualTo(0.55));
    });

    test('fixed 区域：不移动', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(
        id: 'p1',
        name: '固定小人',
        area: PetArea.fixed,
        fixedPosition: const PetPoint(0.3, 0.7),
      );
      expect(pet.position.x, closeTo(0.3, 0.001));
      pet.moveTo(const PetPoint(0.9, 0.2));
      pet.update(10);
      expect(pet.position.x, closeTo(0.3, 0.001));
      expect(pet.position.y, closeTo(0.7, 0.001));
    });

    test('拖动也受区域约束', () {
      final pet = Pet(
        id: 'p1',
        name: 'x',
        position: const PetPoint(0.5, 0.8),
      );
      pet.area = PetArea.bottom;
      final clamped = pet.clampToArea(const PetPoint(0.5, 0.05));
      expect(clamped.y, greaterThanOrEqualTo(0.55));
    });
  });

  group('预设行为', () {
    test('爬屏幕：爬到顶部附近', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.7));
      pet.runBehavior(PetBehavior.climb);
      expect(pet.moving, isTrue);
      pet.update(3);
      expect(pet.position.y, lessThan(0.15));
      expect(pet.state, PetState.idle);
    });

    test('跳下来：先跳出屏幕外再回原位', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.6));
      pet.runBehavior(PetBehavior.jumpOff);
      // 中途：y 应该先向上跳（抛物线顶点）
      pet.update(0.3);
      expect(pet.position.y, lessThan(0.6));
      // 小步推进走完全程（含转头回来）
      for (var i = 0; i < 40; i++) {
        pet.update(0.1);
      }
      expect(pet.state, PetState.idle);
      expect(pet.position.y, greaterThan(0.5));
    });

    test('场景 playAction 支持行为动作', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.7));
      scene.playAction('p1', 'climb');
      expect(pet.moving, isTrue);
    });
  });

  group('速度档', () {
    test('慢速档帧率更低', () {
      final def = PetActionDef(
        id: 'a1',
        name: '慢动作',
        fps: 10,
        speedTier: PetSpeedTier.slow,
      );
      expect(def.fps * def.speedTier.factor, closeTo(6, 0.001));
    });

    test('快速档帧率更高', () {
      final def = PetActionDef(
        id: 'a2',
        name: '快动作',
        fps: 10,
        speedTier: PetSpeedTier.fast,
      );
      expect(def.fps * def.speedTier.factor, closeTo(16, 0.001));
    });
  });

  group('双人互动', () {
    test('两个小人贴在一起同步播双人帧组', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final a = scene.createPet(id: 'a', name: 'A', position: const PetPoint(0.4, 0.6));
      final b = scene.createPet(id: 'b', name: 'B', position: const PetPoint(0.7, 0.6));
      scene.registerAction(PetActionDef(
        id: 'hug',
        name: '拥抱',
        kind: PetActionKind.duo,
        fps: 10,
        loop: PetAnimLoop.loop,
        durationSeconds: 3,
      ));
      final ok = scene.startDuo('a', 'b', 'hug');
      expect(ok, isTrue);
      expect(a.inDuo, isTrue);
      expect(b.inDuo, isTrue);
      // b 被贴到 a 旁边
      expect((a.position.x - b.position.x).abs(), lessThan(0.15));
      expect((a.position.y - b.position.y).abs(), lessThan(0.01));
      // 双人帧组共享主导者帧
      expect(a.currentFrame, b.currentFrame);
      // 互动中 busy
      expect(a.busy, isTrue);
      expect(b.busy, isTrue);
      // 到时自动分开（loop 播 3 秒）
      for (var i = 0; i < 200; i++) {
        scene.update(0.02);
      }
      expect(a.inDuo, isFalse);
      expect(b.inDuo, isFalse);
    });

    test('打断后留下的一方播放 breakActionId', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final a = scene.createPet(id: 'a', name: 'A', position: const PetPoint(0.4, 0.6));
      final b = scene.createPet(id: 'b', name: 'B', position: const PetPoint(0.7, 0.6));
      a.breakActionId = 'sad';
      scene.registerAction(PetActionDef(
        id: 'sad',
        name: '难过',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'sad',
      ));
      scene.registerAction(PetActionDef(
        id: 'hug',
        name: '拥抱',
        kind: PetActionKind.duo,
        fps: 10,
        loop: PetAnimLoop.loop,
        durationSeconds: 99,
      ));
      scene.startDuo('a', 'b', 'hug');
      // 用户拖走 b → 打断 → 留下的 a 播 a 配置的难过动作
      scene.breakDuo('b');
      expect(a.inDuo, isFalse);
      expect(b.inDuo, isFalse);
      expect(a.currentActionId, 'sad');
    });

    test('playAction duo 自动找伙伴互动', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.createPet(id: 'a', name: 'A', position: const PetPoint(0.4, 0.6));
      scene.createPet(id: 'b', name: 'B', position: const PetPoint(0.7, 0.6));
      scene.registerAction(PetActionDef(
        id: 'kiss',
        name: '亲亲',
        kind: PetActionKind.duo,
        fps: 10,
        loop: PetAnimLoop.once,
        durationSeconds: 1,
      ));
      scene.playAction('a', 'kiss');
      expect(scene.petById('a')!.inDuo, isTrue);
      expect(scene.petById('b')!.inDuo, isTrue);
    });
  });

  group('方向移动步骤', () {
    test('组合动作里向左走几秒（撞边自动停）', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.5));
      scene.registerAction(PetActionDef(
        id: 'idle',
        name: '待机',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'idle',
      ));
      scene.saveActivity(PetActivityDef(
        id: 'left_walk',
        name: '向左走',
        steps: [
          PetActivityStep(
              actionId: 'idle', moveDir: PetMoveDir.left, moveSec: 1),
        ],
      ));
      scene.runActivity('p1', 'left_walk');
      for (var i = 0; i < 150; i++) {
        scene.update(0.02);
      }
      expect(pet.position.x, lessThan(0.5));
      // 撞边不会出屏幕
      expect(pet.position.x, greaterThanOrEqualTo(0.0));
      expect(pet.position.x, lessThanOrEqualTo(1.0));
    });

    test('向下走 y 增大且不出屏', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.3));
      scene.registerAction(PetActionDef(
        id: 'idle',
        name: '待机',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'idle',
      ));
      scene.saveActivity(PetActivityDef(
        id: 'down_walk',
        name: '向下走',
        steps: [
          PetActivityStep(
              actionId: 'idle', moveDir: PetMoveDir.down, moveSec: 2),
        ],
      ));
      scene.runActivity('p1', 'down_walk');
      for (var i = 0; i < 300; i++) {
        scene.update(0.02);
      }
      expect(pet.position.y, greaterThan(0.3));
      expect(pet.position.y, lessThanOrEqualTo(1.0));
    });
  });

  group('自动过渡', () {
    test('动作切换时透明度从 0 淡入', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(id: 'p1', name: 'x');
      scene.registerAction(PetActionDef(
        id: 'jump',
        name: '跳',
        fps: 12,
        loop: PetAnimLoop.once,
        frameDir: 'jump',
      ));
      scene.playAction('p1', 'jump');
      expect(pet.transitionOpacity, lessThan(1.0));
      // 0.15 秒后淡入完成
      for (var i = 0; i < 20; i++) {
        scene.update(0.01);
      }
      expect(pet.transitionOpacity, 1.0);
    });
  });

  group('方向移动 8向与撞墙', () {
    PetScene _sceneWithIdle() {
      final s = PetScene(frames: _MemoryFrameSource({}));
      s.registerAction(PetActionDef(
        id: 'idle',
        name: '待机',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'idle',
      ));
      return s;
    }

    test('右上斜向移动：x 增大 y 减小', () {
      final scene = _sceneWithIdle();
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.4, 0.6));
      scene.saveActivity(PetActivityDef(
        id: 'up_right',
        name: '右上走',
        steps: [
          PetActivityStep(
              actionId: 'idle',
              moveDir: PetMoveDir.upRight,
              moveSec: 1),
        ],
      ));
      scene.runActivity('p1', 'up_right');
      for (var i = 0; i < 150; i++) {
        scene.update(0.02);
      }
      expect(pet.position.x, greaterThan(0.4));
      expect(pet.position.y, lessThan(0.6));
    });

    test('撞墙模式：一直向左走到屏幕边停下', () {
      final scene = _sceneWithIdle();
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.5));
      scene.saveActivity(PetActivityDef(
        id: 'to_wall',
        name: '走到撞墙',
        steps: [
          PetActivityStep(
              actionId: 'idle',
              moveDir: PetMoveDir.left,
              moveUntilWall: true),
        ],
      ));
      scene.runActivity('p1', 'to_wall');
      // 走足够久（远大于固定秒数模式）
      for (var i = 0; i < 1000; i++) {
        scene.update(0.02);
      }
      // 停在屏幕左边，没跑出去
      expect(pet.position.x, lessThan(0.1));
      expect(pet.position.x, greaterThanOrEqualTo(0.0));
      // 撞墙后步骤结束，小人回待机（活动完成）
      expect(pet.activity, isNull);
    });

    test('撞墙模式：一直向右走到屏幕右边', () {
      final scene = _sceneWithIdle();
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.3, 0.5));
      scene.saveActivity(PetActivityDef(
        id: 'to_wall_r',
        name: '走到右墙',
        steps: [
          PetActivityStep(
              actionId: 'idle',
              moveDir: PetMoveDir.right,
              moveUntilWall: true),
        ],
      ));
      scene.runActivity('p1', 'to_wall_r');
      for (var i = 0; i < 1000; i++) {
        scene.update(0.02);
      }
      expect(pet.position.x, greaterThan(0.9));
      expect(pet.position.x, lessThanOrEqualTo(1.0));
    });

    test('爬屏幕按距离算时长：从底部爬到顶刚好停', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.8));
      scene.playAction('p1', 'climb');
      // 速度 0.35/s，距离 0.74 → 约 2.1 秒
      for (var i = 0; i < 300; i++) {
        scene.update(0.02);
      }
      expect(pet.position.y, lessThan(0.1));
      expect(pet.position.y, greaterThanOrEqualTo(0.0));
      expect(pet.moving, isFalse);
    });
  });
  group('目标点步骤（指哪走哪）', () {
    PetScene _sceneWithIdle() {
      final s = PetScene(frames: _MemoryFrameSource({}));
      s.registerAction(PetActionDef(
        id: 'idle',
        name: '待机',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'idle',
      ));
      s.registerAction(PetActionDef(
        id: 'jump',
        name: '跳',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'jump',
      ));
      return s;
    }

    test('跳到中间：播跳帧同时移动到目标点，到点后待机', () {
      final scene = _sceneWithIdle();
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.2, 0.7));
      scene.saveActivity(PetActivityDef(
        id: 'jump_mid',
        name: '跳到中间',
        steps: [
          PetActivityStep(
              actionId: 'jump',
              targetX: 0.5,
              targetY: 0.5,
              trajectory: PetMoveTrajectory.jump),
        ],
      ));
      scene.runActivity('p1', 'jump_mid');
      for (var i = 0; i < 300; i++) {
        scene.update(0.02);
      }
      // 到达中间附近（速度 0.55/s，距离约 0.58 → 约 1 秒）
      expect((pet.position.x - 0.5).abs(), lessThan(0.05));
      expect((pet.position.y - 0.5).abs(), lessThan(0.05));
      expect(pet.moving, isFalse);
      expect(pet.activity, isNull);
    });

    test('目标越界：自动截断到屏幕边，不会跑出去，然后进下一步', () {
      final scene = _sceneWithIdle();
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.5));
      scene.saveActivity(PetActivityDef(
        id: 'off_screen',
        name: '跳出屏幕',
        steps: [
          PetActivityStep(
              actionId: 'idle',
              targetX: 1.8,
              targetY: -0.5,
              trajectory: PetMoveTrajectory.jump),
          PetActivityStep(
              actionId: 'idle',
              targetX: 0.5,
              targetY: 0.5,
              trajectory: PetMoveTrajectory.walk),
        ],
      ));
      scene.runActivity('p1', 'off_screen');
      for (var i = 0; i < 600; i++) {
        scene.update(0.02);
      }
      // 截断到右上角边界内，然后走回中间
      expect(pet.position.x, lessThanOrEqualTo(1.0));
      expect(pet.position.y, greaterThanOrEqualTo(0.0));
      expect((pet.position.x - 0.5).abs(), lessThan(0.05));
      expect((pet.position.y - 0.5).abs(), lessThan(0.05));
    });

    test('飞过去：平滑曲线到达目标', () {
      final scene = _sceneWithIdle();
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.1, 0.9));
      scene.saveActivity(PetActivityDef(
        id: 'fly_up',
        name: '飞到左上',
        steps: [
          PetActivityStep(
              actionId: 'idle',
              targetX: 0.15,
              targetY: 0.1,
              trajectory: PetMoveTrajectory.fly),
        ],
      ));
      scene.runActivity('p1', 'fly_up');
      for (var i = 0; i < 300; i++) {
        scene.update(0.02);
      }
      expect((pet.position.x - 0.15).abs(), lessThan(0.05));
      expect((pet.position.y - 0.1).abs(), lessThan(0.05));
      expect(pet.moving, isFalse);
    });
  });
  group('动作自带位移（导入时配的"播的时候怎么动"）', () {
    test('playAction 原地动作带目标：边播帧边移动，到点停', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.registerAction(PetActionDef(
        id: 'jump_to_mid',
        name: '跳到中间',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'jump_to_mid',
        targetX: 0.5,
        targetY: 0.5,
        trajectory: PetMoveTrajectory.jump,
      ));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.15, 0.8));
      scene.playAction('p1', 'jump_to_mid');
      for (var i = 0; i < 300; i++) {
        scene.update(0.02);
      }
      expect((pet.position.x - 0.5).abs(), lessThan(0.05));
      expect((pet.position.y - 0.5).abs(), lessThan(0.05));
      expect(pet.moving, isFalse);
    });

    test('组合动作里用带位移的动作：移动完才进下一步', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.registerAction(PetActionDef(
        id: 'to_left_edge',
        name: '跑到左边',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'to_left_edge',
        targetX: 0.02,
        targetY: 0.5,
      ));
      scene.registerAction(PetActionDef(
        id: 'idle',
        name: '待机',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'idle',
      ));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.8, 0.5));
      scene.saveActivity(PetActivityDef(
        id: 'run_then_idle',
        name: '跑过去再待机',
        steps: [
          PetActivityStep(actionId: 'to_left_edge'),
          PetActivityStep(actionId: 'idle', durationSec: 0.3),
        ],
      ));
      scene.runActivity('p1', 'run_then_idle');
      for (var i = 0; i < 400; i++) {
        scene.update(0.02);
      }
      // 先到左边，再播待机，活动结束
      expect(pet.position.x, lessThan(0.1));
      expect(pet.activity, isNull);
    });
  });
  group('方向+距离相对位移（导入时配置）', () {
    test('playAction 带 moveDir+moveDist：从聊天框基准朝方向走固定距离', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.registerAction(PetActionDef(
        id: 'hop_left',
        name: '向左跳',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'hop_left',
        moveDir: PetMoveDir.left,
        moveDist: 0.3,
        trajectory: PetMoveTrajectory.jump,
        moveRef: PetMoveRef.dock,
      ));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.5));
      scene.playAction('p1', 'hop_left');
      for (var i = 0; i < 300; i++) {
        scene.update(0.02);
      }
      // 聊天框基准 (0.5, 0.85) 往左 0.3 → (0.2, 0.85)
      expect((pet.position.x - 0.2).abs(), lessThan(0.05));
      expect((pet.position.y - 0.85).abs(), lessThan(0.05));
      expect(pet.moving, isFalse);
    });

    test('playAction 带 moveDir+moveDist：从屏幕中间基准朝方向走固定距离', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.registerAction(PetActionDef(
        id: 'hop_up',
        name: '向上跳',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'hop_up',
        moveDir: PetMoveDir.up,
        moveDist: 0.3,
        trajectory: PetMoveTrajectory.jump,
        moveRef: PetMoveRef.center,
      ));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.5, 0.8));
      scene.playAction('p1', 'hop_up');
      for (var i = 0; i < 300; i++) {
        scene.update(0.02);
      }
      // 屏幕中间 (0.5, 0.5) 往上 0.3 → (0.5, 0.2)
      expect((pet.position.x - 0.5).abs(), lessThan(0.05));
      expect((pet.position.y - 0.2).abs(), lessThan(0.05));
      expect(pet.moving, isFalse);
    });

    test('moveDist 超出屏幕自动截断（不会跑出去）', () {
      final scene = PetScene(frames: _MemoryFrameSource({}));
      scene.registerAction(PetActionDef(
        id: 'run_right',
        name: '向右跑',
        fps: 8,
        loop: PetAnimLoop.loop,
        frameDir: 'run_right',
        moveDir: PetMoveDir.right,
        moveDist: 2.0, // 远超屏幕
      ));
      final pet = scene.createPet(
          id: 'p1', name: 'x', position: const PetPoint(0.4, 0.5));
      scene.playAction('p1', 'run_right');
      for (var i = 0; i < 400; i++) {
        scene.update(0.02);
      }
      expect(pet.position.x, lessThanOrEqualTo(0.98));
      expect(pet.moving, isFalse);
    });
  });
}
