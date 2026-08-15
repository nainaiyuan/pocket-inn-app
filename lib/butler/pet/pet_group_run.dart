/// 桌宠模块 — 互动组运行时（纯 Dart，可单测）
///
/// 驱动一组演员按剧本一步步演：
/// - 每步开始：给每个坑播它动作库里的动作 + 按移动类型算目标点并 moveTo
/// - 每步时长：自动取各坑动作时长最大值（最少 2.5s），或用手动时长
/// - 帧/移动的逐帧推进仍由各 Pet 自己的 update() 完成，这里只管编排和计时
///
/// 8-15 底层引擎 v2 新增（全部配置驱动，无配置 = 行为与 v1 完全一致）：
/// - 编队移动（PetGroupStep.formationLeaderId）：带头坑走，其他 stay 坑
///   保持相对偏移跟随（每帧追 leader 当前位置 + 开演时记录的偏移）
/// - 待机行为（PetGroupSlot.idleActionId）：坑这步没动作也没移动时，
///   循环播配置的待机动作（代替干站着）
/// - 提起反应（PetGroupSlot.heldReactionActionId）：组里有人被用户提起，
///   其他坑播配置的反应动作（一次触发，不每帧重复）
/// - 摆放行为（PetGroupSlot.placedActionId）：坑被用户放下（held 变 false）
///   时播配置的动作
library;

import 'dart:math' as math;

import 'pet_models.dart';

/// 互动组演员接口：由 Pet（pet_scene.dart）实现。
///
/// 抽接口是为了让运行时层不依赖 Flutter（pet_scene.dart 引了 debug_logger，
/// 纯 Dart 单测进不去），互动组逻辑因此可以脱离 UI 验证。
abstract class PetActor {
  String get id;
  bool get held;
  PetControlOwner get controlOwner;
  PetPoint get position;
  String? get currentActionId;
  set currentActionId(String? v);
  void stopMoving();
  void moveTo(PetPoint target, {double duration});
  void playAction(PetActionDef def, List<String> frames, {int? repeat});
  void stop();
  PetPoint clampToArea(PetPoint p);
}

/// 互动组运行时数据（def + 各坑动作库 + 帧），由 UI 层从数据库加载后注入场景
class PetGroupRuntime {
  final PetGroupDef def;
  final Map<String, PetActionDef> slotActions;
  final Map<String, List<String>> slotFrames;

  PetGroupRuntime({
    required this.def,
    required this.slotActions,
    required this.slotFrames,
  });
}

class PetGroupRun {
  final PetGroupDef def;
  final List<PetActor> cast;

  /// 与 cast 一一对应的坑
  final List<PetGroupSlot> slots;

  final PetActionDef? Function(String actionId) actionResolver;
  final List<String> Function(String actionId) framesResolver;

  int _stepIndex = 0;
  double _stepElapsed = 0;
  double _stepDuration = 2.5;
  bool _stepStarted = false;
  bool _finished = false;
  bool _paused = false;

  // v2 编队：本步带头坑 id + 各成员相对带头坑的初始偏移
  String? _formationLeaderId;
  final Map<String, PetPoint> _formationOffsets = {};

  // v2 提起反应：已触发过的成员（放下后重置，可再触发）
  final Set<String> _heldFired = {};

  // v2 摆放：上一帧 held 的成员（held true→false 转变时触发）
  final Set<String> _wasHeld = {};

  PetGroupRun({
    required this.def,
    required this.cast,
    required this.slots,
    required this.actionResolver,
    required this.framesResolver,
  });

  bool get finished => _finished;
  int get stepIndex => _stepIndex;

  /// 剧本进度 0~1
  double get progress =>
      def.steps.isEmpty ? 1 : _stepIndex / def.steps.length;

  PetGroupStep? get currentStep =>
      _stepIndex < def.steps.length ? def.steps[_stepIndex] : null;

  /// 暂停（提起来）：停掉各小人的移动，步骤计时冻结；放下后 resume 续播
  void pause() {
    if (_paused || _finished) return;
    _paused = true;
    for (final pet in cast) {
      pet.stopMoving();
    }
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
  }

  /// 场景每帧调用（先让各 Pet 自己 update，再推进编排计时）
  void update(double dt) {
    if (_finished || _paused) return;
    if (_stepIndex >= def.steps.length) {
      _finished = true;
      return;
    }
    final step = def.steps[_stepIndex];
    if (!_stepStarted) {
      _startStep(step);
      _stepStarted = true;
    }
    // v2：编队跟随 + 提起反应 + 摆放行为（每帧检测，转变才触发）
    _tickFormation(step);
    _tickHeldReactions();
    _tickPlaced();
    _stepElapsed += dt;
    if (_stepElapsed >= _stepDuration) {
      _advanceStep();
    }
  }

