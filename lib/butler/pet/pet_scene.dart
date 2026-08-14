/// 桌宠模块 — 场景层（Pet 单实例 + PetScene 多小人世界）
///
/// - [Pet]：一个小人实例。位置、朝向、当前动作、移动、说话，独立状态机
/// - [PetScene]：一个屏幕空间，多个小人共存，共享帧图来源和事件总线
///
/// 从第一天就是多实例设计：男主小人、用户小人同屏互动，各自独立又互相可见。
library;

import 'dart:async';
import 'dart:math' as math;

import '../../utils/debug_logger.dart';
import 'pet_engine.dart';
import 'pet_state_detector.dart';
import 'pet_models.dart';

/// 小人状态
enum PetState {
  /// 待机（无动作，播放待机动画）
  idle,

  /// 正在播放原地动作
  acting,

  /// 正在移动
  moving,

  /// 正在执行组合动作
  activity,

  /// 正在说话（气泡显示中，动作可继续）
  speaking,
}

/// 单个小人实例
class Pet {
  final String id;
  String name;

  /// 8-14 22:2x（GPT 方案：桌宠是连续存在的实体）：
  /// 运行时位置缓存（App 进程级静态）——页面重建/restore 后恢复
  /// 当前位置，不再瞬移回 preferredStart（preferredStart 只是
  /// "首次出现位置"，不是"每次刷新位置"）。App 重启才回起点。
  static final Map<String, PetPoint> lastPositions = {};

  /// 相对坐标（0~1）；setter 同步进静态缓存
  PetPoint _position;
  PetPoint get position => _position;
  set position(PetPoint v) {
    _position = v;
    lastPositions[id] = v;
  }

  // ===== 8-14 23:2x 控制权 + 状态系统（GPT 19 条 v1.2） =====

  /// 控制权：auto / user（用户操作）/ interaction（互动组）/ response（状态响应）
  PetControlOwner controlOwner = PetControlOwner.auto;

  /// 被用户按住（held 状态，拖动中）
  bool held = false;

  /// 暂停的移动快照（用户抓住时暂停，响应结束可恢复——不销毁）
  PetMoveState? suspendedMove;

  /// 状态检测器（per-pet，previous != current 防重复触发）
  PetStateDetector detector = PetStateDetector();

  /// 被扔时的飞行距离（屏幕百分比，来自角色配置）
  double throwDistance = 0.5;

  /// 朝向（影响镜像）
  PetFacing facing;

  /// 显示大小
  double scale;

  /// 当前状态
  PetState state = PetState.idle;

  /// 当前帧动画播放器
  PetAnimPlayer? _player;

  /// 当前移动状态
  PetMoveState? _move;

  /// 当前组合动作运行器（由场景注入逻辑）
  PetActivityRun? _activity;

  /// 当前动作 id（null = 待机）
  String? currentActionId;

  /// 说话回调（UI 层设置：显示气泡）
  void Function(String petId, String text)? onSpeak;

  /// 动作完成回调（活动执行器/UI 监听）
  void Function(String petId, String actionId)? onActionDone;

  /// 活动区域（满屏 / 输入框上方 / 固定位置）
  PetArea area = PetArea.full;

  /// area == fixed 时的固定坐标（相对 0~1）
  PetPoint? fixedPosition;

  /// 双人互动被打断后播放的动作 id（默认待机，UI 可配置为"难过"等）
  String breakActionId = 'idle';

  /// 双人互动：互动对象
  Pet? _pair;

  double _pairElapsed = 0;
  double _pairDuration = 0;

  /// 自动过渡透明度 0~1：动作切换时 0.15s 内从 0 淡入，衔接不突兀
  double _transition = 1.0;

  /// 渲染透明度系数（UI 层乘到 opacity 上）
  double get transitionOpacity => _transition;

  /// 是否正在双人互动
  bool get inDuo => _pair != null;

  /// 互动对象
  Pet? get pair => _pair;

  Pet({
    required this.id,
    required this.name,
    PetPoint? position,
    this.facing = PetFacing.right,
    this.scale = 1.0,
    this.avatarPath,
  }) : _position = position ?? const PetPoint(0.5, 0.5);

  /// 8-14 17:4x（用户：我的小人是你小人复制的，一模一样）：
  /// 角色头像——没配动作帧时 idle 显示自己的头像，
  /// 不再所有新角色都撞脸默认小人
  String? avatarPath;

  /// 按活动区域约束坐标
  PetPoint clampToArea(PetPoint p) {
    switch (area) {
      case PetArea.fixed:
        return fixedPosition ?? p;
      case PetArea.bottom:
        // 只在输入框上方区域（屏幕下半部）
        return PetPoint(
          p.x.clamp(0.02, 0.98),
          p.y.clamp(0.55, 0.95),
        );
      case PetArea.full:
        return PetPoint(
          p.x.clamp(0.02, 0.98),
          p.y.clamp(0.05, 0.95),
        );
    }
  }

  /// 当前要渲染的帧（null = 无帧可显示）
  String? get currentFrame {
    if (_player != null) return _player!.currentFrame;
    // 双人互动：共享主导者的帧（图里画了两个小人，两边显示同一帧）
    if (_pair != null && _pair!._player != null) {
      return _pair!._player!.currentFrame;
    }
    return null;
  }

  /// 是否正在移动
  bool get moving => _move != null && !_move!.finished;

  /// 立即停下当前移动
  void stopMoving() => _move = null;

  /// 是否忙（有动作/移动/组合动作/双人互动在跑）
  bool get busy =>
      _pair != null ||
      _activity != null ||
      moving ||
      (_player != null && !_player!.finished);

  /// 帧动画播放器（只读）
  PetAnimPlayer? get player => _player;

  /// 移动状态（只读）
  PetMoveState? get move => _move;

  /// 组合动作运行器（只读）
  PetActivityRun? get activity => _activity;

  /// 帧推进
  void update(double dt) {
    // 双人互动优先：共享帧推进 + 计时
    if (_pair != null) {
      _updatePair(dt);
      return;
    }

    // 组合动作优先驱动（活动执行器内部会调用 tickMove/tickAnim）
    if (_activity != null) {
      _activity!.update(dt, this);
      if (_activity!.finished) {
        _activity = null;
        _enterIdle();
      }
      _tickTransition(dt);
      return;
    }

    tickMove(dt);
    tickAnim(dt);
    _tickTransition(dt);
  }

  /// 双人互动推进（主导者驱动共享帧，双方各自计时）
  void _updatePair(double dt) {
    _pairElapsed += dt;
    if (_player != null) {
      _player!.update(dt);
    }
    _tickTransition(dt);
    // 用户设置的互动时长到点即分开（帧循环只影响画面循环，不影响时长）
    if (_pairDuration > 0 && _pairElapsed >= _pairDuration) {
      _endPair();
    }
  }

  /// 结束双人互动（双方解除，回待机）
  void _endPair() {
    if (_pair == null) return;
    final partner = _pair;
    _pair = null;
    if (partner != null && partner._pair == this) {
      partner._pair = null;
      partner._enterIdle();
    }
    _enterIdle();
  }

  /// 自动过渡：透明度 0.15s 淡入
  void _tickTransition(double dt) {
    if (_transition < 1) {
      _transition = math.min(1, _transition + dt / 0.15);
    }
  }

  void _startTransition() {
    _transition = 0;
  }

  /// 推进移动（正常 update 与活动执行器共用）
  void tickMove(double dt) {
    if (_move == null || _move!.finished) return;
    _move!.update(dt);
    position = clampToArea(_move!.position);
    // 根据移动方向自动翻转朝向
    final dir = _move!.directionX;
    if (dir.abs() > 0.001) {
      facing = dir > 0 ? PetFacing.right : PetFacing.left;
    }
    if (_move!.finished) {
      final done = _move!;
      _move = null;
      // 转头往回走支持
      if (_turnBackPending) {
        _turnBackPending = false;
        _startMove(
            from: position,
            to: _turnBackOrigin,
            duration: done.duration,
            ease: done.ease);
        return;
      }
      state = PetState.idle;
      _onActionDone('move');
    }
  }

