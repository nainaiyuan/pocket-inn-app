import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_frame_source_impl.dart';
import '../../services/pet_settings_notifier.dart';

/// 移动目标编辑结果
class MoveTargetResult {
  /// 目标点（碰墙模式下 = 沿方向到屏幕边的点，仅预览）
  final PetPoint target;

  /// 当前方向（点过方向按钮，或由目标点相对锚点推断）
  final PetMoveDir dir;

  /// 当前距离 0.1~1.0
  final double dist;

  /// 碰墙模式（组合步骤用）：一直走到屏幕边才停
  final bool untilWall;

  /// true = 最后一次操作是方向按钮/距离滑块（"从锚点朝方向走"语义）
  final bool usedDir;

  const MoveTargetResult({
    required this.target,
    required this.dir,
    required this.dist,
    required this.untilWall,
    required this.usedDir,
  });
}

/// 移动目标编辑器（方向+距离 与 到某个位置 合并版）
///
/// 迷你手机屏幕：灰点 = 起点锚点（方向+距离的基准），粉点 = 目标。
/// - 点地图任意位置 = 直接指定目标点（"到某个位置"）
/// - 8 向按钮 + 距离滑块 = 从灰点朝该方向走多远（"方向+距离"）
/// - 碰墙开关（组合步骤用）= 朝方向一直走到屏幕边
class MoveTargetEditor extends StatefulWidget {
  /// 起点锚点（灰点）
  final PetPoint anchor;

  /// 初始目标点
  final PetPoint? initialTarget;

  /// 初始方向（旧数据带 moveDir 时传入，方向按钮会高亮）
  final PetMoveDir? initialDir;

  /// 初始距离
  final double? initialDist;

  /// 初始碰墙模式
  final bool initialUntilWall;

  /// 是否显示"一直走到屏幕边"开关（组合移动步骤用）
  final bool showUntilWall;

  /// 是否显示起点锚点（灰点 + 路径线）；剧本步骤里"到某位置"不需要
  final bool anchorVisible;

  final ValueChanged<MoveTargetResult> onChanged;

  const MoveTargetEditor({
    super.key,
    required this.anchor,
    this.initialTarget,
    this.initialDir,
    this.initialDist,
    this.initialUntilWall = false,
    this.showUntilWall = false,
    this.anchorVisible = true,
    required this.onChanged,
  });

  @override
  State<MoveTargetEditor> createState() => _MoveTargetEditorState();
}

class _MoveTargetEditorState extends State<MoveTargetEditor> {
  /// 迷你屏尺寸：高度固定，宽度按设备屏幕比例算（平板宽、手机窄），
  /// 记录的一直是 0~1 相对坐标，换设备照样用
  Size _map = const Size(150, 250);

  Size _mapSize() {
    final screen = MediaQuery.of(context).size;
    final ratio = (screen.width / screen.height).clamp(0.45, 1.5);
    const h = 250.0;
    final w = (h * ratio).clamp(120.0, 300.0);
    return Size(w, h);
  }

  late PetPoint _target;
  late PetMoveDir _dir;
  late double _dist;
  late bool _untilWall;
  late bool _usedDir;

  @override
  void initState() {
    super.initState();
    _dir = widget.initialDir ?? PetMoveDir.left;
    _dist = widget.initialDist ?? 0.3;
    _untilWall = widget.initialUntilWall;
    // 带方向进来的（旧数据）视为"方向+距离"语义，锚点变化时目标跟着重算
    _usedDir = widget.initialDir != null;
    _target = widget.initialTarget ??
        (_untilWall ? _edgeTarget(_dir) : _targetFor(_dir, _dist));
  }

  @override
  void didUpdateWidget(MoveTargetEditor old) {
    super.didUpdateWidget(old);
    if (old.anchor != widget.anchor) {
      // 锚点变了：方向模式的目标跟着新锚点重算；点选模式保持绝对目标
      if (_usedDir && !_untilWall) {
        _target = _targetFor(_dir, _dist);
        _emit();
      }
    }
  }

  PetPoint _targetFor(PetMoveDir d, double dist) {
    final (vx, vy) = d.vector;
    return PetPoint(
      (widget.anchor.x + vx * dist).clamp(0.02, 0.98),
      (widget.anchor.y + vy * dist).clamp(0.02, 0.98),
    );
  }

