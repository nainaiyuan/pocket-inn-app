import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../butler/pet/pet_models.dart';
import '../../../butler/pet/pet_store.dart';
import '../../../services/pet_frame_source_impl.dart';
import '../../../services/pet_settings_notifier.dart';
import '../../../utils/debug_logger.dart';

/// 桌宠动作管理卡片（右页）
///
/// 用户流程：
/// 1. 「＋ 导入帧图」：多选图片 → 自动数帧 → 命名 → 选类型/速度档 → 保存
/// 2. 「移动组」：把"走""跑"绑成一组，系统按移动速度自动切换
class PetActionSection extends StatefulWidget {
  const PetActionSection({super.key});

  @override
  State<PetActionSection> createState() => _PetActionSectionState();
}

class _PetActionSectionState extends State<PetActionSection> {
  final _store = PetStore();
  List<PetActionDef> _userActions = [];
  List<PetActivityDef> _activities = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final actions = await _store.allActions();
    final activities = await _store.allActivities();
    if (!mounted) return;
    setState(() {
      _userActions = actions;
      _activities = activities;
      _loading = false;
    });
  }

  Future<void> _import() async {
    await showDialog(
      context: context,
      builder: (_) => const _ImportDialog(),
    );
    await _load();
  }

  Future<void> _manageGroups() async {
    await showDialog(
      context: context,
      builder: (_) => _MoveGroupDialog(store: _store, actions: _userActions),
    );
    await _load();
  }

  Future<void> _manageActivities() async {
    await showDialog(
      context: context,
      builder: (_) => _ActivityDialog(
        store: _store,
        activities: _activities,
        actions: _userActions,
      ),
    );
    await _load();
  }

  Future<void> _removeAction(PetActionDef a) async {
    await _store.removeAction(a.id);
    PetSettingsNotifier.instance.notifyChanged();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '桌宠动作',
      child: _loading
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.add_photo_alternate_outlined,
                          size: 16),
                      label: const Text('导入帧图', style: TextStyle(fontSize: 12)),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFB0789A),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _manageGroups,
                      icon: const Icon(Icons.link_rounded, size: 16),
                      label: const Text('移动组（走+跑）',
                          style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _manageActivities,
                      icon: const Icon(Icons.playlist_play_rounded, size: 16),
                      label: const Text('组合动作', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                      ),
                    ),
                  ],
                ),
                if (_userActions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      '还没有自建动作。导入方法：多选图片（按顺序）→ 自动数帧 → 起名',
                      style: TextStyle(fontSize: 11, color: Color(0xFF9A8A90)),
                    ),
                  )
                else
                  for (final a in _userActions)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.animation_rounded,
                          size: 18, color: Color(0xFFB0789A)),
                      title: Text(a.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '${a.frameCount} 帧 · ${a.durationSeconds}秒'
                        '${switch (a.kind) {
                              PetActionKind.moveTo => ' · 移动',
                              PetActionKind.duo => ' · 双人',
                              _ => a.target != null
                                  ? ' · ${a.trajectory.label}到'
                                      '(${(a.target!.x * 100).round()}%,'
                                      '${(a.target!.y * 100).round()}%)'
                                  : '',
                            }}',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 16, color: Color(0xFFC0A0A8)),
                        onPressed: () => _removeAction(a),
                      ),
                    ),
              ],
            ),
    );
  }
}

/// 右页统一的区块卡片样式（与右侧栏其他区块一致）
class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0E4EC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8A5A72),
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 导入时用户选择的动作类型
enum _ImportKind {
  inPlace('原地动作', '跳/挥手/待机等，站在原地播'),
  move('移动动作', '走/跑，用于移动组绑定'),
  duo('双人互动', '每张图里画两个小人挨在一起（一半是你，一半是男主）');

  final String label;
  final String hint;
  const _ImportKind(this.label, this.hint);
}

/// 播的时候怎么动（导入时配置，只对原地动作生效）
enum _HowMove {
  none('原地不动', '就在原地播这组帧'),
  dir('朝方向走到屏幕边', '上下左右斜着都行，到边自动停'),
  target('到某个位置', '滑滑块选目标点，角度/时长自动算');

  final String label;
  final String hint;
  const _HowMove(this.label, this.hint);
}