  /// 推进帧动画（正常 update 与活动执行器共用）
  void tickAnim(double dt) {
    _player?.update(dt);
    if (_player != null && _player!.finished && state == PetState.acting) {
      final doneId = _lastPlayedActionId ?? 'action';
      _player = null;
      _enterIdle();
      _onActionDone(doneId);
    }
  }

  bool _turnBackPending = false;
  PetPoint _turnBackOrigin = PetPoint.origin;

  /// 播放一个原地动作（帧动画）
  ///
  /// 注意：不清理 _activity —— 组合动作执行器在活动期间调用本方法，
  /// 活动需要保持存活来驱动后续步骤。
  void playAction(PetActionDef def, List<String> frames, {int? repeat}) {
    _move = null;
    _lastPlayedActionId = def.id;
    _player = PetAnimPlayer(
      frames: frames,
      fps: def.fps * def.speedTier.factor,
      loop: def.loop,
      maxLoops: repeat != null && repeat > 1 ? repeat : 0,
    );
    currentActionId = def.id;
    state = PetState.acting;
    _startTransition();
  }

  String? _lastPlayedActionId;

  /// 8-14 17:0x（用户：设了单个动作小人就是不动——真根因）：
  /// 自主播放的剩余秒数。>0 时每秒递减，归零 stop() 回待机。
  /// 因为用户动作是 loop 无限循环，PetAnimPlayer.finished 永远
  /// false，_player 永不为 null，旧触发条件（_player == null）
  /// 导致 _tickAutoAct 是死代码——小人永远只播待机帧。
  double autoActionLeft = 0;

  /// 播放待机（回落到待机帧）
  void playIdle(List<String> idleFrames, {double fps = 8}) {
    _player = PetAnimPlayer(frames: idleFrames, fps: fps, loop: PetAnimLoop.loop);
    currentActionId = 'idle';
    state = PetState.idle;
    _startTransition();
  }

  /// 移动到目标位置（播放移动帧 + 插值）
  void moveTo(
    PetPoint target, {
    double duration = 3,
    PetAnimPlayer? movePlayer,
    bool turnBack = false,
    PetMoveEase ease = PetMoveEase.easeInOut,
    double jumpHeight = 0,
  }) {
    if (area == PetArea.fixed) {
      // 固定位置的小人不移动，原地待着
      return;
    }
    final clamped = clampToArea(target);
    if (turnBack) {
      _turnBackPending = true;
      _turnBackOrigin = position;
    } else {
      _turnBackPending = false;
    }
    _startMove(
        from: position,
        to: clamped,
        duration: duration,
        movePlayer: movePlayer,
        ease: ease,
        jumpHeight: jumpHeight);
  }

  void _startMove({
    required PetPoint from,
    required PetPoint to,
    required double duration,
    PetAnimPlayer? movePlayer,
    PetMoveEase ease = PetMoveEase.easeInOut,
    double jumpHeight = 0.3,
  }) {
    _move = PetMoveState(
      from: from,
      to: to,
      duration: duration,
      ease: ease,
      jumpHeight: jumpHeight,
    );
    if (movePlayer != null) {
      _player = movePlayer;
    }
    currentActionId = 'move';
    state = PetState.moving;
    _startTransition();
  }

  /// 预设行为（爬屏幕 / 跳下来）
  void runBehavior(PetBehavior behavior) {
    switch (behavior) {
      case PetBehavior.climb:
        // 沿屏幕边缘爬到顶部：速度固定 0.35/s，从哪爬都刚好到顶
        // （爬的动画帧是循环的，爬多久都行——动画循环播，位置持续动）
        final target = PetPoint(position.x, 0.06);
        final dist = position.distanceTo(target);
        final duration = dist / 0.35;
        _startMove(
          from: position,
          to: target,
          duration: duration,
          ease: PetMoveEase.easeInOut,
        );
      case PetBehavior.jumpOff:
        // 抛物线跳出屏幕底部，然后自动回到原位
        _turnBackPending = true;
        _turnBackOrigin = PetPoint(position.x, 0.8);
        _startMove(
          from: position,
          to: PetPoint(position.x, 1.15),
          duration: 1.1,
          ease: PetMoveEase.jump,
          jumpHeight: 0.35,
        );
    }
    _onActionDone('behavior:${behavior.name}');
  }

  /// 转头（翻转朝向）
  void turnAround() {
    facing = facing == PetFacing.left ? PetFacing.right : PetFacing.left;
    _onActionDone('turn');
  }

  /// 说话（触发气泡，不打断动作）
  void speak(String text) {
    state = PetState.speaking;
    onSpeak?.call(id, text);
  }

  /// 停止当前一切，回待机
  void stop() {
    _endPair();
    _activity = null;
    _move = null;
    _turnBackPending = false;
    _player = null;
    currentActionId = null;
    _enterIdle();
  }

  void _enterIdle() {
    state = PetState.idle;
    currentActionId = 'idle';
  }

  void _onActionDone(String actionId) {
    onActionDone?.call(id, actionId);
  }
}

/// 组合动作运行器（由 PetActivityRunner 创建，Pet 持有）
/// 移动起点计算：dock=聊天框（底部上方）/ center=屏幕中间 /
/// custom=用户自定义坐标（startX/startY，缺省 0.5,0.5）
PetPoint _moveBasePoint(PetMoveRef ref, {double? x, double? y}) =>
    PetMoveRef.basePoint(ref, x: x, y: y);

class PetActivityRun {
  final PetActivityDef def;
  int _stepIndex = 0;
  double _stepElapsed = 0;
  bool _finished = false;
  bool _stepStarted = false;

  /// 每步的动作定义查找（由场景注入）
  final PetActionDef Function(String actionId) actionResolver;

  /// 每步的帧图查找（由场景注入）
  final List<String> Function(String actionId) framesResolver;

  /// 移动动画解析（走/跑切换，由场景注入；可空 = 不播移动帧）
  final PetActionDef? Function(String? moveGroupId, double speed)
      moveAnimResolver;

  PetActivityRun({
    required this.def,
    required this.actionResolver,
    required this.framesResolver,
    PetActionDef? Function(String? moveGroupId, double speed)?
        moveAnimResolver,
  }) : moveAnimResolver = moveAnimResolver ?? _noMoveAnim;

  static PetActionDef? _noMoveAnim(String? moveGroupId, double speed) => null;

  bool get finished => _finished;
  int get stepIndex => _stepIndex;
  PetActivityStep? get currentStep =>
      _stepIndex < def.steps.length ? def.steps[_stepIndex] : null;

  /// 步骤进度 0~1
  double get progress =>
      def.steps.isEmpty ? 1 : _stepIndex / def.steps.length;

