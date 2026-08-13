import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_settings_notifier.dart';
import '../../utils/debug_logger.dart';
import 'pet_group_page.dart';
import 'pet_profile_page.dart';
import 'pet_widgets.dart';

/// 桌宠设置中心 —— 管家页面入口
///
/// 最外层就两块：
/// ① 多角色互动：一个个小框（图），点图进去配置（选 AB + 绑定互动）
/// ② 单角色：一个个小框（图），点图进去配置（基础动作 + 组合动作）
class PetSetupPage extends StatefulWidget {
  const PetSetupPage({super.key});

  @override
  State<PetSetupPage> createState() => _PetSetupPageState();
}

class _PetSetupPageState extends State<PetSetupPage> {
  final _store = PetStore();
  List<PetProfile> _profiles = [];
  List<PetGroupDef> _groups = [];
  List<PetActionDef> _actions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _store.allProfiles();
    final groups = await _store.allGroups();
    final actions = await _store.allActions();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _groups = groups;
      _actions = actions;
      _loading = false;
    });
  }

  /// 新建角色：名字 + 头像
  Future<void> _createPet() async {
    final nameCtrl = TextEditingController();
    String? avatarSrc;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('新建小人'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration:
                    const InputDecoration(hintText: '小人的名字（如：我的小猫）'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: const Color(0xFFF0E4EA),
                    backgroundImage: avatarSrc != null
                        ? FileImage(File(avatarSrc!))
                        : null,
                    child: avatarSrc == null
                        ? const Icon(Icons.person_outline,
                            color: Color(0xFFB0789A))
                        : null,
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.image,
                        allowMultiple: false,
                      );
                      if (result == null || result.files.isEmpty) return;
                      setDlg(() => avatarSrc = result.files.first.path);
                    },
                    icon: const Icon(Icons.add_a_photo_outlined,
                        size: 18, color: Color(0xFFB0789A)),
                    label: const Text('选头像',
                        style: TextStyle(color: Color(0xFFB0789A))),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB0789A)),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return;

    final petId = 'pet_${DateTime.now().millisecondsSinceEpoch}';
    String? avatarPath;
    if (avatarSrc != null) {
      try {
        final dir = await PetStore.avatarsDir();
        final ext = p.extension(avatarSrc!);
        avatarPath = p.join(dir, '$petId$ext');
        await File(avatarSrc!).copy(avatarPath);
      } catch (e) {
        DebugLogger.log('桌宠', '头像复制失败: $e');
      }
    }
    await _store.saveProfile(PetProfile(
      petId: petId,
      name: name,
      avatarPath: avatarPath,
    ));
    PetSettingsNotifier.instance.notifyChanged();
    _load();
  }

  Future<void> _toggle(PetProfile pet, bool visible) async {
    await _store.setProfileVisible(pet.petId, visible);
    PetSettingsNotifier.instance.notifyChanged();
    setState(() => pet.visible = visible);
  }

  /// 新建/编辑互动（对话框里勾选两角色 + 选/建互动动作）
  Future<void> _editGroup(PetGroupDef? existing) async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PetGroupPage(existing: existing)),
    );
    if (created == true) _load();
  }

  Future<void> _deleteGroup(PetGroupDef g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个互动组？'),
        content: Text('「${g.name}」会被删掉（包括所有坑的动作和帧图）'),
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
    await _store.removeGroup(g.id);
    PetSettingsNotifier.instance.notifyChanged();
    _load();
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF6F8),
      appBar: AppBar(
        title: const Text('桌宠'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF6A4A5A),
        elevation: 0.5,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 顶部说明卡
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF7E8F0), Color(0xFFFDF1F6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.pets, color: Color(0xFFB0789A), size: 30),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '这里放你的小人：\n单角色 = 一个小人一个框：点进去配它的动作和组合表演\n互动组 = 几个小人一起演：每坑一个角色（自己的帧图），一步步排剧本（A走、B跑、A去抱…）',
                          style: TextStyle(
                              fontSize: 12.5, color: Color(0xFF8A5A72)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // ═══ 单角色 ═══
                Row(
                  children: [
                    const Text('单角色',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6A4A5A))),
                    const Spacer(),
                    Text('${_profiles.length} 个',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFB0A0A6))),
                  ],
                ),
                const SizedBox(height: 4),
                const Text('一个小人一个框：点进去配 动作 + 组合',
                    style: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
                const SizedBox(height: 10),
                if (_profiles.isEmpty) ...[
                  const _EmptyHint(text: '还没有小人，点下面「＋」新建第一个'),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _createPet,
                    icon: const Icon(Icons.add,
                        size: 18, color: Color(0xFFB0789A)),
                    label: const Text('新建小人',
                        style: TextStyle(
                            color: Color(0xFFB0789A), fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFD8C0CA)),
                      backgroundColor: const Color(0x11F0E4EA),
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ] else
                  // 固定 3:4 竖框：列数随屏幕宽度自适应，宽平板也不变形
                  LayoutBuilder(
                    builder: (ctx, cons) {
                      final cols = (cons.maxWidth / 200).floor().clamp(2, 6);
                      return GridView.count(
                        crossAxisCount: cols,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 3 / 4,
                        children: [
                          for (final pet in _profiles)
                            _PetCard(
                              pet: pet,
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          PetProfilePage(petId: pet.petId)),
                                );
                                _load();
                              },
                              onToggle: (v) => _toggle(pet, v),
                            ),
                          _NewBox(label: '新建小人', onTap: _createPet),
                        ],
                      );
                    },
                  ),
                // ═══ 互动组（多角色剧本）═══
                Row(
                  children: [
                    const Text('互动组',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6A4A5A))),
                    const SizedBox(width: 6),
                    const Icon(Icons.favorite,
                        size: 14, color: Color(0xFFB0789A)),
                    const Spacer(),
                    Text('${_groups.length} 组',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFB0A0A6))),
                  ],
                ),
                const SizedBox(height: 4),
                const Text('几个小人一起演：每个小人一个坑（自己的帧图），一步步排剧本（A走、B跑、A去抱…）',
                    style: TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
                const SizedBox(height: 10),
                if (_groups.isEmpty) ...[
                  const _EmptyHint(
                      text: '还没有互动组，点下面「＋」排第一个（如 A 跑过去抱 B）'),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _editGroup(null),
                    icon: const Icon(Icons.add,
                        size: 18, color: Color(0xFFB0789A)),
                    label: const Text('新建互动组',
                        style: TextStyle(
                            color: Color(0xFFB0789A), fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFD8C0CA)),
                      backgroundColor: const Color(0x11F0E4EA),
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ] else
                  // 互动组框同样固定 3:4，和单角色框整齐
                  LayoutBuilder(
                    builder: (ctx, cons) {
                      final cols = (cons.maxWidth / 200).floor().clamp(2, 6);
                      return GridView.count(
                        crossAxisCount: cols,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 3 / 4,
                        children: [
                          for (final g in _groups)
                            _GroupCard(
                              group: g,
                              bindNames: [
                                for (final s in g.slots)
                                  s.bindPetId != null ? _petName(s.bindPetId!) : s.label,
                              ],
                              onTap: () => _editGroup(g),
                              onDelete: () => _deleteGroup(g),
                            ),
                          _NewBox(label: '新建互动组', onTap: () => _editGroup(null)),
                        ],
                      );
                    },
                  ),
                const SizedBox(height: 20),

                const SizedBox(height: 12),
                const Text('聊天页右页会显示每个小人的缩略图和名字，勾选 = 出现在陪伴页',
                    style:
                        TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  PetProfile? _petById(String id) {
    for (final p in _profiles) {
      if (p.petId == id) return p;
    }
    return null;
  }
}

/// 空态提示
class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

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
        style: const TextStyle(
            fontSize: 12, color: Color(0xFFB0A0A6), height: 1.6),
      ),
    );
  }
}