/// 导入帧图对话框
///
/// 流程：选图（多选，顺序即帧顺序）→ 自动数帧 → 预览 →
/// 命名 + 类型 + 秒数 → 保存（复制文件 + 写动作记录）
class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _nameController = TextEditingController();
  final _secondsController = TextEditingController(text: '1');
  List<String>? _files;
  _ImportKind _kind = _ImportKind.inPlace;

  /// 播的时候怎么动：不动 / 朝方向走到屏幕边 / 到某个位置
  _HowMove _howMove = _HowMove.none;
  PetMoveDir _moveDir = PetMoveDir.left;
  double _targetX = 0.5;
  double _targetY = 0.5;
  PetMoveTrajectory _trajectory = PetMoveTrajectory.walk;
  bool _saving = false;

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    final paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    if (paths.isEmpty) return;
    setState(() {
      _files = paths;
      // 自动建议秒数：帧数 ÷ 10（约 10fps）
      _secondsController.text = (paths.length / 10).toStringAsFixed(1);
    });
  }

  /// 方向对应的屏幕边中点（走到边 = 目标点在边上）
  (double?, double?) _edgePoint(PetMoveDir d) {
    final (vx, vy) = d.vector;
    return (0.5 + vx * 0.45, 0.5 + vy * 0.45);
  }

  Future<void> _save() async {
    final files = _files;
    if (files == null || files.isEmpty) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先给动作起个名字')),
      );
      return;
    }
    final seconds = double.tryParse(_secondsController.text.trim()) ?? 1;
    if (seconds <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('秒数要大于 0')),
      );
      return;
    }
    setState(() => _saving = true);

    // 1. 复制帧图到 pet/animations/<动作id>/
    final actionId = 'act_${DateTime.now().millisecondsSinceEpoch}';
    final dir = await FilePetFrameSource.actionDir(actionId);
    final copied = <String>[];
    final usedNames = <String>{};
    for (final src in files) {
      final ext = p.extension(src);
      var base = p.basenameWithoutExtension(src);
      var fileName = '$base$ext';
      var n = 1;
      while (usedNames.contains(fileName)) {
        fileName = '${base}_$n$ext';
        n++;
      }
      usedNames.add(fileName);
      final dest = p.join(dir, fileName);
      await File(src).copy(dest);
      copied.add(dest);
    }

    // 2. 写动作记录（匀速：fps = 帧数 ÷ 秒数）
    final store = PetStore();
    final kind = switch (_kind) {
      _ImportKind.inPlace => PetActionKind.inPlace,
      _ImportKind.move => PetActionKind.moveTo,
      _ImportKind.duo => PetActionKind.duo,
    };
    final fps = (copied.length / seconds).clamp(1.0, 60.0);
    // "播的时候怎么动"：原地动作才生效（移动组/双人由各自机制驱动）
    final (tx, ty) = switch (_howMove) {
      _HowMove.none => (null, null),
      _HowMove.dir => _edgePoint(_moveDir),
      _HowMove.target => (_targetX, _targetY),
    };
    final def = PetActionDef(
      id: actionId,
      name: name,
      kind: kind,
      fps: fps,
      loop: PetAnimLoop.loop,
      frameDir: actionId,
      frameCount: copied.length,
      durationSeconds: seconds,
      targetX: tx,
      targetY: ty,
      trajectory: _trajectory,
    );
    await store.saveAction(def);
    PetSettingsNotifier.instance.notifyChanged();
    DebugLogger.log('桌宠', '导入动作: $name (${copied.length}帧/${seconds}秒, ${kind.name})');

    if (!mounted) return;
    Navigator.pop(context);
    if (_kind == _ImportKind.move) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('「$name」已保存，去「移动组」里把它绑成走/跑吧'),
          duration: const Duration(seconds: 3),
        ),
      );
    } else if (_kind == _ImportKind.duo) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('「$name」已保存！把两个小人拖到一起就会触发'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return AlertDialog(
      title: const Text('导入帧图'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (files == null)
                Center(
                  child: OutlinedButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('选择图片（可多选，按顺序）'),
                  ),
                )
              else ...[
                Text('共 ${files.length} 帧（按选择顺序播放）',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8A5A72))),
                const SizedBox(height: 8),
                SizedBox(
                  height: 90,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: files.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(files[i]),
                        width: 80,
                        height: 90,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 80,
                          height: 90,
                          color: const Color(0xFFF0E4EC),
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('重新选图', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '动作名字',
                    hintText: '如：走路 / 挥手',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('这个动作是：', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                SegmentedButton<_ImportKind>(
                  segments: [
                    for (final k in _ImportKind.values)
                      ButtonSegment(
                          value: k,
                          label: Text(k.label,
                              style: const TextStyle(fontSize: 11))),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: 6),
                Text(_kind.hint,
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFFB0A0A6))),
                const SizedBox(height: 12),
                TextField(
                  controller: _secondsController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: '这组帧播几秒',
                    hintText: '如：0.5 快 / 1 正常 / 2 慢',
                    suffixText: '秒',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                const Text('匀速播放；同样一组帧，秒数越短看起来越快',
                    style: TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
                // 播的时候怎么动（只对原地动作显示；移动动作由移动组驱动，双人贴住）
                if (_kind == _ImportKind.inPlace) ...[
                  const SizedBox(height: 12),
                  const Text('播的时候怎么动：',
                      style: TextStyle(fontSize: 12)),
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
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final d in PetMoveDir.values)
                          SizedBox(
                            width: 42,
                            height: 30,
                            child: OutlinedButton(
                              onPressed: () => setState(() => _moveDir = d),
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
                                      fontSize: 10,
                                      color: Color(0xFF8A5A72))),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_howMove == _HowMove.target) ...[
                    const SizedBox(height: 8),
                    _TrajectorySelector(
                      value: _trajectory,
                      onChanged: (t) => setState(() => _trajectory = t),
                    ),
                    const SizedBox(height: 8),
                    _TargetPicker(
                      initial: PetPoint(_targetX, _targetY),
                      onChanged: (p) {
                        _targetX = p.x;
                        _targetY = p.y;
                      },
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (files != null)
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存动作'),
          ),
      ],
    );
  }
}

/// 移动组管理对话框：把"走""跑"绑成一组
class _MoveGroupDialog extends StatefulWidget {
  final PetStore store;
  final List<PetActionDef> actions;

  const _MoveGroupDialog({required this.store, required this.actions});

  @override
  State<_MoveGroupDialog> createState() => _MoveGroupDialogState();
}

class _MoveGroupDialogState extends State<_MoveGroupDialog> {
  final _nameController = TextEditingController();
  String? _walkId;
  String? _runId;
  List<PetMoveGroupDef> _groups = [];
  bool _loading = true;

  /// 可选动作：内置 walk/run + 用户自建
  List<PetActionDef> get _candidates => [
        for (final a in PetBuiltinActions.all)
          if (a.id == 'walk' || a.id == 'run') a,
        ...widget.actions,
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final groups = await widget.store.allMoveGroups();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final walkId = _walkId;
    if (name.isEmpty || walkId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('起个名字并至少选一个"走"动作')),
      );
      return;
    }
    final def = PetMoveGroupDef(
      id: 'grp_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      walkActionId: walkId,
      runActionId: _runId,
    );
    await widget.store.saveMoveGroup(def);
    PetSettingsNotifier.instance.notifyChanged();
    DebugLogger.log('桌宠', '保存移动组: $name (走=$walkId 跑=$_runId)');
    await _load();
    _nameController.clear();
    setState(() {
      _walkId = null;
      _runId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('移动组（走+跑绑定）'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '小人移动时，系统按速度自动切换：慢=走，快=跑。',
                style: TextStyle(fontSize: 12, color: Color(0xFF8A5A72)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '组名字',
                  hintText: '如：我的走路组',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _walkId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '走（慢速动画）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final a in _candidates)
                    DropdownMenuItem(
                        value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setState(() => _walkId = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: _runId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '跑（快速动画，可留空）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('不用跑')),
                  for (final a in _candidates)
                    DropdownMenuItem<String?>(
                        value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setState(() => _runId = v),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: const Text('保存这个组'),
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB0789A)),
                ),
              ),
              const Divider(height: 20),
              if (_loading)
                const Center(
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)))
              else if (_groups.isEmpty)
                const Text('还没有自建组（默认组：走+跑）',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9A8A90)))
              else
                for (final g in _groups)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const Icon(Icons.directions_walk, size: 18, color: Color(0xFFB0789A)),
                    title: Text(g.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '走: ${_nameOf(g.walkActionId)}'
                      '${g.runActionId != null ? ' · 跑: ${_nameOf(g.runActionId!)}' : ''}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 16, color: Color(0xFFC0A0A8)),
                      onPressed: () async {
                        await widget.store.removeMoveGroup(g.id);
                        PetSettingsNotifier.instance.notifyChanged();
                        await _load();
                      },
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }

  String _nameOf(String id) {
    for (final a in _candidates) {
      if (a.id == id) return a.name;
    }
    return id;
  }
}

