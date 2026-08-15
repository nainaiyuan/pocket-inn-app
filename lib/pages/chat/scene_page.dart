import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../butler/pet/pet.dart';
import '../../butler/pet/pet_bridge.dart';
import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_timer.dart';
import '../../butler/pet/pet_scene.dart';
import '../../butler/pet/pet_store.dart';
import '../../butler/pet/scene_director.dart';
import '../../butler/pet/scene_models.dart' as sm;
import '../../butler/tools/butler_tool_registry.dart';
import '../../butler/tools/tool_intent_parser.dart';
import '../../services/pet_frame_source_impl.dart';
import '../../utils/debug_logger.dart';
import '../home/companion_page.dart' show PetFrameView;
import 'services/ai_chat_service.dart';
import '../../ai_provider/models.dart';
import 'state/current_character_state.dart';
import 'placeholder_portrait.dart';

/// 8-15 03:0x 全屏场景模式 P0：场景页（16 号冲刺安排）
///
/// 结构：底图 → 热点层（点击触发）→ 角色层（复用 PetWorld 引擎 +
/// PetFrameView）→ 底部卡片区（文游卡：文字 + 选项）→ 返回按钮。
///
/// 闭环：进场景 → 点热点(node) → SceneDirector 跑节点 →
/// 动作演出 → 卡片 → WAIT_USER → 用户选择 → 下一节点。
///
/// 零回归：独立页面 + 新表；没配场景/热点 = 纯聊天场景无变化。
class ScenePage extends StatefulWidget {
  final String sceneId;

  const ScenePage({super.key, required this.sceneId});

  @override
  State<ScenePage> createState() => _ScenePageState();
}

