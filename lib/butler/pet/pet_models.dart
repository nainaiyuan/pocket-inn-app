/// 桌宠模块 — 数据模型
///
/// 全部是纯 Dart 模型，不依赖 Flutter UI，本地可单测。
/// 设计原则：
/// - 坐标用相对坐标（0~1，按屏幕宽高比例），适配任何屏幕
/// - 动作 = 帧图目录 + 播放参数；帧数由引擎扫描自动得到，用户零配置
/// - 组合动作 = 动作的有序序列，支持时长/重复/说话/移动/转头
library;

import 'dart:convert';
import 'dart:math' as math;

/// 动作种类
enum PetActionKind {
  /// 原地动作：纯帧动画（待机/跳/转圈/挥手/开心…）
  inPlace,

  /// 移动到目标位置（播放移动帧 + 位置插值 + 朝向翻转）
  moveTo,

  /// 转头：翻转朝向（原地）
  turn,

  /// 预设行为：爬屏幕、跳下来等（引擎内置逻辑）
  behavior,

  /// 双人互动：帧图里画了两个小人挨在一起，两个小人贴在一起同步播放
  duo,
}

/// 位移轨迹（动作/移动步骤带目标点时，怎么过去）
enum PetMoveTrajectory {
  walk('走过去', '直线匀速走'),
  jump('跳过去', '抛物线跳过去'),
  fly('飞过去', '平滑曲线飘过去');

  final String label;
  final String hint;
  const PetMoveTrajectory(this.label, this.hint);

  static PetMoveTrajectory? fromName(String? name) => switch (name) {
        'walk' => PetMoveTrajectory.walk,
        'jump' => PetMoveTrajectory.jump,
        'fly' => PetMoveTrajectory.fly,
        _ => null,
      };
}

/// 移动方向（组合动作里的方向移动步骤用，8 方向含斜角）
/// 移动起点：动作从哪个基准位置开始动（上下左右是最大移动距离）
/// dock/center 只是预设快捷项，用户可自己定起点（custom + startX/startY）
enum PetMoveRef {
  /// 预设1：从聊天框（手机底部）位置出发，聊天框弹起就当底部基准
  dock('聊天框'),

  /// 预设2：从屏幕中间位置出发
  center('屏幕中间'),

  /// 用户自定义起点（startX/startY 屏幕相对坐标）
  custom('自定义');

  final String label;
  const PetMoveRef(this.label);

  static PetMoveRef fromName(String? name) => switch (name) {
        'center' => PetMoveRef.center,
        'custom' => PetMoveRef.custom,
        // 老数据 self/hero/未知 都回退聊天框基准
        _ => PetMoveRef.dock,
      };

  /// 基准点：方向+距离 的起点（dock=聊天框 / center=屏幕中间 / custom=自定义坐标）
  static PetPoint basePoint(PetMoveRef ref, {double? x, double? y}) =>
      switch (ref) {
        PetMoveRef.dock => const PetPoint(0.5, 0.85),
        PetMoveRef.center => const PetPoint(0.5, 0.5),
        PetMoveRef.custom => PetPoint(x ?? 0.5, y ?? 0.5),
      };
}

enum PetMoveDir {
  up,
  down,
  left,
  right,
  upLeft,
  upRight,
  downLeft,
  downRight;

  static PetMoveDir? fromName(String? name) => switch (name) {
        'up' => PetMoveDir.up,
        'down' => PetMoveDir.down,
        'left' => PetMoveDir.left,
        'right' => PetMoveDir.right,
        'upLeft' => PetMoveDir.upLeft,
        'upRight' => PetMoveDir.upRight,
        'downLeft' => PetMoveDir.downLeft,
        'downRight' => PetMoveDir.downRight,
        _ => null,
      };

  String get label => switch (this) {
        PetMoveDir.up => '向上',
        PetMoveDir.down => '向下',
        PetMoveDir.left => '向左',
        PetMoveDir.right => '向右',
        PetMoveDir.upLeft => '左上',
        PetMoveDir.upRight => '右上',
        PetMoveDir.downLeft => '左下',
        PetMoveDir.downRight => '右下',
      };