  void _startStep(PetGroupStep step) {
    // 步时长：手动优先；否则取各坑动作时长最大值，最少 2.5s
    _stepDuration = step.duration ?? 2.5;
    for (final slotStep in step.slotSteps) {
      final idx = _indexOfSlot(slotStep.slotId);
      if (idx < 0 || idx >= cast.length) continue;
      // 被用户抓住的演员跳过（互动组其他人照常演）
      if (cast[idx].held || cast[idx].controlOwner == PetControlOwner.user) {
        continue;
      }
      final def = slotStep.actionId != null
          ? actionResolver(slotStep.actionId!)
          : null;
      if (def != null && slotStep.actionId != null) {
        final d = def.durationSeconds > 0 ? def.durationSeconds : 2.5;
        if (step.duration == null && d > _stepDuration) _stepDuration = d;
      }
    }
    if (_stepDuration < 2.5) _stepDuration = 2.5;

    // v2 编队准备：记带头坑 + 各 stay 坑相对偏移（开演瞬间快照）
    _formationOffsets.clear();
    _formationLeaderId = step.formationLeaderId;
    if (_formationLeaderId != null) {
      final leaderIdx = _indexOfSlot(_formationLeaderId!);
      if (leaderIdx >= 0 &&
          leaderIdx < cast.length &&
          !cast[leaderIdx].held &&
          cast[leaderIdx].controlOwner != PetControlOwner.user) {
        final leaderPos = cast[leaderIdx].position;
        for (final slotStep in step.slotSteps) {
          if (slotStep.slotId == _formationLeaderId) continue;
          if (slotStep.moveType != PetGroupMoveType.stay) continue;
          final idx = _indexOfSlot(slotStep.slotId);
          if (idx < 0 || idx >= cast.length) continue;
          _formationOffsets[slotStep.slotId] = PetPoint(
            cast[idx].position.x - leaderPos.x,
            cast[idx].position.y - leaderPos.y,
          );
        }
      } else {
        // 带头坑不可用（被抓住）：本步退化为普通步
        _formationLeaderId = null;
      }
    }

    // 各坑开演
    for (final slotStep in step.slotSteps) {
      final idx = _indexOfSlot(slotStep.slotId);
      if (idx < 0 || idx >= cast.length) continue;
      final pet = cast[idx];
      // 被用户抓住的演员跳过本步（松手后下步自动恢复）
      if (pet.held || pet.controlOwner == PetControlOwner.user) {
        continue;
      }
      final def = slotStep.actionId != null
          ? actionResolver(slotStep.actionId!)
          : null;
      // 动作：有动作就播（循环帧播满整步）；没有 → v2 待机行为
      if (def != null && slotStep.actionId != null) {
        pet.playAction(def, framesResolver(slotStep.actionId!));
      } else if (slotStep.moveType == PetGroupMoveType.stay) {
        final idleId = _slotOf(idx)?.idleActionId;
        if (idleId != null) {
          final idleDef = actionResolver(idleId);
          if (idleDef != null) {
            pet.playAction(idleDef, framesResolver(idleId));
          }
        }
      }
      // v2 编队：stay 成员不单独移动，跟随由 _tickFormation 每帧处理
      if (_formationLeaderId != null &&
          slotStep.moveType == PetGroupMoveType.stay) {
        continue;
      }
      // 移动
      final duration = _stepDuration;
      switch (slotStep.moveType) {
        case PetGroupMoveType.stay:
          break;
        case PetGroupMoveType.dir:
          final (vx, vy) =
              (slotStep.moveDir ?? PetMoveDir.left).vector;
          final dist = slotStep.moveDist ?? 0.3;
          pet.moveTo(
            pet.clampToArea(PetPoint(
              pet.position.x + vx * dist,
              pet.position.y + vy * dist,
            )),
            duration: duration,
          );
        case PetGroupMoveType.spot:
          pet.moveTo(
            pet.clampToArea(PetPoint(
              slotStep.targetX ?? 0.5,
              slotStep.targetY ?? 0.5,
            )),
            duration: duration,
          );
        case PetGroupMoveType.approach:
          final partner = _partnerOf(idx);
          if (partner != null) {
            pet.moveTo(
              _approachTarget(pet.position, partner.position,
                  slotStep.moveDist ?? 0.05),
              duration: duration,
            );
          }
        case PetGroupMoveType.leave:
          final partner = _partnerOf(idx);
          if (partner != null) {
            pet.moveTo(
              _leaveTarget(pet.position, partner.position,
                  slotStep.moveDist ?? 0.3),
              duration: duration,
            );
          }
        case PetGroupMoveType.wall:
          final (vx, vy) =
              (slotStep.moveDir ?? PetMoveDir.left).vector;
          pet.moveTo(
            pet.clampToArea(PetPoint(
              pet.position.x + vx * 2,
              pet.position.y + vy * 2,
            )),
            duration: duration,
          );
      }
    }
  }