  /// 沿方向走到屏幕边（预览用，超出部分 clamp 到边）
  PetPoint _edgeTarget(PetMoveDir d) => _targetFor(d, 1.5);

  /// 由目标点相对锚点的方位推断方向（点地图后让方向按钮保持同步）
  PetMoveDir _inferDir(PetPoint t) {
    final dx = t.x - widget.anchor.x;
    final dy = t.y - widget.anchor.y;
    final ax = dx.abs();
    final ay = dy.abs();
    if (ax < 0.03 && ay < 0.03) return _dir;
    if (ax > ay * 1.5) return dx > 0 ? PetMoveDir.right : PetMoveDir.left;
    if (ay > ax * 1.5) return dy > 0 ? PetMoveDir.down : PetMoveDir.up;
    if (dx > 0) return dy > 0 ? PetMoveDir.downRight : PetMoveDir.upRight;
    return dy > 0 ? PetMoveDir.downLeft : PetMoveDir.upLeft;
  }

  void _emit() {
    widget.onChanged(MoveTargetResult(
      target: _target,
      dir: _dir,
      dist: _dist,
      untilWall: _untilWall,
      usedDir: _usedDir,
    ));
  }

  void _tap(Offset local) {
    setState(() {
      _untilWall = false;
      _target = PetPoint(
        (local.dx / _map.width).clamp(0.02, 0.98),
        (local.dy / _map.height).clamp(0.02, 0.98),
      );
      _usedDir = false;
      _dir = _inferDir(_target);
    });
    _emit();
  }

  void _pickDir(PetMoveDir d) {
    setState(() {
      _dir = d;
      _usedDir = true;
      _target = _untilWall ? _edgeTarget(d) : _targetFor(d, _dist);
    });
    _emit();
  }

  void _setDist(double v) {
    setState(() {
      _dist = v;
      _usedDir = true;
      _target = _targetFor(_dir, v);
    });
    _emit();
  }

  void _setUntilWall(bool v) {
    setState(() {
      _untilWall = v;
      _usedDir = true;
      _target = v ? _edgeTarget(_dir) : _targetFor(_dir, _dist);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    _map = _mapSize();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 迷你屏幕：起点灰点 → 目标粉点 + 路径线（点地图 = 指哪走哪）
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _tap(d.localPosition),
            child: Container(
              width: _map.width,
              height: _map.height,
              decoration: BoxDecoration(
                color: const Color(0xFFF5F0F2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFD8C8CE)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  children: [
                    // 聊天框区域（屏幕底部输入框）：让用户直观看到聊天框在哪，
                    // "从聊天框出发"的灰点正好落在它上沿中间
                    Positioned(
                      left: 0,
                      right: 0,
                      top: _map.height * 0.78,
                      height: _map.height * 0.22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0x22D0B8C4),
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(11)),
                          border: const Border(
                              top: BorderSide(
                                  color: Color(0x55B0A0A6), width: 1)),
                        ),
                        alignment: Alignment.topCenter,
                        padding: const EdgeInsets.only(top: 2),
                        child: const Text('聊天框',
                            style: TextStyle(
                                fontSize: 8, color: Color(0x99B0A0A6))),
                      ),
                    ),
                    // 起点锚点 + 路径线（anchorVisible=false 时隐藏）
                    if (widget.anchorVisible) ...[
                      Positioned(
                        left: widget.anchor.x * _map.width - 4,
                        top: widget.anchor.y * _map.height - 4,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFFC0B0B6),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _PathPainter(
                              from: widget.anchor, to: _target),
                        ),
                      ),
                    ],
                    // 目标亮点
                    Positioned(
                      left: _target.x * _map.width - 7,
                      top: _target.y * _map.height - 7,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFFB0789A),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
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
                          style:
                              TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
                    ),
                    if (_untilWall)
                      const Positioned(
                        right: 6,
                        top: 4,
                        child: Text('走到屏幕边',
                            style: TextStyle(
                                fontSize: 9, color: Color(0xFFB0789A))),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // 距离 / 碰墙状态
        Center(
          child: Text(
            _untilWall
                ? '朝「${_dir.label}」一直走到屏幕边'
                : '距离：${(_dist * 100).round()}%（从灰点出发）',
            style: const TextStyle(fontSize: 10.5, color: Color(0xFF8A5A72)),
          ),
        ),
        const SizedBox(height: 8),
        // 8 向快捷按钮（方向+距离 / 碰墙 共用）
        const Text('方向快捷：',
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
                  onPressed: () => _pickDir(d),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    side: BorderSide(
                      color: _dir == d
                          ? const Color(0xFFB0789A)
                          : const Color(0xFFD8C0CA),
                      width: _dir == d ? 1.6 : 1,
                    ),
                    backgroundColor:
                        _dir == d ? const Color(0x22B0789A) : null,
                  ),
                  child: Text(d.label,
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFF8A5A72))),
                ),
              ),
          ],
        ),
        // 距离滑块（碰墙时隐藏）
        if (!_untilWall) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              const Text('距离',
                  style: TextStyle(fontSize: 10, color: Color(0xFFB0A0A6))),
              Expanded(
                child: Slider(
                  value: _dist,
                  min: 0.1,
                  max: 1.0,
                  activeColor: const Color(0xFFB0789A),
                  onChanged: _setDist,
                ),
              ),
              SizedBox(
                width: 34,
                child: Text('${(_dist * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 10, color: Color(0xFF8A5A72))),
              ),
            ],
          ),
        ],
        // 碰墙开关（组合步骤）
        if (widget.showUntilWall)
          Row(
            children: [
              const Expanded(
                child: Text('一直走到屏幕边（碰到边缘才停）',
                    style: TextStyle(fontSize: 11, color: Color(0xFF6A4A5A))),
              ),
              Switch(
                value: _untilWall,
                activeTrackColor: const Color(0xFFB0789A),
                onChanged: _setUntilWall,
              ),
            ],
          ),
        const SizedBox(height: 4),
        const Text('点地图 = 直接指定位置；点方向按钮 = 从灰点朝这个方向走',
            style: TextStyle(fontSize: 9.5, color: Color(0xFFC0B0B6))),
      ],
    );
  }
}

