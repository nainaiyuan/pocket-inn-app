import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../butler/pet/pet.dart';
import '../../butler/pet/pet_bridge.dart';
import '../../butler/pet/pet_engine.dart';
import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_scene.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_frame_source_impl.dart';
import '../../services/pet_settings_notifier.dart';
import '../../utils/debug_logger.dart';

/// 陪伴页面 —— 桌宠世界
///
/// 男主可视化形象：多小人同屏、帧动画、移动、气泡、投喂、组合动作。
/// 所有逻辑在 butler/pet 纯 Dart 模块，这里只做渲染和交互。
class CompanionPage extends StatefulWidget {
  const CompanionPage({super.key});

  @override
  State<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends State<CompanionPage>
    with SingleTickerProviderStateMixin {
  PetWorld? _world;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  /// 每个小人的气泡数据（petId → 数据）
  final Map<String, _SpeechData> _speeches = {};

  /// 投喂模式：选中的食物 id（null = 未选择）
  String? _feedingItemId;

  /// 全局提示（好感度变化等）
  String? _toast;
  Timer? _toastTimer;

  /// 导航小圈：当前被控制的小人（一次一个）；拖小人到圈上绑定
  String? _joystickPetId;
  Offset _joystickVec = Offset.zero;
  final GlobalKey _joystickKey = GlobalKey();

  int _speechSeq = 0;

  @override
  void initState() {
    super.initState();
    _initWorld();
  }

  Future<void> _initWorld() async {
    final world = PetWorld(store: PetStore(), frames: FilePetFrameSource());
    await world.restore();
    await world.preloadAll();
    // 按右页设置同步小人（首次自动创建男主小人）
    await world.syncVisible();
    _syncSpeakCallbacks(world);
    // 加载互动组运行时（距离自动触发用）
    await _loadGroupRuntimes(world);

    // 右页改设置 → 同步场景
    PetSettingsNotifier.instance.addListener(_onPetSettingsChanged);

    // 互动事件 → 男主"看得见"（这里先本地记录，AI 桥后续接入管家）
    world.events.stream.listen(_onInteraction);

    if (!mounted) return;
    setState(() => _world = world);
    _ticker = createTicker(_onTick)..start();

    // 桌宠桥：男主指令队列立即执行
    PetBridge.instance.attach(world);
  }

  /// 从数据库加载所有互动组（def + 各坑动作库 + 帧）注入场景，供距离自动触发
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
      DebugLogger.log('桌宠', '互动组运行时加载完成：${runtimes.length} 组');
    } catch (e) {
      DebugLogger.log('桌宠', '加载互动组运行时失败: $e');
    }
  }

  void _syncSpeakCallbacks(PetWorld world) {
    for (final pet in world.scene.pets) {
      pet.onSpeak = (petId, text) => _showSpeech(petId, text);
    }
  }

  void _onPetSettingsChanged() {
    final world = _world;
    if (world == null) return;
    world.syncVisible().then((_) {
      if (!mounted) return;
      _syncSpeakCallbacks(world);
      // 互动组增删改后同步运行时
      _loadGroupRuntimes(world);
      setState(() {});
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
    // 导航小圈：控制绑定的那个小人跟着圈动
    final jid = _joystickPetId;
    if (jid != null && _joystickVec != Offset.zero) {
      final jpet = world.scene.petById(jid);
      if (jpet != null) {
        const speed = 0.5;
        jpet.position = jpet.clampToArea(PetPoint(
          jpet.position.x + _joystickVec.dx * speed * dt,
          jpet.position.y + _joystickVec.dy * speed * dt,
        ));
      }
    }
    setState(() {}); // 每帧刷新帧动画/移动
  }

  void _onInteraction(PetInteractionEvent e) {
    DebugLogger.log('桌宠', '互动事件: ${e.summary}');
    if (e.type == PetInteractionType.feed) {
      _showSpeech(e.petId, '好吃！谢谢你～');
    }
  }

  void _showSpeech(String petId, String text) {
    _speechSeq++;
    setState(() {
      _speeches[petId] = _SpeechData(text: text, seq: _speechSeq);
    });
  }

  void _dismissSpeech(String petId) {
    if (!mounted) return;
    setState(() => _speeches.remove(petId));
  }

  void _showToast(String msg) {
    _toastTimer?.cancel();
    setState(() => _toast = msg);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  String _petName(String id) {
    final world = _world;
    if (world == null) return id;
    return world.scene.petById(id)?.name ?? id;
  }

  @override
  void dispose() {
    PetSettingsNotifier.instance.removeListener(_onPetSettingsChanged);
    PetBridge.instance.detach();
    _ticker?.dispose();
    _toastTimer?.cancel();
    _world?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final world = _world;
    if (world == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          // 背景
          const _PetBackground(),
          // 小人层
          ...world.scene.pets.map((pet) => _buildPetLayer(world, pet)),
          // 投喂模式提示
          if (_feedingItemId != null) _buildFeedingHint(),
          // 全局提示
          if (_toast != null) _buildToast(),
          // 控制面板
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildControlPanel(world),
          ),
        ],
      ),
    );
  }

  // ========== 小人渲染 ==========

  Widget _buildPetLayer(PetWorld world, Pet pet) {
    return Positioned.fill(
      child: LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        const baseSize = 120.0;
        // 聊天页限制最大尺寸（图太大不撑爆）；模拟立绘场景不受此限制
        final size = (baseSize * pet.scale).clamp(0.0, 220.0);
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
                onPanEnd: (_) => _onPetDragEnd(world, pet, w, h),
                child: _PetFrameView(pet: pet, size: size),
              ),
            ),
            // 导航小圈绑定中的小人：粉色高亮圈
            if (_joystickPetId == pet.id)
              Positioned(
                left: left - 5,
                top: top - 5,
                width: size + 10,
                height: size + 10,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: const Color(0xFFB0789A), width: 2.5),
                    ),
                  ),
                ),
              ),
            // 气泡
            if (_speeches[pet.id] != null)
              Positioned(
                left: left + size / 2 - 90,
                top: top - 46,
                width: 180,
                child: _SpeechBubble(
                  data: _speeches[pet.id]!,
                  onFinished: () => _dismissSpeech(pet.id),
                ),
              ),
          ],
        );
      }),
    );
  }

  void _onPetTap(PetWorld world, Pet pet) {
    world.events.emit(PetInteractionEvent(
      type: PetInteractionType.tap,
      petId: pet.id,
      intensity: 0.5,
      x: pet.position.x,
      y: pet.position.y,
    ));
    // 投喂模式：点击小人 = 投喂
    final feeding = _feedingItemId;
    if (feeding != null) {
      _feedPet(world, pet, feeding);
      return;
    }
    // 随机做个动作
    const actions = ['jump', 'spin', 'wave', 'happy'];
    final action = actions[math.Random().nextInt(actions.length)];
    world.playAction(pet.id, action);
  }

  void _onPetLongPress(PetWorld world, Pet pet) {
    world.events.emit(PetInteractionEvent(
      type: PetInteractionType.pet,
      petId: pet.id,
      intensity: 0.85,
      x: pet.position.x,
      y: pet.position.y,
    ));
    _showSpeech(pet.id, '嗯…好舒服');
    world.playAction(pet.id, 'happy');
  }

  void _onPetDrag(PetWorld world, Pet pet, DragUpdateDetails d, double w, double h) {
    if (w <= 0 || h <= 0) return;
    // 互动组在演 → 提起来暂停（放下续播）
    final groupRun = world.scene.groupRun;
    if (groupRun != null && groupRun.cast.contains(pet)) {
      world.scene.pauseGroup();
    }
    // 双人互动中拖走 = 打断（留下的一方播配置的"被打断后动作"）
    if (pet.inDuo) {
      world.breakDuo(pet.id);
    }
    pet.position = pet.clampToArea(PetPoint(
      pet.position.x + d.delta.dx / w,
      pet.position.y + d.delta.dy / h,
    ));
    // 速度 → 强度：拖得快 = 兴奋
    final speed = d.delta.distance;
    world.events.emit(PetInteractionEvent(
      type: PetInteractionType.drag,
      petId: pet.id,
      intensity: (speed / 12).clamp(0.0, 1.0),
      x: pet.position.x,
      y: pet.position.y,
    ));
  }

  /// 松手时检查：旁边有没有另一个小人 → 靠近就触发双人互动
  /// 小人拖拽结束：落在导航小圈上 = 绑定控制；绑定的被拖走 = 解除
  void _onPetDragEnd(PetWorld world, Pet pet, double w, double h) {
    final rect = _joystickRect();
    if (rect != null) {
      final screenPos = Offset(pet.position.x * w, pet.position.y * h);
      if (rect.inflate(14).contains(screenPos)) {
        setState(() => _joystickPetId = pet.id);
        _showToast('已绑定「${pet.name}」，动小圈控制它');
        return;
      }
      if (_joystickPetId == pet.id) {
        setState(() => _joystickPetId = null);
        _showToast('已解除控制');
      }
    }
    world.scene.resumeGroup();
    _maybeStartDuo(world, pet);
  }

  /// 导航小圈在屏幕上的位置（用于判断小人是否拖到圈上）
  Rect? _joystickRect() {
    final box = _joystickKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }

  void _maybeStartDuo(PetWorld world, Pet pet) {
    // 互动组在演时，旧的"松手贴贴"不触发，避免两套系统打架
    if (world.scene.groupRun != null) return;
    final duoActions = world.scene.actionDefs.values
        .where((d) => d.kind == PetActionKind.duo)
        .toList();
    if (duoActions.isEmpty) return;
    Pet? partner;
    for (final p in world.scene.pets) {
      if (p.id != pet.id &&
          !p.inDuo &&
          pet.position.distanceTo(p.position) < 0.16) {
        partner = p;
        break;
      }
    }
    if (partner == null) return;
    // 已配置的角色互动优先（配对 + 指定动作）
    PetStore().duoConfigs().then((configs) {
      if (!mounted) return;
      for (final c in configs) {
        if (c.matches(pet.id, partner!.id)) {
          if (world.scene.actionDefs.containsKey(c.actionId)) {
            world.startDuo(pet.id, partner.id, c.actionId);
            return;
          }
        }
      }
      // 没配置：单个互动动作直接用，多个让用户选
      if (duoActions.length == 1) {
        world.startDuo(pet.id, partner!.id, duoActions.first.id);
        return;
      }
      showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('选一个互动吧',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final a in duoActions)
                ListTile(
                  leading: const Icon(Icons.favorite_rounded,
                      color: Color(0xFFB0789A)),
                  title: Text(a.name),
                  subtitle: Text('${a.frameCount} 帧 · ${a.durationSeconds}秒'),
                  onTap: () {
                    Navigator.pop(ctx);
                    world.startDuo(pet.id, partner!.id, a.id);
                  },
                ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _feedPet(PetWorld world, Pet pet, String itemId) async {
    final result = await world.feed(pet.id, itemId);
    setState(() => _feedingItemId = null);
    if (result.success) {
      final item = PetBuiltinFoods.byId(itemId);
      _showSpeech(pet.id, '${item?.emoji ?? ''} 好吃！');
    } else {
      _showToast('投喂失败');
    }
  }

  Widget _buildFeedingHint() {
    final item = _feedingItemId != null
        ? PetBuiltinFoods.byId(_feedingItemId!)
        : null;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${item?.emoji ?? ''} 投喂模式：点一下小人喂它 ${item?.name ?? ''}',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }

  Widget _buildToast() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 56,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFFFD6E0).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(_toast!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A4A5A))),
        ),
      ),
    );
  }

  // ========== 控制面板 ==========

  Widget _buildControlPanel(PetWorld world) {
    final actions = world.scene.actionDefs.values.toList();
    final activities = world.scene.activities.values.toList();
    final primaryPet = world.scene.pets.isNotEmpty ? world.scene.pets.first : null;

    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 导航小圈：拖小人到圈上 = 控制它，动圈小人跟着动
          Row(
            children: [
              _NavJoystick(
                key: _joystickKey,
                size: 68,
                onVecChanged: (v) => setState(() => _joystickVec = v),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _joystickPetId == null
                    ? const Text('把小人拖到小圈上 = 控制它，动圈它跟着动（一次一个）',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFFB0A0A6)))
                    : Text('正在控制：${_petName(_joystickPetId!)}（把它拖走解除）',
                        style: const TextStyle(
                            fontSize: 11.5, color: Color(0xFF8A5A72))),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 输入框：打字 → 小人头上气泡
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputController,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (text) {
                    if (text.trim().isEmpty || primaryPet == null) return;
                    world.speak(primaryPet.id, text.trim());
                    _inputController.clear();
                  },
                  decoration: InputDecoration(
                    hintText: '打字，让男主说出来…',
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF5F0F6),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: () {
                  final text = _inputController.text;
                  if (text.trim().isEmpty || primaryPet == null) return;
                  world.speak(primaryPet.id, text.trim());
                  _inputController.clear();
                },
                icon: const Icon(Icons.send_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 动作按钮
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final a in actions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(a.name, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        if (primaryPet == null) return;
                        world.playAction(primaryPet.id, a.id);
                        DebugLogger.log('桌宠', '播放动作: ${a.id}');
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 食物 + 组合动作
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final f in PetBuiltinFoods.all)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: Text(f.emoji, style: const TextStyle(fontSize: 14)),
                      label: Text('${f.name}+${f.value}',
                          style: const TextStyle(fontSize: 11)),
                      selected: _feedingItemId == f.id,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        setState(() =>
                            _feedingItemId = _feedingItemId == f.id ? null : f.id);
                      },
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: VerticalDivider(width: 1),
                ),
                for (final act in activities)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: const Icon(Icons.play_arrow_rounded,
                          size: 14, color: Color(0xFFB0789A)),
                      label: Text(act.name, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        if (primaryPet == null) return;
                        world.runActivity(primaryPet.id, act.id);
                        DebugLogger.log('桌宠', '运行组合动作: ${act.name}');
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('编组合', style: TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openActivityEditor(world),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  final TextEditingController _inputController = TextEditingController();

  void _openActivityEditor(PetWorld world) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ActivityEditorSheet(world: world),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }
}

/// 气泡数据
class _SpeechData {
  final String text;
  final int seq;
  const _SpeechData({required this.text, required this.seq});
}

/// 背景
/// 导航小圈：拖动摇杆头 → 回调归一化方向向量（-1~1）；松手回中回调零向量
class _NavJoystick extends StatefulWidget {
  final double size;
  final ValueChanged<Offset> onVecChanged;

  const _NavJoystick({super.key, required this.size, required this.onVecChanged});

  @override
  State<_NavJoystick> createState() => _NavJoystickState();
}

class _NavJoystickState extends State<_NavJoystick> {
  Offset _vec = Offset.zero;

  void _update(Offset localPos) {
    final radius = widget.size / 2;
    final center = Offset(radius, radius);
    var v = localPos - center;
    final len = v.distance;
    if (len > radius) v = v / len * radius; // 限制在圆内
    final norm = len == 0 ? Offset.zero : v / radius; // 归一化 -1~1
    setState(() => _vec = v);
    widget.onVecChanged(norm);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final radius = size / 2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (d) => _update(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) {
        setState(() => _vec = Offset.zero);
        widget.onVecChanged(Offset.zero);
      },
      onPanCancel: () {
        setState(() => _vec = Offset.zero);
        widget.onVecChanged(Offset.zero);
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x33F0E4EA),
          border: Border.all(color: const Color(0xFFD8C0CA), width: 1.5),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 十字刻度
            CustomPaint(
                size: Size(size, size), painter: _JoystickGridPainter()),
            // 摇杆头
            Positioned(
              left: radius - 16 + _vec.dx,
              top: radius - 16 + _vec.dy,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFB0789A),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小圈十字刻度
class _JoystickGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x44D8C0CA)
      ..strokeWidth = 1;
    final c = size.center(Offset.zero);
    canvas.drawLine(Offset(c.dx, 0), Offset(c.dx, size.height), paint);
    canvas.drawLine(Offset(0, c.dy), Offset(size.width, c.dy), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PetBackground extends StatelessWidget {
  const _PetBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFFD6E0),
            Color(0xFFD6C8E8),
            Color(0xFFC8D8E8),
          ],
        ),
      ),
    );
  }
}

