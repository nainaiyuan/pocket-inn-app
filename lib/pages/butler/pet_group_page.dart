import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../butler/pet/pet.dart';
import '../../butler/pet/pet_scene.dart';
import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_frame_source_impl.dart';
import '../../services/pet_settings_notifier.dart';
import '../../utils/debug_logger.dart';
import 'pet_widgets.dart';

/// 互动组配置页 —— 角色坑 × 剧本
///
/// 自由度很高，页面把每一步都写清楚：
/// - 角色坑：想几个人就几个坑；每坑绑定一个单人（仅显示名字）+ 自己的动作库（帧图）
/// - 剧本：一步步排；每步给每个坑选"播哪个动作 + 怎么动"
/// - 移动：原地 / 方向+距离 / 到某位置 / 靠近对方 / 离开对方 / 走到碰墙
class PetGroupPage extends StatefulWidget {
  final PetGroupDef? existing;

  const PetGroupPage({super.key, this.existing});

  @override
  State<PetGroupPage> createState() => _PetGroupPageState();
}

class _SlotEdit {
  String slotId;
  String label;
  String? bindPetId;
  List<PetActionDef> actions = [];

  _SlotEdit(this.slotId, this.label, {this.bindPetId});
}

class _SlotStepEdit {
  String slotId;
  String? actionId;
  PetGroupMoveType moveType = PetGroupMoveType.stay;
  PetMoveDir moveDir = PetMoveDir.left;
  double moveDist = 0.3;
  double approachDist = 0.05;
  double leaveDist = 0.3;
  PetPoint spot = const PetPoint(0.5, 0.5);

  _SlotStepEdit(this.slotId);
}

class _StepEdit {
  final TextEditingController durCtrl = TextEditingController();
  List<_SlotStepEdit> slotSteps = [];
}