  /// 推进（dt 秒），驱动 Pet 执行当前步骤
  void update(double dt, Pet pet) {
    if (_finished) return;

    final step = currentStep;
    if (step == null) {
      _finished = true;
      return;
    }

    // 说话步骤：触发气泡，立即进入下一步
    if (step.isSpeak) {
      pet.speak(step.text ?? '');
      // 活动仍在驱动，状态归活动（speak 只负责触发气泡）
      pet.state = PetState.activity;
      _advanceStep();
      return;
    }

    final def = actionResolver(step.actionId);

    // 方向移动步骤：从当前位置朝 8 方向之一走（固定速度 0.3/s），
    // 起点由组合动作的 startRef 决定（先瞬移过去再一步步走）
    // 可走固定秒数，也可"一直走到撞墙/屏幕边"才停下
    if (step.isMoveDir) {
      if (!_stepStarted) {
        const speed = 0.3;
        final from = pet.position;
        final (vx, vy) = step.moveDir!.vector;
        // 距离优先：moveDist（屏幕百分比）> 撞墙 > 秒数×速度
        final dist = step.moveDist ??
            (step.moveUntilWall ? 10.0 : speed * (step.moveSec ?? 2));
        final target = pet.clampToArea(
            PetPoint(from.x + vx * dist, from.y + vy * dist));
        // 按实际可走距离算时长 → 速度恒定；撞墙时提前到点停
        final actualDist = from.distanceTo(target);
        final duration = step.moveSec ?? actualDist / speed;
        pet.moveTo(target,
            duration: duration, turnBack: step.turnBack);
        _stepStarted = true;
      }
      _stepElapsed += dt;
      pet.tickMove(dt);
      if (!pet.moving && _stepElapsed > 0.05) {
        _advanceStep();
      }
      return;
    }

    // 目标点步骤（任何动作 + target）：
    // 速度固定 → 时长按距离自动换算；越界被夹到屏幕边（撞墙截断）
    // 移动动作播走/跑帧；原地动作（跳/飞等）边播帧边移动
    if (step.target != null) {
      if (!_stepStarted) {
        final from = pet.position;
        final clamped = pet.clampToArea(step.target!);
        final actualDist = from.distanceTo(clamped);
        final speed = switch (step.trajectory) {
          PetMoveTrajectory.walk => 0.35,
          PetMoveTrajectory.jump => 0.55,
          PetMoveTrajectory.fly => 0.45,
        };
        final duration = actualDist / speed;
        if (def.kind == PetActionKind.moveTo) {
          // 移动动作：按速度选走/跑帧
          final moveDef =
              moveAnimResolver(def.moveGroupId, actualDist / duration);
          if (moveDef != null) {
            final movePlayer = PetAnimPlayer(
              frames: framesResolver(moveDef.id),
              fps: moveDef.fps * moveDef.speedTier.factor,
              loop: PetAnimLoop.loop,
            );
            pet.moveTo(
              clamped,
              duration: duration,
              movePlayer: movePlayer,
              turnBack: step.turnBack,
              ease: switch (step.trajectory) {
                PetMoveTrajectory.walk => PetMoveEase.linear,
                PetMoveTrajectory.jump => PetMoveEase.jump,
                PetMoveTrajectory.fly => PetMoveEase.easeInOut,
              },
              jumpHeight:
                  step.trajectory == PetMoveTrajectory.jump ? 0.25 : 0,
            );
          } else {
            pet.moveTo(
              clamped,
              duration: duration,
              turnBack: step.turnBack,
              ease: switch (step.trajectory) {
                PetMoveTrajectory.walk => PetMoveEase.linear,
                PetMoveTrajectory.jump => PetMoveEase.jump,
                PetMoveTrajectory.fly => PetMoveEase.easeInOut,
              },
              jumpHeight:
                  step.trajectory == PetMoveTrajectory.jump ? 0.25 : 0,
            );
          }
        } else {
          // 原地动作带位移：先播帧（循环），位置同时动
          pet.playAction(def, framesResolver(step.actionId));
          pet.moveTo(
            clamped,
            duration: duration,
            turnBack: step.turnBack,
            ease: switch (step.trajectory) {
              PetMoveTrajectory.walk => PetMoveEase.linear,
              PetMoveTrajectory.jump => PetMoveEase.jump,
              PetMoveTrajectory.fly => PetMoveEase.easeInOut,
            },
            jumpHeight: step.trajectory == PetMoveTrajectory.jump ? 0.25 : 0,
          );
        }
        _stepStarted = true;
      }
      _stepElapsed += dt;
      pet.tickAnim(dt);
      pet.tickMove(dt);
      if (!pet.moving && _stepElapsed > 0.05) {
        // 移动结束（含转头往回走整体结束）
        _advanceStep();
      }
      return;
    }

    // 转头步骤
    if (def.kind == PetActionKind.turn) {
      if (!_stepStarted) {
        pet.turnAround();
        _stepStarted = true;
      }
      _stepElapsed += dt;
      if (_stepElapsed >= 0.5) {
        _advanceStep();
      }
      return;
    }

    // 原地动作步骤（动作自带位移目标/相对位移时，边播帧边移动）
    if (!_stepStarted) {
      pet.playAction(def, framesResolver(step.actionId), repeat: step.repeat);
      if (def.target != null || (def.moveDir != null && def.moveDist != null)) {
        final from = pet.position;
        final PetPoint target;
        if (def.target != null) {
          target = def.target!;
        } else {
          // 8-14 17:5x（用户：修 bug 要看联动——组合动作步骤也一样）：
          // 从当前位置出发（上一步在哪结束就从哪继续），不瞬移回起点
          final (vx, vy) = def.moveDir!.vector;
          target = PetPoint(from.x + vx * def.moveDist!,
              from.y + vy * def.moveDist!);
        }
        final clamped = pet.clampToArea(target);
        final actualDist = from.distanceTo(clamped);
        final speed = switch (def.trajectory) {
          PetMoveTrajectory.walk => 0.35,
          PetMoveTrajectory.jump => 0.55,
          PetMoveTrajectory.fly => 0.45,
        };
        pet.moveTo(
          clamped,
          duration: def.moveSec ?? actualDist / speed,
          ease: switch (def.trajectory) {
            PetMoveTrajectory.walk => PetMoveEase.linear,
            PetMoveTrajectory.jump => PetMoveEase.jump,
            PetMoveTrajectory.fly => PetMoveEase.easeInOut,
          },
          jumpHeight: def.trajectory == PetMoveTrajectory.jump ? 0.25 : 0,
        );
      }
      _stepStarted = true;
    }
    _stepElapsed += dt;
    pet.tickAnim(dt);
    if (pet.moving) pet.tickMove(dt);

    // 指定了时长：到时即进下一步
    if (step.durationSec != null && _stepElapsed >= step.durationSec!) {
      _advanceStep();
      return;
    }

    // 带位移的动作：移动完才算这步结束（帧循环播着无所谓）
    if (def.target != null || (def.moveDir != null && def.moveDist != null)) {
      if (!pet.moving && _stepElapsed > 0.05) {
        _advanceStep();
      }
      return;
    }

    // 动作播完（含 repeat 循环次数播完）即进下一步
    // 注意：tickAnim 播完后会把 player 置空，所以 player == null 也视为播完
    final player = pet.player;
    if (player == null || player.finished) {
      _advanceStep();
    }
  }

  void _advanceStep() {
    _stepElapsed = 0;
    _stepStarted = false;
    _stepIndex++;
    if (_stepIndex >= def.steps.length) {
      _finished = true;
    }
  }

  /// 跳过当前步骤（活动编辑预览用）
  void skipStep() => _advanceStep();
}

/// 桌宠世界 — 多个小人共享一个屏幕空间
class PetScene {
  final PetFrameSource frames;
  final List<Pet> _pets = [];

  /// 组合动作库（id → 定义）
  final Map<String, PetActivityDef> _activities = {};

  /// 动作定义库（内置 + 用户自建，id → 定义）
  final Map<String, PetActionDef> _actionDefs = {};

  // 8-14 22:2x（GPT 方案：自主行动状态机 MOVE→DWELL→MOVE）：
  // 移动完成后的停留秒数 / 上一帧是否在移动 / 自主移动序号（日志）
  final Map<String, double> _dwellLeft = {};
  final Map<String, bool> _wasMoving = {};
  final Map<String, int> _autoSeq = {};

  // ===== 8-14 23:2x 状态系统（GPT 19 条 v1.2） =====
  /// 状态绑定缓存（profileId → 绑定列表，PetWorld restore 时加载）
  final Map<String, List<PetStateBinding>> _stateBindings = {};
  /// 联动缓存（'targetId|stateId' → 观察者响应列表）
  final Map<String, List<PetStateLink>> _stateLinks = {};
  /// 响应队列（petId → 待播 (type, id)）
  final Map<String, List<MapEntry<String, String>>> _respQueue = {};
  /// 响应进行中
  final Map<String, bool> _respActive = {};
  /// 抛射飞行中（移动完成 → 落点检测）
  final Map<String, bool> _pendingThrow = {};

