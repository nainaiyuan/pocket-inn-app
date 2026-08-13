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
          // ═══ 显示大小 ═══
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE8D8E0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.pets,
                        size: 15, color: Color(0xFFB0789A)),
                    const SizedBox(width: 6),
                    const Text('显示大小',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6A4A5A))),
                    const Spacer(),
                    Text('${(pet.scale * 100).round()}%',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFB0789A))),
                  ],
                ),
                const SizedBox(height: 2),
                const Text('图太大在聊天页会被限制，调小一点更合适',
                    style: TextStyle(
                        fontSize: 10.5, color: Color(0xFFB0A0A6))),
                Slider(
                  value: pet.scale.clamp(0.4, 2.0),
                  min: 0.4,
                  max: 2.0,
                  divisions: 16,
                  activeColor: const Color(0xFFB0789A),
                  inactiveColor: const Color(0xFFE8D8E0),
                  onChanged: (v) async {
                    await _savePet(pet.copyWith(scale: v));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

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

  // 播的时候怎么动
  _HowMove _howMove = _HowMove.none;
  PetMoveDir _moveDir = PetMoveDir.left;
  double _moveDist = 0.3;
  double _targetX = 0.5;
  double _targetY = 0.5;
  double _startX = 0.5;
  double _startY = 0.5;
  PetMoveTrajectory _trajectory = PetMoveTrajectory.walk;

  /// 移动起点：聊天框 / 屏幕中间（预设快捷）/ 自定义
  PetMoveRef _moveRef = PetMoveRef.dock;

  /// 编辑时是否重选了图（没重选 = 保留原帧图，不重拷）
  bool _repicked = false;
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
      _moveRef = e.moveRef;
      _startX = e.startX ?? 0.5;
      _startY = e.startY ?? 0.5;
      final t = e.target;
      if (t != null) {
        // 新格式：目标点（绝对位置）
        _howMove = _HowMove.move;
        _targetX = t.x;
        _targetY = t.y;
        _trajectory = e.trajectory;
      } else if (e.moveDir != null) {
        // 老格式：方向+距离 → 换算成目标点（相对锚点），编辑后自动迁移
        _howMove = _HowMove.move;
        _moveDir = e.moveDir!;
        _moveDist = e.moveDist ?? 0.3;
        _trajectory = e.trajectory;
        final base = PetMoveRef.basePoint(_moveRef, x: _startX, y: _startY);
        final (vx, vy) = e.moveDir!.vector;
        _targetX = (base.x + vx * _moveDist).clamp(0.02, 0.98);
        _targetY = (base.y + vy * _moveDist).clamp(0.02, 0.98);
      }
      // 编辑：把已有帧图回填，不重新选图也能保存（保留原帧）
      _loadExistingFrames(e.id);
    }
  }

  Future<void> _loadExistingFrames(String actionId) async {
    final frames = await FilePetFrameSource().framesFor(actionId);
    if (!mounted || frames.isEmpty) return;
    setState(() => _files = frames);
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    try {
      // 立即复制到应用私有目录，防止 file_picker 临时文件被系统清理
      final staged = await FilePetFrameSource.stagePickedFiles(
          result.files.map((f) => f.path ?? '').where((e) => e.isNotEmpty).toList());
      if (!mounted) return;
      setState(() {
        _files = staged;
        _repicked = true;
      });
    } catch (e) {
      if (!mounted) return;
      _toast('图片暂存失败，请重选：$e');
    }
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
    final files = _files;
    if (files == null || files.isEmpty) {
      _toast('先上传图片（帧图）');
      return;
    }
    setState(() => _saving = true);

    final existing = widget.existing;
    final actionId = existing?.id ?? 'act_${DateTime.now().millisecondsSinceEpoch}';
    final store = PetStore();

    // 帧图：复制到动作目录
    // 重选了图（或新建）→ 清旧帧重拷；编辑但没重选 → 原帧图就在目录里，直接保留
    // （旧代码：编辑时没重选图也先删目录再拷，源文件被删 → 保存直接崩）
    final dir = await FilePetFrameSource.actionDir(actionId);
    final frameCount = files.length;
    if (_repicked || existing == null) {
      try {
        if (await Directory(dir).exists()) {
          await Directory(dir).delete(recursive: true);
        }
        for (var i = 0; i < files.length; i++) {
          final f = files[i];
          // 加序号前缀：多选同名文件不互相覆盖，且天然按选择顺序播放
          final target = p.join(
              dir, '${i.toString().padLeft(3, '0')}_${p.basename(f)}');
          await File(f).copy(target);
        }
      } catch (e) {
        DebugLogger.log('桌宠', '帧图复制失败: $e');
        if (!mounted) return;
        setState(() => _saving = false);
        _toast('保存失败（帧图复制出错）：$e');
        return;
      }
    }
    final fps = (frameCount / seconds).clamp(1.0, 60.0);
    final loop = PetAnimLoop.loop;

    final kind = _howMove == _HowMove.none
        ? PetActionKind.inPlace
        : PetActionKind.moveTo;
    final def = PetActionDef(
      id: actionId,
      name: name,
      kind: kind,
      fps: fps,
      loop: loop,
      frameDir: actionId,
      frameCount: frameCount,
      durationSeconds: seconds,
      // 移动统一存"目标点"（方向+距离 在编辑器里已换算成目标点）
      targetX: _howMove == _HowMove.move ? _targetX : null,
      targetY: _howMove == _HowMove.move ? _targetY : null,
      trajectory: _trajectory,
    );
    try {
      await store.saveAction(def);
    } catch (e) {
      DebugLogger.log('桌宠', '保存动作失败: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
      return;
    }
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
    return AlertDialog(
      title: Text(widget.existing == null ? '添加动作' : '编辑动作'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 上传帧图（必须）
              OutlinedButton.icon(
                onPressed: _saving ? null : _pick,
                icon: const Icon(Icons.upload_file,
                    size: 18, color: Color(0xFFB0789A)),
                label: Text(_files == null ? '上传图片（可多选，按顺序）' : '重新选图',
                    style: const TextStyle(color: Color(0xFFB0789A))),
              ),
              const SizedBox(height: 6),
              Text(_frameHint,
                  style:
                      const TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
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
              // 播的时候怎么动
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
                onSelectionChanged: (s) => setState(() => _howMove = s.first),
              ),
              const SizedBox(height: 4),
              Text(_howMove.hint,
                  style: const TextStyle(
                      fontSize: 10.5, color: Color(0xFFB0A0A6))),
              if (_howMove == _HowMove.move) ...[
                const SizedBox(height: 8),
                // 起点（方向+距离 的基准点）
                const Text('从哪出发（起点）：', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                SegmentedButton<PetMoveRef>(
                  segments: [
                    for (final r in PetMoveRef.values)
                      ButtonSegment(
                          value: r,
                          label: Text(r.label,
                              style: const TextStyle(fontSize: 10.5))),
                  ],
                  selected: {_moveRef},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _moveRef = s.first),
                ),
                const SizedBox(height: 4),
                Text(
                  switch (_moveRef) {
                    PetMoveRef.dock => '预设：起点 = 聊天框（手机底部）位置',
                    PetMoveRef.center => '预设：起点 = 屏幕中间',
                    PetMoveRef.custom => '自定义：自己定起点',
                  },
                  style: const TextStyle(
                      fontSize: 10.5, color: Color(0xFFB0A0A6)),
                ),
                if (_moveRef == PetMoveRef.custom) ...[
                  const SizedBox(height: 4),
                  _AxisSlider(
                    label: '起点 左右',
                    value: _startX,
                    onChanged: (v) => setState(() => _startX = v),
                  ),
                  _AxisSlider(
                    label: '起点 上下',
                    value: _startY,
                    onChanged: (v) => setState(() => _startY = v),
                  ),
                ],
                const SizedBox(height: 10),
                // 移动目标：方向+距离 与 到某个位置 合并
                MoveTargetEditor(
                  anchor: PetMoveRef.basePoint(_moveRef, x: _startX, y: _startY),
                  initialTarget: PetPoint(_targetX, _targetY),
                  initialDir: _moveDir,
                  initialDist: _moveDist,
                  onChanged: (r) {
                    _targetX = r.target.x;
                    _targetY = r.target.y;
                  },
                ),
                const SizedBox(height: 8),
                TrajectorySelector(
                  value: _trajectory,
                  onChanged: (t) => setState(() => _trajectory = t),
                ),
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

/// 播的时候怎么动（导入时配置）
enum _HowMove {
  none('原地不动', '就在原地播这组帧'),
  move('移动', '选起点 → 点地图指哪走哪，或点方向按钮 + 距离滑块从起点朝这个方向走');

  final String label;
  final String hint;
  const _HowMove(this.label, this.hint);
}

/// ─────────────────────────────────────────────
/// 组合动作对话框：初始位置 + 混合步骤（动作 / 方向移动）
/// 小人从初始位置开始，一个步骤接一个步骤，走到碰墙自动停
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
  late final List<PetActivityStep> _steps;

  /// 初始位置：null = 当前位置 / dock = 聊天框 / center = 屏幕中间 / custom = 自定义
  PetMoveRef? _startRef;
  double _startX = 0.5;
  double _startY = 0.5;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    _steps = [...?e?.steps];
    _startRef = e?.startRef;
    _startX = e?.startX ?? 0.5;
    _startY = e?.startY ?? 0.5;
  }

  String _stepLabel(PetActivityStep step) {
    if (step.isMoveDir) {
      final dist = step.moveDist != null
          ? '走${(step.moveDist! * 100).round()}%'
          : (step.moveUntilWall ? '走到碰墙' : '走${step.moveSec ?? 2}秒');
      return '${step.moveDir!.label}$dist';
    }
    if (step.target != null) {
      return '到位置 (${(step.target!.x * 100).round()}%, ${(step.target!.y * 100).round()}%)';
    }
    for (final a in widget.actions) {
      if (a.id == step.actionId) return a.name;
    }
    return step.actionId;
  }

  String _stepSub(PetActivityStep step) {
    if (step.isMoveDir) {
      return step.moveUntilWall ? '一直走，碰到屏幕边缘停下' : '方向移动步骤';
    }
    if (step.target != null) return '走到这个屏幕位置停下';
    for (final a in widget.actions) {
      if (a.id == step.actionId) {
        return '${a.frameCount}帧 · ${a.durationSeconds}秒'
            '${a.moveDir != null ? ' · ${a.moveDir!.label}走${(a.moveDist! * 100).round()}%' : ''}'
            '${a.target != null ? ' · 到目标点' : ''}';
      }
    }
    return '';
  }

  void _move(int index, int delta) {
    setState(() {
      final target = index + delta;
      if (target < 0 || target >= _steps.length) return;
      final tmp = _steps[index];
      _steps[index] = _steps[target];
      _steps[target] = tmp;
    });
  }

  /// 添加已有动作（多选追加到末尾）
  Future<void> _addActions() async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _PickActionsDialog(actions: widget.actions),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      _steps.addAll([
        for (final id in picked) PetActivityStep(actionId: id),
      ]);
    });
  }

  /// 添加移动步骤：方向+距离 / 到某个位置 / 走到碰墙（合并版编辑器）
  Future<void> _addMoveStep() async {
    // 锚点 = 组合初始位置（灰点参考）；没有初始位置就画在屏幕中间
    final anchor = _startRef != null
        ? PetMoveRef.basePoint(_startRef!, x: _startX, y: _startY)
        : const PetPoint(0.5, 0.5);
    final step = await showDialog<PetActivityStep>(
      context: context,
      builder: (_) => _MoveStepDialog(anchor: anchor),
    );
    if (step == null) return;
    setState(() => _steps.add(step));
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('给组合起个名字')));
      return;
    }
    if (_steps.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('至少加一个步骤')));
      return;
    }
    setState(() => _saving = true);
    final store = PetStore();
    await store.saveActivity(PetActivityDef(
      id: widget.existing?.id ?? 'grp_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      startRef: _startRef,
      startX: _startRef == PetMoveRef.custom ? _startX : null,
      startY: _startRef == PetMoveRef.custom ? _startY : null,
      steps: _steps,
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
        height: 460,
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
            // 初始位置：小人从这里开始动
            Row(
              children: [
                const Text('初始位置：',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6A4A5A))),
                const SizedBox(width: 6),
                Expanded(
                  child: SegmentedButton<PetMoveRef?>(
                    segments: const [
                      ButtonSegment(
                          value: null,
                          label: Text('当前位置',
                              style: TextStyle(fontSize: 10.5))),
                      ButtonSegment(
                          value: PetMoveRef.dock,
                          label: Text('聊天框',
                              style: TextStyle(fontSize: 10.5))),
                      ButtonSegment(
                          value: PetMoveRef.center,
                          label: Text('屏幕中间',
                              style: TextStyle(fontSize: 10.5))),
                      ButtonSegment(
                          value: PetMoveRef.custom,
                          label: Text('自定义',
                              style: TextStyle(fontSize: 10.5))),
                    ],
                    selected: {_startRef},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setState(() => _startRef = s.first),
                  ),
                ),
              ],
            ),
            if (_startRef == PetMoveRef.custom) ...[
              const SizedBox(height: 4),
              _AxisSlider(
                label: '起点 左右',
                value: _startX,
                onChanged: (v) => setState(() => _startX = v),
              ),
              _AxisSlider(
                label: '起点 上下',
                value: _startY,
                onChanged: (v) => setState(() => _startY = v),
              ),
            ],
            const SizedBox(height: 4),
            const Text('小人先出现在这里，然后按下面步骤一个接一个走，碰到屏幕边缘自动停',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
            const SizedBox(height: 8),
            // 步骤列表
            Row(
              children: [
                const Text('步骤：',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6A4A5A))),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addActions,
                  icon: const Icon(Icons.add,
                      size: 15, color: Color(0xFFB0789A)),
                  label: const Text('加动作',
                      style:
                          TextStyle(fontSize: 11.5, color: Color(0xFFB0789A))),
                ),
                TextButton.icon(
                  onPressed: _addMoveStep,
                  icon: const Icon(Icons.directions_walk,
                      size: 15, color: Color(0xFFB0789A)),
                  label: const Text('加移动',
                      style:
                          TextStyle(fontSize: 11.5, color: Color(0xFFB0789A))),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: _steps.isEmpty
                  ? Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0x22F0E4EA),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        '还没有步骤：'
                        '「加动作」= 播一段动作；'
                        '「加移动」= 方向+距离 / 指哪走哪 / 走到碰墙',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF9A8A90),
                            height: 1.6),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _steps.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Color(0xFFF0E8EC)),
                      itemBuilder: (_, i) {
                        final step = _steps[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: step.isMoveDir
                              ? const Icon(Icons.directions_walk,
                                  size: 18, color: Color(0xFFB0789A))
                              : const Icon(Icons.movie_outlined,
                                  size: 18, color: Color(0xFFC896B4)),
                          title: Text(_stepLabel(step),
                              style: const TextStyle(fontSize: 13)),
                          subtitle: Text(_stepSub(step),
                              style: const TextStyle(fontSize: 10)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_upward,
                                    size: 16, color: Color(0xFFB0789A)),
                                onPressed: i == 0 ? null : () => _move(i, -1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.arrow_downward,
                                    size: 16, color: Color(0xFFB0789A)),
                                onPressed: i == _steps.length - 1
                                    ? null
                                    : () => _move(i, 1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 16, color: Color(0xFFD0A0B0)),
                                onPressed: () =>
                                    setState(() => _steps.removeAt(i)),
                              ),
                            ],
                          ),
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

