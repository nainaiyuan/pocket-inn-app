import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../butler/pet/pet.dart';
import '../../../butler/pet/pet_bridge.dart';
import '../../../butler/pet/pet_models.dart';
import '../../../butler/pet/pet_scene.dart';
import '../../../butler/pet/pet_store.dart';
import '../../../services/pet_frame_source_impl.dart';
import '../../../services/pet_settings_notifier.dart';
import '../../../utils/debug_logger.dart';
import '../../butler/pet_setup_page.dart';
import '../../home/companion_page.dart' show PetFrameView, SpeechBubble, SpeechData;

/// 聊天页桌宠层 —— 趴在聊天框上方，和男主聊天时小人就在旁边互动
///
/// 位置：聊天页消息区和输入栏之间的一行区域（不挡消息、不挡输入）。
/// 交互：点一下 = 互动事件；长按 = 菜单（摸摸头/调大小/去配置）；
/// 拖拽 = 移动（互动组演到一半提起来暂停、放下续播）。
class PetChatOverlay extends StatefulWidget {
  const PetChatOverlay({super.key});

  @override
  State<PetChatOverlay> createState() => _PetChatOverlayState();
}

class _PetChatOverlayState extends State<PetChatOverlay>
    with SingleTickerProviderStateMixin {
  PetWorld? _world;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  final Map<String, SpeechData> _speeches = {};
  int _speechSeq = 0;
  // 8-14 07:0x：设置通知防抖——调大小滑块拖动会高频 notifyChanged，
  // 每次都全量重载互动组运行时（查库+读帧）→ 日志刷屏。
  Timer? _settingsDebounce;

  @override
  void initState() {
    super.initState();
    _initWorld();
  }

  Future<void> _initWorld() async {
    final world = PetWorld(store: PetStore(), frames: FilePetFrameSource());
    await world.restore();
    await world.preloadAll();
    await world.syncVisible();
    // 男主指令 → 聊天页桌宠直接执行
    PetBridge.instance.attach(world);
    // 互动组运行时（距离自动触发）
    await _loadGroupRuntimes(world);

    // 设置变更（勾选显示/调大小/互动组）→ 同步
    PetSettingsNotifier.instance.addListener(_onSettingsChanged);

    if (!mounted) return;
    setState(() => _world = world);
    _ticker = createTicker(_onTick)..start();
  }

  Future<void> _loadGroupRuntimes(PetWorld world) async {
    try {
      final store = PetStore();
      final groups = await store.allGroups();
      final runtimes = <PetGroupRuntime>[];
      for (final g in groups) {
        final slotActions = <String, PetActionDef>{};
        final slotFrames = <String, List<String>>{};
        for (final slot in g.slots) {
          final acts = await store.slotActions(slot.slotId);
          for (final a in acts) {
            slotActions[a.id] = a;
            slotFrames[a.id] = await FilePetFrameSource().framesFor(a.id);
          }
        }
        runtimes.add(PetGroupRuntime(
            def: g, slotActions: slotActions, slotFrames: slotFrames));
      }
      world.scene.groupRuntimes = runtimes;
      DebugLogger.log('桌宠', '聊天页互动组运行时加载：${runtimes.length} 组');
    } catch (e) {
      DebugLogger.log('桌宠', '聊天页加载互动组运行时失败: $e');
    }
  }

  void _onSettingsChanged() {
    // 防抖：高频通知合并成一次（滑块拖动期间不重复加载）
    _settingsDebounce?.cancel();
    _settingsDebounce = Timer(const Duration(milliseconds: 800), () {
      final world = _world;
      if (world == null) return;
      world.syncVisible().then((_) {
        if (!mounted) return;
        _loadGroupRuntimes(world);
        setState(() {});
      });
    });
  }

  void _onTick(Duration elapsed) {
    final world = _world;
    if (world == null) return;
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    world.update(dt.clamp(0.0, 0.1));
    setState(() {});
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _settingsDebounce?.cancel();
    PetSettingsNotifier.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  // ========== 交互 ==========

  void _onPetTap(PetWorld world, Pet pet) {
    world.events.emit(PetInteractionEvent(
      type: PetInteractionType.tap,
      petId: pet.id,
      intensity: 0.4,
      x: pet.position.x,
      y: pet.position.y,
    ));
  }

  void _onPetLongPress(PetWorld world, Pet pet) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(
              pet.name,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6A4A5A)),
            ),
            Text(
              '当前大小 ${(pet.scale * 100).round()}%',
              style:
                  const TextStyle(fontSize: 11, color: Color(0xFFB0A0A6)),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.volunteer_activism,
                  color: Color(0xFFB0789A)),
              title: const Text('摸摸头', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.pop(ctx);
                world.events.emit(PetInteractionEvent(
                  type: PetInteractionType.pet,
                  petId: pet.id,
                  intensity: 0.85,
                  x: pet.position.x,
                  y: pet.position.y,
                ));
                _showSpeech(pet.id, '嗯…好舒服');
                world.playAction(pet.id, 'happy');
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.straighten, color: Color(0xFFB0789A)),
              title: const Text('调大小', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.pop(ctx);
                _showScaleDialog(world, pet);
              },
            ),
            ListTile(
              leading: const Icon(Icons.pets, color: Color(0xFFB0789A)),
              title: const Text('去配置桌宠', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PetSetupPage()),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showScaleDialog(PetWorld world, Pet pet) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return AlertDialog(
            title: Text('「${pet.name}」的大小',
                style: const TextStyle(fontSize: 15)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: pet.scale.clamp(0.4, 2.0),
                  min: 0.4,
                  max: 2.0,
                  divisions: 32,
                  activeColor: const Color(0xFFB0789A),
                  label: '${(pet.scale * 100).round()}%',
                  onChanged: (v) async {
                    pet.scale = v;
                    setDlg(() {});
                    setState(() {});
                    final profiles = await world.store.allProfiles();
                    final profile = profiles
                        .where((p) => p.petId == pet.id)
                        .firstOrNull;
                    if (profile != null) {
                      profile.scale = v;
                      await world.store.saveProfile(profile);
                    }
                    PetSettingsNotifier.instance.notifyChanged();
                  },
                ),
                Text(
                  '${(pet.scale * 100).round()}%',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF6A4A5A)),
                ),
                const SizedBox(height: 4),
                const Text('50% 变小 · 100% 原样 · 200% 变大（每个角色单独设置）',
                    style: TextStyle(
                        fontSize: 10.5, color: Color(0xFFB0A0A6))),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('完成')),
            ],
          );
        },
      ),
    );
  }

  void _onPetDrag(PetWorld world, Pet pet, DragUpdateDetails d, double w,
      double h) {
    if (w <= 0 || h <= 0) return;
    // 互动组在演 → 提起来暂停（放下续播）
    final groupRun = world.scene.groupRun;
    if (groupRun != null && groupRun.cast.contains(pet)) {
      world.scene.pauseGroup();
    }
    if (pet.inDuo) {
      world.breakDuo(pet.id);
    }
    pet.position = pet.clampToArea(PetPoint(
      pet.position.x + d.delta.dx / w,
      pet.position.y + d.delta.dy / h,
    ));
    final speed = d.delta.distance;
    world.events.emit(PetInteractionEvent(
      type: PetInteractionType.drag,
      petId: pet.id,
      intensity: (speed / 12).clamp(0.0, 1.0),
      x: pet.position.x,
      y: pet.position.y,
    ));
  }

  void _onPetDragEnd(PetWorld world, Pet pet) {
    world.scene.resumeGroup();
  }

  void _showSpeech(String petId, String text) {
    _speechSeq++;
    setState(() {
      _speeches[petId] = SpeechData(text: text, seq: _speechSeq);
    });
  }

  void _dismissSpeech(String petId) {
    if (!mounted) return;
    setState(() => _speeches.remove(petId));
  }

  // ========== 渲染 ==========

  @override
  Widget build(BuildContext context) {
    final world = _world;
    if (world == null) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final pet in world.scene.pets)
              _buildPetLayer(world, pet, w, h),
          ],
        );
      },
    );
  }

  Widget _buildPetLayer(
      PetWorld world, Pet pet, double w, double h) {
    const baseSize = 100.0;
    // 聊天页里小人小一点（不抢聊天），最大 180
    final size = (baseSize * pet.scale).clamp(0.0, 180.0);
    final left = pet.position.x * w - size / 2;
    final top = pet.position.y * h - size / 2;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: left,
          top: top,
          width: size,
          height: size,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _onPetTap(world, pet),
            onLongPress: () => _onPetLongPress(world, pet),
            onPanUpdate: (d) => _onPetDrag(world, pet, d, w, h),
            onPanEnd: (_) => _onPetDragEnd(world, pet),
            child: PetFrameView(pet: pet, size: size),
          ),
        ),
        if (_speeches[pet.id] != null)
          Positioned(
            left: left + size / 2 - 90,
            top: top - 42,
            width: 180,
            child: SpeechBubble(
              data: _speeches[pet.id]!,
              onFinished: () => _dismissSpeech(pet.id),
            ),
          ),
      ],
    );
  }
}
