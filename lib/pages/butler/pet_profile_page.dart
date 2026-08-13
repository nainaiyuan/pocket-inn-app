import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_frame_source_impl.dart';
import '../../services/pet_settings_notifier.dart';
import '../../utils/debug_logger.dart';
import 'pet_widgets.dart';

/// 角色详情页 —— 一个小人的全部配置
///
/// ① 头部：头像/名字（点击可换头像、改名）
/// ② 我的动作：上传图片做的动作，一格一个收纳（名字/帧数/怎么动）
/// ③ 动作组合：勾选已有动作编成组合，一格一个收纳
/// ④ 其他设置：显示开关/活动区域/大小/互动被打断反应
class PetProfilePage extends StatefulWidget {
  final String petId;

  const PetProfilePage({super.key, required this.petId});

  @override
  State<PetProfilePage> createState() => _PetProfilePageState();
}

class _PetProfilePageState extends State<PetProfilePage> {
  final _store = PetStore();
  PetProfile? _pet;
  List<PetActionDef> _actions = [];
  List<PetActivityDef> _activities = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pet = await _store.getProfile(widget.petId);
    final actions = await _store.allActions();
    final activities = await _store.allActivities();
    if (!mounted) return;
    setState(() {
      _pet = pet;
      _actions = actions;
      _activities = activities;
      _loading = false;
    });
  }

  Future<void> _savePet(PetProfile updated) async {
    await _store.saveProfile(updated);
    PetSettingsNotifier.instance.notifyChanged();
    setState(() => _pet = updated);
  }

  /// 换头像
  Future<void> _changeAvatar() async {
    final pet = _pet;
    if (pet == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    try {
      final dir = await PetStore.avatarsDir();
      final ext = p.extension(result.files.first.path!);
      final target = p.join(dir, '${pet.petId}$ext');
      await File(result.files.first.path!).copy(target);
      await _savePet(pet.copyWith(avatarPath: target));
    } catch (e) {
      DebugLogger.log('桌宠', '换头像失败: $e');
    }
  }

  /// 改名
  Future<void> _rename() async {
    final pet = _pet;
    if (pet == null) return;
    final ctrl = TextEditingController(text: pet.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改名字'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '小人的名字'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB0789A)),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _savePet(pet.copyWith(name: name));
    }
  }

  /// 添加/编辑动作：上传图片（或用预设）→ 配置 → 命名保存
  Future<void> _editAction(PetActionDef? existing) async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _ActionEditDialog(existing: existing),
    );
    if (created == true) _load();
  }

  /// 新建/编辑组合：勾选已有动作 → 命名
  Future<void> _editActivity(PetActivityDef? existing) async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _ComboEditDialog(actions: _actions, existing: existing),
    );
    if (created == true) _load();
  }

  Future<void> _deleteAction(PetActionDef a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除动作「${a.name}」？'),
        content: const Text('帧图也会一起删掉'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:
                FilledButton.styleFrom(backgroundColor: const Color(0xFFC05060)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.removeAction(a.id);
    // 删帧图目录
    try {
      final dir = await FilePetFrameSource.actionDir(a.id);
      if (await Directory(dir).exists()) {
        await Directory(dir).delete(recursive: true);
      }
    } catch (e) {
      DebugLogger.log('桌宠', '删帧图失败: $e');
    }
    PetSettingsNotifier.instance.notifyChanged();
    _load();
  }

  Future<void> _deleteActivity(PetActivityDef act) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除组合「${act.name}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:
                FilledButton.styleFrom(backgroundColor: const Color(0xFFC05060)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.removeActivity(act.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final pet = _pet;
    if (_loading || pet == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: Colors.white),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFFAF6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF6A4A5A),
        elevation: 0.5,
        title: Row(
          children: [
            GestureDetector(
              onTap: _changeAvatar,
              child: CircleAvatar(
                radius: 15,
                backgroundColor: const Color(0xFFF0E4EA),
                backgroundImage: pet.avatarPath != null
                    ? FileImage(File(pet.avatarPath!))
                    : null,
                child: pet.avatarPath == null
                    ? const Icon(Icons.pets,
                        size: 16, color: Color(0xFFB0789A))
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _rename,
              child: Text(pet.name,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.edit_outlined, size: 13, color: Color(0xFFB0A0A6)),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ═══ 我的动作 ═══
          Row(
            children: [
              const Text('我的动作',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6A4A5A))),
              const Spacer(),
              Text('${_actions.length} 个',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFB0A0A6))),
            ],
          ),
          const SizedBox(height: 4),
          const Text('上传图片做成动作，每个动作一格',
              style: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
          const SizedBox(height: 10),
          if (_actions.isEmpty)
            _EmptyBox(text: '还没有动作\n点下面「＋ 添加动作」开始（可用预设，或上传图片）')
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final a in _actions) _ActionCard(
                  action: a,
                  onTap: () => _editAction(a),
                  onDelete: () => _deleteAction(a),
                ),
              ],
            ),
          const SizedBox(height: 10),
          _AddButton(label: '添加动作', onTap: () => _editAction(null)),
          const SizedBox(height: 24),

          // ═══ 动作组合 ═══
          Row(
            children: [
              const Text('动作组合',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6A4A5A))),
              const Spacer(),
              Text('${_activities.length} 个',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFB0A0A6))),
            ],
          ),
          const SizedBox(height: 4),
          const Text('把几个动作勾选在一起，编成一段表演',
              style: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
          const SizedBox(height: 10),
          if (_activities.isEmpty)
            _EmptyBox(text: '还没有组合\n点下面「＋ 新建组合」把动作串起来')
          else
            for (final act in _activities) _ComboCard(
              activity: act,
              actions: _actions,
              onTap: () => _editActivity(act),
              onDelete: () => _deleteActivity(act),
            ),
          const SizedBox(height: 10),
          _AddButton(label: '新建组合', onTap: () => _editActivity(null)),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

/// 空状态提示
class _EmptyBox extends StatelessWidget {
  final String text;

  const _EmptyBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22),
      decoration: BoxDecoration(
        color: const Color(0x22F0E4EA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8D8E0)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Color(0xFFB0A0A6), height: 1.6),
      ),
    );
  }
}

