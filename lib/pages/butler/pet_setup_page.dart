import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../butler/pet/pet_models.dart';
import '../../butler/pet/pet_store.dart';
import '../../services/pet_settings_notifier.dart';
import '../../utils/debug_logger.dart';
import 'pet_duo_page.dart';
import 'pet_profile_page.dart';

/// 桌宠设置中心 —— 管家页面入口
///
/// 角色大类网格：每个角色一格（缩略图+名字），点进去是那个角色的配置页；
/// 底部「角色互动」配置双人互动；新建角色在这里。
class PetSetupPage extends StatefulWidget {
  const PetSetupPage({super.key});

  @override
  State<PetSetupPage> createState() => _PetSetupPageState();
}

class _PetSetupPageState extends State<PetSetupPage> {
  final _store = PetStore();
  List<PetProfile> _profiles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _store.allProfiles();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
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
                          '在这里配置你的小人：\n上传图片做成动作 → 组合成表演 → 聊天页显示',
                          style: TextStyle(
                              fontSize: 12.5, color: Color(0xFF8A5A72)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // 角色互动入口
                _DuoEntryCard(onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PetDuoPage()),
                  );
                  _load();
                }),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('我的小人',
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
                const SizedBox(height: 10),
                // 角色大类网格
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.82,
                  children: [
                    for (final pet in _profiles) _PetCard(
                      pet: pet,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => PetProfilePage(petId: pet.petId)),
                        );
                        _load();
                      },
                      onToggle: (v) => _toggle(pet, v),
                    ),
                    // 新建角色卡
                    _NewPetCard(onTap: _createPet),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('聊天页右页会显示每个小人的缩略图和名字，勾选 = 出现在陪伴页',
                    style:
                        TextStyle(fontSize: 11, color: Color(0xFFB0A0A6))),
              ],
            ),
    );
  }
}

/// 角色互动入口卡
class _DuoEntryCard extends StatelessWidget {
  final VoidCallback onTap;

  const _DuoEntryCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE8D8E0)),
          ),
          child: const Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: Color(0xFFF0E4EA),
                child: Icon(Icons.favorite, color: Color(0xFFB0789A)),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('角色互动',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6A4A5A))),
                    SizedBox(height: 2),
                    Text('选两个小人，配一段双人互动（如贴贴、一起跳）',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFFB0A0A6))),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFFD0B8C4)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 角色大类卡：头像 + 名字 + 显示开关
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

/// 新建角色卡：虚线框 + 加号
class _NewPetCard extends StatelessWidget {
  final VoidCallback onTap;

  const _NewPetCard({required this.onTap});

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
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_circle_outline,
                  size: 36, color: Color(0xFFB0789A)),
              SizedBox(height: 8),
              Text('新建小人',
                  style: TextStyle(
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