/// 组合动作列表：已有组合 + 新建入口
class _ActivityDialog extends StatefulWidget {
  final PetStore store;
  final List<PetActivityDef> activities;
  final List<PetActionDef> actions;

  const _ActivityDialog({
    required this.store,
    required this.activities,
    required this.actions,
  });

  @override
  State<_ActivityDialog> createState() => _ActivityDialogState();
}

class _ActivityDialogState extends State<_ActivityDialog> {
  late List<PetActivityDef> _activities;

  @override
  void initState() {
    super.initState();
    _activities = List.of(widget.activities);
  }

  Future<void> _create() async {
    final created = await showDialog<PetActivityDef>(
      context: context,
      builder: (_) => _ActivityEditorDialog(
        store: widget.store,
        actions: widget.actions,
      ),
    );
    if (created != null) {
      setState(() => _activities.add(created));
    }
  }

  Future<void> _edit(PetActivityDef def) async {
    final edited = await showDialog<PetActivityDef>(
      context: context,
      builder: (_) => _ActivityEditorDialog(
        store: widget.store,
        actions: widget.actions,
        existing: def,
      ),
    );
    if (edited != null) {
      setState(() {
        final i = _activities.indexWhere((a) => a.id == def.id);
        if (i >= 0) _activities[i] = edited;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('组合动作'),
      content: SizedBox(
        width: 380,
        child: _activities.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: Text('还没有组合动作。\n'
                    '组合 = 把多个动作按顺序串起来，'
                    '比如：快跑1秒 → 向左走到撞墙 → 跳一下。\n'
                    '步骤之间会自动平滑衔接，不用你配置。',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9A8A90))),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final a in _activities)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.queue_music_rounded,
                          size: 18, color: Color(0xFFB0789A)),
                      title: Text(a.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text('${a.steps.length} 步',
                          style: const TextStyle(fontSize: 11)),
                      onTap: () => _edit(a),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 16, color: Color(0xFFC0A0A8)),
                        onPressed: () async {
                          await widget.store.removeActivity(a.id);
                          PetSettingsNotifier.instance.notifyChanged();
                          setState(() => _activities.removeWhere(
                              (x) => x.id == a.id));
                        },
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('新建组合'),
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0789A)),
        ),
      ],
    );
  }
}