/// ＋ 按钮（添加动作/新建组合）
class _AddButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _AddButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.add, size: 18, color: Color(0xFFB0789A)),
        label: Text(label,
            style: const TextStyle(color: Color(0xFFB0789A), fontSize: 13)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0xFFD8C0CA)),
          backgroundColor: const Color(0x11F0E4EA),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

/// 动作卡（收纳格）：名字 + 帧数/秒数 + 怎么动摘要；点卡片可编辑
class _ActionCard extends StatelessWidget {
  final PetActionDef action;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ActionCard({
    required this.action,
    required this.onTap,
    required this.onDelete,
  });

  String get _moveHint {
    if (action.target != null) {
      final t = action.target!;
      return '${action.trajectory.label}到(${(t.x * 100).round()}%,'
          '${(t.y * 100).round()}%)';
    }
    if (action.moveDir != null && action.moveDist != null) {
      final d = (action.moveDist! * 100).round();
      final sec = action.moveSec != null ? ' · ${action.moveSec}秒' : '';
      return '${action.moveDir!.label}走$d%$sec';
    }
    return '原地';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 150,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE8D8E0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      action.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6A4A5A)),
                    ),
                  ),
                  GestureDetector(
                    onTap: onDelete,
                    child: const Icon(Icons.delete_outline,
                        size: 16, color: Color(0xFFD0A0B0)),
                  ),
                ],
              ),
          const SizedBox(height: 6),
          Text('${action.frameCount} 帧 · ${action.durationSeconds}秒',
              style:
                  const TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x22F0E4EA),
              borderRadius: BorderRadius.circular(6),
            ),
              child: Text(_moveHint,
                  style: const TextStyle(
                      fontSize: 10, color: Color(0xFF8A5A72))),
            ),
              ],
            ),
          ),
        ),
      );
  }
}