/// 多角色互动小框：两个头像并排 + 名字
class _GroupCard extends StatelessWidget {
  final PetGroupDef group;
  final List<String> bindNames;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _GroupCard({
    required this.group,
    required this.bindNames,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final names = bindNames.join(' + ');
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE8D8E0)),
          ),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F0F4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.favorite,
                          size: 34,
                          color: group.steps.isEmpty
                              ? const Color(0xFFD8C8CE)
                              : const Color(0xFFB0789A)),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: onDelete,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: const Color(0x33FFFFFF),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.delete_outline,
                              size: 13, color: Color(0xFFD0A0B0)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A5A)),
              ),
              const SizedBox(height: 2),
              Text(
                '${group.slots.length} 个坑 · ${group.steps.length} 步',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Color(0xFFB0A0A6)),
              ),
              const SizedBox(height: 2),
              Text(
                names.isEmpty ? '未绑定小人' : names,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Color(0xFFB0A0A6)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetCard extends StatelessWidget {
  final PetProfile pet;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  const _PetCard({
    required this.pet,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: pet.visible
                    ? const Color(0xFFE8D8E0)
                    : const Color(0xFFF0E8EC)),
          ),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F0F4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: pet.avatarPath != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.file(
                                File(pet.avatarPath!),
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.pets,
                                    size: 40,
                                    color: Color(0xFFD0B8C4)),
                              ),
                            )
                          : const Icon(Icons.pets,
                              size: 40, color: Color(0xFFD0B8C4)),
                    ),
                    // 显示开关
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: () => onToggle(!pet.visible),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: pet.visible
                                ? const Color(0xFFB0789A)
                                : const Color(0xFFD0C0C8),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            pet.visible
                                ? Icons.visibility
                                : Icons.visibility_off,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                pet.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A5A)),
              ),
              const SizedBox(height: 2),
              const Text('点进去配置',
                  style: TextStyle(fontSize: 10, color: Color(0xFFB0A0A6))),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新建框：虚线框 + 加号
class _NewBox extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _NewBox({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: const Color(0xFFDCC8D2),
                width: 1.5,
                style: BorderStyle.solid),
            color: const Color(0x22F0E4EA),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_circle_outline,
                  size: 36, color: Color(0xFFB0789A)),
              const SizedBox(height: 8),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8A5A72))),
            ],
          ),
        ),
      ),
    );
  }
}
