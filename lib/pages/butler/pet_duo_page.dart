import 'package:flutter/material.dart';

import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_settings_notifier.dart';

/// 角色互动 —— 选两个小人，配一段双人互动
///
/// 流程：勾选两个角色 → 选一个双人互动动作（导入时类型选"双人互动"的帧组）
/// → 保存。陪伴页上这两个小人靠近时会自动播这段互动。
class PetDuoPage extends StatefulWidget {
  const PetDuoPage({super.key});

  @override
  State<PetDuoPage> createState() => _PetDuoPageState();
}

class _PetDuoPageState extends State<PetDuoPage> {
  final _store = PetStore();
  List<PetProfile> _profiles = [];
  List<PetActionDef> _actions = [];
  List<PetDuoConfig> _configs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _store.allProfiles();
    final actions = await _store.allActions();
    final configs = await _store.duoConfigs();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _actions = actions;
      _configs = configs;
      _loading = false;
    });
  }

  List<PetActionDef> get _duoActions =>
      [for (final a in _actions) if (a.kind == PetActionKind.duo) a];

  String _petName(String id) {
    for (final p in _profiles) {
      if (p.petId == id) return p.name;
    }
    return id;
  }

  String _actionName(String id) {
    for (final a in _actions) {
      if (a.id == id) return a.name;
    }
    return id;
  }

  /// 新建/编辑一条互动
  Future<void> _edit(PetDuoConfig? existing) async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _DuoEditDialog(
        profiles: _profiles,
        duoActions: _duoActions,
        existing: existing,
      ),
    );
    if (created == true) _load();
  }

  Future<void> _delete(PetDuoConfig c) async {
    await _store.removeDuoConfig(c.pairId);
    PetSettingsNotifier.instance.notifyChanged();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF6F8),
      appBar: AppBar(
        title: const Text('角色互动'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF6A4A5A),
        elevation: 0.5,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x22F0E4EA),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE8D8E0)),
                  ),
                  child: const Text(
                    '先勾选两个小人（如 A+B），再选一段双人互动。\n'
                    '陪伴页上这两个小人靠近时会自动播放这段互动。\n'
                    '双人互动动作 = 导入图片时类型选「双人互动」，每张图里画两个小人挨在一起。',
                    style: TextStyle(
                        fontSize: 11.5, color: Color(0xFF8A5A72), height: 1.6),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('已配互动',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6A4A5A))),
                    const Spacer(),
                    Text('${_configs.length} 条',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFB0A0A6))),
                  ],
                ),
                const SizedBox(height: 10),
                if (_configs.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(
                      color: const Color(0x22F0E4EA),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE8D8E0)),
                    ),
                    child: const Text('还没有互动\n点下面「＋ 新建互动」配置第一对',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB0A0A6),
                            height: 1.6)),
                  )
                else
                  for (final c in _configs)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE8D8E0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.favorite,
                              size: 18, color: Color(0xFFB0789A)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_petName(c.petA)} 和 ${_petName(c.petB)}',
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF6A4A5A)),
                                ),
                                const SizedBox(height: 2),
                                Text('互动：${_actionName(c.actionId)}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFFB0A0A6))),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined,
                                size: 18, color: Color(0xFFB0789A)),
                            onPressed: () => _edit(c),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: Color(0xFFD0A0B0)),
                            onPressed: () => _delete(c),
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: () => _edit(null),
                    icon: const Icon(Icons.add,
                        size: 18, color: Color(0xFFB0789A)),
                    label: const Text('新建互动',
                        style: TextStyle(
                            color: Color(0xFFB0789A), fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFD8C0CA)),
                      backgroundColor: const Color(0x11F0E4EA),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_duoActions.isEmpty)
                  const Text(
                    '提示：还没有「双人互动」类型的动作。去角色配置页 → 添加动作，'
                    '类型选「双人互动」，每张图里画两个小人挨在一起。',
                    style: TextStyle(
                        fontSize: 11, color: Color(0xFFC0A0B0), height: 1.5),
                  ),
              ],
            ),
    );
  }
}

/// 互动编辑对话框：勾选两个角色 + 选互动动作
class _DuoEditDialog extends StatefulWidget {
  final List<PetProfile> profiles;
  final List<PetActionDef> duoActions;
  final PetDuoConfig? existing;

  const _DuoEditDialog({
    required this.profiles,
    required this.duoActions,
    this.existing,
  });

  @override
  State<_DuoEditDialog> createState() => _DuoEditDialogState();
}

class _DuoEditDialogState extends State<_DuoEditDialog> {
  final List<String> _selected = [];
  String? _actionId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _selected.addAll([e.petA, e.petB]);
      _actionId = e.actionId;
    }
  }

  Future<void> _save() async {
    if (_selected.length != 2) {
      _toast('勾选两个小人');
      return;
    }
    if (_actionId == null) {
      _toast('选一段互动动作');
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

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建互动'),
      content: SizedBox(
        width: 340,
        height: 380,
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('选两个小人：',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB0A0A6))),
            ),
            const SizedBox(height: 4),
            Expanded(
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
                    title: Text(pet.name, style: const TextStyle(fontSize: 13)),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('互动动作：',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB0A0A6))),
            ),
            const SizedBox(height: 4),
            if (widget.duoActions.isEmpty)
              const Text('还没有双人互动动作，先去角色配置页添加',
                  style: TextStyle(fontSize: 11, color: Color(0xFFC0A0B0)))
            else
              DropdownButtonFormField<String>(
                initialValue: _actionId,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                hint: const Text('选一段互动', style: TextStyle(fontSize: 12)),
                items: [
                  for (final a in widget.duoActions)
                    DropdownMenuItem(
                        value: a.id,
                        child: Text('${a.name}（${a.durationSeconds}秒）',
                            style: const TextStyle(fontSize: 12.5))),
                ],
                onChanged: (v) => setState(() => _actionId = v),
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