  /// 方向单位向量（x, y），斜向已归一化
  (double, double) get vector => switch (this) {
        PetMoveDir.up => (0, -1),
        PetMoveDir.down => (0, 1),
        PetMoveDir.left => (-1, 0),
        PetMoveDir.right => (1, 0),
        PetMoveDir.upLeft => (-0.7071, -0.7071),
        PetMoveDir.upRight => (0.7071, -0.7071),
        PetMoveDir.downLeft => (-0.7071, 0.7071),
        PetMoveDir.downRight => (0.7071, 0.7071),
      };
}

/// 速度档（用户配置：慢/正常/快）
/// factor 为倍率：影响帧率与观感速度
enum PetSpeedTier {
  slow(0.6),
  normal(1.0),
  fast(1.6);

  final double factor;
  const PetSpeedTier(this.factor);

  String get label => switch (this) {
        PetSpeedTier.slow => '慢',
        PetSpeedTier.normal => '正常',
        PetSpeedTier.fast => '快',
      };

  static PetSpeedTier fromName(String? name) => switch (name) {
        'slow' => PetSpeedTier.slow,
        'fast' => PetSpeedTier.fast,
        _ => PetSpeedTier.normal,
      };
}

/// 预设行为（引擎内置逻辑，无需帧图）
enum PetBehavior {
  /// 爬屏幕：沿屏幕边缘爬到顶部
  climb,

  /// 从屏幕跳下来：抛物线跳出屏幕底部，再自动回到原位
  jumpOff;

  static PetBehavior? fromName(String? name) => switch (name) {
        'climb' => PetBehavior.climb,
        'jumpOff' => PetBehavior.jumpOff,
        _ => null,
      };
}

/// 小人活动区域
enum PetArea {
  /// 满屏跑
  full,

  /// 只在输入框上方区域（屏幕下半部）
  bottom,

  /// 固定在某个位置
  fixed;

  static PetArea fromName(String? name) => switch (name) {
        'bottom' => PetArea.bottom,
        'fixed' => PetArea.fixed,
        _ => PetArea.full,
      };
}

/// 移动动画组：把"走""跑"绑成一组，系统按移动速度自动切换
class PetMoveGroupDef {
  final String id;
  final String name;

  /// 走（慢速用）
  final String walkActionId;

  /// 跑（快速用），null = 只有走
  final String? runActionId;

  const PetMoveGroupDef({
    required this.id,
    required this.name,
    required this.walkActionId,
    this.runActionId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'walkActionId': walkActionId,
        'runActionId': runActionId,
      };

  factory PetMoveGroupDef.fromJson(Map<String, dynamic> json) =>
      PetMoveGroupDef(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        walkActionId: json['walkActionId'] as String? ?? 'walk',
        runActionId: json['runActionId'] as String?,
      );
}

/// 动画循环方式
enum PetAnimLoop {
  /// 循环播放
  loop,

  /// 播完即止
  once,

  /// 来回播放（正播→倒播）
  pingpong,
}

/// 命名位置（屏幕相对坐标 0~1）
enum PetSpot {
  center, // 屏幕中间 (0.5, 0.5)
  leftThird, // 左 1/3 处
  rightThird, // 右 1/3 处（2/3 位置）
  topThird, // 上 1/3 处
  bottomThird, // 下 1/3 处（2/3 位置）
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// 命名位置 → 相对坐标
extension PetSpotPosition on PetSpot {
  double x() {
    switch (this) {
      case PetSpot.center:
        return 0.5;
      case PetSpot.leftThird:
        return 1 / 3;
      case PetSpot.rightThird:
        return 2 / 3;
      case PetSpot.topThird:
        return 0.5;
      case PetSpot.bottomThird:
        return 0.5;
      case PetSpot.topLeft:
        return 0.15;
      case PetSpot.topRight:
        return 0.85;
      case PetSpot.bottomLeft:
        return 0.15;
      case PetSpot.bottomRight:
        return 0.85;
    }
  }