/// 轨迹三选：走过去 / 跳过去 / 飞过去
class TrajectorySelector extends StatelessWidget {
  final PetMoveTrajectory value;
  final ValueChanged<PetMoveTrajectory> onChanged;

  const TrajectorySelector({
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
      final back = Offset(tip.dx - ux * 10, tip.dy - uy * 10);
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
  bool shouldRepaint(_PathPainter old) => old.from != from || old.to != to;
}

/// ─────────────────────────────────────────────
/// 互动编辑对话框：勾选两个角色 + 选/建互动动作
/// ─────────────────────────────────────────────
class DuoEditDialog extends StatefulWidget {
  final List<PetProfile> profiles;
  final PetDuoConfig? existing;

  const DuoEditDialog({
    super.key,
    required this.profiles,
    this.existing,
  });

  @override
  State<DuoEditDialog> createState() => _DuoEditDialogState();
}

class _DuoEditDialogState extends State<DuoEditDialog> {
  final List<String> _selected = [];
  String? _actionId;
  bool _saving = false;

  List<PetActionDef> _duoActions = [];
  bool _loadingActions = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _selected.addAll([e.petA, e.petB]);
      _actionId = e.actionId;
    }
    _loadDuoActions();
  }

  Future<void> _loadDuoActions() async {
    final store = PetStore();
    final all = await store.allActions();
    if (!mounted) return;
    setState(() {
      _duoActions = [
        for (final a in all)
          if (a.kind == PetActionKind.duo) a,
      ];
      _loadingActions = false;
    });
  }

