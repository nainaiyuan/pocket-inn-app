import 'pet_models.dart';
import 'pet_scene.dart' show Pet, PetArea;

/// 8-14 23:2x（GPT 19 条设计 §6/§14/§15）：
/// 统一位置/事件判定——阈值集中一处，防重复触发。
/// 输入：当前位置/活动区域/速度/用户操作；输出：(stateId, source)。
class PetStateResult {
  final String stateId;
  final String source; // auto / user
  const PetStateResult(this.stateId, this.source);
}

class PetStateDetector {
  /// 距边界多远算"贴边"（屏幕百分比，改阈值只改这里）
  static const double edgeThreshold = 0.05;

  /// 松手速度超过它 = "扔"（屏幕/秒）
  static const double throwSpeedThreshold = 0.8;

  String? _prevStateId;
  String? _prevSource;

  void reset() {
    _prevStateId = null;
    _prevSource = null;
  }

  /// 位置 → 持续状态（贴边/居中/角落），来源 auto/user
  PetStateResult detectPosition(Pet pet, {String source = 'auto'}) {
    final p = pet.position;
    final (minX, maxX, minY, maxY) = switch (pet.area) {
      PetArea.full => (0.02, 0.98, 0.02, 0.98),
      PetArea.bottom => (0.02, 0.98, 0.55, 0.95),
      PetArea.fixed => (0.02, 0.98, p.y, p.y),
    };
    final atLeft = p.x <= minX + edgeThreshold;
    final atRight = p.x >= maxX - edgeThreshold;
    final atTop = p.y <= minY + edgeThreshold;
    final atBottom = p.y >= maxY - edgeThreshold;
    final String state;
    if (atLeft && atTop || atRight && atTop) {
      state = PetStateIds.edgeTop; // 角落优先归"顶"
    } else if (atLeft && atBottom || atRight && atBottom) {
      state = PetStateIds.edgeBottom;
    } else if (atLeft) {
      state = PetStateIds.edgeLeft;
    } else if (atRight) {
      state = PetStateIds.edgeRight;
    } else if (atTop) {
      state = PetStateIds.edgeTop;
    } else if (atBottom) {
      state = PetStateIds.edgeBottom;
    } else {
      state = PetStateIds.center;
    }
    return PetStateResult(state, source);
  }

  /// 是否"进入"该状态（previous != current 才 true，防每帧重复触发）
  bool isEntered(PetStateResult r) {
    final changed = r.stateId != _prevStateId || r.source != _prevSource;
    _prevStateId = r.stateId;
    _prevSource = r.source;
    return changed;
  }
}