  double y() {
    switch (this) {
      case PetSpot.center:
        return 0.5;
      case PetSpot.leftThird:
        return 0.5;
      case PetSpot.rightThird:
        return 0.5;
      case PetSpot.topThird:
        return 1 / 3;
      case PetSpot.bottomThird:
        return 2 / 3;
      case PetSpot.topLeft:
        return 0.2;
      case PetSpot.topRight:
        return 0.2;
      case PetSpot.bottomLeft:
        return 0.8;
      case PetSpot.bottomRight:
        return 0.8;
    }
  }
}

/// 相对坐标点（0~1，屏幕宽高比例）
class PetPoint {
  final double x;
  final double y;

  const PetPoint(this.x, this.y);

  static const origin = PetPoint(0, 0);

  PetPoint lerp(PetPoint other, double t) =>
      PetPoint(x + (other.x - x) * t, y + (other.y - y) * t);

  double distanceTo(PetPoint other) {
    final dx = other.x - x;
    final dy = other.y - y;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  bool operator ==(Object other) =>
      other is PetPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'PetPoint($x, $y)';
}

/// 朝向
enum PetFacing { left, right }

/// 动作定义（内置模板 + 用户自建，统一形状）
class PetActionDef {
  final String id;
  final String name;
  final PetActionKind kind;

  /// 播放帧率（默认 10）
  final double fps;

  /// 循环方式
  final PetAnimLoop loop;

  /// 帧图目录名（相对 pet/animations/），null = 无帧图（如 turn 可用内置翻转）
  final String? frameDir;

  /// 所属互动组坑位 id（null = 单人自己的动作；非 null = 互动组里某个坑的动作库）
  final String? slotId;

  /// 所属角色 id（8-14 15:4x：区分"我的小人"和"初始小人"的图——
  /// 单人动作按角色归属，互动组坑动作 null = 共享）
  final String? profileId;

  /// 该动作当前实际帧数（由引擎扫描自动得到，0 = 用户还没放图）
  final int frameCount;

  /// 移动动作播放的移动帧动作 id（默认 walk）
  final String moveAnimId;

  /// 移动目标：命名位置
  final PetSpot? targetSpot;

  /// 移动目标：自定义坐标（相对 0~1）
  final double? targetX;
  final double? targetY;

  /// 相对位移：朝方向走 moveDist（屏幕百分比 0~1），从当前位置出发
  final PetMoveDir? moveDir;
  final double? moveDist;
  final double? moveSec;

  /// 移动起点基准：dock/center 预设 / custom 自定义
  final PetMoveRef moveRef;

  /// 自定义起点坐标（moveRef == custom 时生效，屏幕相对坐标 0~1）
  final double? startX;
  final double? startY;

  /// 位移轨迹（带 target 时怎么过去：走/跳/飞）
  final PetMoveTrajectory trajectory;

  /// 移动耗时（秒），默认 3
  final double moveDurationSec;

  /// 速度档（用户配置：慢/正常/快），影响帧率与观感
  final PetSpeedTier speedTier;

  /// 移动组 id（moveTo 用；null = 默认走+跑组）
  final String? moveGroupId;

  /// 这组帧播几秒（用户导入时填；fps 由 帧数/秒数 算出来）
  /// duo 类型：两个小人挨在一起播几秒（默认互动时长）
  final double durationSeconds;

  const PetActionDef({
    required this.id,
    required this.name,
    this.kind = PetActionKind.inPlace,
    this.fps = 10,
    this.loop = PetAnimLoop.loop,
    this.frameDir,
    this.slotId,
    this.profileId,
    this.frameCount = 0,
    this.moveAnimId = 'walk',
    this.targetSpot,
    this.targetX,
    this.targetY,
    this.moveDir,
    this.moveDist,
    this.moveSec,
    this.moveRef = PetMoveRef.dock,
    this.startX,
    this.startY,
    this.trajectory = PetMoveTrajectory.walk,
    this.moveDurationSec = 3,
    this.speedTier = PetSpeedTier.normal,
    this.moveGroupId,
    this.durationSeconds = 1,
  });