/// 小人帧渲染：真实帧图 or 占位图形
class _PetFrameView extends StatelessWidget {
  final Pet pet;
  final double size;

  const _PetFrameView({required this.pet, required this.size});

  @override
  Widget build(BuildContext context) {
    final frame = pet.currentFrame;
    Widget child;
    if (frame == null) {
      child = const SizedBox.shrink();
    } else if (frame.startsWith('placeholder:')) {
      final parsed = PetPlaceholderFrames.parse(frame);
      child = CustomPaint(
        painter: _PlaceholderPainter(
          actionId: parsed?.$1 ?? 'idle',
          index: parsed?.$2 ?? 0,
          total: parsed?.$3 ?? 1,
          color: const Color(0xFFB0789A),
        ),
      );
    } else {
      child = Image.file(
        File(frame),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }

    // 朝向：朝左镜像（双人互动时图里已画好方向，不镜像）
    if (pet.facing == PetFacing.left && !pet.inDuo) {
      child = Transform.flip(flipX: true, child: child);
    }
    // 自动过渡：动作切换时 0.15s 淡入，衔接不突兀
    if (pet.transitionOpacity < 1) {
      child = Opacity(opacity: pet.transitionOpacity, child: child);
    }
    return child;
  }
}

/// 占位图形绘制（用户没放图时的小人形）
class _PlaceholderPainter extends CustomPainter {
  final String actionId;
  final int index;
  final int total;
  final Color color;