/// 组合动作编辑器：名字 + 步骤编排（动作/移动/说话）
class _ActivityEditorDialog extends StatefulWidget {
  final PetStore store;
  final List<PetActionDef> actions;
  final PetActivityDef? existing;

  const _ActivityEditorDialog({
    required this.store,
    required this.actions,
    this.existing,
  });

  @override
  State<_ActivityEditorDialog> createState() => _ActivityEditorDialogState();
}

class _ActivityEditorDialogState extends State<_ActivityEditorDialog> {
  late final TextEditingController _nameController;
  late final List<PetActivityStep> _steps;

  /// 可选动作：内置 + 用户自建
  late final List<PetActionDef> _candidates;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.existing?.name ?? '');
    _steps = List.of(widget.existing?.steps ?? []);
    _candidates = [...PetBuiltinActions.all, ...widget.actions];
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _actionName(String id) {
    for (final a in _candidates) {
      if (a.id == id) return a.name;
    }
    return id;
  }

  String _stepDesc(PetActivityStep s) {
    if (s.isSpeak) return '说："${s.text ?? ''}"';
    if (s.target != null) {
      final t = s.target!;
      return '${s.trajectory.label} 到'
          ' (横向 ${(t.x * 100).round()}%, 竖向 ${(t.y * 100).round()}%)';
    }
    if (s.isMoveDir) {
      return '${s.moveDir!.label}走 ${s.moveUntilWall ? "直到撞墙" : "${s.moveSec}秒"}';
    }
    final dur =
        s.durationSec != null ? ' ${s.durationSec}秒' : '（播完为止）';
    // 动作自带移动属性（导入时配的"播的时候怎么动"）
    PetActionDef? def;
    for (final c in _candidates) {
      if (c.id == s.actionId) {
        def = c;
        break;
      }
    }
    if (def != null && def.target != null) {
      final t = def.target!;
      return '${_actionName(s.actionId)}（${def.trajectory.label}到'
          ' ${(t.x * 100).round()}%,${(t.y * 100).round()}%）$dur';
    }
    return '${_actionName(s.actionId)}$dur';
  }

  Future<void> _addStep() async {
    final kind = await showDialog<_StepKind>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('添加步骤'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _StepKind.action),
            child: const ListTile(
              leading: Icon(Icons.animation_rounded, color: Color(0xFFB0789A)),
              title: Text('动作'),
              subtitle: Text('播放一组帧（如：快跑 1秒）'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _StepKind.move),
            child: const ListTile(
              leading: Icon(Icons.directions_walk_rounded,
                  color: Color(0xFFB0789A)),
              title: Text('移动'),
              subtitle: Text('朝一个方向走几秒 / 直到撞墙'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _StepKind.speak),
            child: const ListTile(
              leading: Icon(Icons.chat_bubble_outline_rounded,
                  color: Color(0xFFB0789A)),
              title: Text('说话'),
              subtitle: Text('冒出气泡说一句话'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
    if (kind == null) return;
    final step = await showDialog<PetActivityStep>(
      context: context,
      builder: (_) => _StepDialog(kind: kind, candidates: _candidates),
    );
    if (step != null) {
      setState(() => _steps.add(step));
    }
  }

  Future<void> _editStep(int index) async {
    final step = _steps[index];
    final kind = step.isSpeak
        ? _StepKind.speak
        : step.isMoveDir
            ? _StepKind.move
            : _StepKind.action;
    final edited = await showDialog<PetActivityStep>(
      context: context,
      builder: (_) =>
          _StepDialog(kind: kind, candidates: _candidates, existing: step),
    );
    if (edited != null) {
      setState(() => _steps[index] = edited);
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('给组合起个名字')),
      );
      return;
    }
    if (_steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少加一个步骤')),
      );
      return;
    }
    final def = PetActivityDef(
      id: widget.existing?.id ??
          'actv_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      steps: _steps,
    );
    await widget.store.saveActivity(def);
    PetSettingsNotifier.instance.notifyChanged();
    if (mounted) Navigator.pop(context, def);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '新建组合' : '编辑组合'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '组合名字',
                  hintText: '如：打招呼 / 晨练',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('步骤（从上到下依次播放，之间自动平滑衔接）：',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8A5A72))),
              const SizedBox(height: 4),
              if (_steps.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('还没有步骤',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFFB0A0A6))),
                )
              else
                for (var i = 0; i < _steps.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Text('${i + 1}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFB0789A))),
                    title: Text(_stepDesc(_steps[i]),
                        style: const TextStyle(fontSize: 12.5)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_upward,
                              size: 14, color: Color(0xFFB0A0A6)),
                          onPressed: i == 0
                              ? null
                              : () => setState(() {
                                    final t = _steps[i];
                                    _steps[i] = _steps[i - 1];
                                    _steps[i - 1] = t;
                                  }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.arrow_downward,
                              size: 14, color: Color(0xFFB0A0A6)),
                          onPressed: i == _steps.length - 1
                              ? null
                              : () => setState(() {
                                    final t = _steps[i];
                                    _steps[i] = _steps[i + 1];
                                    _steps[i + 1] = t;
                                  }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined,
                              size: 14, color: Color(0xFF9A8A90)),
                          onPressed: () => _editStep(i),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 14, color: Color(0xFFC0A0A8)),
                          onPressed: () =>
                              setState(() => _steps.removeAt(i)),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addStep,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('添加步骤', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存组合'),
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0789A)),
        ),
      ],
    );
  }
}