  PetActionDef copyWith({int? frameCount, PetSpeedTier? speedTier}) =>
      PetActionDef(
        id: id,
        name: name,
        kind: kind,
        fps: fps,
        loop: loop,
        frameDir: frameDir,
        frameCount: frameCount ?? this.frameCount,
        // 8-14 19:2x（用户：播完恢复3:4图）：copyWith 必须保留归属字段——
        // preloadFrames 用 copyWith(frameCount) 更新帧数时若丢掉
        // profileId/slotId → _actionDefs 里的动作变无主 →
        // idle 匹配/自主行动 pool 全部失效（头像兜底）
        profileId: profileId,
        slotId: slotId,
        moveAnimId: moveAnimId,
        targetSpot: targetSpot,
        targetX: targetX,
        targetY: targetY,
        moveRef: moveRef,
        startX: startX,
        startY: startY,
        moveDurationSec: moveDurationSec,
        speedTier: speedTier ?? this.speedTier,
        moveGroupId: moveGroupId,
        durationSeconds: durationSeconds,
      );

  /// 目标点（moveTo 用）；null = 未指定
  PetPoint? get target {
    if (targetSpot != null) return PetPoint(targetSpot!.x(), targetSpot!.y());
    if (targetX != null && targetY != null) {
      return PetPoint(targetX!, targetY!);
    }
    return null;
  }

  /// 用户是否已提供帧图
  bool get hasFrames => frameCount > 0;
}

/// 内置动作模板库
class PetBuiltinActions {
  static const List<PetActionDef> all = [
    PetActionDef(
      id: 'idle',
      name: '待机',
      kind: PetActionKind.inPlace,
      fps: 8,
      loop: PetAnimLoop.loop,
      frameDir: 'idle',
    ),
    PetActionDef(
      id: 'walk',
      name: '走路',
      kind: PetActionKind.inPlace,
      fps: 10,
      loop: PetAnimLoop.loop,
      frameDir: 'walk',
    ),
    PetActionDef(
      id: 'run',
      name: '跑',
      kind: PetActionKind.inPlace,
      fps: 14,
      loop: PetAnimLoop.loop,
      frameDir: 'run',
    ),
    PetActionDef(
      id: 'jump',
      name: '跳',
      kind: PetActionKind.inPlace,
      fps: 12,
      loop: PetAnimLoop.once,
      frameDir: 'jump',
    ),
    PetActionDef(
      id: 'spin',
      name: '转圈',
      kind: PetActionKind.inPlace,
      fps: 15,
      loop: PetAnimLoop.loop,
      frameDir: 'spin',
    ),
    PetActionDef(
      id: 'wave',
      name: '挥手',
      kind: PetActionKind.inPlace,
      fps: 10,
      loop: PetAnimLoop.once,
      frameDir: 'wave',
    ),
    PetActionDef(
      id: 'happy',
      name: '开心',
      kind: PetActionKind.inPlace,
      fps: 10,
      loop: PetAnimLoop.loop,
      frameDir: 'happy',
    ),
    PetActionDef(
      id: 'turn',
      name: '转头',
      kind: PetActionKind.turn,
      fps: 6,
      loop: PetAnimLoop.once,
      frameDir: 'turn',
    ),
    // 预设行为（引擎内置逻辑，无需帧图）
    PetActionDef(
      id: 'climb',
      name: '爬屏幕',
      kind: PetActionKind.behavior,
      fps: 8,
      loop: PetAnimLoop.loop,
    ),
    PetActionDef(
      id: 'jumpOff',
      name: '跳下来',
      kind: PetActionKind.behavior,
      fps: 10,
      loop: PetAnimLoop.once,
    ),
  ];

