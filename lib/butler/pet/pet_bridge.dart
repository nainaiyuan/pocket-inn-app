import '../../utils/debug_logger.dart';
import '../skills/butler_skill.dart';
import '../skills/butler_skill_registry.dart';
import '../tools/butler_tool.dart';
import '../tools/butler_tool_registry.dart';
import 'pet.dart';
import 'pet_models.dart';

/// 桌宠桥：聊天页（男主）↔ 陪伴页（桌宠世界）
///
/// 男主在聊天里下指令（"去跳个舞""爬屏幕"）→ PetActionTool 收到 →
/// 排进队列；陪伴页打开时 PetBridge.attach(world) 立即执行队列，
/// 小人就开始做动作/说话。陪伴页没开时指令排队，开了自动补执行。
///
/// 男主"感知"互动：PetPerceiveSkill 把最近的小人互动摘要注入 Prompt，
/// 男主就知道你刚才喂了它、摸了它、把它拖到了哪里。
class PetBridge {
  PetBridge._();

  static final PetBridge instance = PetBridge._();

  /// 当前桌宠世界（陪伴页 attach；离开时 detach）
  PetWorld? world;

  /// 男主下过但还没执行的指令（陪伴页未开时排队）
  final List<PetCommand> _pending = [];

  bool get hasWorld => world != null;

  /// 陪伴页初始化完成后调用：立即执行排队指令
  void attach(PetWorld w) {
    world = w;
    final queued = List.of(_pending);
    _pending.clear();
    for (final cmd in queued) {
      execute(cmd);
    }
  }

  /// 陪伴页销毁时调用
  void detach() {
    world = null;
  }

  /// 执行一条指令（世界在 → 立即；不在 → 排队）
  void enqueue(PetCommand cmd) {
    if (world == null) {
      _pending.add(cmd);
      DebugLogger.log('桌宠桥', '陪伴页未打开，指令排队: ${cmd.summary}');
      return;
    }
    execute(cmd);
  }

  /// 立即执行
  void execute(PetCommand cmd) {
    final w = world;
    if (w == null) return;
    final petId = cmd.petId ?? _mainPetId(w);

    if (cmd.say != null && cmd.say!.isNotEmpty) {
      w.speak(petId, cmd.say!);
    }
    if (cmd.activityId != null) {
      w.runActivity(petId, cmd.activityId!);
    } else if (cmd.behavior != null) {
      final b = PetBehavior.fromName(cmd.behavior);
      if (b != null) w.runBehavior(petId, b);
    } else if (cmd.actionId != null) {
      w.playAction(petId, cmd.actionId!);
    }
    DebugLogger.log('桌宠桥', '执行: ${cmd.summary} (pet=$petId)');
  }

  String _mainPetId(PetWorld w) {
    if (w.scene.pets.isEmpty) return 'male_lead';
    return w.scene.pets.first.id;
  }
}

/// 一条桌宠指令（男主 → 小人）
class PetCommand {
  /// 目标小人 id（null = 第一个/男主小人）
  final String? petId;

  /// 动作 id（jump/spin/wave/happy/climb/jumpOff…）
  final String? actionId;

  /// 组合动作 id
  final String? activityId;

  /// 预设行为（climb/jumpOff）
  final String? behavior;

  /// 让小人说的话
  final String? say;

  const PetCommand({
    this.petId,
    this.actionId,
    this.activityId,
    this.behavior,
    this.say,
  });

  String get summary =>
      [if (say != null) '说"$say"', if (activityId != null) '表演$activityId', if (behavior != null) '行为$behavior', if (actionId != null) '动作$actionId']
          .join('+');
}

/// 🔧 桌宠动作控制工具：男主让小人做动作/说话/表演
class PetActionTool extends ButlerTool {
  @override
  String get id => 'pet_action';

  @override
  String get name => '桌宠动作';

  @override
  String get description =>
      '控制陪伴页的小人：做动作（跳/转圈/挥手/开心/爬屏幕/跳下来…）、说话、表演组合动作。'
      '当用户提到陪伴页的小人、或你想主动逗她/表演时使用。';

  @override
  Future<String> call(Map<String, dynamic> args) async {
    final action = args['action'] as String?;
    final activity = args['activity'] as String?;
    final behavior = args['behavior'] as String?;
    final say = args['say'] as String?;
    final petId = args['petId'] as String?;

    if ((action == null || action.isEmpty) &&
        (activity == null || activity.isEmpty) &&
        (behavior == null || behavior.isEmpty) &&
        (say == null || say.isEmpty)) {
      return '指令为空：需要 action / activity / behavior / say 至少一个';
    }

    PetBridge.instance.enqueue(PetCommand(
      petId: petId,
      actionId: action,
      activityId: activity,
      behavior: behavior,
      say: say,
    ));

    final target = behavior ?? action ?? activity ?? '说话';
    return '已让小人$target（陪伴页打开时立即表演）';
  }
}

/// 桌宠感知技能：男主"看见"用户与小人互动
class PetPerceiveSkill extends ButlerSkill {
  @override
  String get id => 'pet_perceive';

  @override
  String get name => '桌宠感知';

  @override
  String get description =>
      '用户提到桌宠/小人/宠物相关互动（喂、摸、拖、抱、玩小人）时触发：读取最近的小人互动事件注入，让男主感知到';

  @override
  List<String> get triggers => [
    '桌宠', '小人', '宠物', '投喂', '喂了', '喂它', '摸', '抚摸', '拖', '抱',
    '爬屏幕', '跳下来', '转圈', '挥手', '玩小人', '我的小人', '它的',
  ];

  @override
  int get priority => 5;

  @override
  List<String> get flowSteps =>
      ['触发匹配', '🔧 读最近小人互动', '生成感知注入'];

  @override
  Future<ButlerSkillResult> execute(ButlerSkillContext ctx) async {
    try {
      final w = PetBridge.instance.world;
      if (w == null) {
        return const ButlerSkillResult(
            promptInjection: '【桌宠】陪伴页还没打开过，暂时没有小人互动记录。');
      }
      final summary = w.events.recentSummary(count: 8);
      return ButlerSkillResult(
        promptInjection:
            '【你感知到的小人互动】$summary。你可以自然地回应或让小人做点什么（用 pet_action 工具）。',
      );
    } catch (e) {
      DebugLogger.log('桌宠感知', '失败: $e');
      return const ButlerSkillResult();
    }
  }
}

/// 注册桌宠工具 + 技能（幂等）
void registerPetBridge() {
  ButlerToolRegistry.instance.register(PetActionTool());
  ButlerSkillRegistry.instance.register(PetPerceiveSkill());
  DebugLogger.log('桌宠桥', '桌宠 AI 桥已注册（pet_action / pet_perceive）');
}