  /// 移动动画组（走+跑绑定，id → 定义）
  final Map<String, PetMoveGroupDef> _moveGroups = {};

  /// 正在跑的互动组（null = 没有）
  PetGroupRun? _groupRun;

  /// 互动组结束回调（UI 监听，比如散场后做点什么）
  void Function(PetGroupRun run)? onGroupFinished;

  /// 可自动触发的互动组（UI 层从数据库加载后注入）
  List<PetGroupRuntime> groupRuntimes = const [];

  /// 距离检测计时器
  double _groupCheckAcc = 0;

  /// 互动组散场后的冷却（防止立刻重触发）
  DateTime? _groupCooldownUntil;

  /// 开演前各小人正在播的单人动作（散场 resume 用）
  final Map<String, String?> _preRunActions = {};

  PetScene({required this.frames}) {
    // 加载内置动作模板
    for (final a in PetBuiltinActions.all) {
      _actionDefs[a.id] = a;
    }
    // 默认移动组：走 + 跑
    _moveGroups['default'] = const PetMoveGroupDef(
      id: 'default',
      name: '默认',
      walkActionId: 'walk',
      runActionId: 'run',
    );
  }

  List<Pet> get pets => List.unmodifiable(_pets);

  Map<String, PetActionDef> get actionDefs => Map.unmodifiable(_actionDefs);

  Map<String, PetActivityDef> get activities => Map.unmodifiable(_activities);

  Map<String, PetMoveGroupDef> get moveGroups => Map.unmodifiable(_moveGroups);

  /// 注册/覆盖移动组
  void registerMoveGroup(PetMoveGroupDef def) => _moveGroups[def.id] = def;

  /// 按移动速度解析移动动画（走/跑切换）
  ///
  /// [moveGroupId] 指定组；null 用默认组。
  /// 速度 = 距离/时长（屏幕比例每秒），超过阈值用跑。
  PetActionDef resolveMoveAnim(String? moveGroupId, double speed) {
    final group = _moveGroups[moveGroupId ?? 'default'] ?? _moveGroups['default']!;
    const runThreshold = 0.45;
    final useRun = group.runActionId != null && speed > runThreshold;
    final actionId = useRun ? group.runActionId! : group.walkActionId;
    return _actionDefs[actionId] ?? _actionDefs['walk']!;
  }

