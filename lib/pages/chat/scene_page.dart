import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../butler/pet/pet.dart';
import '../../butler/pet/pet_bridge.dart';
import '../../butler/pet/pet_models.dart';
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
import 'state/current_character_state.dart';

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
    with SingleTickerProviderStateMixin {
  PetWorld? _world;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  sm.PetScene? _scene;
  List<sm.PetHotspot> _hotspots = const [];
  SceneDirector? _director;
  bool _loading = true;
  bool _missing = false;

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    PetBridge.instance
      ..sceneActive = false
      ..onCardShow = null;
    if (identical(PetBridge.instance.world, _world)) {
      PetBridge.instance.detach();
    }
    _ticker?.dispose();
    _director?.stop();
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _state.init();
    final store = PetStore();
    sm.PetScene? scene;
    final scenes = await store.allScenes();
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
    final world = PetWorld(store: store, frames: FilePetFrameSource());
    await world.restore();
    await world.preloadAll();
    await world.syncVisible();

    final director = SceneDirector(store: store, scene: scene)
      ..onNodeEntered = _onNodeEntered
      ..onCard = _onCard
      ..onFinished = _onSceneFinished;

    // 8-15 P1：AI 演出指令直达场景页——PetBridge.world 指向本页世界；
    // 桌宠页 ticker 通过 sceneActive 防抢回
    PetBridge.instance
      ..sceneActive = true
      ..attach(world)
      ..onCardShow = _onAiCard;

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
      if (!mounted) return;
      setState(() {
        _cardText = textOut.isEmpty ? '（男主没有回应）' : textOut;
        _aiBusy = false;
      });
    } catch (e) {
      DebugLogger.log('桌宠', '场景 AI 对话失败: $e');
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _aiError = '对话失败：$e';
      });
    }
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
          // 返回按钮
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xCCB0789A),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
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
            children: world.scene.pets.map((pet) {
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
            }).toList(),
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
