import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_frame_source_impl.dart';
import '../../services/pet_settings_notifier.dart';

/// 目标点选择器：模拟手机屏幕的小方块 + 横向/竖向双滑块 + 8 向快捷按钮
///
/// 用户"指哪走哪"：滑滑块选目标位置，亮点实时显示，
/// 角度/距离/时长全部由引擎自动换算，用户零配置。
class TargetPicker extends StatefulWidget {
  final PetPoint? initial;
  final ValueChanged<PetPoint> onChanged;

  const TargetPicker({this.initial, required this.onChanged});

  @override
  State<TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends State<TargetPicker> {
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
            const Text('横向',
                style: TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
            Text(
              '目标：横向 ${(_x * 100).round()}% · 竖向 ${(_y * 100).round()}%',
              style: const TextStyle(fontSize: 10, color: Color(0xFF8A5A72)),
            ),
            const Text('竖向',
                style: TextStyle(fontSize: 9, color: Color(0xFFB0A0A6))),
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