enum _StepKind { action, move, speak }

/// 步骤编辑对话框（按类型显示不同表单）
class _StepDialog extends StatefulWidget {
  final _StepKind kind;
  final List<PetActionDef> candidates;
  final PetActivityStep? existing;

  const _StepDialog({
    required this.kind,
    required this.candidates,
    this.existing,
  });

  @override
  State<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends State<_StepDialog> {
  late String _actionId;
  late final TextEditingController _secController;
  late final TextEditingController _speakController;
  late double _targetX;
  late double _targetY;
  late bool _moveWith;
  late PetMoveTrajectory _trajectory;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _actionId = e?.actionId ?? widget.candidates.first.id;
    _secController =
        TextEditingController(text: e?.durationSec?.toString() ?? '');
    _speakController = TextEditingController(text: e?.text ?? '');
    _targetX = e?.targetX ?? 0.5;
    _targetY = e?.targetY ?? 0.5;
    _moveWith = e?.targetX != null || e?.targetSpot != null;
    _trajectory = e?.trajectory ?? PetMoveTrajectory.walk;
  }

  @override
  void dispose() {
    _secController.dispose();
    _speakController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(switch (widget.kind) {
        _StepKind.action => '动作步骤',
        _StepKind.move => '移动步骤',
        _StepKind.speak => '说话步骤',
      }),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: switch (widget.kind) {
            _StepKind.action => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _actionId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '动作',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final a in widget.candidates)
                        DropdownMenuItem(
                            value: a.id,
                            child: Text(
                                '${a.name}'
                                '${switch (a.kind) {
                                      PetActionKind.moveTo => '（移动）',
                                      PetActionKind.duo => '（双人）',
                                      _ => '',
                                    }}')),
                    ],
                    onChanged: (v) =>
                        setState(() => _actionId = v ?? _actionId),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _secController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: '播几秒（留空 = 播完为止）',
                      suffixText: '秒',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同时移动（跳/飞到某个位置）',
                        style: TextStyle(fontSize: 13)),
                    subtitle: const Text('边播这组帧边移动到目标点',
                        style: TextStyle(fontSize: 11)),
                    value: _moveWith,
                    activeTrackColor: const Color(0xFFB0789A),
                    onChanged: (v) => setState(() => _moveWith = v),
                  ),
                  if (_moveWith) ...[
                    const SizedBox(height: 4),
                    _TrajectorySelector(
                      value: _trajectory,
                      onChanged: (t) => setState(() => _trajectory = t),
                    ),
                    const SizedBox(height: 8),
                    _TargetPicker(
                      initial: PetPoint(_targetX, _targetY),
                      onChanged: (p) {
                        _targetX = p.x;
                        _targetY = p.y;
                      },
                    ),
                  ],
                ],
              ),
            _StepKind.move => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('走到哪：',
                      style:
                          TextStyle(fontSize: 12, color: Color(0xFF8A5A72))),
                  const SizedBox(height: 4),
                  _TrajectorySelector(
                    value: _trajectory,
                    onChanged: (t) => setState(() => _trajectory = t),
                  ),
                  const SizedBox(height: 8),
                  _TargetPicker(
                    initial: PetPoint(_targetX, _targetY),
                    onChanged: (p) {
                      _targetX = p.x;
                      _targetY = p.y;
                    },
                  ),
                ],
              ),
            _StepKind.speak => TextField(
                controller: _speakController,
                decoration: const InputDecoration(
                  labelText: '说什么',
                  hintText: '如：大家好呀',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final sec = double.tryParse(_secController.text.trim());
            final step = switch (widget.kind) {
              _StepKind.action => PetActivityStep(
                  actionId: _actionId,
                  durationSec: sec,
                  targetX: _moveWith ? _targetX : null,
                  targetY: _moveWith ? _targetY : null,
                  trajectory: _trajectory,
                ),
              // 移动步骤 = 用移动组帧（走/跑）走到目标点
              _StepKind.move => PetActivityStep(
                  actionId: 'walk',
                  targetX: _targetX,
                  targetY: _targetY,
                  trajectory: _trajectory,
                ),
              _StepKind.speak => PetActivityStep(
                  actionId: 'speak',
                  text: _speakController.text.trim(),
                ),
            };
            Navigator.pop(context, step);
          },
          child: const Text('确定'),
          style:
              FilledButton.styleFrom(backgroundColor: const Color(0xFFB0789A)),
        ),
      ],
    );
  }
}