class _PetGroupPageState extends State<PetGroupPage> {
  final _store = PetStore();
  late final TextEditingController _nameCtrl = TextEditingController();
  String? _groupId;
  bool _triggerOn = false;
  double _triggerDist = 0.5;
  String _exitMode = 'idle';
  List<_SlotEdit> _slots = [];
  List<_StepEdit> _steps = [];
  List<PetProfile> _profiles = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _store.allProfiles();
    final existing = widget.existing;
    if (existing != null) {
      _groupId = existing.id;
      _nameCtrl.text = existing.name;
      _triggerOn = existing.triggerDist != null;
      _triggerDist = existing.triggerDist ?? 0.5;
      _exitMode = existing.exitMode;
      // 坑 + 各坑动作库
      for (final slot in existing.slots) {
        final acts = await _store.slotActions(slot.slotId);
        final edit = _SlotEdit(slot.slotId, slot.label,
            bindPetId: slot.bindPetId)
          ..actions = acts;
        _slots.add(edit);
      }
      // 剧本
      for (final step in existing.steps) {
        final edit = _StepEdit();
        if (step.duration != null) {
          edit.durCtrl.text = step.duration!.toStringAsFixed(1);
        }
        edit.slotSteps = [
          for (final ss in step.slotSteps)
            _SlotStepEdit(ss.slotId)
              ..actionId = ss.actionId
              ..moveType = ss.moveType
              ..moveDir = ss.moveDir ?? PetMoveDir.left
              ..moveDist = ss.moveDist ?? 0.3
              ..approachDist = ss.moveDist ?? 0.05
              ..leaveDist = ss.moveDist ?? 0.3
              ..spot = PetPoint(ss.targetX ?? 0.5, ss.targetY ?? 0.5),
        ];
        _steps.add(edit);
      }
    }
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      if (_slots.isEmpty) {
        _slots = [
          _SlotEdit('slot_${DateTime.now().millisecondsSinceEpoch}', '左半边'),
        ];
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ---------------- 坑 ----------------

  void _addSlot() {
    setState(() {
      final n = _slots.length;
      final label = switch (n) {
        0 => '左半边',
        1 => '右半边',
        _ => '角色${n + 1}',
      };
      final slot = _SlotEdit(
          'slot_${DateTime.now().millisecondsSinceEpoch}', label);
      _slots.add(slot);
      // 新坑自动进每个步骤
      for (final step in _steps) {
        step.slotSteps.add(_SlotStepEdit(slot.slotId));
      }
    });
  }

  void _removeSlot(_SlotEdit slot) {
    setState(() {
      _slots.remove(slot);
      for (final step in _steps) {
        step.slotSteps.removeWhere((s) => s.slotId == slot.slotId);
      }
    });
  }

  // ---------------- 剧本 ----------------

  void _addStep() {
    setState(() {
      final step = _StepEdit();
      step.slotSteps =
          _slots.map((s) => _SlotStepEdit(s.slotId)).toList();
      _steps.add(step);
    });
  }

  void _removeStep(_StepEdit step) {
    setState(() => _steps.remove(step));
  }

  // ---------------- 保存 ----------------

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('先给互动组起个名字');
      return;
    }
    if (_slots.isEmpty) {
      _toast('先加一个角色坑');
      return;
    }
    setState(() => _saving = true);
    final groupId = _groupId ?? 'grp_${DateTime.now().millisecondsSinceEpoch}';
    _groupId = groupId;
    final n = _slots.length;
    final slots = [
      for (var i = 0; i < _slots.length; i++)
        PetGroupSlot(
          slotId: _slots[i].slotId,
          index: i,
          bindPetId: _slots[i].bindPetId,
          label: _slots[i].label,
          // 初始摆位：均分横排
          x: (i + 1) / (n + 1),
          y: 0.6,
        ),
    ];
    final steps = [
      for (final st in _steps)
        PetGroupStep(
          [
            for (final ss in st.slotSteps)
              PetSlotStep(
                slotId: ss.slotId,
                actionId: ss.actionId,
                moveType: ss.moveType,
                moveDir: (ss.moveType == PetGroupMoveType.dir ||
                        ss.moveType == PetGroupMoveType.wall)
                    ? ss.moveDir
                    : null,
                moveDist: switch (ss.moveType) {
                  PetGroupMoveType.dir => ss.moveDist,
                  PetGroupMoveType.approach => ss.approachDist,
                  PetGroupMoveType.leave => ss.leaveDist,
                  _ => null,
                },
                targetX: ss.moveType == PetGroupMoveType.spot
                    ? ss.spot.x
                    : null,
                targetY: ss.moveType == PetGroupMoveType.spot
                    ? ss.spot.y
                    : null,
              ),
          ],
          duration: double.tryParse(st.durCtrl.text.trim()),
        ),
    ];
    final def = PetGroupDef(
      id: groupId,
      name: name,
      triggerDist: _triggerOn ? _triggerDist : null,
      exitMode: _exitMode,
      slots: slots,
      steps: steps,
      updatedAt: DateTime.now().toIso8601String(),
    );
    try {
      await _store.saveGroup(def);
    } catch (e) {
      DebugLogger.log('桌宠', '保存互动组失败: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
      return;
    }
    PetSettingsNotifier.instance.notifyChanged();
    if (!mounted) return;
    setState(() => _saving = false);
    _toast('已保存');
    Navigator.pop(context, true);
  }

  // ---------------- 试播 ----------------

