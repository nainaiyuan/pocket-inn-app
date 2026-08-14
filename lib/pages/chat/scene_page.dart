import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../butler/pet/pet.dart';
import '../../butler/pet/pet_scene.dart';
import '../../butler/pet/pet_store.dart';
import '../../butler/pet/scene_director.dart';
import '../../butler/pet/scene_models.dart' as sm;
import '../../services/pet_frame_source_impl.dart';
import '../../utils/debug_logger.dart';
import '../home/companion_page.dart' show PetFrameView;

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _director?.stop();
    super.dispose();
  }

  Future<void> _init() async {
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
    // 空选项卡片：点击继续（click / clickTarget）
    if (_cardChoices.isEmpty && !_cardDone) {
      _director?.userClick();
    }
  }

  void _onChoiceTap(sm.PetChoice c) {
    _director?.userChoose(c.choiceId);
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
                child: PetFrameView(pet: pet, size: size),
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