/// 目标点选择器：模拟手机屏幕的小方块 + 横向/竖向双滑块 + 8 向快捷按钮
///
/// 用户"指哪走哪"：滑滑块选目标位置，亮点实时显示，
/// 角度/距离/时长全部由引擎自动换算，用户零配置。
class _TargetPicker extends StatefulWidget {
  final PetPoint? initial;
  final ValueChanged<PetPoint> onChanged;

  const _TargetPicker({this.initial, required this.onChanged});

  @override
  State<_TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends State<_TargetPicker> {
  late double _x;
  late double _y;

  /// 起点（预览用）：默认屏幕中央
  static const _origin = PetPoint(0.5, 0.5);

  @override
  void initState() {
    super.initState();
    _x = widget.initial?.x ?? 0.5;
    _y = widget.initial?.y ?? 0.5;
  }

  void _set(double x, double y) {
    setState(() {
      _x = x.clamp(0.02, 0.98);
      _y = y.clamp(0.02, 0.98);
    });
    widget.onChanged(PetPoint(_x, _y));
  }

  void _quick(PetMoveDir d) {
    final (vx, vy) = d.vector;
    // 朝方向走到屏幕边（边中点）
    _set(0.5 + vx * 0.45, 0.5 + vy * 0.45);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 迷你屏幕：起点灰点 → 目标亮点 + 路径线
        Center(
          child: Container(
            width: 150,
            height: 250,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F0F2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD8C8CE)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                children: [
                  // 起点
                  Positioned(
                    left: _origin.x * 150 - 4,
                    top: _origin.y * 250 - 4,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFC0B0B6),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  // 路径线（起点 → 目标）
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _PathPainter(
                          from: _origin, to: PetPoint(_x, _y)),
                    ),
                  ),
                  // 目标亮点
                  Positioned(
                    left: _x * 150 - 7,
                    top: _y * 250 - 7,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: const Color(0xFFB0789A),
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x55B0789A), blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
                  // 边提示
                  const Positioned(
                    left: 6,
                    top: 4,
                    child: Text('屏幕',
                        style: TextStyle(
                            fontSize: 9, color: Color(0xFFB0A0A6))),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 双滑块：横向 + 竖向（竖向滑块在上 = 目标在上）
        Row(
          children: [
            const SizedBox(width: 4),
            RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: 120,
                child: Slider(
                  value: 1 - _y,
                  min: 0,
                  max: 1,
                  activeColor: const Color(0xFFB0789A),
                  onChanged: (v) => _set(_x, 1 - v),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: _x,
                min: 0,
                max: 1,
                activeColor: const Color(0xFFB0789A),
                onChanged: (v) => _set(v, _y),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('横向', style: TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
            Text(
              '目标：横向 ${(_x * 100).round()}% · 竖向 ${(_y * 100).round()}%',
              style: const TextStyle(fontSize: 10, color: Color(0xFF8A5A72)),
            ),
            const Text('竖向', style: TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
          ],
        ),
        const SizedBox(height: 8),
        // 8 向快捷：点一下 = 朝那个方向走到屏幕边
        const Text('快捷：朝这个方向走到屏幕边',
            style: TextStyle(fontSize: 10, color: Color(0xFFB0A0A6))),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final d in PetMoveDir.values)
              SizedBox(
                width: 40,
                height: 28,
                child: OutlinedButton(
                  onPressed: () => _quick(d),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    side: const BorderSide(color: Color(0xFFD8C0CA)),
                  ),
                  child: Text(d.label,
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFF8A5A72))),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('超出屏幕的位置会自动截断到屏幕边，不会跑出去',
            style: TextStyle(fontSize: 9.5, color: Color(0xFFC0B0B6))),
      ],
    );
  }
}

/// 起点 → 目标 路径线画笔
class _PathPainter extends CustomPainter {
  final PetPoint from;
  final PetPoint to;