  Future<void> _testPlay() async {
    final world = PetWorld.live;
    if (world == null) {
      _toast('先打开桌宠页（主界面），再回来点试播');
      return;
    }
    await _save();
    if (!mounted || _groupId == null) return;
    final groups = await _store.allGroups();
    final def = groups.where((g) => g.id == _groupId).firstOrNull;
    if (def == null || def.slots.isEmpty) {
      _toast('互动组没存上，试播不了');
      return;
    }
    // 坑动作库 + 帧
    final slotActions = <String, PetActionDef>{};
    final slotFrames = <String, List<String>>{};
    for (final slot in def.slots) {
      final acts = await _store.slotActions(slot.slotId);
      for (final a in acts) {
        slotActions[a.id] = a;
        slotFrames[a.id] = await FilePetFrameSource().framesFor(a.id);
      }
    }
    // 选角：绑定的小人在场就用，不在场/没绑定就建临时小人
    final tempIds = <String>[];
    final cast = <Pet>[];
    for (final slot in def.slots) {
      Pet? pet = slot.bindPetId != null
          ? world.scene.petById(slot.bindPetId!)
          : null;
      if (pet == null) {
        final tmpId = 'tmp_grp_${slot.slotId}';
        pet = world.scene.createPet(id: tmpId);
        pet.position = PetPoint(slot.x, slot.y);
        tempIds.add(tmpId);
      }
      cast.add(pet);
    }
    world.scene.onGroupFinished = (run) {
      for (final id in tempIds) {
        world.scene.removePet(id);
      }
    };
    world.scene.startGroup(def, cast, def.slots,
        slotActions: slotActions, slotFrames: slotFrames);
    _toast('试播中：到桌宠页看效果（播完自动收尾）');
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF6F8),
      appBar: AppBar(
        title: const Text('互动组'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF6A4A5A),
        elevation: 0.5,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionCard(
            children: [
              const Text('名字', style: TextStyle(fontSize: 12)),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  hintText: '比如：贴贴 / 追逐 / 安慰',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('距离近自动开始',
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text('两个小人走近到这个距离就自动开演',
                    style: TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
                value: _triggerOn,
                activeTrackColor: const Color(0xFFB0789A),
                onChanged: (v) => setState(() => _triggerOn = v),
              ),
              if (_triggerOn)
                Row(children: [
                  const Text('触发距离', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _triggerDist,
                      min: 0.1,
                      max: 1.0,
                      activeColor: const Color(0xFFB0789A),
                      onChanged: (v) => setState(() => _triggerDist = v),
                    ),
                  ),
                  Text('${(_triggerDist * 100).round()}%',
                      style: const TextStyle(fontSize: 12)),
                ]),
              const SizedBox(height: 4),
              const Text('演完怎么办', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'idle',
                      label: Text('回待机', style: TextStyle(fontSize: 10.5))),
                  ButtonSegment(
                      value: 'resume',
                      label: Text('接着刚才的单人动作',
                          style: TextStyle(fontSize: 10.5))),
                ],
                selected: {_exitMode},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _exitMode = s.first),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // ---------- 角色坑 ----------
          Row(children: [
            const Text('角色坑（想几个人就几个）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: _addSlot,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('加坑', style: TextStyle(fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          for (var i = 0; i < _slots.length; i++) _buildSlotCard(i),
          const SizedBox(height: 14),
          // ---------- 剧本 ----------
          Row(children: [
            const Text('剧本（一步步排，每步所有小人同时演）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: _addStep,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('加步骤', style: TextStyle(fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          if (_steps.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text('还没有步骤：「加步骤」→ 每步给每个坑选动作和怎么动',
                    style:
                        TextStyle(fontSize: 11.5, color: Color(0xFFB0A0A6))),
              ),
            ),
          for (var i = 0; i < _steps.length; i++) _buildStepCard(i),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _testPlay,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('试播', style: TextStyle(fontSize: 13)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB0789A)),
                child: const Text('保存', style: TextStyle(fontSize: 13)),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _sectionCard({required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x22D8C8CE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  // ---------------- 坑卡片 ----------------

  Widget _buildSlotCard(int i) {
    final slot = _slots[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x22D8C8CE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFF0E4EA),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('坑 ${i + 1}：${slot.label}',
                  style: const TextStyle(fontSize: 11.5)),
            ),
            const Spacer(),
            IconButton(
              onPressed: () => _removeSlot(slot),
              icon: const Icon(Icons.delete_outline, size: 18),
              color: const Color(0xFFC05060),
              visualDensity: VisualDensity.compact,
            ),
          ]),
          const SizedBox(height: 4),
          // 绑定单人（仅区分显示）
          Row(children: [
            const Text('绑定小人(仅显示名字):',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
            const SizedBox(width: 8),
            DropdownButton<String?>(
              value: slot.bindPetId,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6A4A5A)),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('不绑定')),
                for (final pr in _profiles)
                  DropdownMenuItem<String?>(
                      value: pr.petId, child: Text(pr.name)),
              ],
              onChanged: (v) => setState(() => slot.bindPetId = v),
            ),
          ]),
          const SizedBox(height: 6),
          // 动作库
          Row(children: [
            const Text('动作库（这个坑自己的帧图动作）:',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _manageSlotActions(slot),
              icon: const Icon(Icons.video_library_outlined, size: 15),
              label: Text('管理（${slot.actions.length}）',
                  style: const TextStyle(fontSize: 11)),
            ),
          ]),
          if (slot.actions.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final a in slot.actions)
                  Chip(
                    label: Text(a.name,
                        style: const TextStyle(fontSize: 10.5)),
                    backgroundColor: const Color(0xFFF6EEF2),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ---------------- 坑动作库管理 ----------------

  Future<void> _manageSlotActions(_SlotEdit slot) async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return AlertDialog(
            title: Text('「${slot.label}」的动作库'),
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (slot.actions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('还没有动作：点下面「加动作」，传一摞帧图起个名',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFFB0A0A6))),
                    ),
                  for (final a in slot.actions)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(a.name,
                          style: const TextStyle(fontSize: 12.5)),
                      subtitle: Text('${a.frameCount} 帧 · ${a.durationSeconds}s',
                          style: const TextStyle(fontSize: 10.5)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 17),
                          onPressed: () async {
                            await _editSlotAction(ctx, slot, a);
                            setDlg(() {});
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 17),
                          color: const Color(0xFFC05060),
                          onPressed: () async {
                            await _store.removeSlotAction(a.id);
                            slot.actions.remove(a);
                            setDlg(() {});
                          },
                        ),
                      ]),
                    ),
                  const SizedBox(height: 6),
                  FilledButton.icon(
                    onPressed: () async {
                      await _editSlotAction(ctx, slot, null);
                      setDlg(() {});
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('加动作', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFB0789A)),
                  ),
                ],
              ),
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

  Future<void> _editSlotAction(
      BuildContext ctx, _SlotEdit slot, PetActionDef? existing) async {
    final result = await showDialog<_SlotActionDraft>(
      context: ctx,
      builder: (_) => _SlotActionDialog(existing: existing),
    );
    if (result == null) return;
    final actionId = existing?.id ??
        'act_${DateTime.now().millisecondsSinceEpoch}';
    // 帧图复制（重选图才清旧帧，同单人动作的保存逻辑）
    final dir = await FilePetFrameSource.actionDir(actionId);
    if (result.repicked || existing == null) {
      try {
        if (await Directory(dir).exists()) {
          await Directory(dir).delete(recursive: true);
        }
        for (var i = 0; i < result.files.length; i++) {
          final f = result.files[i];
          final target = p.join(
              dir, '${i.toString().padLeft(3, '0')}_${p.basename(f)}');
          await File(f).copy(target);
        }
      } catch (e) {
        DebugLogger.log('桌宠', '坑动作帧图复制失败: $e');
        _toast('保存失败（帧图复制出错）');
        return;
      }
    }
    final seconds =
        double.tryParse(result.secondsCtrl.text.trim()) ?? 1.0;
    final def = PetActionDef(
      id: actionId,
      name: result.nameCtrl.text.trim(),
      kind: PetActionKind.inPlace,
      fps: (result.files.length / seconds).clamp(1.0, 60.0),
      loop: PetAnimLoop.loop,
      frameDir: actionId,
      frameCount: result.files.length,
      durationSeconds: seconds,
      slotId: slot.slotId,
    );
    try {
      await _store.saveSlotAction(def);
    } catch (e) {
      DebugLogger.log('桌宠', '保存坑动作失败: $e');
      _toast('保存失败：$e');
      return;
    }
    // 更新本地列表
    final idx = slot.actions.indexWhere((a) => a.id == actionId);
    if (idx >= 0) {
      slot.actions[idx] = def;
    } else {
      slot.actions.add(def);
    }
  }

  // ---------------- 步骤卡片 ----------------

  Widget _buildStepCard(int i) {
    final step = _steps[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x22D8C8CE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFE8EEF6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('步骤 ${i + 1}',
                  style: const TextStyle(fontSize: 11.5)),
            ),
            const Spacer(),
            // 手动时长（空 = 自动）
            SizedBox(
              width: 150,
              child: TextField(
                controller: step.durCtrl,
                decoration: const InputDecoration(
                  labelText: '本步时长(秒,空=自动)',
                  isDense: true,
                  labelStyle:
                      TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6)),
                ),
                style: const TextStyle(fontSize: 11.5),
                keyboardType: TextInputType.number,
              ),
            ),
            IconButton(
              onPressed: () => _removeStep(step),
              icon: const Icon(Icons.delete_outline, size: 18),
              color: const Color(0xFFC05060),
              visualDensity: VisualDensity.compact,
            ),
          ]),
          const SizedBox(height: 4),
          for (final ss in step.slotSteps) _buildSlotStepEditor(ss),
        ],
      ),
    );
  }

  Widget _buildSlotStepEditor(_SlotStepEdit ss) {
    final slot = _slots.where((s) => s.slotId == ss.slotId).firstOrNull;
    if (slot == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF6F8),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('${slot.label}:', style: const TextStyle(fontSize: 11.5)),
            const SizedBox(width: 8),
            // 播哪个动作
            DropdownButton<String?>(
              value: ss.actionId,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6A4A5A)),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('不播动作')),
                for (final a in slot.actions)
                  DropdownMenuItem<String?>(
                      value: a.id, child: Text(a.name)),
              ],
              onChanged: (v) => setState(() => ss.actionId = v),
            ),
            const SizedBox(width: 8),
            // 怎么动
            DropdownButton<PetGroupMoveType>(
              value: ss.moveType,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6A4A5A)),
              items: [
                for (final m in PetGroupMoveType.values)
                  DropdownMenuItem(value: m, child: Text(m.label)),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  ss.moveType = v;
                  // 切类型时给个合理默认距离
                  if (v == PetGroupMoveType.dir) ss.moveDist = 0.3;
                  if (v == PetGroupMoveType.approach) ss.approachDist = 0.05;
                  if (v == PetGroupMoveType.leave) ss.leaveDist = 0.3;
                });
              },
            ),
          ]),
          const SizedBox(height: 4),
          Text(_moveHint(ss.moveType),
              style: const TextStyle(
                  fontSize: 10, color: Color(0xFFB0A0A6))),
          const SizedBox(height: 6),
          ..._moveParams(ss),
        ],
      ),
    );
  }

  String _moveHint(PetGroupMoveType m) => switch (m) {
        PetGroupMoveType.stay => '原地播帧',
        PetGroupMoveType.dir => '从当前位置朝方向走一段',
        PetGroupMoveType.spot => '走到地图上这个点（相对屏幕位置）',
        PetGroupMoveType.approach => '走到挨着搭档',
        PetGroupMoveType.leave => '往搭档反方向拉开',
        PetGroupMoveType.wall => '沿方向一直走到屏幕边',
      };

  List<Widget> _moveParams(_SlotStepEdit ss) {
    switch (ss.moveType) {
      case PetGroupMoveType.stay:
        return const [];
      case PetGroupMoveType.dir:
        return [
          _dirSelector(ss),
          _distSlider(
            label: '走多远',
            value: ss.moveDist,
            min: 0.1,
            max: 0.9,
            onChanged: (v) => setState(() => ss.moveDist = v),
          ),
        ];
      case PetGroupMoveType.spot:
        return [
          MoveTargetEditor(
            anchor: const PetPoint(0.5, 0.5),
            anchorVisible: false,
            initialTarget: ss.spot,
            onChanged: (r) => ss.spot = r.target,
          ),
        ];
      case PetGroupMoveType.approach:
        return [
          _distSlider(
            label: '挨着距离（0=完全贴住）',
            value: ss.approachDist,
            min: 0.0,
            max: 0.2,
            onChanged: (v) => setState(() => ss.approachDist = v),
          ),
        ];
      case PetGroupMoveType.leave:
        return [
          _distSlider(
            label: '拉开多远',
            value: ss.leaveDist,
            min: 0.1,
            max: 0.8,
            onChanged: (v) => setState(() => ss.leaveDist = v),
          ),
        ];
      case PetGroupMoveType.wall:
        return [_dirSelector(ss)];
    }
  }

  Widget _dirSelector(_SlotStepEdit ss) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final d in PetMoveDir.values)
          ChoiceChip(
            label: Text(d.label, style: const TextStyle(fontSize: 10.5)),
            selected: ss.moveDir == d,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selectedColor: const Color(0xFFE8D8E2),
            onSelected: (_) => setState(() => ss.moveDir = d),
          ),
      ],
    );
  }

  Widget _distSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(children: [
      Text(label, style: const TextStyle(fontSize: 10.5)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          activeColor: const Color(0xFFB0789A),
          onChanged: onChanged,
        ),
      ),
      Text('${(value * 100).round()}%',
          style: const TextStyle(fontSize: 10.5)),
    ]);
  }
}