  _PlaceholderPainter({
    required this.actionId,
    required this.index,
    required this.total,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final baseY = h * 0.72;

    // 弹跳类动作：上下动
    var dy = 0.0;
    var rotation = 0.0;
    var dx = 0.0;
    switch (actionId) {
      case 'jump':
        dy = -PetPlaceholderFrames.bounce(index, total) * h * 0.45;
        break;
      case 'happy':
      case 'wave':
        dy = -PetPlaceholderFrames.bounce(index, total) * h * 0.12;
        break;
      case 'spin':
        rotation = PetPlaceholderFrames.rotate(index, total);
        break;
      case 'walk':
      case 'run':
        dx = math.sin(index / math.max(1, total) * math.pi * 2) * w * 0.06;
        dy = -math.cos(index / math.max(1, total) * math.pi * 2).abs() *
            h *
            0.04;
        break;
      default: // idle 轻微呼吸
        dy = -math.sin(index / math.max(1, total) * math.pi * 2) * h * 0.015;
    }

    canvas.save();
    canvas.translate(cx + dx, baseY + dy);
    if (rotation != 0) {
      canvas.rotate(rotation * math.pi / 180);
    }

    final headPaint = Paint()..color = color;
    final bodyPaint = Paint()..color = color.withValues(alpha: 0.55);

    // 头
    canvas.drawCircle(Offset(0, -h * 0.22), w * 0.17, headPaint);
    // 身体
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset(0, h * 0.02), width: w * 0.3, height: h * 0.34),
      const Radius.circular(10),
    );
    canvas.drawRRect(bodyRect, bodyPaint);
    // 眼睛
    final eyePaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(-w * 0.05, -h * 0.24), w * 0.045, eyePaint);
    canvas.drawCircle(Offset(w * 0.07, -h * 0.24), w * 0.045, eyePaint);
    final pupilPaint = Paint()..color = const Color(0xFF5A3A4A);
    canvas.drawCircle(Offset(-w * 0.045, -h * 0.24), w * 0.02, pupilPaint);
    canvas.drawCircle(Offset(w * 0.075, -h * 0.24), w * 0.02, pupilPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlaceholderPainter old) =>
      old.index != index || old.actionId != actionId;
}