  /// v2 编队跟随：每帧把 stay 成员的目标点设为 leader 当前位置 + 初始偏移
  void _tickFormation(PetGroupStep step) {
    final leaderId = _formationLeaderId;
    if (leaderId == null || _formationOffsets.isEmpty) return;
    final leaderIdx = _indexOfSlot(leaderId);
    if (leaderIdx < 0 || leaderIdx >= cast.length) return;
    final leader = cast[leaderIdx];
    if (leader.held || leader.controlOwner == PetControlOwner.user) return;
    for (final entry in _formationOffsets.entries) {
      final idx = _indexOfSlot(entry.key);
      if (idx < 0 || idx >= cast.length) continue;
      final pet = cast[idx];
      if (pet.held || pet.controlOwner == PetControlOwner.user) continue;
      pet.moveTo(
        pet.clampToArea(PetPoint(
          leader.position.x + entry.value.x,
          leader.position.y + entry.value.y,
        )),
        duration: 0.15,
      );
    }
  }

  /// v2 提起反应：谁被提起（held 刚变 true）→ 其他坑播 heldReactionActionId
  void _tickHeldReactions() {
    for (var i = 0; i < cast.length; i++) {
      final pet = cast[i];
      if (pet.held && !_heldFired.contains(pet.id)) {
        _heldFired.add(pet.id);
        for (var j = 0; j < cast.length; j++) {
          if (j == i) continue;
          final rid = _slotOf(j)?.heldReactionActionId;
          if (rid == null) continue;
          final def = actionResolver(rid);
          if (def != null) {
            cast[j].playAction(def, framesResolver(rid));
          }
        }
      } else if (!pet.held) {
        _heldFired.remove(pet.id);
      }
    }
  }

  /// v2 摆放行为：成员 held true→false（放下）→ 自己播 placedActionId
  void _tickPlaced() {
    for (var i = 0; i < cast.length; i++) {
      final pet = cast[i];
      if (_wasHeld.contains(pet.id) && !pet.held) {
        _wasHeld.remove(pet.id);
        final pid = _slotOf(i)?.placedActionId;
        if (pid != null) {
          final def = actionResolver(pid);
          if (def != null) {
            pet.playAction(def, framesResolver(pid));
          }
        }
      } else if (pet.held) {
        _wasHeld.add(pet.id);
      }
    }
  }

  int _indexOfSlot(String slotId) {
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].slotId == slotId) return i;
    }
    return -1;
  }

  PetGroupSlot? _slotOf(int idx) =>
      idx >= 0 && idx < slots.length ? slots[idx] : null;

  /// 搭档：两人组 = 对方；多人组 = 下一个坑（循环）
  PetActor? _partnerOf(int idx) {
    if (cast.length < 2) return null;
    return cast[(idx + 1) % cast.length];
  }

  /// 靠近：朝对方走到间隔 [gap]（默认 0.05 = 挨着）
  PetPoint _approachTarget(PetPoint me, PetPoint other, double gap) {
    final dx = other.x - me.x;
    final dy = other.y - me.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return other;
    return PetPoint(
      (other.x - dx / len * gap).clamp(0.02, 0.98),
      (other.y - dy / len * gap).clamp(0.02, 0.98),
    );
  }

  /// 离开：往反方向拉开 [dist]
  PetPoint _leaveTarget(PetPoint me, PetPoint other, double dist) {
    final dx = me.x - other.x;
    final dy = me.y - other.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) {
      return PetPoint(
        (me.x + 0.2).clamp(0.02, 0.98),
        (me.y + 0.2).clamp(0.02, 0.98),
      );
    }
    return PetPoint(
      (me.x + dx / len * dist).clamp(0.02, 0.98),
      (me.y + dy / len * dist).clamp(0.02, 0.98),
    );
  }

  void _advanceStep() {
    _stepIndex++;
    _stepElapsed = 0;
    _stepStarted = false;
    _formationOffsets.clear();
    _formationLeaderId = null;
    if (_stepIndex >= def.steps.length) {
      _finished = true;
      // 散场：各小人回待机（留在当前位置）
      for (final pet in cast) {
        pet.stop();
      }
    }
  }
}