/// 坑动作编辑草稿（名字 + 帧图 + 秒数）
class _SlotActionDraft {
  final TextEditingController nameCtrl;
  final TextEditingController secondsCtrl;
  final List<String> files;
  final bool repicked;

  _SlotActionDraft({
    required this.nameCtrl,
    required this.secondsCtrl,
    required this.files,
    required this.repicked,
  });
}

class _SlotActionDialog extends StatefulWidget {
  final PetActionDef? existing;

  const _SlotActionDialog({this.existing});

  @override
  State<_SlotActionDialog> createState() => _SlotActionDialogState();
}

class _SlotActionDialogState extends State<_SlotActionDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _secondsCtrl;
  List<String> _files = [];
  bool _repicked = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _secondsCtrl = TextEditingController(
        text: (widget.existing?.durationSeconds ?? 1.0).toString());
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );
      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _files = result.files.map((f) => f.path ?? '').where((e) => e.isNotEmpty).toList();
          _repicked = true;
          // 自动算秒数：帧数 / 10fps
          if (_files.isNotEmpty) {
            _secondsCtrl.text = (_files.length / 10).toStringAsFixed(1);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '加动作' : '改动作'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('动作名字（比如：走 / 跑 / 抱 / 生气）',
                style: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(isDense: true),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _picking ? null : _pick,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
              label: Text(
                  _files.isEmpty
                      ? (widget.existing == null ? '选帧图（可多选）' : '重选帧图（可不选，保留旧的）')
                      : '已选 ${_files.length} 张',
                  style: const TextStyle(fontSize: 12)),
            ),
            if (_files.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('选图顺序就是播放顺序', style: const TextStyle(fontSize: 10, color: Color(0xFFB0A0A6))),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _secondsCtrl,
              decoration: const InputDecoration(
                labelText: '播几秒',
                isDense: true,
                labelStyle: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6)),
              ),
              style: const TextStyle(fontSize: 13),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(content: Text('先起个名字')));
              return;
            }
            // 新建必须有图；编辑可以不重选（保留旧帧）
            if (_files.isEmpty && widget.existing == null) {
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(content: Text('先选帧图')));
              return;
            }
            final files = _files.isEmpty
                ? List.generate(
                    widget.existing?.frameCount ?? 0, (i) => '')
                : _files;
            Navigator.pop(
                context,
                _SlotActionDraft(
                  nameCtrl: _nameCtrl,
                  secondsCtrl: _secondsCtrl,
                  files: files,
                  repicked: _repicked,
                ));
          },
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0789A)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