class _ScenePageState extends State<ScenePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  PetWorld? _world;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  sm.PetScene? _scene;
  List<sm.PetHotspot> _hotspots = const [];
  SceneDirector? _director;
  bool _loading = true;
  bool _missing = false;
  String? _loadError; // 8-15 14:1x：初始化异常兜底（防静默卡死）

  // ---- 卡片状态 ----
  String? _cardText;
  List<sm.PetChoice> _cardChoices = const [];
  bool _showCard = false;
  bool _cardDone = false; // end 节点后显示"结束"
  bool _aiCard = false; // AI 演出卡片（选项结果回传 PetBridge.lastChoice）

  /// 已触发的 area 热点（防重复触发；角色离开后重置可再触发）
  final Set<String> _firedAreas = {};

  // ---- AI 对话（8-15 P1：AI 立绘聊天 = AI 聊天换输出端） ----
  final _state = CurrentCharacterState();
  final _aiSvc = AiChatService();
  final TextEditingController _inputCtrl = TextEditingController();
  bool _aiBusy = false;
  String? _aiError;

  // ---- 陪伴计时（8-15 P1/P2：正/倒计时 + 循环演出 + 奖励） ----
  PetTimerSession? _timer;
  bool _timerMode = false;
  int _timerSecAcc = 0; // 累计秒（ticker 驱动）
  int _loopActAcc = 0; // 循环动作累计秒
  String? _speech; // 角色气泡
  Timer? _speechTimer;
  String? _toast; // 全局提示（好感度等）
  Timer? _toastTimer;
  bool _timerToastDone = false; // 完成 toast 只弹一次

  // ---- 立绘模式（P2 占位：程序绘制 8 表情） ----
  bool _portraitMode = false;
  String _expression = 'normal';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 8-15 14:1x（ANR 防护）：先渲染 loading 首帧，路由动画完成后再
    // 跑初始化——避免 push 过渡期间主线程被初始化抢满导致无响应
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    PetBridge.instance
      ..sceneActive = false
      ..onCardShow = null
      ..onExpression = null;
    if (identical(PetBridge.instance.world, _world)) {
      PetBridge.instance.detach();
    }
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.dispose();
    _director?.stop();
    _inputCtrl.dispose();
    _speechTimer?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      DebugLogger.log('桌宠', '场景页初始化：开始');
      await _state.init();
      DebugLogger.log('桌宠', '场景页初始化：角色状态就绪');
      final store = PetStore();
      sm.PetScene? scene;
      final scenes = await store.allScenes();
      DebugLogger.log('桌宠', '场景页初始化：读到场景 ${scenes.length} 个');
      for (final s in scenes) {
        if (s.sceneId == widget.sceneId) {
          scene = s;
          break;
        }
      }
      if (scene == null) {
        DebugLogger.log('桌宠', '场景页：场景 ${widget.sceneId} 不存在');
        if (mounted) setState(() {
          _loading = false;
          _missing = true;
        });
        return;
      }
      final hotspots = await store.hotspotsForScene(scene.sceneId);
      DebugLogger.log('桌宠', '场景页初始化：热点 ${hotspots.length} 个');
      final world = PetWorld(store: store, frames: FilePetFrameSource());
      await world.restore();
      DebugLogger.log('桌宠', '场景页初始化：世界 restore 完成');
      await world.preloadAll();
      DebugLogger.log('桌宠', '场景页初始化：帧图预载完成');
      await world.syncVisible();
      DebugLogger.log('桌宠', '场景页初始化：小人同步完成 ${world.scene.pets.length} 个');

      final director = SceneDirector(store: store, scene: scene)
        ..onNodeEntered = _onNodeEntered
        ..onCard = _onCard
        ..onFinished = _onSceneFinished;

      // 8-15 P1：AI 演出指令直达场景页——PetBridge.world 指向本页世界；
      // 桌宠页 ticker 通过 sceneActive 防抢回
      PetBridge.instance
        ..sceneActive = true
        ..attach(world)
        ..onCardShow = _onAiCard
        ..onExpression = _onExpression;

      // 陪伴计时配置（无配置用默认：倒计时 25 分钟/每 60s +1）
      final mainPet = world.scene.pets.isNotEmpty ? world.scene.pets.first : null;
      if (mainPet != null) {
        final setting =
            await store.timerSettingFor(mainPet.id) ?? const PetTimerSetting(petId: '');
        _timer = PetTimerSession(
          mode: setting.mode,
          durationSec: setting.durationSec,
          rewardIntervalSec: setting.rewardIntervalSec,
          rewardAmount: setting.rewardAmount,
          lines: setting.lines,
        );
        DebugLogger.log('桌宠', '陪伴计时配置：${setting.mode.name} '
            '${setting.durationSec}s 奖励每${setting.rewardIntervalSec}s+${setting.rewardAmount} '
            '话术${setting.lines.length}条');
      }

      DebugLogger.log('桌宠',
          '场景页加载：${scene.name} | 热点 ${hotspots.length} | 角色 ${world.scene.pets.length}');
      if (!mounted) return;
      setState(() {
        _world = world;
        _scene = scene;
        _hotspots = hotspots;
        _director = director;
        _loading = false;
      });
      _ticker = createTicker(_onTick)..start();
      DebugLogger.log('桌宠', '场景页初始化：完成，ticker 已启动');
    } catch (e, st) {
      DebugLogger.log('桌宠', '场景页初始化异常: $e\n$st');
      if (mounted) setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  void _onTick(Duration elapsed) {
    final world = _world;
    if (world == null) return;
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    world.scene.update(dt);
    _checkAreaTriggers(world);
    _tickTimer();
    if (mounted) setState(() {});
  }

  // ===== SceneDirector 回调 =====

  void _onNodeEntered(sm.PetNode node) {
    // 解析 content JSON：{"text": "...", "action": "id", "activity": "id"}
    String? text;
    String? actionId;
    String? activityId;
    final raw = node.content;
    if (raw != null && raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        text = m['text'] as String?;
        actionId = m['action'] as String?;
        activityId = m['activity'] as String?;
      } catch (_) {}
    }
    _playOnFirstPet(actionId: actionId, activityId: activityId);
    setState(() {
      _cardText = text ?? '';
      _cardChoices = const [];
      _showCard = text != null && text.isNotEmpty;
      _cardDone = false;
    });
    DebugLogger.log('桌宠', '场景节点进入 ${node.nodeId} '
        'type=${node.type.name} continue=${node.continueType.name} '
        'waitUser=${node.waitUser}');

    // auto 节点：内容播完自动推进（第一版：动作给 1.5s 演出时间）
    if (node.continueType == sm.PetContinueType.auto && !node.waitUser) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        _director?.nodeContentDone();
      });
    }
  }

  void _onCard(sm.PetNode node, List<sm.PetChoice> choices) {
    setState(() {
      _cardChoices = choices;
      _showCard = true;
      _cardDone = false;
    });
  }

  void _onSceneFinished() {
    DebugLogger.log('桌宠', '场景流程结束');
    setState(() {
      _cardDone = true;
      _cardText = '（剧情结束）';
      _cardChoices = const [];
      _showCard = true;
    });
  }

  // ===== 陪伴计时（8-15 P1/P2） =====

  /// 分心感知：切后台/离开 → 暂停计时 + AI 主动说话拉回用户
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        _timerMode &&
        (_timer?.running ?? false)) {
      DebugLogger.log('桌宠', '用户分心（切后台）→ 暂停计时 + AI 拉回');
      _timer?.pause();
      _onDistracted();
    }
  }

  Future<void> _onDistracted() async {
    final pid = _state.personaId;
    if (pid == null || pid.isEmpty) {
      _speak('怎么走了？我在这等你。');
      return;
    }
    try {
      final result = await _aiSvc.generateReply(
        '',
        pid,
        personaName: _state.personaName ?? '角色',
        personaPrompt: _state.persona?.prompt ?? '',
        sessionId: 'scene_${widget.sceneId}',
        systemEvent: '用户刚才走开了/切走了（陪伴计时中分心）。'
            '说一句温柔的话把她拉回来，可以配一个小动作（pet_action）。',
      );
      if (!mounted) return;
      await _applyAiResult(result);
    } catch (e) {
      DebugLogger.log('桌宠', '分心 AI 说话失败，降级预设话术: $e');
      _speak('怎么走了？我在这等你。');
    }
  }

  /// 切换正/倒计时（重置 + 持久化）
  void _switchTimerMode() {
    final t = _timer;
    if (t == null) return;
    setState(() {
      t.mode = t.mode == PetTimerMode.countdown
          ? PetTimerMode.countup
          : PetTimerMode.countdown;
      t.reset();
      _timerSecAcc = 0;
      _loopActAcc = 0;
      _timerToastDone = false;
    });
    _saveTimerConfig();
    _speak(t.mode == PetTimerMode.countdown ? '换成倒计时啦。' : '换成正计时啦。');
  }

  /// 持久化计时配置（模式/时长/奖励/话术）
  Future<void> _saveTimerConfig() async {
    final t = _timer;
    final world = _world;
    if (t == null || world == null || world.scene.pets.isEmpty) return;
    try {
      await PetStore().saveTimerSetting(PetTimerSetting(
        petId: world.scene.pets.first.id,
        mode: t.mode,
        durationSec: t.durationSec,
        rewardIntervalSec: t.rewardIntervalSec,
        rewardAmount: t.rewardAmount,
        linesJson: t.lines.isEmpty ? null : jsonEncode(t.lines),
      ));
    } catch (e) {
      DebugLogger.log('桌宠', '保存计时配置失败: $e');
    }
  }

  void _tickTimer() {
    final timer = _timer;
    if (timer == null || !_timerMode) return;
    _timerSecAcc++;
    if (_timerSecAcc < 1) return;
    // 每秒推进一次（ticker 帧率 60，用累计秒做节流）
    if (!timer.running) return;
    final events = timer.tick();
    for (final e in events) {
      _onTimerEvent(e);
    }
    // 计时中角色循环演出：每 8~12 秒随机播一个动作
    _loopActAcc++;
    if (_loopActAcc >= 8 + (_timerSecAcc % 5)) {
      _loopActAcc = 0;
      _playRandomAct();
    }
  }

  void _onTimerEvent(PetTimerEvent e) {
    final world = _world;
    switch (e.type) {
      case PetTimerEventType.reward:
        // 好感度奖励
        if (world != null && world.scene.pets.isNotEmpty) {
          final petId = world.scene.pets.first.id;
          world.feedSystem.store.addAffection(petId, e.amount);
        }
        _showToast('陪伴 +${e.amount} ❤');
        _speak('谢谢你陪我这么久。');
        break;
      case PetTimerEventType.line:
        if (e.text != null && e.text!.isNotEmpty) {
          _speak(e.text!);
        }
        break;
      case PetTimerEventType.completed:
        if (world != null && world.scene.pets.isNotEmpty) {
          final petId = world.scene.pets.first.id;
          world.feedSystem.store.addAffection(petId, 5);
        }
        if (!_timerToastDone) {
          _timerToastDone = true;
          _showToast('陪伴完成！好感 +5 ❤❤');
        }
        _speak('时间到了，谢谢你陪我。今天也辛苦了。');
        _playRandomAct();
        break;
    }
  }

  /// 随机播一个动作（计时中循环演出 / 点击互动）
  void _playRandomAct() {
    final world = _world;
    if (world == null || world.scene.pets.isEmpty) return;
    const acts = ['happy', 'wave', 'spin', 'jump'];
    final act = acts[Random().nextInt(acts.length)];
    world.scene.playAction(world.scene.pets.first.id, act);
  }

  /// 角色气泡说话（自动消失）
  void _speak(String text) {
    setState(() => _speech = text);
    _speechTimer?.cancel();
    _speechTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _speech = null);
    });
  }

  void _showToast(String text) {
    setState(() => _toast = text);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _toggleTimerMode() {
    setState(() => _timerMode = !_timerMode);
    if (_timerMode) {
      _timerSecAcc = 0;
      _loopActAcc = 0;
      _speak('我会一直陪着你的。');
    } else {
      _timer?.pause();
    }
  }

  void _startTimer() {
    _timerSecAcc = 0;
    _timerToastDone = false;
    _timer?.start();
    _speak('开始啦，专心做事，我陪你。');
  }

  void _pauseTimer() {
    _timer?.pause();
    _speak('休息一下也好。');
  }

  void _resetTimer() {
    _timer?.reset();
    _timerSecAcc = 0;
    _loopActAcc = 0;
    _timerToastDone = false;
  }

  /// 点角色互动：计时中播随机动作 + 说一句（预设/默认）
  void _onPetTap() {
    _playRandomAct();
    final timer = _timer;
    if (timer != null && _timerMode && timer.running) {
      final pool = timer.lines.isNotEmpty ? timer.lines : timer.defaultLines;
      if (pool.isNotEmpty) {
        _speak(pool[Random().nextInt(pool.length)]);
      }
    } else {
      _speak('嗯？我在呢。');
    }
  }

  /// area 热点：角色进入矩形区域自动触发（enter；离开重置可再触发）
  void _checkAreaTriggers(PetWorld world) {
    final pets = world.scene.pets;
    if (pets.isEmpty) return;
    final pet = pets.first;
    final px = pet.position.x;
    final py = pet.position.y;
    for (final h in _hotspots) {
      if (h.type != sm.PetHotspotType.area) continue;
      if (h.trigger != sm.PetHotspotTrigger.enter) continue;
      final inside = px >= h.x &&
          px <= h.x + h.w &&
          py >= h.y &&
          py <= h.y + h.h;
      if (inside && !_firedAreas.contains(h.hotspotId)) {
        _firedAreas.add(h.hotspotId);
        DebugLogger.log('桌宠', '热点区域进入 ${h.hotspotId} 触发');
        _onHotspotTap(h);
      } else if (!inside) {
        _firedAreas.remove(h.hotspotId);
      }
    }
  }

  /// item 热点：拖动角色松手落在道具上 = 投喂（drop 触发）
  void _checkDrop(PetWorld world, Pet pet) {
    for (final h in _hotspots) {
      if (h.type != sm.PetHotspotType.item) continue;
      if (h.trigger != sm.PetHotspotTrigger.drop) continue;
      final dx = (pet.position.x - h.x).abs();
      final dy = (pet.position.y - h.y).abs();
      final radius = (h.w > 0 ? h.w : 0.1) / 2 + 0.05;
      if (dx <= radius && dy <= radius) {
        DebugLogger.log('桌宠', '道具投喂 ${h.hotspotId} 触发');
        _onHotspotTap(h);
        return;
      }
    }
  }

  void _playOnFirstPet({String? actionId, String? activityId}) {
    final world = _world;
    if (world == null) return;
    final pets = world.scene.pets;
    if (pets.isEmpty) return;
    final pet = pets.first;
    if (activityId != null && activityId.isNotEmpty) {
      world.scene.runActivity(pet.id, activityId);
    } else if (actionId != null && actionId.isNotEmpty) {
      world.scene.playAction(pet.id, actionId);
    }
  }

  // ===== 用户操作 =====

  void _onHotspotTap(sm.PetHotspot h) {
    DebugLogger.log('桌宠', '场景热点点击 ${h.hotspotId} '
        'type=${h.type.name} binding=${h.bindingType}:${h.bindingId}');
    switch (h.bindingType) {
      case 'node':
        _director?.start(h.bindingId);
        break;
      case 'action':
        _playOnFirstPet(actionId: h.bindingId);
        break;
      case 'activity':
        _playOnFirstPet(activityId: h.bindingId);
        break;
      case 'group':
        // 互动组绑定：第一版跳过（节点/动作/组合已覆盖闭环）
        DebugLogger.log('桌宠', '热点 group 绑定第一版跳过');
        break;
    }
  }

  void _onCardTap() {
    // 空选项卡片：点击继续（click / clickTarget / AI 卡关闭）
    if (_cardChoices.isEmpty && !_cardDone) {
      if (_aiCard) {
        setState(() {
          _showCard = false;
          _aiCard = false;
        });
        return;
      }
      _director?.userClick();
    }
  }

  void _onChoiceTap(sm.PetChoice c) {
    if (_aiCard) {
      // AI 卡片：选择结果回传男主（下一轮感知注入），关闭卡片
      PetBridge.instance.lastChoice = c.label;
      DebugLogger.log('桌宠', 'AI 卡片选择: ${c.label}');
      setState(() {
        _showCard = false;
        _aiCard = false;
      });
      return;
    }
    _director?.userChoose(c.choiceId);
  }

  /// 场景 AI 对话：输入 → AI（场景导演人设）→ 文本上卡片 →
  /// 工具（pet_action 演出指令）直执行 → 结果展示。
  /// 第一版：单轮 + 单工具轮（不循环），不碰聊天页对话管道。
  Future<void> _sendAiChat(String text) async {
    final pid = _state.personaId;
    if (pid == null || pid.isEmpty) {
      setState(() => _aiError = '角色还没加载，稍后再试');
      return;
    }
    final input = text.trim();
    if (input.isEmpty || _aiBusy) return;
    _inputCtrl.clear();
    setState(() {
      _aiBusy = true;
      _aiError = null;
      _cardText = '…';
      _cardChoices = const [];
      _showCard = true;
      _cardDone = false;
      _aiCard = false;
    });
    try {
      final result = await _aiSvc.generateReply(
        input,
        pid,
        personaName: _state.personaName ?? '角色',
        personaPrompt: _state.persona?.prompt ?? '',
        sessionId: 'scene_${widget.sceneId}',
        systemEvent: '你现在在全屏场景模式（文游/小屋）。'
            '你可以用 pet_action 工具指挥小人演出：'
            'say（说话）、action（动作 id：jump/spin/wave/happy/…）、'
            'position（"0.5,0.3" 走到那）、expression（表情）、'
            'choices（选项卡片，如 "推开他|抱住他"，等用户选）。'
            '说话直接显示在卡片上。',
      );
      await _applyAiResult(result);
      if (!mounted) return;
      setState(() => _aiBusy = false);
    } catch (e) {
      DebugLogger.log('桌宠', '场景 AI 对话失败: $e');
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _aiError = '对话失败：$e';
      });
    }
  }

  /// 应用 AI 结果：文本上卡片 + 工具（pet_action 演出指令）直执行
  Future<void> _applyAiResult(AIProviderResult result) async {
    var textOut = result.text.trim();
    // 工具直执行（单轮）：原生 toolCalls + 文本块 ⟨工具:⟩ 都收
    final calls = result.toolCalls ?? ToolIntentParser.extract(result.text);
    if (calls != null && calls.isNotEmpty) {
      final outs = <String>[];
      for (final c in calls) {
        final name = c['name']?.toString() ?? '';
        final tool = ButlerToolRegistry.instance.get(name);
        if (tool == null) continue;
        try {
          final args = c['arguments'];
          final out = await tool.call(
              args is Map ? Map<String, dynamic>.from(args) : {});
          outs.add(out);
          DebugLogger.log('桌宠', '场景 AI 工具 $name → $out');
        } catch (e) {
          outs.add('工具 $name 执行失败: $e');
        }
      }
      if (outs.isNotEmpty) {
        textOut = textOut.isEmpty
            ? '[演出] ${outs.join('；')}'
            : '$textOut\n\n[演出] ${outs.join('；')}';
      }
    }
    setState(() {
      _cardText = textOut.isEmpty ? '（男主没有回应）' : textOut;
      _cardChoices = const [];
      _showCard = true;
      _cardDone = false;
      _aiCard = false;
    });
  }

  /// AI 演出卡片（男主用 pet_action choices 参数弹的选项）
  void _onAiCard(String text, List<String> choices) {
    DebugLogger.log('桌宠', 'AI 演出卡片: "$text" 选项 ${choices.length} 个');
    setState(() {
      _cardText = text;
      _cardChoices = choices
          .map((e) => sm.PetChoice(
                choiceId: 'ai_${e.hashCode}',
                nodeId: '',
                seq: 0,
                label: e,
                targetNode: '',
              ))
          .toList();
      _showCard = true;
      _cardDone = false;
      _aiCard = true;
    });
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: const Text('场景不存在')),
        body: const Center(child: Text('未找到场景配置')),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('场景加载失败')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: Color(0xFFE07A7A), size: 40),
                const SizedBox(height: 12),
                Text(
                  '$_loadError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF5A4049)),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB0789A),
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('返回'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          // 底图（用户上传 / 占位色）
          Positioned.fill(child: _buildBackground()),
          // 热点层
          ..._hotspots.map(_buildHotspot),
          // 角色层（复用 PetFrameView）
          ..._buildPets(),
          // 卡片区
          if (_showCard) _buildCard(),
          // AI 对话输入框（8-15 P1：文游 AI 聊天入口）
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: _buildAiInput(),
              ),
            ),
          ),
          // 顶部按钮：返回 + 陪伴计时
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xCCB0789A),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  if (_timer != null)
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: _timerMode
                            ? const Color(0xCCD08A6A)
                            : const Color(0xCCB0789A),
                        foregroundColor: Colors.white,
                      ),
                      icon: Icon(
                          _timerMode ? Icons.timer_off : Icons.timer_outlined),
                      tooltip: '陪伴计时',
                      onPressed: _toggleTimerMode,
                    ),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: _portraitMode
                          ? const Color(0xCCD08A6A)
                          : const Color(0xCCB0789A),
                      foregroundColor: Colors.white,
                    ),
                    icon: Icon(_portraitMode
                        ? Icons.portrait
                        : Icons.portrait_outlined),
                    tooltip: '立绘模式',
                    onPressed: _togglePortraitMode,
                  ),
                ],
              ),
            ),
          ),
          // 陪伴计时覆盖层
          if (_timerMode && _timer != null) _buildTimerOverlay(),
          // 立绘覆盖层
          if (_portraitMode) _buildPortraitOverlay(),
          // 全局提示（好感度等）
          if (_toast != null)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 60),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xE6FDF6F9),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [
                        BoxShadow(color: Color(0x22B0789A), blurRadius: 8),
                      ],
                    ),
                    child: Text(
                      _toast!,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFFB0789A)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    final bg = _scene?.bgPath;
    if (bg != null && bg.isNotEmpty) {
      final f = File(bg);
      if (f.existsSync()) {
        return Image.file(f, fit: BoxFit.cover);
      }
    }
    // 占位：暖色渐变底
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF7E8EE), Color(0xFFEAD3E0)],
        ),
      ),
    );
  }

  Widget _buildHotspot(sm.PetHotspot h) {
    return Positioned.fill(
      child: LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final hh = constraints.maxHeight;
        switch (h.type) {
          case sm.PetHotspotType.area:
            final left = h.x * w;
            final top = h.y * hh;
            final ww = h.w * w;
            final hhh = h.h * hh;
            return Positioned(
              left: left,
              top: top,
              width: ww,
              height: hhh,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _onHotspotTap(h),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0x66B0789A), width: 2),
                    color: const Color(0x1AB0789A),
                  ),
                ),
              ),
            );
          case sm.PetHotspotType.point:
          case sm.PetHotspotType.furniture:
          case sm.PetHotspotType.item:
            final size = h.w * w; // point 用 w 当直径
            final left = h.x * w - size / 2;
            final top = h.y * hh - size / 2;
            return Positioned(
              left: left,
              top: top,
              width: size,
              height: size,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _onHotspotTap(h),
                child: _HotspotIcon(type: h.type),
              ),
            );
        }
      }),
    );
  }

  List<Widget> _buildPets() {
    final world = _world;
    if (world == null) return const [];
    return [
      Positioned.fill(
        child: LayoutBuilder(builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          const baseSize = 150.0; // 全屏场景：小人放大
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final pet in world.scene.pets) ...[
                () {
                  final size = (baseSize * pet.scale).clamp(60.0, 320.0);
                  final left = pet.position.x * w - size / 2;
                  final top = pet.position.y * h - size / 2;
                  return Positioned(
                    left: left,
                    top: top,
                    width: size,
                    height: size,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _onPetTap,
                      onPanUpdate: (d) {
                        // 8-15 P1：场景页角色可拖动（0~1 坐标），
                        // 松手落道具上 = 投喂
                        pet.position = PetPoint(
                          (pet.position.x + d.delta.dx / w).clamp(0.0, 1.0),
                          (pet.position.y + d.delta.dy / h).clamp(0.0, 1.0),
                        );
                        pet.stopMoving();
                      },
                      onPanEnd: (_) => _checkDrop(world, pet),
                      child: PetFrameView(pet: pet, size: size),
                    ),
                  );
                }(),
                // 角色气泡（陪伴计时说话）
                if (_speech != null && pet.id == world.scene.pets.first.id)
                  Positioned(
                    left: pet.position.x * w - 60,
                    top: pet.position.y * h - 46,
                    width: 120,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xF2FDF6F9),
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                                color: Color(0x22B0789A), blurRadius: 6),
                          ],
                        ),
                        child: Text(
                          _speech!,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF5A4049)),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          );
        }),
      ),
    ];
  }

  Widget _buildCard() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(20),
        color: const Color(0xFFFDF6F9),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _cardText ?? '',
                style: const TextStyle(
                  fontSize: 16,
                  color: Color(0xFF5A4049),
                  height: 1.5,
                ),
              ),
              if (_cardChoices.isNotEmpty) ...[
                const SizedBox(height: 14),
                ..._cardChoices.map((c) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFB0789A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => _onChoiceTap(c),
                        child: Text(c.label),
                      ),
                    )),
              ] else if (!_cardDone) ...[
                const SizedBox(height: 10),
                Text(
                  '（点击继续）',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                  ),
                ),
                // 空选项卡片整体可点
                InkWell(
                  onTap: _onCardTap,
                  child: const SizedBox(height: 10),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ===== 立绘模式（P2 占位） =====

  void _togglePortraitMode() {
    setState(() => _portraitMode = !_portraitMode);
  }

  /// AI expression 指令 → 切表情（占位立绘直接响应）
  void _onExpression(String expr) {
    if (!kExpressionLabels.containsKey(expr)) {
      DebugLogger.log('桌宠', '未知表情 $expr，忽略');
      return;
    }
    DebugLogger.log('桌宠', '立绘表情切换 → $expr');
    if (mounted) setState(() => _expression = expr);
  }

  /// 立绘覆盖层：全屏大图 + 表情按钮行 + 关闭
  Widget _buildPortraitOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xF7FDF0F5),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Color(0xFF9A7B8C)),
                      onPressed: _togglePortraitMode,
                    ),
                    Text(
                      '立绘 · ${kExpressionLabels[_expression] ?? _expression}',
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF9A7B8C)),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: PlaceholderPortrait(
                    expression: _expression,
                    size: MediaQuery.of(context).size.width * 0.72,
                  ),
                ),
              ),
              // 表情按钮行
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: kExpressionLabels.entries.map((e) {
                    final selected = e.key == _expression;
                    return ChoiceChip(
                      label: Text(e.value,
                          style: TextStyle(
                              fontSize: 13,
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFF5A4049))),
                      selected: selected,
                      selectedColor: const Color(0xFFB0789A),
                      backgroundColor: const Color(0xFFFDF6F9),
                      onSelected: (_) =>
                          setState(() => _expression = e.key),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 陪伴计时覆盖层：大数字 + 进度条 + 控制按钮
  Widget _buildTimerOverlay() {
    final timer = _timer!;
    final mm = (timer.displaySec ~/ 60).toString().padLeft(2, '0');
    final ss = (timer.displaySec % 60).toString().padLeft(2, '0');
    final modeLabel = timer.mode == PetTimerMode.countdown ? '倒计时' : '正计时';
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: true,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0x33B0789A),
                Colors.transparent,
                const Color(0x22B0789A),
              ],
            ),
          ),
          child: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 52),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xE6FDF6F9),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Color(0x33B0789A), blurRadius: 12),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$modeLabel · 陪伴中',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9A7B8C))),
                      const SizedBox(height: 4),
                      Text(
                        '$mm:$ss',
                        style: const TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF5A4049),
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: timer.progress,
                          minHeight: 6,
                          backgroundColor: const Color(0x33B0789A),
                          valueColor: const AlwaysStoppedAnimation(
                              Color(0xFFB0789A)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (timer.running)
                            IconButton(
                              icon: const Icon(Icons.pause_circle,
                                  color: Color(0xFFB0789A), size: 30),
                              onPressed: _pauseTimer,
                            )
                          else
                            IconButton(
                              icon: const Icon(Icons.play_circle,
                                  color: Color(0xFFB0789A), size: 30),
                              onPressed: _startTimer,
                            ),
                          IconButton(
                            icon: const Icon(Icons.refresh,
                                color: Color(0xFF9A7B8C), size: 24),
                            onPressed: _resetTimer,
                          ),
                          IconButton(
                            icon: const Icon(Icons.swap_horiz,
                                color: Color(0xFF9A7B8C), size: 24),
                            tooltip: '正/倒计时切换',
                            onPressed: _switchTimerMode,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部 AI 输入框（发送 → _sendAiChat）
  Widget _buildAiInput() {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(28),
      color: const Color(0xF2FDF6F9),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 6, top: 4, bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                enabled: !_aiBusy,
                maxLines: 1,
                style: const TextStyle(fontSize: 15, color: Color(0xFF5A4049)),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: _aiBusy ? '男主演出中…' : '跟男主说话…（可用 pet_action 指挥演出）',
                  hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                ),
                onSubmitted: _sendAiChat,
              ),
            ),
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFB0789A),
                foregroundColor: Colors.white,
              ),
              icon: _aiBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send, size: 18),
              onPressed: _aiBusy ? null : () => _sendAiChat(_inputCtrl.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// 热点图标（第一版：形状 + emoji 占位，素材体系后续版本）
class _HotspotIcon extends StatelessWidget {
  final sm.PetHotspotType type;
  const _HotspotIcon({required this.type});

  @override
  Widget build(BuildContext context) {
    final (emoji, color) = switch (type) {
      sm.PetHotspotType.point => ('✨', const Color(0x66B0789A)),
      sm.PetHotspotType.furniture => ('🛋️', const Color(0x66A078B0)),
      sm.PetHotspotType.item => ('🎁', const Color(0x66B09A78)),
      sm.PetHotspotType.area => ('', const Color(0x1AB0789A)),
    };
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: const Color(0x99B0789A), width: 2),
      ),
      alignment: Alignment.center,
      child: Text(emoji, style: const TextStyle(fontSize: 20)),
    );
  }
}