/// 勾选已有动作（多选）
class _PickActionsDialog extends StatefulWidget {
  final List<PetActionDef> actions;

  const _PickActionsDialog({required this.actions});

  @override
  State<_PickActionsDialog> createState() => _PickActionsDialogState();
}

class _PickActionsDialogState extends State<_PickActionsDialog> {
  final List<String> _picked = [];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('加动作'),
      content: SizedBox(
        width: 320,
        height: 360,
        child: ListView.separated(
          itemCount: widget.actions.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Color(0xFFF0E8EC)),
          itemBuilder: (_, i) {
            final a = widget.actions[i];
            final checked = _picked.contains(a.id);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Checkbox(
                value: checked,
                activeColor: const Color(0xFFB0789A),
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _picked.add(a.id);
                    } else {
                      _picked.remove(a.id);
                    }
                  });
                },
              ),
              title: Text(a.name, style: const TextStyle(fontSize: 13)),
              subtitle: Text('${a.frameCount}帧 · ${a.durationSeconds}秒',
                  style: const TextStyle(fontSize: 10)),
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _picked),
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0789A)),
          child: const Text('加入'),
        ),
      ],
    );
  }
}

/// 坐标轴滑块（0~1 屏幕相对坐标）
class _AxisSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _AxisSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            activeColor: const Color(0xFFB0789A),
            inactiveColor: const Color(0xFFE8D8E0),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text('${(value * 100).round()}%',
              style: const TextStyle(
                  fontSize: 10.5, color: Color(0xFF8A5A72))),
        ),
      ],
    );
  }
}

