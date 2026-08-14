import '../../utils/debug_logger.dart';
import '../skills/butler_skill.dart';
import '../skills/butler_skill_registry.dart';
import '../tools/butler_tool.dart';
import '../tools/butler_tool_registry.dart';
import 'pet.dart';
import 'pet_engine.dart';
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

  /// 全屏场景页是否开着（8-15 P1）：场景页开着时桌宠页的 ticker
  /// 不得抢回 attach——演出目标必须始终是场景页
  bool sceneActive = false;

  /// AI 演出卡片回调（场景页注册）：收到 choices 时显示选项卡片
  void Function(String text, List<String> choices)? onCardShow;

  /// 表情指令回调（立绘模式注册）：expression 指令 → 切立绘表情
  void Function(String expression)? onExpression;

  /// 用户在 AI 卡片上最后一次选择（感知注入用，选完不清除——
  /// 男主下一轮就能"记得"用户上次选了什么）
  String? lastChoice;

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
    // 8-15 P1：演出移动——AI 给 0~1 坐标，小人走过去（复用 moveTo 插值）
    if (cmd.posX != null && cmd.posY != null) {
      final pet = w.scene.petById(petId);
      if (pet != null) {
        pet.moveTo(
          PetPoint(cmd.posX!, cmd.posY!),
          duration: cmd.moveSec ?? 2.5,
          ease: PetMoveEase.easeInOut,
        );
        DebugLogger.log('桌宠桥',
            '演出移动 $petId → (${cmd.posX!.toStringAsFixed(2)},${cmd.posY!.toStringAsFixed(2)})');
      }
    }
    if (cmd.activityId != null) {
      w.runActivity(petId, cmd.activityId!);
    } else if (cmd.behavior != null) {
      final b = PetBehavior.fromName(cmd.behavior);
      if (b != null) w.runBehavior(petId, b);
    } else if (cmd.actionId != null) {
      w.playAction(petId, cmd.actionId!);
    }
    // 8-15 P1：AI 选项卡片——choices 非空时触发卡片回调（场景页显示）
    if (cmd.choices != null && cmd.choices!.isNotEmpty) {
      onCardShow?.call(cmd.say ?? '', cmd.choices!);
    }
    if (cmd.expression != null) {
      // 表情指令：立绘模式切表情（占位立绘直接响应；真素材 P2 替换）
      onExpression?.call(cmd.expression!);
      DebugLogger.log('桌宠桥', '演出表情 ${cmd.expression}');
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

  /// 演出移动目标（0~1 屏幕坐标；AI 说"走到门口/到她身边"）
  final double? posX;
  final double? posY;

  /// 移动时长秒数（默认 2.5）
  final double? moveSec;

  /// 表情名（normal/smile/happy/sad/angry/surprised/embarrassed/crying；
  /// 第一版记录日志，P2 映射立绘资源）
  final String? expression;

  /// AI 选项卡片（非空时场景页显示选项按钮；点选结果进
  /// PetBridge.lastChoice 供男主下一轮感知）
  final List<String>? choices;

  const PetCommand({
    this.petId,
    this.actionId,
    this.activityId,
    this.behavior,
    this.say,
    this.posX,
    this.posY,
    this.moveSec,
    this.expression,
    this.choices,
  });

  String get summary => [
        if (say != null) '说"$say"',
        if (activityId != null) '表演$activityId',
        if (behavior != null) '行为$behavior',
        if (actionId != null) '动作$actionId',
        if (posX != null && posY != null)
          '走到(${posX!.toStringAsFixed(2)},${posY!.toStringAsFixed(2)})',
        if (expression != null) '表情$expression',
        if (choices != null) '选项${choices!.length}个',
      ].join('+');
}

/// 🔧 桌宠动作控制工具：男主让小人做动作/说话/表演
class PetActionTool extends ButlerTool {
  @override
  String get id => 'pet_action';

  @override
  String get name => '桌宠动作';

  @override
  String get description =>
      '控制陪伴页/全屏场景的小人演出：做动作（跳/转圈/挥手/开心/爬屏幕/跳下来…）、'
      '说话、表演组合动作、走到某个位置、摆表情、弹选项卡片。'
      '参数：action（动作id）、activity（组合id）、behavior（行为）、say（说的话）、'
      'position（"0.5,0.3" 屏幕坐标，走到那）、expression（表情名）、'
      'choices（选项列表，如 "推开他|抱住他|转头离开"，配合 say 弹卡片等用户选）。'
      '当用户提到小人、或你想主动演出/逗她/让她走向某处时使用。';

  @override
  Future<String> call(Map<String, dynamic> args) async {
    final action = args['action'] as String?;
    final activity = args['activity'] as String?;
    final behavior = args['behavior'] as String?;
    final say = args['say'] as String?;
    final petId = args['petId'] as String?;
    final expression = args['expression'] as String?;

    double? posX;
    double? posY;
    double? moveSec;
    final pos = args['position'] as String?;
    if (pos != null && pos.isNotEmpty) {
      final parts = pos.split(RegExp(r'[,，\s]+'));
      if (parts.length >= 2) {
        posX = double.tryParse(parts[0]);
        posY = double.tryParse(parts[1]);
      }
    }
    final sec = args['moveSec'] ?? args['seconds'] ?? args['时长'];
    moveSec = sec is num ? sec.toDouble() : double.tryParse('$sec');

    List<String>? choices;
    final ch = args['choices'];
    if (ch is List) {
      choices = ch.map((e) => '$e').toList();
    } else if (ch is String && ch.isNotEmpty) {
      choices = ch
          .split(RegExp(r'[|｜]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    if ((action == null || action.isEmpty) &&
        (activity == null || activity.isEmpty) &&
        (behavior == null || behavior.isEmpty) &&
        (say == null || say.isEmpty) &&
        posX == null &&
        expression == null &&
        (choices == null || choices.isEmpty)) {
      return '指令为空：需要 action / activity / behavior / say / position / expression / choices 至少一个';
    }

    PetBridge.instance.enqueue(PetCommand(
      petId: petId,
      actionId: action,
      activityId: activity,
      behavior: behavior,
      say: say,
      posX: posX,
      posY: posY,
      moveSec: moveSec,
      expression: expression,
      choices: choices,
    ));

    final target = behavior ??
        action ??
        activity ??
        (posX != null ? '走到(${posX!.toStringAsFixed(2)},${posY!.toStringAsFixed(2)})' : null) ??
        (expression != null ? '表情$expression' : null) ??
        (choices != null ? '弹选项卡片' : null) ??
        '说话';
    return '已让小人$target（页面打开时立即演出）';
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
      final last = PetBridge.instance.lastChoice;
      final choiceNote = last == null
          ? ''
          : '（用户上次在卡片选项里选了："$last"）';
      return ButlerSkillResult(
        promptInjection:
            '【你感知到的小人互动】$summary$choiceNote。你可以自然地回应或让小人做点什么（用 pet_action 工具）。',
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