  Future<void> _save() async {
    if (_selected.length != 2) {
      _toast('勾选两个小人');
      return;
    }
    if (_actionId == null) {
      _toast('选一段互动动作（或点「＋上传图新建」）');
      return;
    }
    setState(() => _saving = true);
    final store = PetStore();
    await store.saveDuoConfig(PetDuoConfig(
      pairId: '${_selected[0]}_${_selected[1]}',
      petA: _selected[0],
      petB: _selected[1],
      actionId: _actionId!,
    ));
    PetSettingsNotifier.instance.notifyChanged();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  /// 弹新建互动动作对话框：上传图 → 命名 → 保存为 duo 动作
  Future<void> _createDuoAction() async {
    final created = await showDialog<PetActionDef>(
      context: context,
      builder: (_) => const _NewDuoActionDialog(),
    );
    if (created == null || !mounted) return;
    // 保存成功：刷新列表并自动选中
    setState(() {
      _duoActions = [..._duoActions, created];
      _actionId = created.id;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加互动' : '编辑互动'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('选两个小人：',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB0A0A6))),
            ),
            const SizedBox(height: 4),
            Expanded(
              flex: 5,
              child: ListView.separated(
                itemCount: widget.profiles.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFF0E8EC)),
                itemBuilder: (_, i) {
                  final pet = widget.profiles[i];
                  final checked = _selected.contains(pet.petId);
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Checkbox(
                      value: checked,
                      activeColor: const Color(0xFFB0789A),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            if (_selected.length >= 2) {
                              _toast('最多选两个');
                              return;
                            }
                            _selected.add(pet.petId);
                          } else {
                            _selected.remove(pet.petId);
                          }
                        });
                      },
                    ),
                    title:
                        Text(pet.name, style: const TextStyle(fontSize: 13)),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('互动动作：',
                    style:
                        TextStyle(fontSize: 12, color: Color(0xFFB0A0A6))),
                const Spacer(),
                TextButton.icon(
                  onPressed: _createDuoAction,
                  icon: const Icon(Icons.add,
                      size: 15, color: Color(0xFFB0789A)),
                  label: const Text('上传图新建',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFFB0789A))),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              flex: 4,
              child: _loadingActions
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _duoActions.isEmpty
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0x22F0E4EA),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '还没有互动动作：点右上「上传图新建」，'
                            '上传一组两个小人挨在一起的帧图',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF9A8A90),
                                height: 1.6),
                          ),
                        )
                      : ListView(
                          children: [
                            for (final a in _duoActions)
                              RadioListTile<String>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                activeColor: const Color(0xFFB0789A),
                                title: Text('${a.name}（${a.durationSeconds}秒）',
                                    style: const TextStyle(fontSize: 13)),
                                value: a.id,
                                groupValue: _actionId,
                                onChanged: (v) =>
                                    setState(() => _actionId = v),
                              ),
                          ],
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

/// 新建互动动作小对话框：上传帧图 + 命名 + 秒数，保存后 pop 返回新动作
class _NewDuoActionDialog extends StatefulWidget {
  const _NewDuoActionDialog();

  @override
  State<_NewDuoActionDialog> createState() => _NewDuoActionDialogState();
}

class _NewDuoActionDialogState extends State<_NewDuoActionDialog> {
  List<String>? _files;
  final _nameController = TextEditingController();
  final _secondsController = TextEditingController(text: '1');
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _secondsController.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _files = result.files.map((f) => f.path!).toList();
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _toast('先给互动动作起个名字');
      return;
    }
    final seconds = double.tryParse(_secondsController.text.trim()) ?? 1;
    if (seconds <= 0) {
      _toast('秒数要大于 0');
      return;
    }
    final files = _files;
    if (files == null || files.isEmpty) {
      _toast('先上传互动帧图（两个小人挨在一起的一组图）');
      return;
    }
    setState(() => _saving = true);
    try {
      final actionId = 'duo_${DateTime.now().millisecondsSinceEpoch}';
      final dir = await FilePetFrameSource.actionDir(actionId);
      final copied = <String>[];
      for (final f in files) {
        final target = p.join(dir, p.basename(f));
        await File(f).copy(target);
        copied.add(target);
      }
      final def = PetActionDef(
        id: actionId,
        name: name,
        kind: PetActionKind.duo,
        fps: (copied.length / seconds).clamp(1.0, 60.0),
        loop: PetAnimLoop.loop,
        frameDir: actionId,
        frameCount: copied.length,
        durationSeconds: seconds,
      );
      await PetStore().saveAction(def);
      if (!mounted) return;
      Navigator.pop(context, def);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败，检查图片能否读取');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return AlertDialog(
      title: const Text('新建互动动作'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: _saving ? null : _pick,
                icon: const Icon(Icons.upload_file,
                    size: 18, color: Color(0xFFB0789A)),
                label: Text(files == null ? '上传互动帧图（可多选）' : '重新选图',
                    style: const TextStyle(color: Color(0xFFB0789A))),
              ),
              const SizedBox(height: 6),
              const Text('一组图里两个小人挨在一起，按顺序播放',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFFB0A0A6))),
              if (files != null && files.isNotEmpty) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 52,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: files.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(
                        File(files[i]),
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
                decoration: const InputDecoration(
                  labelText: '互动动作名字',
                  hintText: '如：贴贴 / 抱抱 / 转圈圈',
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
                  labelText: '播几秒',
                  suffixText: '秒',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
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