/// 方向移动步骤：8 向 + 距离滑块 / 走到碰墙
class _MoveStepDialog extends StatefulWidget {
  /// 锚点（灰点）：组合初始位置，仅作方向输入的视觉参考
  final PetPoint anchor;

  const _MoveStepDialog({required this.anchor});

  @override
  State<_MoveStepDialog> createState() => _MoveStepDialogState();
}

class _MoveStepDialogState extends State<_MoveStepDialog> {
  MoveTargetResult? _result;

  PetActivityStep _buildStep() {
    final r = _result ??
        const MoveTargetResult(
          target: PetPoint(0.5, 0.5),
          dir: PetMoveDir.left,
          dist: 0.3,
          untilWall: false,
          usedDir: true,
        );
    if (r.untilWall) {
      // 一直走到屏幕边
      return PetActivityStep(
          actionId: 'idle', moveDir: r.dir, moveUntilWall: true);
    }
    if (r.usedDir) {
      // 相对移动：从当前位置朝方向走 dist
      return PetActivityStep(
          actionId: 'idle', moveDir: r.dir, moveDist: r.dist);
    }
    // 绝对目标：走到这个屏幕位置
    return PetActivityStep(
        actionId: 'idle', targetX: r.target.x, targetY: r.target.y);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('加移动步骤'),
      content: SizedBox(
        width: 330,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MoveTargetEditor(
              anchor: widget.anchor,
              showUntilWall: true,
              onChanged: (r) => _result = r,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _buildStep()),
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0789A)),
          child: const Text('加入'),
        ),
      ],
    );
  }
}
