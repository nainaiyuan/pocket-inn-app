/// 桌宠模块 — 总入口 PetWorld
///
/// 整合：场景（多小人） + 帧图来源 + 事件总线 + 投喂系统 + 持久化。
/// APP 只需要创建 PetWorld，然后：
/// - 创建小人：world.createPet(id: 'male_lead', name: '沈星回')
/// - 预载帧图：await world.preloadAll()
/// - 每帧推进：world.update(dt)
/// - 播放动作：world.playAction(petId, 'jump')
/// - 组合动作：world.runActivity(petId, 'greeting')
/// - 投喂：await world.feed(petId, 'fish')
/// - 订阅互动事件：world.events.stream.listen(...)  ← 男主"看得见"
library;

import 'dart:async';

import 'pet_engine.dart';
import 'pet_event_bus.dart';
import 'pet_feed.dart';
import 'pet_models.dart';
import 'pet_scene.dart';
import 'pet_store.dart';

class PetWorld {
  /// 当前桌宠页的实时世界（互动组配置页"试播"用；null = 桌宠页没开）
  static PetWorld? live;

  late final PetScene scene;
  final PetEventBus events;
  late final PetFeedSystem feedSystem;
  final PetStore store;

  PetWorld({
    PetStore? store,
    PetFrameSource? frames,
    PetEventBus? events,
  })  : store = store ?? PetStore(),
        events = events ?? PetEventBus() {
    scene = PetScene(frames: frames ?? _EmptyFrameSource());
    feedSystem = PetFeedSystem(
      scene: scene,
      events: this.events,
      store: this.store,
    );
    PetWorld.live = this;
  }

  /// 从持久化恢复：组合动作、用户自建动作、移动组
  Future<void> restore() async {
    final activities = await store.allActivities();
    for (final a in activities) {
      scene.saveActivity(a);
    }
    final actions = await store.allActions();
    for (final a in actions) {
      scene.registerAction(a);
    }
    final groups = await store.allMoveGroups();
    for (final g in groups) {
      scene.registerMoveGroup(g);
    }
  }

  /// 预载所有动作的帧图（扫描目录，自动数帧）
  Future<void> preloadAll() => scene.preloadAllFrames();

  Pet createPet({
    required String id,
    String? name,
    PetPoint? position,
    double scale = 1.0,
  }) {
    final pet = scene.createPet(
      id: id,
      name: name,
      position: position,
      scale: scale,
    );
    // 持久化档案（首次创建）
    unawaited(_ensureProfile(id, name ?? id, scale));
    return pet;
  }

  Future<void> _ensureProfile(String petId, String name, double scale) async {
    final existing = await store.getProfile(petId);
    if (existing == null) {
      await store.saveProfile(PetProfile(
        petId: petId,
        name: name,
        affection: 0,
        scale: scale,
      ));
    }
  }

  /// 所有小人档案（含 visible 标记）
  Future<List<PetProfile>> profiles() => store.allProfiles();

  /// 开关小人在陪伴页显示
  Future<void> setProfileVisible(String petId, bool visible) =>
      store.setProfileVisible(petId, visible);

  /// 按档案同步场景：visible 且不在场景 → 创建；隐藏的 → 移除。
  /// 首次使用（无档案）时自动创建默认男主小人。
  Future<void> syncVisible() async {
    var profiles = await store.allProfiles();
    if (profiles.isEmpty) {
      createPet(id: 'male_lead', name: '沈星回');
      return;
    }
    final wanted = profiles.where((p) => p.visible).toList();
    final wantedIds = wanted.map((p) => p.petId).toSet();
    // 移除被隐藏的小人
    for (final pet in scene.pets.toList()) {
      if (!wantedIds.contains(pet.id)) {
        scene.removePet(pet.id);
      }
    }
    // 创建新显示的小人
    for (final p in wanted) {
      if (scene.petById(p.petId) == null) {
        final pet = scene.createPet(
          id: p.petId,
          name: p.name,
          scale: p.scale,
          position: PetPoint(0.5, 0.6),
          area: p.area,
          fixedPosition: (p.fixedX != null && p.fixedY != null)
              ? PetPoint(p.fixedX!, p.fixedY!)
              : null,
        );
        pet.breakActionId = p.breakActionId;
      }
    }
    // 同步已有小人的打断动作配置 + 显示大小
    for (final p in wanted) {
      final existing = scene.petById(p.petId);
      existing?.breakActionId = p.breakActionId;
      existing?.scale = p.scale;
    }
    // 挂上说话回调（页面气泡）
    for (final pet in scene.pets) {
      pet.onSpeak ??= _defaultSpeak;
    }
  }

  void _defaultSpeak(String petId, String text) {
    // 默认无操作（UI 层会覆盖 onSpeak）
  }

  /// 每帧推进（UI 层在 ticker 里调用）
  void update(double dt) => scene.update(dt);

  void playAction(String petId, String actionId) =>
      scene.playAction(petId, actionId);

  /// 预设行为（爬屏幕 / 跳下来）
  void runBehavior(String petId, PetBehavior behavior) {
    final pet = scene.petById(petId);
    pet?.runBehavior(behavior);
  }

  /// 移动组
  void registerMoveGroup(PetMoveGroupDef def) =>
      scene.registerMoveGroup(def);
  Future<void> saveMoveGroup(PetMoveGroupDef def) async {
    scene.registerMoveGroup(def);
    await store.saveMoveGroup(def);
  }

  /// 更新小人活动区域并持久化
  Future<void> updatePetArea(
    String petId, {
    PetArea? area,
    double? fixedX,
    double? fixedY,
  }) async {
    await store.updateProfileArea(petId,
        area: area, fixedX: fixedX, fixedY: fixedY);
    final pet = scene.petById(petId);
    if (pet != null) {
      if (area != null) pet.area = area;
      if (fixedX != null && fixedY != null) {
        pet.fixedPosition = PetPoint(fixedX, fixedY);
      }
      if (pet.area == PetArea.fixed && pet.fixedPosition != null) {
        pet.position = pet.fixedPosition!;
      }
    }
  }

  /// 设置小人的"双人互动被打断后动作"并持久化
  Future<void> setBreakAction(String petId, String actionId) async {
    scene.setBreakAction(petId, actionId);
    await store.updateProfileBreakAction(petId, actionId);
  }

  /// 开始双人互动（两个小人贴在一起播双人帧组）
  bool startDuo(String petAId, String petBId, String duoActionId) =>
      scene.startDuo(petAId, petBId, duoActionId);

  /// 打断双人互动（拖走其中一个小人时调用）
  void breakDuo(String petId) => scene.breakDuo(petId);

  PetActivityRun? runActivity(String petId, String activityId) =>
      scene.runActivity(petId, activityId);

  void speak(String petId, String text) => scene.speak(petId, text);

  Future<PetFeedResult> feed(String petId, String itemId) =>
      feedSystem.feed(petId, itemId);

  void dispose() {
    if (PetWorld.live == this) PetWorld.live = null;
    events.dispose();
  }
}

/// 默认空帧源（APP 层会注入真实实现；测试/无图时引擎用占位帧兜底）
class _EmptyFrameSource implements PetFrameSource {
  @override
  Future<List<String>> framesFor(String actionId) async => const [];

  @override
  Future<bool> hasAction(String actionId) async => false;
}
