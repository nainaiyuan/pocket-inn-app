import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';
import '../../../services/local_storage_service.dart';
import '../../../utils/debug_logger.dart';
import '../state/current_character_state.dart';

/// 左滑侧边栏 —— 选择男主/形象
class ChatSidebarLeft extends StatefulWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final ValueChanged<MapEntry<MaleLead, Persona>> onSelectPersona;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onSetBg;
  final CurrentCharacterState? characterState;

  const ChatSidebarLeft({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onSelectPersona,
    this.onOpenSettings,
    this.onSetBg,
    this.characterState,
  });

  @override
  State<ChatSidebarLeft> createState() => _ChatSidebarLeftState();
}

class _ChatSidebarLeftState extends State<ChatSidebarLeft> {
  final _service = CharacterService();
  String? _expandedLeadId;

  @override
  void initState() {
    super.initState();
    _service.load();
    if (widget.currentLead != null) {
      _expandedLeadId = widget.currentLead!.id;
    }
  }

  void _toggleExpand(String id) {
    setState(() {
      _expandedLeadId = _expandedLeadId == id ? null : id;
    });
  }

  // 选中男主本体
  Future<void> _addNewLead() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('新建角色'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入名字',
            border: InputBorder.none,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _service.addMaleLead(MaleLead(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
      ));
      if (mounted) setState(() {});
    }
  }

  // 默认 persona（当用户点击男主本体时使用）
  Persona _defaultPersona(MaleLead lead) {
    return Persona(
      id: '${lead.id}_default',
      maleLeadId: lead.id,
      name: '默认',
    );
  }

  // 选中男主本体（用第一个 persona 或默认）
  void _selectLead(MaleLead lead) {
    final p = lead.personas.isNotEmpty ? lead.personas.first : _defaultPersona(lead);
    if (widget.characterState != null) {
      widget.characterState!.setCurrent(lead, p);
    } else {
      widget.onSelectPersona(MapEntry(lead, p));
    }
  }

  // 上传立绘（更新男主 avatarPath — 不经过 state，因为 lead 不是 state 管的）
  Future<void> _pickAvatar(MaleLead lead) async {
    await DebugLogger.log('LEFT', '_pickAvatar start');
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.single.path == null) return;
    final file = result.files.single;
    await DebugLogger.log('LEFT', '_pickAvatar picked file=${file.path}');
    final store = LocalStorageService();
    String savedPath;
    if (file.bytes != null) {
      savedPath = await store.saveLeadAvatarFromBytes(lead.id, file.bytes!);
    } else {
      savedPath = await store.saveLeadAvatar(lead.id, File(file.path!));
    }
    await DebugLogger.log('LEFT', '_pickAvatar saved=$savedPath');
    lead.avatarPath = savedPath;
    await _service.updateMaleLead(lead);
    await DebugLogger.log('LEFT', '_pickAvatar updated service');
    // 等文件写完之后再触发 UI 刷新，避免 Image.file 竞争
    await Future.delayed(const Duration(milliseconds: 50));
    if (mounted) setState(() {});
    await DebugLogger.log('LEFT', '_pickAvatar done');
  }

  Future<void> _pickPersonaAvatar(MaleLead lead, Persona persona) async {
    await DebugLogger.log('LEFT', '_pickPersonaAvatar start');
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.single.path == null) return;
    final file = result.files.single;
    await DebugLogger.log('LEFT', '_pickPersonaAvatar picked');
    final store = widget.characterState?.localStorageService ?? LocalStorageService();
    String savedPath;
    if (file.bytes != null) {
      savedPath = await store.savePersonaAvatarFromBytes(lead.id, persona.id, file.bytes!);
    } else {
      savedPath = await store.savePersonaAvatar(lead.id, persona.id, File(file.path!));
    }
    await DebugLogger.log('LEFT', '_pickPersonaAvatar saved=$savedPath');
    if (widget.characterState != null) {
      await widget.characterState!.updateAvatar(savedPath);
    } else {
      persona.avatarPath = savedPath;
      await _service.updatePersona(lead.id, persona);
      await Future.delayed(const Duration(milliseconds: 50));
      if (mounted) setState(() {});
    }
    await DebugLogger.log('LEFT', '_pickPersonaAvatar done');
  }

  @override
  Widget build(BuildContext context) {
    final leads = _service.leads;
    return Container(
      color: const Color(0xFFF5EEF0),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 56),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    '角色',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF3D2C33),
                      letterSpacing: 2,
                    ),
                  ),
                  const Spacer(),
                  // + 新建角色按钮
                  Material(
                    color: Colors.white.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _addNewLead,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_rounded, size: 18, color: const Color(0xFFB48296)),
                            const SizedBox(width: 4),
                            Text('新建', style: TextStyle(fontSize: 14, color: const Color(0xFFB48296))),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: leads.isEmpty
                  ? Center(
                      child: Text(
                        '还没有角色，点 + 新建',
                        style: TextStyle(color: const Color(0xFF8A7A80), fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: leads.length,
                      itemBuilder: (context, index) {
                        final lead = leads[index];
                        final isExpanded = _expandedLeadId == lead.id;
                        final isActive = widget.currentLead?.id == lead.id;
                        return _buildLeadCard(lead, isExpanded, isActive);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeadCard(MaleLead lead, bool isExpanded, bool isActive) {
    return GestureDetector(
      onLongPress: () => _showLeadMenu(lead),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: isActive ? 0.85 : 0.65),
          borderRadius: BorderRadius.circular(18),
          border: isActive
              ? Border.all(color: const Color(0xFFE8A0B8).withValues(alpha: 0.4))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 卡片主体
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // 头像
                  GestureDetector(
                    onTap: () => _selectLead(lead),
                    onLongPress: () => _showLeadMenu(lead),
                    child: Container(
                      width: 56,
                      height: 72,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFFE8A0B8).withValues(alpha: 0.3),
                            const Color(0xFFC8A8D8).withValues(alpha: 0.3),
                          ],
                        ),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: lead.avatarPath.isNotEmpty && File(lead.avatarPath).existsSync()
                            ? Image.file(
                                File(lead.avatarPath),
                                fit: BoxFit.cover,
                                width: 56,
                                height: 72,
                              )
                            : Center(
                                child: Icon(
                                  Icons.person_outline_rounded,
                                  size: 28,
                                  color: const Color(0xFF8A6A78),
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 名字
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _selectLead(lead),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(lead.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF3D2C33))),
                          const SizedBox(height: 2),
                          Text(
                            isActive && widget.currentPersona != null
                                ? '当前形象：${widget.currentPersona!.name}'
                                : '点击开始聊天',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: isActive ? const Color(0xFFB48296) : const Color(0xFF8A7A80)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // 展开箭头
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _toggleExpand(lead.id),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          color: const Color(0xFF8A7A80),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 展开列表
            if (isExpanded) ...[
              const Divider(height: 1, indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  children: [
                    ...lead.personas.map((persona) => _buildPersonaTile(lead, persona)),
                    _buildAddPersonaTile(lead),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 长按弹出菜单
  void _showLeadMenu(MaleLead lead) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: const Color(0xFFF5EEF0),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCCBCC4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                lead.name,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF3D2C33)),
              ),
              const SizedBox(height: 16),
              _MenuBtn(icon: Icons.image_outlined, label: '更换立绘', onTap: () { Navigator.pop(ctx); _pickAvatar(lead); }),
              _MenuBtn(icon: Icons.wallpaper_outlined, label: '设置聊天背景', onTap: () { Navigator.pop(ctx); widget.onSetBg?.call(); }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showPersonaMenu(MaleLead lead, Persona persona) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: const Color(0xFFF5EEF0),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCCBCC4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                persona.name,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF3D2C33)),
              ),
              const SizedBox(height: 16),
              _MenuBtn(icon: Icons.image_outlined, label: '更换头像', onTap: () { Navigator.pop(ctx); _pickPersonaAvatar(lead, persona); }),
              // 删除在右页危险操作区处理
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPersonaTile(MaleLead lead, Persona persona) {
    final isActive = widget.currentLead?.id == lead.id && widget.currentPersona?.id == persona.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onLongPress: () => _showPersonaMenu(lead, persona),
        child: Material(
          color: isActive ? const Color(0xFFE8A0B8).withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => widget.onSelectPersona(MapEntry(lead, persona)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  // 形象头像
                  GestureDetector(
                    onTap: () => _pickPersonaAvatar(lead, persona),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive
                            ? const Color(0xFFE8A0B8).withValues(alpha: 0.35)
                            : Colors.white.withValues(alpha: 0.5),
                        border: Border.all(
                          color: isActive
                              ? const Color(0xFFE8A0B8).withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.4),
                          width: 1.5,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: persona.avatarPath.isNotEmpty && File(persona.avatarPath).existsSync()
                            ? Image.file(
                                File(persona.avatarPath),
                                fit: BoxFit.cover,
                                width: 32,
                                height: 32,
                              )
                            : Icon(
                                Icons.face_6_outlined,
                                size: 16,
                                color: isActive ? const Color(0xFFB48296) : const Color(0xFF8A6A78),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      persona.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                        color: isActive ? const Color(0xFF3D2C33) : const Color(0xFF5A4A52),
                      ),
                    ),
                  ),
                  if (isActive) ...[
                    const SizedBox(width: 4),
                    Container(width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFE8A0B8))),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddPersonaTile(MaleLead lead) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: Colors.white.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final ctrl = TextEditingController();
            final name = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                title: const Text('新建形象'),
                content: TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '如：校园版', border: InputBorder.none),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                  TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('创建')),
                ],
              ),
            );
            if (name != null && name.isNotEmpty) {
              await _service.addPersona(lead.id, Persona(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                maleLeadId: lead.id,
                name: name,
              ));
              if (mounted) setState(() {});
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE8A0B8).withValues(alpha: 0.15),
                    border: Border.all(color: const Color(0xFFE8A0B8).withValues(alpha: 0.3)),
                  ),
                  child: Icon(Icons.add_rounded, size: 18, color: const Color(0xFFB48296)),
                ),
                const SizedBox(width: 10),
                Text('新建身份', style: TextStyle(fontSize: 14, color: const Color(0xFFB48296))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部菜单按钮
class _MenuBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? labelColor;
  final VoidCallback onTap;

  const _MenuBtn({
    required this.icon,
    required this.label,
    this.labelColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: labelColor ?? const Color(0xFF6A4A5A)),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    color: labelColor ?? const Color(0xFF3D2C33),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
