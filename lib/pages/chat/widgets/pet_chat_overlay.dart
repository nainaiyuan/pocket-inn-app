import 'dart:async';

import 'package:flutter/gestures.dart';
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
  /// 8-14 14:5x（用户：拖小人不触发页面滑动）：拖动开始/结束回调，
  /// 聊天页据此锁定/解锁消息列表滚动
  final ValueChanged<bool>? onDragStateChanged;

  const PetChatOverlay({super.key, this.onDragStateChanged});

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
            // 8-14 16:5x（用户：单个动作不能测试吗？一定要多个组合？）：
            // 长按 → 测试动作：列出该小人的动作（自己的+共享+内置），点播
            ListTile(
              leading: const Icon(Icons.play_circle_outline,
                  color: Color(0xFFB0789A)),
              title: const Text('测试动作', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.pop(ctx);
                _showTestActionSheet(world, pet);
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

  /// 8-14 16:5x：测试单个动作（用户动作 + 内置动作，点播立即生效）
  Future<void> _showTestActionSheet(PetWorld world, Pet pet) async {
    final store = PetStore();
    List<PetActionDef> mine = const [];
    try {
      final all = await store.allActions();
      mine = all.where((a) => a.profileId == pet.id).toList();
    } catch (_) {}
    final builtins = PetBuiltinActions.all
        .where((a) => a.id != 'idle')
        .toList();
    if (!mounted) return;
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
              '测试动作 · ${pet.name}',
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6A4A5A)),
            ),
            const SizedBox(height: 4),
            const Text('点一个立刻播放，移动动作会从起点走到目标',
                style: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (mine.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('还没有自己的动作，去配置桌宠里新建',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFFB0A0A6))),
                    ),
                  for (final a in mine)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.upload_file,
                          size: 18, color: Color(0xFFB0789A)),
                      title: Text(a.name,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: const Text('我的动作',
                          style: TextStyle(fontSize: 10)),
                      onTap: () {
                        Navigator.pop(ctx);
                        world.playAction(pet.id, a.id);
                      },
                    ),
                  const Divider(height: 1),
                  for (final a in builtins)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.auto_awesome,
                          size: 18, color: Color(0xFFC0A0B0)),
                      title: Text(a.name,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: const Text('内置',
                          style: TextStyle(fontSize: 10)),
                      onTap: () {
                        Navigator.pop(ctx);
                        world.playAction(pet.id, a.id);
                      },
                    ),
                ],
              ),
            ),
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
    // 8-14 16:5x：只在拖的是互动组成员时才恢复互动组——
    // 拖没参与互动组的小人，互动组状态一点不动（其他小人该干嘛干嘛）
    final groupRun = world.scene.groupRun;
    if (groupRun != null && groupRun.cast.contains(pet)) {
      world.scene.resumeGroup();
    }
  }

  // ---------------- 8-14 16:1x：eager pan 自管理手势 ----------------
  bool _panMoved = false;
  bool _panLongPressHandled = false;
  Timer? _panLongPressTimer;

  /// 8-14 16:3x（用户：点一个小人，其他的所有手势锁定；没点的小人
  /// 自己玩自己的）：当前被触摸的小人 id——其他小人手势禁用（纯展示，
  /// 自主行动动画照常），列表滚动已由 onDragStateChanged 锁。
  String? _touchingPetId;

  void _onPetPanStart(PetWorld world, Pet pet) {
    _panMoved = false;
    _panLongPressHandled = false;
    if (_touchingPetId != pet.id) {
      setState(() => _touchingPetId = pet.id);
    }
    widget.onDragStateChanged?.call(true);
    // 长按候选：500ms 内没移动 = 长按（摸摸头/调大小/去配置菜单）
    _panLongPressTimer?.cancel();
    _panLongPressTimer = Timer(const Duration(milliseconds: 500), () {
      _panLongPressHandled = true;
      _onPetLongPress(world, pet);
    });
  }

  void _onPetPanUpdate(PetWorld world, Pet pet, DragUpdateDetails d, double w,
      double h) {
    if (d.delta.distance > 2) {
      _panMoved = true;
      _panLongPressTimer?.cancel();
    }
    if (_panLongPressHandled) return; // 长按已触发，忽略后续拖动
    _onPetDrag(world, pet, d, w, h);
  }

  void _onPetPanEnd(PetWorld world, Pet pet) {
    _panLongPressTimer?.cancel();
    if (_touchingPetId != null) {
      setState(() => _touchingPetId = null);
    }
    widget.onDragStateChanged?.call(false);
    if (_panLongPressHandled) {
      _panLongPressHandled = false;
      return;
    }
    if (!_panMoved) {
      _onPetTap(world, pet); // 没动 = 点击
    }
    _onPetDragEnd(world, pet);
  }

  void _onPetPanCancel() {
    _panLongPressTimer?.cancel();
    if (_touchingPetId != null) {
      setState(() => _touchingPetId = null);
    }
    widget.onDragStateChanged?.call(false);
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
    // 聊天页小人自由活动：撞到消息区边界自己停（clamp 到区域内），
    // 不限制高度——8-14 14:4x（用户：不要限高，他撞墙自己撞，
    // 只要不跑到输入框下面就行；overlay 覆盖消息区，底部=输入框顶）
    final size = (baseSize * pet.scale).clamp(0.0, 180.0);
    final left = (pet.position.x * w - size / 2).clamp(0.0, w - size);
    final top = (pet.position.y * h - size / 2).clamp(0.0, h - size);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: left,
          top: top,
          width: size,
          height: size,
          // 8-14 16:1x 必杀技（用户：小人就是另一个导航球，要能随时
          // 全方位拖动、绝不触发其他任何东西）：自定义 eager pan——
          // 触摸小人的瞬间立即在竞技场宣布胜利，ListView 滚动识别器
          // 直接出局，列表绝对不滚。点击/长按/拖动全部自管理
          // （eager pan 会吞掉 onTap/onLongPress，所以自己判定）。
          // 8-14 16:3x：全局手势锁——正在拖 A 时，B/C 不注册手势
          // （纯展示 PetFrameView，自主行动动画照常，只是不能同时拖）。
          child: (_touchingPetId != null && _touchingPetId != pet.id)
              ? PetFrameView(pet: pet, size: size)
              : RawGestureDetector(
                  gestures: {
                    _EagerPanRecognizer: GestureRecognizerFactoryWithHandlers<
                        _EagerPanRecognizer>(
                      () => _EagerPanRecognizer(),
                      (r) {
                        r.onStart = (_) {
                          _onPetPanStart(world, pet);
                        };
                        r.onUpdate = (d) {
                          _onPetPanUpdate(world, pet, d, w, h);
                        };
                        r.onEnd = (_) {
                          _onPetPanEnd(world, pet);
                        };
                        r.onCancel = () {
                          _onPetPanCancel();
                        };
                      },
                    ),
                  },
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


/// 8-14 16:1x：立即获胜的 pan 识别器——addAllowedPointer 时直接
/// resolve(accepted)，竞技场当场判定胜利，下层 ListView 滚动识别器
/// 没有任何机会竞争 → 拖小人绝不触发列表滚动（导航球同款手感）。
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
