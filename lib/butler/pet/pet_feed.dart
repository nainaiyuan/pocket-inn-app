/// 桌宠模块 — 投喂系统
///
/// 内置食物库 + 好感度（本地存储，男主可知）。
/// 投喂 = 好感度增加 + 进食动作 + 互动事件。
library;

import 'pet_event_bus.dart';
import 'pet_models.dart';
import 'pet_scene.dart';

/// 投喂结果
class PetFeedResult {
  final bool success;
  final String petId;
  final String? itemId;
  final int affectionBefore;
  final int affectionAfter;

  const PetFeedResult({
    required this.success,
    required this.petId,
    this.itemId,
    this.affectionBefore = 0,
    this.affectionAfter = 0,
  });

  int get delta => affectionAfter - affectionBefore;
}

/// 好感度存储抽象（Flutter 用 sqflite，测试用内存）
abstract class PetAffectionStore {
  Future<int> getAffection(String petId);

  /// 返回增加后的新值
  Future<int> addAffection(String petId, int delta);
}

/// 投喂系统
class PetFeedSystem {
  final PetScene scene;
  final PetEventBus events;
  final PetAffectionStore store;

  PetFeedSystem({
    required this.scene,
    required this.events,
    required this.store,
  });

  /// 投喂：返回结果，失败时 success=false
  Future<PetFeedResult> feed(String petId, String itemId) async {
    final pet = scene.petById(petId);
    final item = PetBuiltinFoods.byId(itemId);
    if (pet == null || item == null) {
      return PetFeedResult(success: false, petId: petId, itemId: itemId);
    }

    final before = await store.getAffection(petId);
    final after = await store.addAffection(petId, item.value);

    // 进食动作：优先 happy（开心），否则转圈
    final happy = scene.actionDefs['happy'];
    if (happy != null && happy.hasFrames) {
      scene.playAction(petId, 'happy');
    } else {
      scene.playAction(petId, 'spin');
    }

    // 触发互动事件（男主感知）
    events.emit(PetInteractionEvent(
      type: PetInteractionType.feed,
      petId: petId,
      intensity: 0.8,
      feedItemId: itemId,
      affectionDelta: item.value,
    ));

    return PetFeedResult(
      success: true,
      petId: petId,
      itemId: itemId,
      affectionBefore: before,
      affectionAfter: after,
    );
  }

  /// 好感度等级（0~100+，人话描述，男主可引用）
  static String affectionLevel(int value) {
    if (value <= 0) return '陌生';
    if (value < 10) return '初识';
    if (value < 30) return '熟悉';
    if (value < 60) return '亲近';
    if (value < 100) return '信赖';
    return '羁绊';
  }
}