/// 组合卡（收纳格）：名字 + 步骤预览 + 删除；点卡片可编辑
class _ComboCard extends StatelessWidget {
  final PetActivityDef activity;
  final List<PetActionDef> actions;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ComboCard({
    required this.activity,
    required this.actions,
    required this.onTap,
    required this.onDelete,
  });

  String _actionName(String id) {
    for (final a in actions) {
      if (a.id == id) return a.name;
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE8D8E0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.play_circle_outline,
                      size: 18, color: Color(0xFFB0789A)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      activity.name,
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6A4A5A)),
                    ),
                  ),
                  GestureDetector(
                    onTap: onDelete,
                    child: const Icon(Icons.delete_outline,
                        size: 16, color: Color(0xFFD0A0B0)),
                  ),
                ],
              ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var i = 0; i < activity.steps.length; i++)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0x22F0E4EA),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${i + 1}. ${_actionName(activity.steps[i].actionId)}',
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFF8A5A72)),
                  ),
                ),
            ],
          ),
        ],
      ),
      ),
      ),
    );
  }
}

/// ─────────────────────────────────────────────
/// 单动作配置对话框：上传图片 → 怎么动 → 命名保存
/// ─────────────────────────────────────────────
class _ActionEditDialog extends StatefulWidget {
  final PetActionDef? existing;

  const _ActionEditDialog({this.existing});

  @override
  State<_ActionEditDialog> createState() => _ActionEditDialogState();
}

class _ActionEditDialogState extends State<_ActionEditDialog> {
  final _nameController = TextEditingController();
  final _secondsController = TextEditingController(text: '1');
  List<String>? _files;
  _ImportKind _kind = _ImportKind.inPlace;

  // 播的时候怎么动
  _HowMove _howMove = _HowMove.none;
  PetMoveDir _moveDir = PetMoveDir.left;
  double _moveDist = 0.3;
  final _moveSecController = TextEditingController();
  double _targetX = 0.5;
  double _targetY = 0.5;
  PetMoveTrajectory _trajectory = PetMoveTrajectory.walk;