  Pet? petById(String id) {
    for (final p in _pets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 男主小人的位置（默认位置2）；场景里没有就回退自己位置
  PetPoint? heroPosition() {
    final hero = petById('male_lead');
    return hero?.position;
  }

  /// 创建一个小人
  Pet createPet({
    required String id,
    String? name,
    PetPoint? position,
    double scale = 1.0,
    PetArea area = PetArea.full,
    PetPoint? fixedPosition,
    String? avatarPath,
  }) {
    final pet = Pet(
      id: id,
      name: name ?? id,
      position: position,
      scale: scale,
      avatarPath: avatarPath,
    );
    pet.area = area;
    pet.fixedPosition = fixedPosition;
    if (area == PetArea.fixed) {
      pet.position = fixedPosition ?? pet.position;
    }
    _pets.add(pet);
    return pet;
  }

  void removePet(String id) {
    _pets.removeWhere((p) => p.id == id);
  }

  /// 注册/更新动作定义
  void registerAction(PetActionDef def) {
    _actionDefs[def.id] = def;
  }

  /// 删除动作定义（内置动作不可删）
  bool removeAction(String id) {
    if (PetBuiltinActions.byId(id) != null) return false;
    return _actionDefs.remove(id) != null;
  }

  /// 保存组合动作
  void saveActivity(PetActivityDef def) {
    _activities[def.id] = def;
  }

  bool removeActivity(String id) => _activities.remove(id) != null;

  /// 场景总推进：所有小人各自更新
  void update(double dt) {
    for (final pet in _pets) {
      pet.update(dt);
    }
    // idle 兜底 + 自主行动（8-14 13:5x 修复 playIdle 从未被调用 → 隐形；
    // 8-14 15:0x 扩展：用户反馈小人不会动/显示内置粉色小人——
    // ① 空闲时随机自发做动作（养宠物自主性 MVP：随机触发"什么时候动"）
    // ② idle 帧优先用用户上传的图，不再显示内置粉色小人）
    for (final pet in _pets) {
      // 8-14 23:2x 状态系统：响应队列推进（含抛射落点检测）
      _tickStateResponses(pet);
      // 位置状态自动检测（GPT 14/15 条）：auto 控制权、没在移动、
      // 没被用户抓住时才检测；previous != current 才触发（防重复）
      if (pet.controlOwner == PetControlOwner.auto &&
          !pet.moving &&
          !pet.held) {
        final r = pet.detector.detectPosition(pet);
        if (pet.detector.isEntered(r)) {
          DebugLogger.log('桌宠',
              '状态进入 ${pet.name} → ${PetStateIds.label(r.stateId)} (${r.source})');
          _enqueueStateResponses(pet, r.stateId, r.source);
          _fireLinks(pet.id, r.stateId);
        }
      }
      // 8-14 17:0x（自主行动死代码修复）：idle 状态（待机帧在播）也
      // 触发——loop 无限循环导致 _player 永不为 null，旧条件永远不满足
      if (pet._pair == null &&
          pet._activity == null &&
          !pet.moving &&
          pet.state == PetState.idle) {
        _tickAutoAct(pet, dt);
        if (pet._player == null &&
            pet.controlOwner != PetControlOwner.response) {
          // 8-15 00:5x（用户：扔出去就消失看不见）：held/飞行期间
          // _player==null 会导致小人不可见——统一播待机帧兜底
          pet.playIdle(_resolveIdleFrames(pet), fps: 4);
        }
      }
      // 自主动作播够秒数 → 停帧回待机（loop 无限循环不会自己结束）
      if (pet.autoActionLeft > 0) {
        pet.autoActionLeft -= dt;
        if (pet.autoActionLeft <= 0) {
          pet.autoActionLeft = 0;
          if (pet._pair == null && pet._activity == null) {
            pet.stop();
          }
        }
      }
    }
    // 互动组编排推进（先让小人动，再算步骤计时）
    final run = _groupRun;
    if (run != null) {
      run.update(dt);
      if (run.finished) {
        _groupRun = null;
        _groupCooldownUntil =
            DateTime.now().add(const Duration(seconds: 3));
        _applyExitMode(run);
        onGroupFinished?.call(run);
      }
    } else {
      // 没有在演 → 周期检查距离触发
      _groupCheckAcc += dt;
      if (_groupCheckAcc >= 0.8) {
        _groupCheckAcc = 0;
        _maybeAutoStartGroup();
      }
    }
  }

  /// 距离自动触发：互动组里所有绑定的小人都在场，且两两距离都 ≤ 触发距离 → 开演
  void _maybeAutoStartGroup() {
    if (_groupRun != null) return;
    final cd = _groupCooldownUntil;
    if (cd != null && DateTime.now().isBefore(cd)) return;
    for (final rt in groupRuntimes) {
      final def = rt.def;
      final trigger = def.triggerDist;
      if (trigger == null || def.slots.length < 2) continue;
      final cast = <Pet>[];
      var ok = true;
      for (final slot in def.slots) {
        final pid = slot.bindPetId;
        if (pid == null) {
          ok = false;
          break;
        }
        final pet = petById(pid);
        if (pet == null) {
          ok = false;
          break;
        }
        cast.add(pet);
      }
      if (!ok) continue;
      var maxDist = 0.0;
      for (var i = 0; i < cast.length; i++) {
        for (var j = i + 1; j < cast.length; j++) {
          final d = cast[i].position.distanceTo(cast[j].position);
          if (d > maxDist) maxDist = d;
        }
      }
      if (maxDist <= trigger) {
        startGroup(def, cast, def.slots,
            slotActions: rt.slotActions, slotFrames: rt.slotFrames);
        return;
      }
    }
  }

  /// 散场：idle = 回待机；resume = 接着开演前各自的单人动作
  void _applyExitMode(PetGroupRun run) {
    final resume = run.def.exitMode == 'resume';
    for (final pet in run.cast) {
      if (!resume) {
        pet.stop();
        continue;
      }
      final aid = _preRunActions[pet.id];
      final def = aid != null ? _actionDefs[aid] : null;
      if (def != null) {
        // 帧是异步加载的：先回待机，帧到了再接着播
        pet.stop();
        unawaited(frames.framesFor(def.id).then((f) {
          if (f.isEmpty) return;
          pet.playAction(def, f);
        }));
      } else {
        pet.stop();
      }
    }
    _preRunActions.clear();
  }

  /// 给指定小人播放组合动作
  PetActivityRun? runActivity(String petId, String activityId) {
    final pet = petById(petId);
    final def = _activities[activityId];
    if (pet == null || def == null) return null;
    // 初始位置：小人先瞬移到基准点，再从那里开始走路径
    if (def.startRef != null) {
      pet.position = pet.clampToArea(_moveBasePoint(def.startRef!,
          x: def.startX, y: def.startY));
      pet.stopMoving();
    }

    final run = PetActivityRun(
      def: def,
      actionResolver: (id) => _actionDefs[id] ?? PetBuiltinActions.byId(id) ?? PetBuiltinActions.all.first,
      framesResolver: (id) => _resolveFramesSync(id),
      moveAnimResolver: (groupId, speed) {
        if (groupId == null) return null;
        final group = _moveGroups[groupId] ?? _moveGroups['default'];
        if (group == null) return null;
        const runThreshold = 0.45;
        final useRun = group.runActionId != null && speed > runThreshold;
        final aid = useRun ? group.runActionId! : group.walkActionId;
        return _actionDefs[aid] ?? _actionDefs['walk'];
      },
    );
    pet._activity = run;
    pet.state = PetState.activity;
    // 立即执行第一步（说话/动作即时响应，不等下一帧）
    run.update(0, pet);
    return run;
  }

  /// 移动速度（按轨迹）
  double _moveSpeed(PetActionDef def) => switch (def.trajectory) {
        PetMoveTrajectory.walk => 0.35,
        PetMoveTrajectory.jump => 0.55,
        PetMoveTrajectory.fly => 0.45,
      };

  /// 统一目标计算（GPT 8-14 22:2x：绝对目标 / toEdge 撞墙 / distance
  /// 方向+距离 三种语义分开，不再用 moveDist=1.0 兼职"走到底"）
  PetPoint _targetFor(Pet pet, PetActionDef def) {
    if (def.target != null) return def.target!;
    if (def.moveDir == null) return pet.position;
    if (def.moveMode == PetMoveMode.toEdge) {
      return _edgeTargetFor(pet, def.moveDir!);
    }
    final (vx, vy) = def.moveDir!.vector;
    return PetPoint(pet.position.x + vx * (def.moveDist ?? 0.3),
        pet.position.y + vy * (def.moveDist ?? 0.3));
  }

  /// 沿方向与活动区域边界求交（走到底 = 撞墙才停，目标不出屏）
  PetPoint _edgeTargetFor(Pet pet, PetMoveDir dir) {
    final (vx, vy) = dir.vector;
    const minX = 0.02, maxX = 0.98;
    final (minY, maxY) = switch (pet.area) {
      PetArea.full => (0.02, 0.98),
      PetArea.bottom => (0.55, 0.95),
      PetArea.fixed => (pet.position.y, pet.position.y),
    };
    double t = double.infinity;
    if (vx > 0) {
      t = (maxX - pet.position.x) / vx;
    } else if (vx < 0) {
      t = (minX - pet.position.x) / vx;
    }
    if (vy > 0) {
      t = math.min(t, (maxY - pet.position.y) / vy);
    } else if (vy < 0) {
      t = math.min(t, (minY - pet.position.y) / vy);
    }
    if (!t.isFinite) return pet.position;
    return PetPoint(pet.position.x + vx * t, pet.position.y + vy * t);
  }

  /// 给指定小人播放单个动作
  void playAction(String petId, String actionId) {
    final pet = petById(petId);
    final def = _actionDefs[actionId];
    if (pet == null || def == null) return;
    if (def.kind == PetActionKind.duo) {
      // 双人互动：找另一个小人一起
      Pet? partner;
      for (final p in _pets) {
        if (p.id != petId) {
          partner = p;
          break;
        }
      }
      if (partner != null) {
        startDuo(petId, partner.id, def.id);
      }
      return;
    }
    if (def.kind == PetActionKind.moveTo) {
      // 8-14 17:1x（用户：动作之间要相对衔接，不能每次都瞬移回起点）：
      // 从【当前位置】出发——上个动作在哪结束，这个就从哪继续。
      // 8-14 22:2x（GPT 方案）：目标 = 绝对目标点 / toEdge 沿方向撞墙 /
      // distance 方向+距离，三种语义分开（_targetFor 统一计算）。
      final target = _targetFor(pet, def);
      final clamped = pet.clampToArea(target);
      final dist = pet.position.distanceTo(clamped);
      // 8-14 22:2x（GPT 方案：日志增强）——序号/mode/起点/目标/距离/时长
      final seq = (_autoSeq[pet.id] ?? 0) + 1;
      _autoSeq[pet.id] = seq;
      final moveDur = def.moveSec ?? dist / _moveSpeed(def);
      DebugLogger.log('桌宠',
          '自主移动 #$seq mode=${def.moveMode.name} '
          '方向=${def.moveDir?.name ?? "无"} '
          'from=(${pet.position.x.toStringAsFixed(2)},${pet.position.y.toStringAsFixed(2)}) '
          'to=(${clamped.x.toStringAsFixed(2)},${clamped.y.toStringAsFixed(2)}) '
          '距离=${dist.toStringAsFixed(2)} 时长=${moveDur.toStringAsFixed(2)}s');
      pet.playAction(def, _resolveFramesSync(actionId));
      // 8-14 21:2x（用户：走走停停、走一半就停——真根因）：autoActionLeft
      // 之前 = 帧播秒数（durationSeconds），移动走到底远不止 2 秒 →
      // 2 秒被掐断只走 20% → 等 8~20 秒再触发。改成移动时长：
      // 走完才算完，一次走到底。
      pet.autoActionLeft = moveDur + 0.3;
      pet.moveTo(
        clamped,
        duration: moveDur,
        ease: switch (def.trajectory) {
          PetMoveTrajectory.walk => PetMoveEase.linear,
          PetMoveTrajectory.jump => PetMoveEase.jump,
          PetMoveTrajectory.fly => PetMoveEase.easeInOut,
        },
        jumpHeight: def.trajectory == PetMoveTrajectory.jump ? 0.25 : 0,
      );
      return;
    }
    if (def.kind == PetActionKind.turn) {
      pet.turnAround();
      return;
    }
    if (def.kind == PetActionKind.behavior) {
      final behavior = PetBehavior.fromName(actionId);
      if (behavior != null) {
        // 先播行为帧（爬/跳的动画循环播），再开始行为移动——
        // 动画 1 秒循环，位置持续动，直到爬完/跳完
        pet.playAction(def, _resolveFramesSync(actionId));
        pet.runBehavior(behavior);
        return;
      }
    }
    // 原地动作带位移（导入时配的"播的时候怎么动"）：边播帧边移动，
    // 目标统一 _targetFor（绝对目标 / toEdge 撞墙 / distance 方向+距离）
    if (def.kind == PetActionKind.inPlace &&
        (def.target != null ||
            (def.moveDir != null &&
                (def.moveMode == PetMoveMode.toEdge || def.moveDist != null)))) {
      final from = pet.position;
      final clamped = pet.clampToArea(_targetFor(pet, def));
      final actualDist = from.distanceTo(clamped);
      final speed = _moveSpeed(def);
      final moveDur = def.moveSec ?? actualDist / speed;
      pet.playAction(def, _resolveFramesSync(actionId));
      pet.autoActionLeft = moveDur + 0.3;
      pet.moveTo(
        clamped,
        duration: moveDur,
        ease: switch (def.trajectory) {
          PetMoveTrajectory.walk => PetMoveEase.linear,
          PetMoveTrajectory.jump => PetMoveEase.jump,
          PetMoveTrajectory.fly => PetMoveEase.easeInOut,
        },
        jumpHeight: def.trajectory == PetMoveTrajectory.jump ? 0.25 : 0,
      );
      return;
    }
    pet.playAction(def, _resolveFramesSync(actionId));
    pet.autoActionLeft = def.durationSeconds ?? 2;
  }

  /// 同步取帧（无图时用占位帧兜底）
  List<String> _resolveFramesSync(String actionId) {
    final def = _actionDefs[actionId];
    if (def == null) return [];
    if (def.hasFrames) {
      // 有帧图：异步扫描的结果缓存在这里（由 UI 层预载入）
      final cached = _frameCache[actionId];
      if (cached != null && cached.isNotEmpty) return cached;
    }
    return PetPlaceholderFrames.forAction(def);
  }

  /// 帧图缓存（UI 层预载入：扫描目录 → 存入）
  final Map<String, List<String>> _frameCache = {};

  /// 自主行动倒计时（petId → 剩余秒）——8-14 15:0x：养宠物自主性
  final Map<String, double> _autoActIn = {};
  final math.Random _autoRand = math.Random();

  /// 自主行动：空闲小人每隔随机时间自发做一个动作（用户动作优先），
  /// 移动方式（上下/左右/方向+距离）由动作定义驱动，播完回 idle。
  // ===== 8-14 23:2x 控制权 + 状态系统核心（GPT 19 条 v1.2） =====

  /// 加载状态配置（PetWorld restore 后调用，缓存到场景）
  void loadStateConfigs(
      List<PetStateBinding> bindings, List<PetStateLink> links) {
    _stateBindings.clear();
    for (final b in bindings) {
      _stateBindings.putIfAbsent(b.profileId, () => []).add(b);
    }
    _stateLinks.clear();
    for (final l in links) {
      if (!l.enabled) continue;
      _stateLinks
          .putIfAbsent('${l.targetId}|${l.targetState}', () => [])
          .add(l);
    }
  }

  /// 用户开始控制（panStart）：控制权 user + 暂停移动 + held 响应
  void beginUserControl(String petId) {
    final pet = petById(petId);
    if (pet == null) return;
    pet.controlOwner = PetControlOwner.user;
    pet.held = true;
    // 暂停当前移动（不销毁，记快照；响应结束可恢复）
    if (pet.moving && pet._move != null) {
      pet.suspendedMove = pet._move;
      pet.stopMoving();
    }
    pet.stop(); // 停当前动作
    _respQueue.remove(petId);
    _respActive[petId] = false;
    pet.detector.reset();
    DebugLogger.log('桌宠', '用户控制开始 ${pet.name}（held）');
    _enqueueStateResponses(pet, PetStateIds.held, 'user');
  }

  /// 用户结束控制（panEnd）：扔/放判定 + 事件响应 + 抛射/落点
  void endUserControl(String petId,
      {double speed = 0, double dx = 0, double dy = 0}) {
    final pet = petById(petId);
    if (pet == null) return;
    pet.held = false;
    _enqueueStateResponses(pet, PetStateIds.userRelease, 'user');
    // 判定扔/放（8-15 00:5x 用户：我只是想挪动它——慢速拖动=放下）：
    // 只看松手速度——快速甩 = 扔，慢速挪 = 原地放下
    final isThrow = speed >= PetStateDetector.throwSpeedThreshold;
    if (isThrow) {
      final (vx, vy) = (dx != 0 || dy != 0)
          ? _normalize(dx, dy)
          : PetMoveDir.left.vector;
      final target = pet.clampToArea(PetPoint(
          pet.position.x + vx * pet.throwDistance,
          pet.position.y + vy * pet.throwDistance));
      final dur = pet.position.distanceTo(target) / 0.5;
      DebugLogger.log('桌宠',
          '被扔 ${pet.name} 方向=(${vx.toStringAsFixed(2)},${vy.toStringAsFixed(2)}) '
          '距离=${pet.throwDistance.toStringAsFixed(2)} 目标=(${target.x.toStringAsFixed(2)},${target.y.toStringAsFixed(2)})');
      pet.controlOwner = PetControlOwner.response;
      _pendingThrow[pet.id] = true;
      pet.moveTo(target, duration: dur, ease: PetMoveEase.linear);
      _enqueueStateResponses(pet, PetStateIds.thrown, 'user');
      _fireLinks(pet.id, PetStateIds.thrown);
    } else {
      pet.controlOwner = PetControlOwner.response;
      _enqueueStateResponses(pet, PetStateIds.dropped, 'user');
      _fireLinks(pet.id, PetStateIds.dropped);
    }
    _fireLinks(pet.id, PetStateIds.userRelease);
  }

  /// 归一化方向向量
  (double, double) _normalize(double x, double y) {
    final len = math.sqrt(x * x + y * y);
    if (len < 0.0001) return (0, 0);
    return (x / len, y / len);
  }

  /// 把某状态（含来源）的绑定响应排进队列（顺序播）
  void _enqueueStateResponses(Pet pet, String stateId, String source) {
    final binds = (_stateBindings[pet.id] ?? const [])
        .where((b) =>
            b.stateId == stateId &&
            b.source == source &&
            b.enabled &&
            b.autoDetect &&
            b.responseId != null)
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    if (binds.isEmpty) return;
    for (final b in binds) {
      _respQueue
          .putIfAbsent(pet.id, () => [])
          .add(MapEntry(b.responseType, b.responseId!));
    }
    DebugLogger.log('桌宠',
        '状态 ${PetStateIds.label(stateId)}($source) → ${binds.length} 个响应 ${pet.name}');
  }

  /// A 进入某状态/事件 → 所有观察者联动响应（没配置 = 无反应）
  void _fireLinks(String targetId, String stateId) {
    final links = _stateLinks['$targetId|$stateId'] ?? const [];
    for (final l in links) {
      final observer = petById(l.observerId);
      if (observer == null) continue;
      // 用户正在操作 / 在演互动组 → 不抢
      if (observer.held || observer.controlOwner == PetControlOwner.user) {
        continue;
      }
      if (observer._activity != null || observer._pair != null) continue;
      if (l.responseType == PetResponseType.goto) {
        _respQueue.putIfAbsent(observer.id, () => []).add(
            MapEntry(PetResponseType.goto, l.responseId ?? targetId));
      } else if (l.responseId != null) {
        _respQueue
            .putIfAbsent(observer.id, () => [])
            .add(MapEntry(l.responseType, l.responseId!));
      }
    }
  }

  /// 播放一个响应项
  void _playRespItem(Pet pet, MapEntry<String, String> item) {
    final type = item.key, id = item.value;
    switch (type) {
      case PetResponseType.action:
        playAction(pet.id, id);
      case PetResponseType.activity:
        runActivity(pet.id, id);
      case PetResponseType.goto:
        // 无视距离走到目标小人身边
        final target = petById(id);
        if (target != null) {
          final dist = pet.position.distanceTo(target.position);
          DebugLogger.log('桌宠',
              '联动 ${pet.name} → 走到 ${target.name} 身边（${dist.toStringAsFixed(2)}）');
          pet.moveTo(target.position,
              duration: dist / 0.5, ease: PetMoveEase.linear);
        }
      default:
        playAction(pet.id, id);
    }
  }

  /// 每帧推进状态响应队列（顺序播完 → 恢复阶段）
  void _tickStateResponses(Pet pet) {
    // 抛射完成 → 落点检测（进入落点状态 → 响应）
    if ((_pendingThrow[pet.id] ?? false) && !pet.moving) {
      _pendingThrow[pet.id] = false;
      final r = pet.detector.detectPosition(pet, source: 'user');
      DebugLogger.log('桌宠',
          '抛射落点 ${pet.name} → ${PetStateIds.label(r.stateId)}');
      if (pet.detector.isEntered(r)) {
        _enqueueStateResponses(pet, r.stateId, 'user');
        _fireLinks(pet.id, r.stateId);
      }
    }
    final q = _respQueue[pet.id] ?? const <MapEntry<String, String>>[];
    if (q.isEmpty) {
      if (_respActive[pet.id] ?? false) {
        _respActive[pet.id] = false;
        _finishResponsePhase(pet);
      } else if (pet.controlOwner == PetControlOwner.response &&
          !pet.moving) {
        // 8-15 05:1x 修复（用户：拖完小人闪着闪着就没了）：
        // 没绑定响应（队列空且从未激活）→ 归还控制权。否则
        // controlOwner 卡 response → 待机帧兜底(controlOwner!=response
        // 才播)被挡 → playIdle 帧播完 _player=null → 小人消失。
        // 放（无响应）与扔（飞行完落点检测后无响应）两条路径都覆盖；
        // 飞行中 !pet.moving 为 false → 不打断抛射。
        DebugLogger.log('桌宠',
            '${pet.name} 无绑定响应 → 归还控制权 auto');
        _finishResponsePhase(pet);
      }
      return;
    }
    if (!(_respActive[pet.id] ?? false)) {
      _respActive[pet.id] = true;
      pet.controlOwner = PetControlOwner.response;
      _playRespItem(pet, q.first);
      _respQueue[pet.id] = q.sublist(1);
      return;
    }
    // 上一个响应播完（回 idle 且没在移动）→ 播下一个 / 收尾
    if (pet.state == PetState.idle && !pet.moving) {
      final rest = _respQueue[pet.id] ?? const <MapEntry<String, String>>[];
      if (rest.isEmpty) {
        _respActive[pet.id] = false;
        _finishResponsePhase(pet);
      } else {
        _playRespItem(pet, rest.first);
        _respQueue[pet.id] = rest.sublist(1);
      }
    }
  }

  /// 响应阶段结束：恢复互动组参与 / 恢复被暂停的移动 / 回待机
  void _finishResponsePhase(Pet pet) {
    // 8-15 00:5x：用户还抓着（held）→ 控制权保持 user，不结束
    if (pet.held) return;
    pet.controlOwner = PetControlOwner.auto;
    final suspended = pet.suspendedMove;
    pet.suspendedMove = null;
    if (suspended != null && !suspended.finished) {
      final remaining = suspended.duration * (1 - suspended.progress);
      if (remaining > 0.05) {
        DebugLogger.log('桌宠',
            '${pet.name} 恢复移动 剩余 ${remaining.toStringAsFixed(1)}s');
        pet.moveTo(suspended.to,
            duration: remaining,
            ease: suspended.ease,
            jumpHeight: suspended.jumpHeight);
        return;
      }
    }
    pet.playIdle(_resolveIdleFrames(pet), fps: 4);
  }

  void _tickAutoAct(Pet pet, double dt) {
    // 8-14 23:2x（控制权）：只有 auto 拥有者才自主行动；
    // 用户操作（user/held）、状态响应（response）、互动组（interaction）都不抢
    if (pet.controlOwner != PetControlOwner.auto) return;
    if (pet.held) return;
    // 8-14 16:5x（用户：其他小人该干嘛干嘛）：只跳过正在演剧本的
    // 小人——互动组运行时没参与的小人照常自主行动
    final run = _groupRun;
    if (run != null && run.cast.contains(pet)) return;
    // 8-14 22:2x（GPT 方案：状态机 MOVE→DWELL→MOVE，动作完成驱动，
    // 不用固定 timer）：移动刚完成 → 设 1.5~3s 停留，再选下一动作
    final wasMoving = _wasMoving[pet.id] ?? false;
    if (wasMoving && !pet.moving) {
      _dwellLeft[pet.id] = 1.5 + _autoRand.nextDouble() * 1.5;
      DebugLogger.log('桌宠',
          '自主移动完成 → 停留 ${_dwellLeft[pet.id]!.toStringAsFixed(1)}s');
    }
    _wasMoving[pet.id] = pet.moving;
    // 停留中 → 递减等待（走到底后待一小会儿）
    final dwell = _dwellLeft[pet.id] ?? 0;
    if (dwell > 0) {
      _dwellLeft[pet.id] = dwell - dt;
      return;
    }
    // 正在移动/演动作 → 等完成（下一次动作由完成驱动，不是 timer 到点）
    if (pet.moving || pet.state != PetState.idle) return;
    // 8-14 15:4x：只挑自己角色的动作
    // 8-14 17:2x（用户：不要给我的小人设置我没做的动作）：
    // 只播该小人自己配的动作（profileId 匹配），排除内置动作
    // （walk/run/jump/spin/wave/happy...）和旧数据 null 共享——
    // 没配动作的小人就不自主做动作，安静待机
    final pool = _actionDefs.values
        .where((d) =>
            (d.kind == PetActionKind.inPlace ||
                d.kind == PetActionKind.moveTo) &&
            d.frameDir != null &&
            d.slotId == null &&
            d.profileId == pet.id &&
            PetBuiltinActions.byId(d.id) == null)
        .toList();
    if (pool.isEmpty) return;
    // 8-14 22:2x（GPT 方案：贴边处理）——选动作先算目标，走距 < 0.05
    // （当前方向已撞墙/没可移动距离）就换方向/换动作重试，最多 6 次；
    // 全贴边 → 短等 1.5s 再试，不播 0 距离动作（避免"走不动"）
    PetActionDef? picked;
    for (var attempt = 0; attempt < 6; attempt++) {
      final def = pool[_autoRand.nextInt(pool.length)];
      if (pet.position.distanceTo(_targetFor(pet, def)) >= 0.05) {
        picked = def;
        break;
      }
    }
    if (picked == null) {
      _dwellLeft[pet.id] = 1.5;
      return;
    }
    playAction(pet.id, picked.id);
  }

  /// 8-14 17:2x（用户：一刷新又跑屏幕中间去了——我设置了从输入框
  /// 某个位置开始动）：该小人的首选起点（第一个带起点的移动动作），
  /// 刷新后小人出现在配置的起点，而不是屏幕中间。
  PetPoint? preferredStart(String petId) {
    for (final d in _actionDefs.values) {
      if (d.slotId != null) continue;
      if (d.profileId != petId) continue;
      if (d.moveRef == null) continue;
      final isMove =
          d.kind == PetActionKind.moveTo ||
              (d.kind == PetActionKind.inPlace &&
                  (d.target != null || d.moveDir != null));
      if (!isMove) continue;
      return _moveBasePoint(d.moveRef, x: d.startX, y: d.startY);
    }
    return null;
  }

  /// idle 帧解析：用户上传的动作帧优先（8-14 15:0x 用户反馈——
  /// 聊天页显示内置粉色小人而不是自己的图），没有才用内置占位。
  /// 8-14 15:4x：按角色区分——先找该 pet 自己的动作（profileId 匹配），
  /// 再兼容旧数据（profileId=null 的共享动作），最后内置占位。
  List<String> _resolveIdleFrames(Pet pet) {
    // 8-14 17:2x（用户：默认的和我自己的角色没有分开，该分开分开）：
    // 只认 profileId == 自己的动作；旧数据 null 共享兜底取消——
    // 默认小人不会再用用户角色的图，用户小人也不会被默认覆盖。
    // 没配动作 → 单帧静态占位（不闪不乱动，安静待机）。
    for (final e in _frameCache.entries) {
      if (e.value.isEmpty) continue;
      final def = _actionDefs[e.key];
      if (def == null || def.frameDir == null || def.slotId != null) continue;
      if (def.profileId == pet.id) return e.value;
    }
    // 没配动作帧：有头像就显示头像（自己角色的样子，不撞脸默认小人）
    final av = pet.avatarPath;
    if (av != null && av.isNotEmpty) return [av];
    return const ['placeholder:idle:0:1'];
  }

  /// 预载入动作帧图（UI 层调用）
  Future<void> preloadFrames(String actionId) async {
    final list = await frames.framesFor(actionId);
    _frameCache[actionId] = list;
    final def = _actionDefs[actionId];
    if (def != null && list.isNotEmpty) {
      registerAction(def.copyWith(frameCount: list.length));
    }
  }

  /// 8-14 17:5x（用户：怕刷新不同步）——清空所有动作定义/帧缓存，
  /// 供 restore 全量重载：配置页新增/删除/修改动作后，聊天页同步生效
  void clearActions() {
    _actionDefs.clear();
    _activities.clear();
    _moveGroups.clear();
    _frameCache.clear();
  }

  /// 预载入所有已注册动作的帧图
  Future<void> preloadAllFrames() async {
    for (final id in _actionDefs.keys) {
      await preloadFrames(id);
    }
  }

  /// 说话（指定小人）
  void speak(String petId, String text) {
    petById(petId)?.speak(text);
  }

  /// 开始双人互动：两个小人贴在一起，同步播放双人帧组
  ///
  /// [duoActionId] 必须是 duo 类型动作（帧图里画了两个小人挨在一起）。
  /// 播完（非循环）自动分开；也可被 breakDuo 打断。
  bool startDuo(String petAId, String petBId, String duoActionId) {
    final a = petById(petAId);
    final b = petById(petBId);
    final def = _actionDefs[duoActionId];
    if (a == null || b == null || def == null || def.kind != PetActionKind.duo) {
      return false;
    }
    // 结束各自现有活动/互动
    a.stop();
    b.stop();
    // b 贴到 a 旁边（按 a 朝向左右贴）
    final dir = a.facing == PetFacing.right ? 1.0 : -1.0;
    b.position = b.clampToArea(
        PetPoint(a.position.x + dir * 0.13, a.position.y));
    // a 驱动共享帧（b 渲染时从 a 取帧）
    final frames = _resolveFramesSync(def.id);
    final player = PetAnimPlayer(
      frames: frames,
      fps: def.fps * def.speedTier.factor,
      loop: def.loop,
    );
    a._pair = b;
    b._pair = a;
    a._pairElapsed = 0;
    b._pairElapsed = 0;
    a._pairDuration = def.durationSeconds;
    b._pairDuration = def.durationSeconds;
    a._player = player;
    a.currentActionId = def.id;
    b.currentActionId = def.id;
    a.state = PetState.acting;
    b.state = PetState.acting;
    a._startTransition();
    // ignore: avoid_print
    print('桌宠: 双人互动开始 ${a.name} × ${b.name} = ${def.name}');
    return true;
  }

  /// 打断双人互动（用户拖走其中一个小人时调用）
  ///
  /// 被留下的那个小人播放自己配置的"被打断后动作"（breakActionId，
  /// 默认待机；用户可设为"难过"等）。
  void breakDuo(String petId) {
    final pet = petById(petId);
    if (pet == null || pet._pair == null) return;
    final partner = pet._pair!;
    pet._endPair();
    final bdef = _actionDefs[partner.breakActionId] ?? _actionDefs['idle']!;
    partner.playAction(bdef, _resolveFramesSync(bdef.id));
    // ignore: avoid_print
    print('桌宠: 双人互动被打断 ${partner.name} 播放 ${bdef.name}');
  }

  /// 设置小人的"被打断后动作"
  void setBreakAction(String petId, String actionId) {
    petById(petId)?.breakActionId = actionId;
  }
}

// ==================== 互动组运行器（多角色剧本） ====================
//
// 驱动一组 Pet 按剧本一步步演：
// - 每步开始：给每个坑播它动作库里的动作 + 按移动类型算目标点并 moveTo
// - 每步时长：自动取各坑动作时长最大值（最少 2.5s），或用手动时长
// - 帧/移动的逐帧推进仍由各 Pet 自己的 update() 完成，这里只管编排和计时
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
  final List<Pet> cast;

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
      // 8-14 23:2x：被用户抓住的演员跳过（互动组其他人照常演）
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

    // 各坑开演
    for (final slotStep in step.slotSteps) {
      final idx = _indexOfSlot(slotStep.slotId);
      if (idx < 0 || idx >= cast.length) continue;
      final pet = cast[idx];
      // 8-14 23:2x：被用户抓住的演员跳过本步（松手后下步自动恢复）
      if (pet.held || pet.controlOwner == PetControlOwner.user) {
        continue;
      }
      final def = slotStep.actionId != null
          ? actionResolver(slotStep.actionId!)
          : null;
      // 动作：有动作就播（循环帧播满整步）；没有就不动它现有的播放器
      if (def != null && slotStep.actionId != null) {
        pet.playAction(def, framesResolver(slotStep.actionId!));
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

  int _indexOfSlot(String slotId) {
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].slotId == slotId) return i;
    }
    return -1;
  }