  _PathPainter({required this.from, required this.to});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x88B0789A)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(from.x * size.width, from.y * size.height)
      ..lineTo(to.x * size.width, to.y * size.height);
    canvas.drawPath(path, paint);
    // 箭头
    final dx = to.x - from.x;
    final dy = to.y - from.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 0.02) {
      final ux = dx / len;
      final uy = dy / len;
      final tip = Offset(to.x * size.width, to.y * size.height);
      final back = Offset(
          tip.dx - ux * 10, tip.dy - uy * 10);
      final n = Offset(-uy, ux);
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(back.dx + n.dx * 4, back.dy + n.dy * 4)
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(back.dx - n.dx * 4, back.dy - n.dy * 4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PathPainter old) =>
      old.from != from || old.to != to;
}

/// 轨迹三选：走过去 / 跳过去 / 飞过去
class _TrajectorySelector extends StatelessWidget {
  final PetMoveTrajectory value;
  final ValueChanged<PetMoveTrajectory> onChanged;

  const _TrajectorySelector({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('怎么过去：', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        SegmentedButton<PetMoveTrajectory>(
          segments: [
            for (final t in PetMoveTrajectory.values)
              ButtonSegment(
                value: t,
                label: Text(t.label, style: const TextStyle(fontSize: 11)),
              ),
          ],
          selected: {value},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 4),
        Text(value.hint,
            style:
                const TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
      ],
    );
  }
}