  /// 选中的预设动作 id（null = 自己上传图）
  String? _presetId;
  bool _nameEdited = false;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameController.text = e.name;
      _nameEdited = true;
      _secondsController.text = e.durationSeconds.toString();
      _kind = switch (e.kind) {
        PetActionKind.inPlace => _ImportKind.inPlace,
        PetActionKind.moveTo => _ImportKind.move,
        PetActionKind.duo => _ImportKind.duo,
        _ => _ImportKind.inPlace,
      };
      // 预设动作（引用内置帧、无用户图）
      if (e.frameCount == 0 && e.frameDir != null && PetBuiltinActions.byId(e.frameDir!) != null) {
        _presetId = e.frameDir;
      }
      final t = e.target;
      if (t != null) {
        _howMove = _HowMove.target;
        _targetX = t.x;
        _targetY = t.y;
        _trajectory = e.trajectory;
      } else if (e.moveDir != null) {
        _howMove = _HowMove.dir;
        _moveDir = e.moveDir!;
        _moveDist = e.moveDist ?? 0.3;
        if (e.moveSec != null) _moveSecController.text = e.moveSec.toString();
      }
    }
  }

  /// 可选用的预设动作（原地类 + 引擎行为）
  List<PetActionDef> get _presets => [
        for (final a in PetBuiltinActions.all)
          if (a.kind == PetActionKind.inPlace ||
              a.kind == PetActionKind.behavior)
            a,
      ];

  void _pickPreset(PetActionDef a) {
    setState(() {
      _presetId = a.id;
      if (!_nameEdited) {
        _nameController.text = a.name;
        _nameEdited = true;
      }
    });
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    setState(() {
      _files = result.files.map((f) => f.path!).toList();
      _presetId = null;
    });
  }

  String get _frameHint {
    final files = _files;
    if (files == null || files.isEmpty) return '还没选图';
    return '已选 ${files.length} 张，按文件名顺序播放';
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _toast('先给动作起个名字');
      return;
    }
    final seconds = double.tryParse(_secondsController.text.trim()) ?? 1;
    if (seconds <= 0) {
      _toast('秒数要大于 0');
      return;
    }
    // 预设动作：不需要图；自己上传：必须有图
    final usingPreset = _presetId != null;
    final files = _files;
    if (!usingPreset && (files == null || files.isEmpty)) {
      _toast('先选图片（或用预设动作）');
      return;
    }
    setState(() => _saving = true);

    final existing = widget.existing;
    final actionId = existing?.id ?? 'act_${DateTime.now().millisecondsSinceEpoch}';
    final store = PetStore();

    // 帧图：预设 → 引用内置 frameDir；上传 → 复制到动作目录
    String? frameDir;
    int frameCount = 0;
    double fps;
    PetAnimLoop loop;
    if (usingPreset) {
      final preset = PetBuiltinActions.byId(_presetId!)!;
      frameDir = preset.frameDir ?? preset.id;
      fps = preset.fps;
      loop = preset.loop;
    } else {
      frameDir = actionId;
      final dir = await FilePetFrameSource.actionDir(actionId);
      // 编辑时重选图：先清旧帧
      if (await Directory(dir).exists()) {
        await Directory(dir).delete(recursive: true);
      }
      final copied = <String>[];
      for (final f in files!) {
        final target = p.join(dir, p.basename(f));
        await File(f).copy(target);
        copied.add(target);
      }
      frameCount = copied.length;
      fps = (copied.length / seconds).clamp(1.0, 60.0);
      loop = PetAnimLoop.loop;
    }

    final kind = switch (_kind) {
      _ImportKind.inPlace => PetActionKind.inPlace,
      _ImportKind.move => PetActionKind.moveTo,
      _ImportKind.duo => PetActionKind.duo,
    };
    final moveSec = double.tryParse(_moveSecController.text.trim());
    final def = PetActionDef(
      id: actionId,
      name: name,
      kind: kind,
      fps: fps,
      loop: loop,
      frameDir: frameDir,
      frameCount: frameCount,
      durationSeconds: seconds,
      moveDir: _howMove == _HowMove.dir ? _moveDir : null,
      moveDist: _howMove == _HowMove.dir ? _moveDist : null,
      moveSec: _howMove == _HowMove.dir ? moveSec : null,
      targetX: _howMove == _HowMove.target ? _targetX : null,
      targetY: _howMove == _HowMove.target ? _targetY : null,
      trajectory: _trajectory,
    );
    await store.saveAction(def);
    PetSettingsNotifier.instance.notifyChanged();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final usingPreset = _presetId != null;
    return AlertDialog(
      title: Text(widget.existing == null ? '添加动作' : '编辑动作'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 动作类型
              SegmentedButton<_ImportKind>(
                segments: [
                  for (final k in _ImportKind.values)
                    ButtonSegment(
                        value: k,
                        label:
                            Text(k.label, style: const TextStyle(fontSize: 11))),
                ],
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 6),
              Text(
                _kind.hint,
                style:
                    const TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6)),
              ),
              const SizedBox(height: 12),
              // 预设动作（原地/行为类才有）
              if (_kind == _ImportKind.inPlace) ...[
                const Text('用预设动作（不用画图）：',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in _presets)
                      FilterChip(
                        label: Text(a.name,
                            style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        selected: _presetId == a.id,
                        selectedColor: const Color(0x33B0789A),
                        backgroundColor: const Color(0x11F0E4EA),
                        checkmarkColor: const Color(0xFFB0789A),
                        side: BorderSide(
                          color: _presetId == a.id
                              ? const Color(0xFFB0789A)
                              : const Color(0xFFE0D0D8),
                        ),
                        onSelected: (_) => _pickPreset(a),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              // 上传图片（预设选中时不显示）
              if (!usingPreset) ...[
                OutlinedButton.icon(
                  onPressed: _saving ? null : _pick,
                  icon: const Icon(Icons.upload_file,
                      size: 18, color: Color(0xFFB0789A)),
                  label: Text(_files == null ? '上传图片（可多选，按顺序）' : '重新选图',
                      style: const TextStyle(color: Color(0xFFB0789A))),
                ),
                const SizedBox(height: 6),
                Text(_frameHint,
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFFB0A0A6))),
                if (_files != null && _files!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 52,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _files!.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (_, i) => ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(
                          File(_files![i]),
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 52,
                            height: 52,
                            color: const Color(0xFFF0E8EC),
                            child: const Icon(Icons.broken_image,
                                size: 18, color: Color(0xFFD0B8C4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
              ] else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0x22F0E4EA),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('使用内置动画，无需上传图片',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Color(0xFF8A5A72))),
                ),
              TextField(
                controller: _nameController,
                onChanged: (_) => _nameEdited = true,
                decoration: const InputDecoration(
                  labelText: '动作名字',
                  hintText: '如：跳一下 / 向左跑',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _secondsController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '播几秒（帧率自动算）',
                  suffixText: '秒',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // 播的时候怎么动（原地动作才有意义；移动/双人由机制驱动）
              if (_kind == _ImportKind.inPlace) ...[
                const Text('播的时候怎么动：', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                SegmentedButton<_HowMove>(
                  segments: [
                    for (final h in _HowMove.values)
                      ButtonSegment(
                          value: h,
                          label: Text(h.label,
                              style: const TextStyle(fontSize: 10.5))),
                  ],
                  selected: {_howMove},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setState(() => _howMove = s.first),
                ),
                const SizedBox(height: 4),
                Text(_howMove.hint,
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFFB0A0A6))),
                if (_howMove == _HowMove.dir) ...[
                  const SizedBox(height: 8),
                  // 8 向
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final d in PetMoveDir.values)
                        SizedBox(
                          width: 42,
                          height: 30,
                          child: OutlinedButton(
                            onPressed: () =>
                                setState(() => _moveDir = d),
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.zero,
                              backgroundColor: _moveDir == d
                                  ? const Color(0x22B0789A)
                                  : null,
                              side: BorderSide(
                                color: _moveDir == d
                                    ? const Color(0xFFB0789A)
                                    : const Color(0xFFD8C0CA),
                              ),
                            ),
                            child: Text(d.label,
                                style: const TextStyle(
                                    fontSize: 10, color: Color(0xFF8A5A72))),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 距离滑块
                  Row(
                    children: [
                      const Text('距离',
                          style: TextStyle(fontSize: 11)),
                      Expanded(
                        child: Slider(
                          value: _moveDist,
                          min: 0.1,
                          max: 1.0,
                          activeColor: const Color(0xFFB0789A),
                          onChanged: (v) =>
                              setState(() => _moveDist = v),
                        ),
                      ),
                      Text('${(_moveDist * 100).round()}%',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF8A5A72))),
                    ],
                  ),
                  // 时间（可留空自动）
                  TextField(
                    controller: _moveSecController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: '走多久（留空 = 自动按距离算）',
                      suffixText: '秒',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('超出屏幕会自动截断，不会跑出去',
                      style: TextStyle(
                          fontSize: 10, color: Color(0xFFC0B0B6))),
                ],
                if (_howMove == _HowMove.target) ...[
                  const SizedBox(height: 8),
                  TrajectorySelector(
                    value: _trajectory,
                    onChanged: (t) => setState(() => _trajectory = t),
                  ),
                  const SizedBox(height: 8),
                  TargetPicker(
                    initial: PetPoint(_targetX, _targetY),
                    onChanged: (pt) {
                      _targetX = pt.x;
                      _targetY = pt.y;
                    },
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0789A)),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('保存'),
        ),
      ],
    );
  }
}