  /// 搭档：两人组 = 对方；多人组 = 下一个坑（循环）
  Pet? _partnerOf(int idx) {
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
    if (_stepIndex >= def.steps.length) {
      _finished = true;
      // 散场：各小人回待机（留在当前位置）
      for (final pet in cast) {
        pet.stopMoving();
        pet.state = PetState.idle;
        pet.currentActionId = 'idle';
      }
    }
  }
}

extension PetSceneGroup on PetScene {
  /// 正在跑的互动组（null = 没有）
  PetGroupRun? get groupRun => _groupRun;

  /// 开始互动组：cast 与 def.slots 一一对应
  ///
  /// [slotActions] 每个坑的动作库（action_id → 定义），
  /// [slotFrames] 每个坑的动作帧（action_id → 帧列表）。
  PetGroupRun? startGroup(
    PetGroupDef def,
    List<Pet> cast,
    List<PetGroupSlot> slots, {
    required Map<String, PetActionDef> slotActions,
    required Map<String, List<String>> slotFrames,
  }) {
    if (cast.isEmpty || cast.length != slots.length) return null;
    // 记下开演前各自在播的单人动作（散场 resume 用），再纳入组编排
    for (final pet in cast) {
      final aid = pet.currentActionId;
      _preRunActions[pet.id] =
          (aid == null || aid == 'idle') ? null : aid;
      pet.stop();
      pet._activity = null;
    }
    final run = PetGroupRun(
      def: def,
      cast: cast,
      slots: slots,
      actionResolver: (id) => slotActions[id],
      framesResolver: (id) => slotFrames[id] ?? const [],
    );
    _groupRun = run;
    return run;
  }

  /// 停止互动组（打断）：各小人回待机
  void stopGroup() {
    final run = _groupRun;
    _groupRun = null;
    if (run == null) return;
    for (final pet in run.cast) {
      pet.stop();
    }
    for (final pet in run.cast) {
      _preRunActions.remove(pet.id);
    }
  }

  /// 暂停（提起来）：冻结剧本计时 + 停移动
  void pauseGroup() => _groupRun?.pause();

  /// 续播（放下）
  void resumeGroup() => _groupRun?.resume();
}