  static PetActionDef? byId(String id) {
    for (final a in all) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// 组合动作 — 步骤
class PetActivityStep {
  /// 动作 id；'speak' = 说话步骤
  final String actionId;

  /// 持续秒数（null = 动作播完为止）
  final double? durationSec;

  /// 重复次数（null = 1）
  final int? repeat;

  /// 说话步骤的文字
  final String? text;

  /// 移动目标：命名位置
  final PetSpot? targetSpot;

  /// 移动目标：自定义坐标
  final double? targetX;
  final double? targetY;

  /// 到达后转头往回走
  final bool turnBack;

  /// 方向移动：朝某方向走（8 方向），null = 非方向移动步骤
  final PetMoveDir? moveDir;

  /// 方向移动持续秒数（null = 按距离/速度自动算）
  final double? moveSec;

  /// 方向移动距离（屏幕百分比 0~1，相对当前位置；null = 按秒数走）
  final double? moveDist;

  /// 方向移动：一直走到撞墙/屏幕边才停下（忽略 moveSec）
  final bool moveUntilWall;

  /// 位移轨迹（带 target 时：怎么过去）
  final PetMoveTrajectory trajectory;

  const PetActivityStep({
    required this.actionId,
    this.durationSec,
    this.repeat,
    this.text,
    this.targetSpot,
    this.targetX,
    this.targetY,
    this.turnBack = false,
    this.moveDir,
    this.moveSec,
    this.moveDist,
    this.moveUntilWall = false,
    this.trajectory = PetMoveTrajectory.walk,
  });

  bool get isSpeak => actionId == 'speak';

  /// 是否方向移动步骤（朝某个方向走几秒/走到撞墙）
  bool get isMoveDir => moveDir != null;

  PetPoint? get target {
    if (targetSpot != null) return PetPoint(targetSpot!.x(), targetSpot!.y());
    if (targetX != null && targetY != null) {
      return PetPoint(targetX!, targetY!);
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'actionId': actionId,
        if (durationSec != null) 'durationSec': durationSec,
        if (repeat != null) 'repeat': repeat,
        if (text != null) 'text': text,
        if (targetSpot != null) 'targetSpot': targetSpot!.name,
        if (targetX != null) 'targetX': targetX,
        if (targetY != null) 'targetY': targetY,
        'turnBack': turnBack,
        if (moveDir != null) 'moveDir': moveDir!.name,
        if (moveDir != null) 'moveSec': moveSec,
        if (moveDir != null) 'moveDist': moveDist,
        if (moveDir != null) 'moveUntilWall': moveUntilWall,
        if (trajectory != PetMoveTrajectory.walk) 'trajectory': trajectory.name,
      };

  factory PetActivityStep.fromJson(Map<String, dynamic> json) =>
      PetActivityStep(
        actionId: json['actionId'] as String,
        durationSec: (json['durationSec'] as num?)?.toDouble(),
        repeat: json['repeat'] as int?,
        text: json['text'] as String?,
        targetSpot: json['targetSpot'] != null
            ? PetSpot.values.byName(json['targetSpot'] as String)
            : null,
        targetX: (json['targetX'] as num?)?.toDouble(),
        targetY: (json['targetY'] as num?)?.toDouble(),
        turnBack: json['turnBack'] as bool? ?? false,
        moveDir: PetMoveDir.fromName(json['moveDir'] as String?),
        moveSec: (json['moveSec'] as num?)?.toDouble() ?? 2,
        moveDist: (json['moveDist'] as num?)?.toDouble(),
        moveUntilWall: json['moveUntilWall'] as bool? ?? false,
        trajectory:
            PetMoveTrajectory.fromName(json['trajectory'] as String?) ??
                PetMoveTrajectory.walk,
      );
}

/// 组合动作 — 定义
class PetActivityDef {
  final String id;
  final String name;
  final List<PetActivityStep> steps;

  /// 初始位置：动作开始时小人先瞬移到这个基准点再走路径
  /// null = 从当前位置开始
  final PetMoveRef? startRef;

  /// 自定义起点坐标（startRef == custom 时生效）
  final double? startX;
  final double? startY;

  const PetActivityDef({
    required this.id,
    required this.name,
    required this.steps,
    this.startRef,
    this.startX,
    this.startY,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (startRef != null) 'startRef': startRef!.name,
        if (startX != null) 'startX': startX,
        if (startY != null) 'startY': startY,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory PetActivityDef.fromJson(Map<String, dynamic> json) =>
      PetActivityDef(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        startRef: json['startRef'] != null
            ? PetMoveRef.fromName(json['startRef'] as String?)
            : null,
        startX: (json['startX'] as num?)?.toDouble(),
        startY: (json['startY'] as num?)?.toDouble(),
        steps: (json['steps'] as List<dynamic>? ?? [])
            .map((e) => PetActivityStep.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 互动事件类型
enum PetInteractionType {
  /// 点击小人
  tap,

  /// 拖动小人
  drag,

  /// 抚摸（长按/轻抚）
  pet,

  /// 投喂
  feed,
}

/// 互动事件 — 男主"看得见"的关键
///
/// 用户对小人做的每件事都变成事件流进管家，
/// 男主由此感知：用户在戳它、在喂它、是开心还是烦躁。
class PetInteractionEvent {
  final PetInteractionType type;
  final String petId;

  /// 强度 0~1：拖得快 = 兴奋，轻轻摸 = 温柔，重击 = 烦躁
  final double intensity;

  /// 事件位置（相对坐标，可空）
  final double? x;
  final double? y;

  final DateTime time;

  /// 投喂相关
  final String? feedItemId;
  final int affectionDelta;

  PetInteractionEvent({
    required this.type,
    required this.petId,
    this.intensity = 0.5,
    this.x,
    this.y,
    DateTime? time,
    this.feedItemId,
    this.affectionDelta = 0,
  }) : time = time ?? DateTime.now();

  /// 人话摘要（进管家上下文用）
  String get summary {
    final who = '小人「$petId」';
    switch (type) {
      case PetInteractionType.tap:
        return '用户点击了$who（力度 ${(intensity * 100).round()}）';
      case PetInteractionType.drag:
        return '用户拖动$who（速度 ${(intensity * 100).round()}）';
      case PetInteractionType.pet:
        return '用户抚摸$who（温柔度 ${(intensity * 100).round()}）';
      case PetInteractionType.feed:
        return '用户投喂$who ${feedItemId ?? ''}，好感度+$affectionDelta';
    }
  }
}

/// 食物（投喂用）
class PetFeedItem {
  final String id;
  final String name;
  final String emoji;

  /// 好感度增量
  final int value;

  const PetFeedItem({
    required this.id,
    required this.name,
    required this.emoji,
    required this.value,
  });
}

/// 内置食物库
class PetBuiltinFoods {
  static const fish = PetFeedItem(id: 'fish', name: '小鱼干', emoji: '🐟', value: 2);
  static const cake = PetFeedItem(id: 'cake', name: '小蛋糕', emoji: '🍰', value: 3);
  static const candy = PetFeedItem(id: 'candy', name: '糖果', emoji: '🍬', value: 1);
  static const milk = PetFeedItem(id: 'milk', name: '牛奶', emoji: '🥛', value: 2);
  static const heart = PetFeedItem(id: 'heart', name: '爱心', emoji: '💖', value: 5);

  static const List<PetFeedItem> all = [fish, cake, candy, milk, heart];

  static PetFeedItem? byId(String id) {
    for (final f in all) {
      if (f.id == id) return f;
    }
    return null;
  }
}

/// 宠物档案（持久化）
class PetProfile {
  final String petId;
  String name;

  /// 好感度（本地存储，男主可知）
  int affection;

  /// 显示大小（相对基准的倍数）
  double scale;

  /// 是否在陪伴页显示（用户可在右页多选开关）
  bool visible;

  /// 活动区域（满屏 / 输入框上方 / 固定位置）
  PetArea area;

  /// area == fixed 时的固定坐标（相对 0~1）
  double? fixedX;
  double? fixedY;

  /// 双人互动被打断后，这个小人的动作 id（默认待机）
  /// 比如互动时被拉开，男主演"难过"（用户可换成自己画的帧组）
  String breakActionId;

  /// 头像图路径（大类框/聊天页显示缩略图；null = 用第一个动作的第一帧）
  String? avatarPath;

  PetProfile({
    required this.petId,
    required this.name,
    this.affection = 0,
    this.scale = 1.0,
    this.visible = true,
    this.area = PetArea.full,
    this.fixedX,
    this.fixedY,
    this.breakActionId = 'idle',
    this.avatarPath,
  });

  Map<String, dynamic> toJson() => {
        'petId': petId,
        'name': name,
        'affection': affection,
        'scale': scale,
        'visible': visible,
        'area': area.name,
        'fixedX': fixedX,
        'fixedY': fixedY,
        'breakActionId': breakActionId,
        'avatarPath': avatarPath,
      };

  factory PetProfile.fromJson(Map<String, dynamic> json) => PetProfile(
        petId: json['petId'] as String,
        name: json['name'] as String? ?? '',
        affection: json['affection'] as int? ?? 0,
        scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
        visible: json['visible'] as bool? ?? true,
        area: PetArea.fromName(json['area'] as String?),
        fixedX: (json['fixedX'] as num?)?.toDouble(),
        fixedY: (json['fixedY'] as num?)?.toDouble(),
        breakActionId: json['breakActionId'] as String? ?? 'idle',
        avatarPath: json['avatarPath'] as String?,
      );

  PetProfile copyWith({
    String? name,
    int? affection,
    double? scale,
    bool? visible,
    PetArea? area,
    double? fixedX,
    double? fixedY,
    String? breakActionId,
    String? avatarPath,
  }) =>
      PetProfile(
        petId: petId,
        name: name ?? this.name,
        affection: affection ?? this.affection,
        scale: scale ?? this.scale,
        visible: visible ?? this.visible,
        area: area ?? this.area,
        fixedX: fixedX ?? this.fixedX,
        fixedY: fixedY ?? this.fixedY,
        breakActionId: breakActionId ?? this.breakActionId,
        avatarPath: avatarPath ?? this.avatarPath,
      );
}

/// 双人互动配置：哪两个小人 + 用哪段互动动作
class PetDuoConfig {
  final String pairId;
  final String petA;
  final String petB;
  final String actionId;

  const PetDuoConfig({
    required this.pairId,
    required this.petA,
    required this.petB,
    required this.actionId,
  });

  bool matches(String a, String b) =>
      (petA == a && petB == b) || (petA == b && petB == a);
}

// ==================== 互动组（多角色剧本） ====================
//
// 互动组 = 角色坑 × 剧本
// - 坑：想几个人就几个坑，每个坑有自己的动作库（帧图），绑定单人仅用于显示名字
// - 剧本：一步步排，每步给每个坑指派"播哪个动作 + 怎么动"
// - 移动类型：stay 原地 / dir 上下左右 / spot 到某位置 / approach 靠近对方 /
//   leave 离开对方 / wall 走到碰墙
// - 所有坐标都是 0~1 相对值，换设备通用

/// 互动组里一个坑（一个角色）
class PetGroupSlot {
  final String slotId;
  final int index;

  /// 绑定单人（仅区分显示用，不参与播放）
  final String? bindPetId;

  /// 坑的名字（默认"左半边"/"右半边"）
  final String label;

  /// 组内初始摆位（相对 0~1）
  final double x;
  final double y;

  const PetGroupSlot({
    required this.slotId,
    required this.index,
    this.bindPetId,
    this.label = '',
    this.x = 0.5,
    this.y = 0.6,
  });

  Map<String, dynamic> toJson() => {
        's': slotId,
        'i': index,
        'p': bindPetId,
        'l': label,
        'x': x,
        'y': y,
      };

  static PetGroupSlot fromJson(Map<String, dynamic> j) => PetGroupSlot(
        slotId: j['s'] as String,
        index: (j['i'] as num?)?.toInt() ?? 0,
        bindPetId: j['p'] as String?,
        label: j['l'] as String? ?? '',
        x: (j['x'] as num?)?.toDouble() ?? 0.5,
        y: (j['y'] as num?)?.toDouble() ?? 0.6,
      );
}

/// 剧本里某个坑的移动方式
enum PetGroupMoveType {
  stay('原地', '就在原地播'),
  dir('方向+距离', '朝方向走一段'),
  spot('到某个位置', '走到地图上某个点'),
  approach('靠近对方', '走到挨着对方'),
  leave('离开对方', '往反方向拉开'),
  wall('走到碰墙', '一直走到屏幕边');

  final String label;
  final String hint;
  const PetGroupMoveType(this.label, this.hint);

  static PetGroupMoveType fromName(String? n) => values.firstWhere(
      (v) => v.name == n,
      orElse: () => PetGroupMoveType.stay);
}

/// 剧本一步里，一个坑的任务：播哪个动作 + 怎么动
class PetSlotStep {
  final String slotId;

  /// 播这个坑动作库里的哪个动作 id
  final String? actionId;

  final PetGroupMoveType moveType;
  final PetMoveDir? moveDir;
  final double? moveDist;
  final double? targetX;
  final double? targetY;

  const PetSlotStep({
    required this.slotId,
    this.actionId,
    this.moveType = PetGroupMoveType.stay,
    this.moveDir,
    this.moveDist,
    this.targetX,
    this.targetY,
  });

  Map<String, dynamic> toJson() => {
        's': slotId,
        'a': actionId,
        'm': moveType.name,
        'd': moveDir?.name,
        'dist': moveDist,
        'x': targetX,
        'y': targetY,
      };

  static PetSlotStep fromJson(Map<String, dynamic> j) => PetSlotStep(
        slotId: j['s'] as String,
        actionId: j['a'] as String?,
        moveType: PetGroupMoveType.fromName(j['m'] as String?),
        moveDir: PetMoveDir.fromName(j['d'] as String?),
        moveDist: (j['dist'] as num?)?.toDouble(),
        targetX: (j['x'] as num?)?.toDouble(),
        targetY: (j['y'] as num?)?.toDouble(),
      );
}

/// 剧本一步：所有坑同时执行各自的任务
class PetGroupStep {
  final List<PetSlotStep> slotSteps;

  /// 手动时长（秒，null = 自动：取各坑动作时长最大值，最少 2.5s）
  final double? duration;

  const PetGroupStep(this.slotSteps, {this.duration});

  Map<String, dynamic> toJson() => {
        'slots': slotSteps.map((e) => e.toJson()).toList(),
        if (duration != null) 'duration': duration,
      };

  static PetGroupStep fromJson(Map<String, dynamic> j) => PetGroupStep(
        ((j['slots'] as List?) ?? const [])
            .map((e) => PetSlotStep.fromJson(e as Map<String, dynamic>))
            .toList(),
        duration: (j['duration'] as num?)?.toDouble(),
      );
}

/// 互动组定义
class PetGroupDef {
  final String id;
  final String name;

  /// 距离触发阈值（0~1，null = 不用距离自动触发）
  final double? triggerDist;

  /// 散场方式：idle 回待机 / resume 接着刚才的单人动作
  final String exitMode;

  final List<PetGroupSlot> slots;
  final List<PetGroupStep> steps;
  final String updatedAt;

  const PetGroupDef({
    required this.id,
    required this.name,
    this.triggerDist,
    this.exitMode = 'idle',
    this.slots = const [],
    this.steps = const [],
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'group_id': id,
        'name': name,
        'trigger_dist': triggerDist,
        'exit_mode': exitMode,
        'slots_json': jsonEncode(slots.map((e) => e.toJson()).toList()),
        'steps_json': jsonEncode(steps.map((e) => e.toJson()).toList()),
        'updated_at': updatedAt,
      };

  static PetGroupDef fromJson(Map<String, dynamic> j) => PetGroupDef(
        id: j['group_id'] as String,
        name: j['name'] as String? ?? '',
        triggerDist: (j['trigger_dist'] as num?)?.toDouble(),
        exitMode: j['exit_mode'] as String? ?? 'idle',
        slots: ((j['slots_json'] as String?) ?? '[]').isEmpty
            ? const []
            : (jsonDecode(j['slots_json'] as String) as List)
                .map((e) => PetGroupSlot.fromJson(e as Map<String, dynamic>))
                .toList(),
        steps: ((j['steps_json'] as String?) ?? '[]').isEmpty
            ? const []
            : (jsonDecode(j['steps_json'] as String) as List)
                .map((e) => PetGroupStep.fromJson(e as Map<String, dynamic>))
                .toList(),
        updatedAt: j['updated_at'] as String? ?? '',
      );
}