/// 动作类型（导入时选择）
enum _ImportKind {
  inPlace('原地动作', '站在原地播（可带移动：跳/走/飞）'),
  move('移动动作', '走/跑，用于移动组绑定'),
  duo('双人互动', '每张图里画两个小人挨在一起（一半是你，一半是男主）');

  final String label;
  final String hint;
  const _ImportKind(this.label, this.hint);
}

/// 播的时候怎么动（导入时配置，只对原地动作生效）
enum _HowMove {
  none('原地不动', '就在原地播这组帧'),
  dir('方向+距离', '8 向选方向，滑块选距离，可选手动时长'),
  target('到某个位置', '滑滑块选目标点，角度/时长自动算');

  final String label;
  final String hint;
  const _HowMove(this.label, this.hint);
}

/// ─────────────────────────────────────────────
/// 组合动作对话框：勾选已有动作 → 排序 → 命名保存
/// ─────────────────────────────────────────────
class _ComboEditDialog extends StatefulWidget {
  final List<PetActionDef> actions;
  final PetActivityDef? existing;

  const _ComboEditDialog({required this.actions, this.existing});

  @override
  State<_ComboEditDialog> createState() => _ComboEditDialogState();
}

class _ComboEditDialogState extends State<_ComboEditDialog> {
  late final TextEditingController _nameController;
  final List<String> _selected = []; // 按勾选顺序
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    if (e != null) {
      _selected.addAll([for (final s in e.steps) s.actionId]);
    }
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _move(int index, int delta) {
    setState(() {
      final target = index + delta;
      if (target < 0 || target >= _selected.length) return;
      final tmp = _selected[index];
      _selected[index] = _selected[target];
      _selected[target] = tmp;
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('给组合起个名字')));
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('至少勾选一个动作')));
      return;
    }
    setState(() => _saving = true);
    final store = PetStore();
    await store.saveActivity(PetActivityDef(
      id: widget.existing?.id ?? 'grp_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      steps: [for (final id in _selected) PetActivityStep(actionId: id)],
    ));
    PetSettingsNotifier.instance.notifyChanged();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '新建组合' : '编辑组合'),
      content: SizedBox(
        width: 380,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '组合名字',
                hintText: '如：跳上来再跳下去',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('勾选动作（按勾选顺序播放，可上下调整）：',
                  style: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.separated(
                itemCount: widget.actions.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFF0E8EC)),
                itemBuilder: (_, i) {
                  final a = widget.actions[i];
                  final idx = _selected.indexOf(a.id);
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Checkbox(
                      value: idx >= 0,
                      activeColor: const Color(0xFFB0789A),
                      onChanged: (_) => _toggle(a.id),
                    ),
                    title: Text(a.name,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '${a.frameCount}帧 · ${a.durationSeconds}秒'
                      '${a.moveDir != null ? ' · ${a.moveDir!.label}走${(a.moveDist! * 100).round()}%' : ''}'
                      '${a.target != null ? ' · 到目标点' : ''}',
                      style: const TextStyle(fontSize: 10),
                    ),
                    trailing: idx >= 0
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_upward,
                                    size: 16, color: Color(0xFFB0789A)),
                                onPressed:
                                    idx == 0 ? null : () => _move(idx, -1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.arrow_downward,
                                    size: 16, color: Color(0xFFB0789A)),
                                onPressed: idx == _selected.length - 1
                                    ? null
                                    : () => _move(idx, 1),
                              ),
                            ],
                          )
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0789A)),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('保存'),
        ),
      ],
    );
  }
}
