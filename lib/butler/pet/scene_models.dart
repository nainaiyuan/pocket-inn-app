import 'pet_models.dart';

// ===== 8-15 02:2x 全屏场景模式 P0 数据模型（16 号冲刺安排） =====
// 纯新增：场景/节点/选项/热点四类实体。不碰现有桌宠任何逻辑。
// 关键：continueType 独立字段——模型不写死成"自动播放"，
// 10 种继续条件都能表达；waitUser 真阻塞标志。

/// 场景（2 楼 = 多场景，每个场景一张底图 + 节点 + 热点）
class PetScene {
  final String sceneId;
  final String name;
  final String? bgPath; // 底图（用户上传，可空 = 纯色占位）
  final int sortOrder;

  const PetScene({
    required this.sceneId,
    required this.name,
    this.bgPath,
    this.sortOrder = 0,
  });

  PetScene copyWith({String? name, String? bgPath, int? sortOrder}) =>
      PetScene(
        sceneId: sceneId,
        name: name ?? this.name,
        bgPath: bgPath ?? this.bgPath,
        sortOrder: sortOrder ?? this.sortOrder,
      );
}

/// 继续条件（10 种，第一版先实现部分，模型全支持）
enum PetContinueType {
  auto, // 自动继续
  click, // 点击屏幕任意处
  clickTarget, // 点击指定对象（content = 目标 id）
  choice, // 选择选项（choices 表）
  freeInput, // 自由输入（AI 节点）
  condition, // 条件达成（content = 条件 JSON）
  moveTo, // 角色移动到指定位置（content = 坐标）
  drag, // 拖动完成（content = 目标描述）
  timer, // 计时（content = 秒数）
  minigame; // 小游戏完成（content = 小游戏 id）

  static PetContinueType fromName(String? name) => PetContinueType.values
      .firstWhere((e) => e.name == name, orElse: () => PetContinueType.auto);
}

/// 节点类型：固定剧情 / AI 自由聊天 / 结束
enum PetNodeType {
  fixed, // 固定剧情（动作组 + 卡片 + 继续条件）
  ai, // AI 节点（AI 演出 + 自由输入）
  end; // 结束

  static PetNodeType fromName(String? name) =>
      PetNodeType.values.firstWhere((e) => e.name == name,
          orElse: () => PetNodeType.fixed);
}

/// 剧情节点（一个"动作组+卡片+继续条件"= 一个节点；串起来 = 剧情）
class PetNode {
  final String nodeId;
  final String sceneId;
  final int seq; // 场景内顺序
  final PetNodeType type;
  final PetContinueType continueType;

  /// 真阻塞：true 时场景引擎冻结推进，必须等用户完成指定操作
  final bool waitUser;

  /// 绑定内容（JSON）：
  /// - fixed：动作组/互动组 id + 卡片内容（文字/选项）
  /// - clickTarget：目标热点 id
  /// - moveTo：目标坐标 {x,y}
  /// - timer：秒数
  /// - condition：条件 JSON
  final String? content;

  /// 单出口继续条件的目标节点（auto/click/timer 等用；choice 走 choices 表）
  final String? targetNode;

  const PetNode({
    required this.nodeId,
    required this.sceneId,
    required this.seq,
    this.type = PetNodeType.fixed,
    this.continueType = PetContinueType.auto,
    this.waitUser = false,
    this.content,
    this.targetNode,
  });

  PetNode copyWith({
    int? seq,
    PetNodeType? type,
    PetContinueType? continueType,
    bool? waitUser,
    String? content,
    String? targetNode,
  }) =>
      PetNode(
        nodeId: nodeId,
        sceneId: sceneId,
        seq: seq ?? this.seq,
        type: type ?? this.type,
        continueType: continueType ?? this.continueType,
        waitUser: waitUser ?? this.waitUser,
        content: content ?? this.content,
        targetNode: targetNode ?? this.targetNode,
      );
}

/// 选项（choice 节点的分支：点选项 → 进入 targetNode）
class PetChoice {
  final String choiceId;
  final String nodeId;
  final int seq;
  final String label; // 按钮文字（如"推开他/抱住他/转头离开"）
  final String targetNode; // 指向下一节点

  const PetChoice({
    required this.choiceId,
    required this.nodeId,
    required this.seq,
    required this.label,
    required this.targetNode,
  });
}

/// 热点形态（统一模型：一个模型四种形态）
enum PetHotspotType {
  point, // 文游的"点"（可挂角色 / 固定屏幕），点击触发
  area, // 活动区域（矩形，不占满屏），角色进入触发
  furniture, // 家具（床/桌/椅素材，固定位），走到附近点击/自动
  item; // 道具，用户拖到角色身上触发（投喂）

  static PetHotspotType fromName(String? name) =>
      PetHotspotType.values.firstWhere((e) => e.name == name,
          orElse: () => PetHotspotType.point);
}

/// 热点触发方式
enum PetHotspotTrigger {
  click, // 点击
  enter, // 角色进入区域
  drop; // 拖放（道具投喂）

  static PetHotspotTrigger fromName(String? name) =>
      PetHotspotTrigger.values.firstWhere((e) => e.name == name,
          orElse: () => PetHotspotTrigger.click);
}

/// 热点（触发器 → 条件 → 绑定内容 → 执行；事件来源统一入口）
class PetHotspot {
  final String hotspotId;
  final String sceneId;
  final PetHotspotType type;
  final PetHotspotTrigger trigger;

  /// 挂角色（point 型可跟角色动；null = 固定屏幕）
  final String? petId;

  /// 位置/区域（相对坐标 0~1；point 用 x,y + size；area 用 x,y,w,h）
  final double x;
  final double y;
  final double w;
  final double h;

  /// 绑定内容类型：action(单动作) / activity(组合) / group(互动组) / node(剧情节点)
  final String bindingType;
  final String bindingId;

  const PetHotspot({
    required this.hotspotId,
    required this.sceneId,
    this.type = PetHotspotType.point,
    this.trigger = PetHotspotTrigger.click,
    this.petId,
    this.x = 0.5,
    this.y = 0.5,
    this.w = 0.1,
    this.h = 0.1,
    required this.bindingType,
    required this.bindingId,
  });

  PetHotspot copyWith({
    PetHotspotType? type,
    PetHotspotTrigger? trigger,
    String? petId,
    double? x,
    double? y,
    double? w,
    double? h,
    String? bindingType,
    String? bindingId,
  }) =>
      PetHotspot(
        hotspotId: hotspotId,
        sceneId: sceneId,
        type: type ?? this.type,
        trigger: trigger ?? this.trigger,
        petId: petId ?? this.petId,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        bindingType: bindingType ?? this.bindingType,
        bindingId: bindingId ?? this.bindingId,
      );
}