/// 气泡（打字机效果）
class _SpeechBubble extends StatefulWidget {
  final _SpeechData data;
  final VoidCallback onFinished;

  const _SpeechBubble({required this.data, required this.onFinished});

  @override
  State<_SpeechBubble> createState() => _SpeechBubbleState();
}

class _SpeechBubbleState extends State<_SpeechBubble> {
  int _shown = 0;
  Timer? _typeTimer;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    _typeTimer = Timer.periodic(const Duration(milliseconds: 40), (t) {
      if (_shown >= widget.data.text.length) {
        t.cancel();
        _holdTimer = Timer(const Duration(seconds: 3), widget.onFinished);
        return;
      }
      setState(() => _shown++);
    });
  }

  @override
  void dispose() {
    _typeTimer?.cancel();
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.data.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8D0E0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        text.length <= _shown ? text : text.substring(0, _shown),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12.5, height: 1.3),
      ),
    );
  }
}

/// 组合动作编辑器（底部弹窗）
class _ActivityEditorSheet extends StatefulWidget {
  final PetWorld world;

  const _ActivityEditorSheet({required this.world});

  @override
  State<_ActivityEditorSheet> createState() => _ActivityEditorSheetState();
}

class _ActivityEditorSheetState extends State<_ActivityEditorSheet> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _speakController = TextEditingController();
  final List<PetActivityStep> _steps = [];

  static const List<PetSpot> _spots = [
    PetSpot.center,
    PetSpot.leftThird,
    PetSpot.rightThird,
    PetSpot.topThird,
    PetSpot.bottomThird,
  ];

  @override
  Widget build(BuildContext context) {
    final actions = widget.world.scene.actionDefs.values.toList();
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: const BoxDecoration(
        color: Color(0xFFFDF8FB),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('组合动作编辑器',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ),
          // 名字 + 保存
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: '组合动作名字（如：打招呼）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _save,
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
          // 动作源
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: [
                for (final a in actions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(a.name, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _steps.add(
                          PetActivityStep(actionId: a.id))),
                    ),
                  ),
                for (final s in _spots)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text('走到${_spotName(s)}',
                          style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _steps.add(
                          PetActivityStep(actionId: 'moveTo', targetSpot: s))),
                    ),
                  ),
              ],
            ),
          ),
          // 说话步骤
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _speakController,
                    decoration: const InputDecoration(
                      hintText: '说句话（气泡）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    final t = _speakController.text.trim();
                    if (t.isEmpty) return;
                    setState(() {
                      _steps.add(PetActivityStep(actionId: 'speak', text: t));
                      _speakController.clear();
                    });
                  },
                  child: const Text('加说话'),
                ),
              ],
            ),
          ),
          // 步骤列表
          Expanded(
            child: _steps.isEmpty
                ? const Center(
                    child: Text('点上面的动作添加步骤',
                        style: TextStyle(color: Colors.grey, fontSize: 13)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _steps.length,
                    itemBuilder: (context, i) => _buildStepTile(i),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepTile(int i) {
    final step = _steps[i];
    final label = step.isSpeak
        ? '💬 ${step.text}'
        : step.targetSpot != null
            ? '🚶 走到${_spotName(step.targetSpot!)}'
            : '🎬 ${_actionName(step.actionId)}';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Text('${i + 1}', style: const TextStyle(fontSize: 13)),
        title: Text(label, style: const TextStyle(fontSize: 13)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_upward, size: 16),
              onPressed: i == 0
                  ? null
                  : () => setState(() {
                        final s = _steps.removeAt(i);
                        _steps.insert(i - 1, s);
                      }),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_downward, size: 16),
              onPressed: i >= _steps.length - 1
                  ? null
                  : () => setState(() {
                        final s = _steps.removeAt(i);
                        _steps.insert(i + 1, s);
                      }),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 16),
              onPressed: () => setState(() => _steps.removeAt(i)),
            ),
          ],
        ),
      ),
    );
  }

  String _actionName(String id) {
    return widget.world.scene.actionDefs[id]?.name ?? id;
  }

  static String _spotName(PetSpot spot) {
    switch (spot) {
      case PetSpot.center:
        return '中间';
      case PetSpot.leftThird:
        return '左1/3';
      case PetSpot.rightThird:
        return '右1/3';
      case PetSpot.topThird:
        return '上1/3';
      case PetSpot.bottomThird:
        return '下1/3';
      default:
        return spot.name;
    }
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先给组合动作起个名字')),
      );
      return;
    }
    if (_steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有步骤')),
      );
      return;
    }
    final id = 'act_${DateTime.now().millisecondsSinceEpoch}';
    final def = PetActivityDef(id: id, name: name, steps: List.of(_steps));
    widget.world.scene.saveActivity(def);
    widget.world.store.saveActivity(def); // 持久化
    DebugLogger.log('桌宠', '保存组合动作: $name (${_steps.length}步)');
    Navigator.pop(context);
  }
}
