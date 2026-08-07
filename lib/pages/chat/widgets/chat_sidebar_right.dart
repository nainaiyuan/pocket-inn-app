import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';
import '../../../services/setting_version_store.dart';
import '../services/chat_storage_service.dart';
import '../state/current_character_state.dart';
import 'task_list_page.dart';

/// 角色设置侧栏（右页）
class ChatSidebarRight extends StatefulWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final VoidCallback onDelete;
  final VoidCallback? onClearChat;
  final VoidCallback? onClosePanel;
  final CurrentCharacterState? characterState;

  const ChatSidebarRight({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onDelete,
    this.onClearChat,
    this.onClosePanel,
    this.characterState,
  });

  @override
  State<ChatSidebarRight> createState() => _ChatSidebarRightState();
}

/// 角色设定结构化字段
class _RoleFields {
  String world; // 世界观·背景
  String relation; // 与用户的关系
  String traits; // 喜好·性格·习惯
  String connections; // 亲朋好友
  String history; // 经历

  _RoleFields({
    this.world = '',
    this.relation = '',
    this.traits = '',
    this.connections = '',
    this.history = '',
  });

  static _RoleFields fromPrompt(String prompt) {
    if (prompt.isEmpty) return _RoleFields();
    try {
      final m = jsonDecode(prompt) as Map<String, dynamic>;
      return _RoleFields(
        world: m['world'] as String? ?? '',
        relation: m['relation'] as String? ?? '',
        traits: m['traits'] as String? ?? '',
        connections: m['connections'] as String? ?? '',
        history: m['history'] as String? ?? '',
      );
    } catch (_) {
      return _RoleFields(world: prompt);
    }
  }

  String toPrompt() {
    final m = <String, String>{
      'world': world,
      'relation': relation,
      'traits': traits,
      'connections': connections,
      'history': history,
    };
    return jsonEncode(m);
  }
}

class _ChatSidebarRightState extends State<ChatSidebarRight> {
  final _greetingCtrl = TextEditingController();
  final _service = CharacterService();

  // 5个设定控制器
  late List<TextEditingController> _fieldCtrls;
  _RoleFields _fields = _RoleFields();

  // 开关
  bool _butlerIntervention = true;
  bool _shareMemory = true;
  bool _showingPrompt = true;

  @override
  void initState() {
    super.initState();
    _fieldCtrls = List.generate(5, (_) => TextEditingController());
    _syncControllers();
  }

  @override
  void didUpdateWidget(ChatSidebarRight old) {
    super.didUpdateWidget(old);
    if (mounted) {
      _syncControllers();
    }
  }

  void _syncControllers() {
    final p = widget.currentPersona;
    if (p == null) return;
    _greetingCtrl.text = p.greeting;

    _fields = _RoleFields.fromPrompt(p.prompt);
    _fieldCtrls[0].text = _fields.world;
    _fieldCtrls[1].text = _fields.relation;
    _fieldCtrls[2].text = _fields.traits;
    _fieldCtrls[3].text = _fields.connections;
    _fieldCtrls[4].text = _fields.history;
  }

  void _saveAll() {
    final p = widget.currentPersona;
    final l = widget.currentLead;
    if (p == null || l == null) return;

    _fields = _RoleFields(
      world: _fieldCtrls[0].text,
      relation: _fieldCtrls[1].text,
      traits: _fieldCtrls[2].text,
      connections: _fieldCtrls[3].text,
      history: _fieldCtrls[4].text,
    );

    final updated = p.copyWith(
      prompt: _fields.toPrompt(),
      greeting: _greetingCtrl.text,
    );
    _service.updatePersona(l.id, updated);
  }

  @override
  void dispose() {
    for (final c in _fieldCtrls) {
      c.dispose();
    }
    _greetingCtrl.dispose();
    super.dispose();
  }

  // ─── 删除 ───
  Future<void> _confirmDeletePersona() async {
    final l = widget.currentLead;
    final p = widget.currentPersona;
    if (l == null || p == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('删除 "${p.name}"？'),
        content: const Text('此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '确定删除',
              style: TextStyle(
                color: Color(0xFFE55050),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      // 从 service 读最新数据判断（widget 传的可能已过期）
      final currentLead = _service.getMaleLead(l.id);
      final personaCount = currentLead?.personas.length ?? 0;
      final isLastPersona = personaCount <= 1;
      final isLastLead = _service.leads.length <= 1;

      if (isLastPersona && isLastLead) {
        // 最后一个形象弹框确认
        final reallyDelete = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text('删除后没有可以聊天的角色了'),
            content: const Text('删掉这个形象后，系统会自动重建默认角色。确认删除吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  '取消',
                  style: TextStyle(color: Color(0xFF8A7A80)),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  '确认删除',
                  style: TextStyle(
                    color: Color(0xFFE55050),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
        if (reallyDelete != true) return;
      }

      await _service.deletePersona(l.id, p.id);
      final updatedLead = _service.getMaleLead(l.id);
      if (updatedLead == null || updatedLead.personas.isEmpty) {
        // 立绘空了 → 删立绘，万一没角色了就重建
        await _service.deleteMaleLead(l.id);
        if (_service.leads.isEmpty) {
          widget.characterState?.createLeadWithDefaultPersona('沈星回');
          await Future.delayed(const Duration(milliseconds: 100));
        }
      } else {
        // 立绘下还有别的 Persona → 自动选第一个
        final nextP = updatedLead.personas.first;
        widget.characterState?.setCurrent(updatedLead, nextP);
      }
      widget.characterState?.notifyUI();
      widget.onClosePanel?.call();
    }
  }

  // 删除所有聊天记录
  Future<void> _confirmDeleteAllChats() async {
    final pid = widget.currentPersona?.id ?? widget.currentLead?.id ?? '';
    if (pid.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('删除所有聊天记录？'),
        content: const Text('当前角色的聊天记录将被清空，此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF8A7A80))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '确定清空',
              style: TextStyle(
                color: Color(0xFFE55050),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      // 用 ChatStorageService 清空
      await ChatStorageService().deleteAllMessages(pid);
      widget.onClearChat?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('聊天记录已清空'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLead =
        widget.currentPersona == null || widget.currentPersona!.isDefault;

    return Container(
      color: const Color(0xFFF5EEF0),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 56),

            // ─── 顶部功能区（设备 / 管家暗号 / API 切换）───
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  _DeviceZone(),
                  const SizedBox(height: 4),
                  _ButlerCodeZone(),
                  const SizedBox(height: 4),
                  _ApiZone(),
                  const SizedBox(height: 4),
                  _QuoteZone(),
                ],
              ),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  // ─── 角色设定（5个结构化字段） ───
                  _SectionCard(
                    title: isLead ? '角色设定（所有形象的经历同步到本体）' : '角色设定',
                    child: Column(
                      children: [
                        _FieldBox(
                          label: '首次问候',
                          ctrl: _greetingCtrl,
                          onChanged: _saveAll,
                          maxLines: 2,
                        ),
                        const SizedBox(height: 8),

                        // 8-06 18:04 用户：合并分类 → 男主框/用户框 + 版本堆叠管理
                        // （男主自己分类；历史版本可修改/删除/一键选用；按键切换不占手势）
                        _SettingVersionPanel(
                          personaId: widget.currentPersona?.id ?? '',
                          legacyPrompt: widget.currentPersona?.prompt ?? '',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 关键词 / 记忆 ───
                  _SectionCard(
                    title: '关键词与记忆',
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              _TabBtn(
                                label: '系统 Prompt',
                                active: _showingPrompt,
                                onTap: () =>
                                    setState(() => _showingPrompt = true),
                              ),
                              const SizedBox(width: 8),
                              _TabBtn(
                                label: '关键词',
                                active: !_showingPrompt,
                                onTap: () =>
                                    setState(() => _showingPrompt = false),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (_showingPrompt)
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0E8EC),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text(
                                '（系统 Prompt 由管家自动生成，可在上方编辑原始设定）',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF8A7A80),
                                  height: 1.5,
                                ),
                              ),
                            )
                          else
                            Center(
                              child: Text(
                                '尚未收集到关键词',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: const Color(0xFF8A7A80),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 全局开关 ───
                  _SectionCard(
                    title: '全局设置',
                    child: Column(
                      children: [
                        _SwitchTile(
                          label: '管家不干预自然语言',
                          subtitle: '开启后用户输入不经过管家处理',
                          value: !_butlerIntervention,
                          onChanged: (v) =>
                              setState(() => _butlerIntervention = !v),
                        ),
                        const SizedBox(height: 4),
                        _SwitchTile(
                          label: '本体记忆共享',
                          subtitle: '所有形象共用本体记忆',
                          value: _shareMemory,
                          onChanged: (v) => setState(() => _shareMemory = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 计时卡片与任务 ───
                  _SectionCard(
                    title: '计时卡片与任务',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const TaskListPage(),
                          ),
                        ),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.list_alt,
                                size: 18,
                                color: Color(0xFFC896B4),
                              ),
                              SizedBox(width: 8),
                              Text(
                                '📋 任务列表',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF6A4A52),
                                ),
                              ),
                              Spacer(),
                              Icon(
                                Icons.chevron_right,
                                size: 18,
                                color: Color(0xFFB0A0A6),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ─── 危险操作 ───
                  _SectionCard(
                    title: '危险操作',
                    child: Column(
                      children: [
                        // 删除当前形象（无论是默认还是分身，都只删当前 Persona）
                        if (widget.currentPersona != null)
                          SizedBox(
                            width: double.infinity,
                            child: Material(
                              color: Colors.redAccent.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: _confirmDeletePersona,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.delete_outline_rounded,
                                        size: 16,
                                        color: Colors.redAccent.withValues(
                                          alpha: 0.6,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '删除当前形象「${widget.currentPersona!.name}」',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.redAccent.withValues(
                                            alpha: 0.8,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        // 删除所有聊天记录
                        SizedBox(
                          width: double.infinity,
                          child: Material(
                            color: Colors.orange.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: _confirmDeleteAllChats,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.chat_bubble_outline_rounded,
                                      size: 16,
                                      color: Colors.orange.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '删除所有聊天记录',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.orange.withValues(
                                          alpha: 0.8,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 设备连接区（可折叠扩展） ───
class _DeviceZone extends StatefulWidget {
  @override
  State<_DeviceZone> createState() => _DeviceZoneState();
}

class _DeviceZoneState extends State<_DeviceZone> {
  bool _expanded = false;

  // 预设设备列表
  static const _presetDevices = [
    _DeviceItem('蓝牙玩具', Icons.toys_outlined),
    _DeviceItem('空调', Icons.ac_unit_outlined),
    _DeviceItem('风扇', Icons.air_outlined),
    _DeviceItem('小机器人', Icons.smart_toy_outlined),
    _DeviceItem('智能灯', Icons.light_outlined),
  ];

  // 占位连接状态
  final Set<String> _connected = {};

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    _connected.isEmpty
                        ? Icons.bluetooth_disabled
                        : Icons.bluetooth_connected,
                    size: 13,
                    color: _connected.isEmpty
                        ? const Color(0xFF8A7A80).withValues(alpha: 0.5)
                        : const Color(0xFFE8A0B8),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _connected.isEmpty
                        ? '未连接任何设备'
                        : '已连接 ${_connected.length} 个设备',
                    style: TextStyle(
                      fontSize: 11,
                      color: _connected.isEmpty
                          ? const Color(0xFF8A7A80).withValues(alpha: 0.5)
                          : const Color(0xFF6A4A5A),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 14,
                      color: const Color(0xFF8A7A80).withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开列表
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _presetDevices
                    .map((d) => _buildDeviceChip(d))
                    .toList(),
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceChip(_DeviceItem d) {
    final connected = _connected.contains(d.name);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (connected) {
            _connected.remove(d.name);
          } else {
            _connected.add(d.name);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: connected
              ? const Color(0xFFE8A0B8).withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: connected
                ? const Color(0xFFE8A0B8).withValues(alpha: 0.25)
                : const Color(0xFF8A7A80).withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              d.icon,
              size: 12,
              color: connected
                  ? const Color(0xFFC87090)
                  : const Color(0xFF8A7A80).withValues(alpha: 0.4),
            ),
            const SizedBox(width: 4),
            Text(
              d.name,
              style: TextStyle(
                fontSize: 10,
                color: connected
                    ? const Color(0xFF6A4A5A)
                    : const Color(0xFF8A7A80).withValues(alpha: 0.5),
                fontWeight: connected ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceItem {
  final String name;
  final IconData icon;
  const _DeviceItem(this.name, this.icon);
}

// ─── 管家暗号区（可扩展列表） ───
class _ButlerCodeZone extends StatefulWidget {
  @override
  State<_ButlerCodeZone> createState() => _ButlerCodeZoneState();
}

class _ButlerCodeZoneState extends State<_ButlerCodeZone> {
  bool _expanded = false;

  static const _presetCodes = [
    _ButlerCode('#A#', '多轮唤醒', '男主发送后，管家再次唤醒一次，可继续对话'),
    _ButlerCode('#B#', '定时唤醒', '管家在指定时间唤醒男主，推送设备数据'),
    _ButlerCode('#C#', '状态报告', '管家定时推送用户手机使用情况'),
    _ButlerCode('#D#', '情感快照', '管家记录当前用户情绪并推送给男主'),
  ];

  final Set<String> _enabledCodes = {};

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.code_outlined,
                    size: 13,
                    color: _enabledCodes.isEmpty
                        ? const Color(0xFF8A7A80).withValues(alpha: 0.5)
                        : const Color(0xFFE8A0B8),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _enabledCodes.isEmpty
                        ? '管家暗号（未启用）'
                        : '已启用 ${_enabledCodes.length} 个暗号',
                    style: TextStyle(
                      fontSize: 11,
                      color: _enabledCodes.isEmpty
                          ? const Color(0xFF8A7A80).withValues(alpha: 0.5)
                          : const Color(0xFF6A4A5A),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 14,
                      color: const Color(0xFF8A7A80).withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                children: _presetCodes.map((c) => _buildCodeRow(c)).toList(),
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeRow(_ButlerCode c) {
    final enabled = _enabledCodes.contains(c.code);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          setState(() {
            if (enabled) {
              _enabledCodes.remove(c.code);
            } else {
              _enabledCodes.add(c.code);
            }
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: enabled
                ? const Color(0xFFE8A0B8).withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: enabled
                      ? const Color(0xFFE8A0B8).withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: enabled
                        ? const Color(0xFFE8A0B8).withValues(alpha: 0.3)
                        : const Color(0xFF8A7A80).withValues(alpha: 0.1),
                  ),
                ),
                child: Text(
                  c.code,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? const Color(0xFFC87090)
                        : const Color(0xFF8A7A80).withValues(alpha: 0.4),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: enabled
                            ? const Color(0xFF6A4A5A)
                            : const Color(0xFF8A7A80).withValues(alpha: 0.5),
                      ),
                    ),
                    Text(
                      c.desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: const Color(0xFF8A7A80).withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: enabled
                      ? const Color(0xFFE8A0B8)
                      : Colors.white.withValues(alpha: 0.5),
                  border: Border.all(
                    color: enabled
                        ? const Color(0xFFE8A0B8)
                        : const Color(0xFF8A7A80).withValues(alpha: 0.2),
                  ),
                ),
                child: enabled
                    ? Icon(Icons.check_rounded, size: 10, color: Colors.white)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ButlerCode {
  final String code;
  final String label;
  final String desc;
  const _ButlerCode(this.code, this.label, this.desc);
}

// ─── API / AI 切换区 ───
class _ApiZone extends StatefulWidget {
  @override
  State<_ApiZone> createState() => _ApiZoneState();
}

class _ApiZoneState extends State<_ApiZone> {
  bool _expanded = false;
  final _apiKeyCtrl = TextEditingController();
  final _endpointCtrl = TextEditingController();

  // 预设 AI
  static const _presetAIs = ['默认', 'DeepSeek', '本地模型', 'Claude', '自定义'];
  String _selected = '默认';

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _endpointCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.api_outlined,
                    size: 13,
                    color: const Color(0xFF8A7A80).withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'AI 模型：$_selected',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6A4A5A),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 14,
                      color: const Color(0xFF8A7A80).withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // AI 选择行
                  SizedBox(
                    height: 32,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _presetAIs.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (_, i) {
                        final ai = _presetAIs[i];
                        final sel = _selected == ai;
                        return GestureDetector(
                          onTap: () => setState(() => _selected = ai),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: sel
                                  ? const Color(
                                      0xFFE8A0B8,
                                    ).withValues(alpha: 0.12)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: sel
                                    ? const Color(
                                        0xFFE8A0B8,
                                      ).withValues(alpha: 0.25)
                                    : const Color(
                                        0xFF8A7A80,
                                      ).withValues(alpha: 0.08),
                              ),
                            ),
                            child: Center(
                              child: Text(
                                ai,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: sel
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: sel
                                      ? const Color(0xFFC87090)
                                      : const Color(
                                          0xFF8A7A80,
                                        ).withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  // API Key
                  SizedBox(
                    height: 30,
                    child: TextField(
                      controller: _apiKeyCtrl,
                      maxLines: 1,
                      obscureText: true,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6A4A5A),
                      ),
                      decoration: InputDecoration(
                        hintText: 'API Key（可选）',
                        hintStyle: TextStyle(
                          fontSize: 10,
                          color: const Color(0xFF8A7A80).withValues(alpha: 0.3),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: const Color(
                              0xFF8A7A80,
                            ).withValues(alpha: 0.1),
                          ),
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Endpoint
                  SizedBox(
                    height: 30,
                    child: TextField(
                      controller: _endpointCtrl,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6A4A5A),
                      ),
                      decoration: InputDecoration(
                        hintText: '自定义 Endpoint（可选）',
                        hintStyle: TextStyle(
                          fontSize: 10,
                          color: const Color(0xFF8A7A80).withValues(alpha: 0.3),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: const Color(
                              0xFF8A7A80,
                            ).withValues(alpha: 0.1),
                          ),
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

// ─── 角色语录区 ───
class _QuoteZone extends StatefulWidget {
  @override
  State<_QuoteZone> createState() => _QuoteZoneState();
}

class _QuoteZoneState extends State<_QuoteZone> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _ctrl.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.format_quote_outlined,
            size: 13,
            color: hasText
                ? const Color(0xFFE8A0B8)
                : const Color(0xFF8A7A80).withValues(alpha: 0.3),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _ctrl,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF6A4A5A),
                  fontStyle: FontStyle.italic,
                ),
                decoration: InputDecoration(
                  hintText: '角色语录（不写不显示）',
                  hintStyle: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF8A7A80).withValues(alpha: 0.3),
                    fontStyle: FontStyle.italic,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 小组件 ───

/// 📚 设定版本管理面板（8-06 18:04/18:08/18:24 用户）
///
/// 男主设定 + 用户设定两个框；历史版本堆叠（chips + ◀▶ 按键切换，不占手势）；
/// 可修改/删除/一键选用/一键回当前；变更日志只追加不删；
/// 男主可查（query_setting_history）；旧版 prompt 自动迁移进来。
class _SettingVersionPanel extends StatefulWidget {
  final String personaId;
  final String legacyPrompt; // 旧版 5 字段 prompt（迁移用）
  const _SettingVersionPanel({
    required this.personaId,
    required this.legacyPrompt,
  });

  @override
  State<_SettingVersionPanel> createState() => _SettingVersionPanelState();
}

class _SettingVersionPanelState extends State<_SettingVersionPanel> {
  SettingBook? _book;
  String _tab = SettingVersionStore.male; // male / user
  String? _viewId; // = 当前版本 id / 备用版本 id；null = 无当前版本
  bool _draft = false; // 正在写新版本（➕新建 或 📦新建副本，未落地）
  String? _draftFrom; // 副本来源版本 id（提示用）
  late final TextEditingController _ctrl;

  String get _typeName => _tab == SettingVersionStore.user ? '用户设定' : '男主设定';

  // 该类型版本列表（新的在前）
  List<SettingVersion> get _versions =>
      _book?.versions.where((v) => v.type == _tab).toList() ?? [];

  // 当前版本（isCurrent=true）
  SettingVersion? get _currentVersion {
    final vs = _versions;
    for (final v in vs) {
      if (v.isCurrent) return v;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    var book = await SettingVersionStore.load(widget.personaId);
    // 旧版 5 字段 prompt 迁移：男主设定为空且有旧数据 → 拼进男主设定
    final legacy = widget.legacyPrompt.trim();
    if (book.currentMale.trim().isEmpty && legacy.isNotEmpty) {
      String migrated;
      try {
        final m = jsonDecode(legacy) as Map<String, dynamic>;
        final parts = <String>[];
        const labels = {
          'world': '世界观·背景',
          'relation': '与用户的关系',
          'traits': '喜好·性格·习惯',
          'connections': '亲朋好友',
          'history': '经历',
        };
        for (final e in labels.entries) {
          final v = m[e.key]?.toString().trim() ?? '';
          if (v.isNotEmpty) parts.add('${e.value}：$v');
        }
        migrated = parts.join('\n');
      } catch (_) {
        migrated = legacy;
      }
      if (migrated.trim().isNotEmpty) {
        book.setCurrent(SettingVersionStore.male, migrated.trim());
        await SettingVersionStore.addChangelog(
          widget.personaId,
          SettingVersionStore.male,
          '从旧版设定迁移合并（初始导入）',
        );
        book = await SettingVersionStore.load(widget.personaId);
      }
    }
    if (!mounted) return;
    setState(() {
      _book = book;
      _draft = false;
      _draftFrom = null;
      _viewId = _currentVersion?.id;
      _ctrl.text = _currentVersion?.content ?? book.currentOf(_tab);
    });
  }

  void _refresh() async {
    final book = await SettingVersionStore.load(widget.personaId);
    if (!mounted) return;
    setState(() {
      _book = book;
      // 若查看的版本被删了 → 回当前（isCurrent 版本）
      final stillExists =
          _viewId == null || book.versions.any((v) => v.id == _viewId);
      if (!stillExists) _viewId = null;
      final cur = book.versions
          .where((v) => v.type == _tab && v.isCurrent)
          .toList();
      if (_viewId == null && cur.isNotEmpty) _viewId = cur.first.id;
      if (!_draft) {
        final viewing = _viewId == null
            ? null
            : book.versions.where((v) => v.id == _viewId).toList().firstOrNull;
        _ctrl.text = viewing?.content ?? book.currentOf(_tab);
      }
    });
  }

  void _switchTab(String tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _draft = false;
      _draftFrom = null;
      _viewId = _currentVersion?.id;
      _ctrl.text = _currentVersion?.content ?? _book?.currentOf(tab) ?? '';
    });
  }

  // ── ➕ 新建：空白新版本（不基于任何版本，不碰现有版本）──
  void _startNewDraft() {
    setState(() {
      _draft = true;
      _draftFrom = null;
      _ctrl.clear();
    });
  }

  // ── 📦 新建副本：复制某版本内容到编辑框（未落地），原版本不动 ──
  void _startCopyDraft(SettingVersion src) {
    setState(() {
      _draft = true;
      _draftFrom = src.id;
      _ctrl.text = src.content;
    });
  }

  void _cancelDraft() {
    setState(() {
      _draft = false;
      _draftFrom = null;
      _viewId = _currentVersion?.id;
      _ctrl.text = _currentVersion?.content ?? _book?.currentOf(_tab) ?? '';
    });
  }

  // ── 保存新版本（draft / 从当前另存）──
  Future<void> _saveNewVersion() async {
    if (_ctrl.text.trim().isEmpty) return;
    final hasAny = _versions.isNotEmpty;
    final v = hasAny
        ? await SettingVersionStore.saveAsVersion(
            widget.personaId,
            _tab,
            _ctrl.text,
            note: _draftFrom != null ? '复制修改（副本）' : '手动保存为新版本',
          )
        // 一个版本都没有 → 第一个版本自动成为当前（没得选）
        : await SettingVersionStore.saveNewVersion(
            widget.personaId,
            _tab,
            _ctrl.text,
            note: '初始设定',
          );
    await SettingVersionStore.addChangelog(
      widget.personaId,
      _tab,
      '手动更新了$_typeName',
    );
    if (!mounted) return;
    setState(() {
      _draft = false;
      _draftFrom = null;
      _viewId = v.id;
      _ctrl.text = v.content;
    });
    _refresh();
  }

  // ── 💾 覆盖当前版本（确认后）──
  Future<void> _saveCurrent() async {
    await SettingVersionStore.saveCurrent(widget.personaId, _tab, _ctrl.text);
    await SettingVersionStore.addChangelog(
      widget.personaId,
      _tab,
      '覆盖了当前$_typeName',
    );
    _refresh();
  }

  // ── 🔁 覆盖某个版本（确认后）──
  Future<void> _overwriteVersion(SettingVersion v) async {
    await SettingVersionStore.updateVersion(widget.personaId, v.id, _ctrl.text);
    await SettingVersionStore.addChangelog(
      widget.personaId,
      _tab,
      '覆盖了版本 ${_versionLabel(v)}',
    );
    _refresh();
  }

  // ── ✨ 选用某版本为当前 ──
  Future<void> _applyVersion(String id) async {
    await SettingVersionStore.applyVersion(widget.personaId, id);
    await SettingVersionStore.addChangelog(
      widget.personaId,
      _tab,
      '选用 ${_versionLabel(_versions.firstWhere((v) => v.id == id))} 作为当前$_typeName',
    );
    _refresh();
  }

  // ── 🗑 删除版本（当前版本带警告）──
  Future<void> _deleteVersion(SettingVersion v) async {
    final isCur = v.isCurrent;
    final ok = await _confirmDialog(
      '删除此版本？',
      isCur
          ? '⚠️ 这是当前版本！删除后设定不再生效，需要重新选一个版本作为当前。'
          : '「${_versionLabel(v)}」会被删除（变更日志保留）。',
      okLabel: '删除',
    );
    if (!ok) return;
    await SettingVersionStore.deleteVersion(widget.personaId, v.id);
    await SettingVersionStore.addChangelog(
      widget.personaId,
      _tab,
      '删除了版本 ${_versionLabel(v)}',
    );
    _refresh();
  }

  // ── 选一个版本作为当前（无当前版本时）──
  Future<void> _pickCurrentDialog() async {
    final vs = _versions;
    if (vs.isEmpty) {
      await _confirmDialog('还没有任何版本', '先在编辑框写一版，点「📦 存为新版本」（第一个版本会自动成为当前）。');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选一个版本作为当前'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final v in vs)
                ListTile(
                  dense: true,
                  title: Text(
                    '${_versionLabel(v)}${v.isCurrent ? '（当前）' : ''}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    v.content.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => Navigator.pop(ctx, v.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked != null) await _applyVersion(picked);
  }

  Future<bool> _confirmDialog(
    String title,
    String message, {
    String okLabel = '确定',
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Text(message, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    if (book == null) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final versions = _versions;
    final current = _currentVersion;
    final hasCurrent = current != null;
    // 正在查看/编辑的版本：_viewId 指向的（无当前时 _viewId=null）
    final viewing = _viewId == null
        ? null
        : versions.where((v) => v.id == _viewId).toList().firstOrNull;
    final isViewingCurrent = viewing != null && viewing.isCurrent;
    final isViewingBackup = viewing != null && !viewing.isCurrent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tab：男主 / 用户
        Row(
          children: [
            _TabBtn(
              label: '男主设定',
              active: _tab == SettingVersionStore.male,
              onTap: () => _switchTab(SettingVersionStore.male),
            ),
            const SizedBox(width: 8),
            _TabBtn(
              label: '用户设定',
              active: _tab == SettingVersionStore.user,
              onTap: () => _switchTab(SettingVersionStore.user),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // 版本条：◀ 版本 chips ▶（按键切换，不占左右滑手势）
        Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left, size: 18),
              color: const Color(0xFF8A7A80),
              onPressed: () {
                final list = <String?>[
                  current?.id,
                  ...versions.map((v) => v.id),
                ];
                final idx = list.indexOf(_viewId);
                if (idx > 0) {
                  final target = list[idx - 1];
                  setState(() {
                    _draft = false;
                    _draftFrom = null;
                    _viewId = target;
                    _ctrl.text = target == null
                        ? book.currentOf(_tab)
                        : versions.firstWhere((v) => v.id == target).content;
                  });
                }
              },
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: [
                    // 当前版本 chip 在最右（⭐ 标记）
                    if (hasCurrent) ...[
                      _VersionChip(
                        label: '⭐当前',
                        active: isViewingCurrent && !_draft,
                        onTap: () => setState(() {
                          _draft = false;
                          _draftFrom = null;
                          _viewId = current.id;
                          _ctrl.text = current.content;
                        }),
                      ),
                      const SizedBox(width: 6),
                    ],
                    for (final v in versions.reversed) ...[
                      const SizedBox(width: 6),
                      _VersionChip(
                        label: _versionLabel(v),
                        active: _viewId == v.id && !_draft,
                        onTap: () => setState(() {
                          _draft = false;
                          _draftFrom = null;
                          _viewId = v.id;
                          _ctrl.text = v.content;
                        }),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right, size: 18),
              color: const Color(0xFF8A7A80),
              onPressed: () {
                final list = <String?>[
                  current?.id,
                  ...versions.map((v) => v.id),
                ];
                final idx = list.indexOf(_viewId);
                if (idx >= 0 && idx < list.length - 1) {
                  final target = list[idx + 1];
                  setState(() {
                    _draft = false;
                    _draftFrom = null;
                    _viewId = target;
                    _ctrl.text = target == null
                        ? book.currentOf(_tab)
                        : versions.firstWhere((v) => v.id == target).content;
                  });
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        // ⚠️ 无当前版本警示条
        if (!hasCurrent && !_draft)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEDE3),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE8A87A)),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '⚠️ 没有当前版本，设定未生效',
                    style: TextStyle(fontSize: 12, color: Color(0xFFB06030)),
                  ),
                ),
                GestureDetector(
                  onTap: _pickCurrentDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8A87A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '选一个版本作为当前',
                      style: TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 编辑框
        TextField(
          controller: _ctrl,
          maxLines: 8,
          minLines: 4,
          decoration: InputDecoration(
            hintText: _draft
                ? (_draftFrom != null
                      ? '副本修改中（原版本不动），改完点「📦 存为新版本」'
                      : '写全新版本（不基于任何版本），写完点「📦 存为新版本」')
                : isViewingCurrent
                ? '$_typeName（当前生效版本，自由写：身份/性格/关系/习惯…）'
                : isViewingBackup
                ? '查看历史版本：可「🔁 覆盖修改」「📦 新建副本」「🗑 删除」'
                : '$_typeName（还没有当前版本，先写一版或选一个）',
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.6),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 操作行
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // ➕ 新建：常驻（不基于任何版本，不碰现有版本）
            if (!_draft)
              _PanelBtn(
                label: '➕ 新建',
                color: const Color(0xFF7FA88A),
                onTap: _startNewDraft,
              ),
            if (_draft) ...[
              _PanelBtn(
                label: '📦 存为新版本',
                color: const Color(0xFF7FA88A),
                onTap: _saveNewVersion,
              ),
              _PanelBtn(
                label: '↩ 取消',
                color: const Color(0xFFC896B4),
                onTap: _cancelDraft,
              ),
            ] else if (isViewingCurrent) ...[
              _PanelBtn(
                label: '💾 覆盖当前',
                color: const Color(0xFF8A6A96),
                onTap: () async {
                  final ok = await _confirmDialog(
                    '覆盖当前版本？',
                    '「${_versionLabel(viewing)}」的内容会被替换成编辑框里的内容，原内容不可恢复。',
                  );
                  if (ok) _saveCurrent();
                },
              ),
              _PanelBtn(
                label: '📦 存为新版本',
                color: const Color(0xFF7FA88A),
                onTap: _saveNewVersion,
              ),
            ] else if (isViewingBackup) ...[
              _PanelBtn(
                label: '🔁 覆盖此版本',
                color: const Color(0xFF8A6A96),
                onTap: () async {
                  final ok = await _confirmDialog(
                    '覆盖此版本？',
                    '「${_versionLabel(viewing)}」的内容会被替换成编辑框里的内容，原内容不可恢复。',
                  );
                  if (ok) _overwriteVersion(viewing);
                },
              ),
              _PanelBtn(
                label: '📦 新建副本',
                color: const Color(0xFF7FA88A),
                onTap: () => _startCopyDraft(viewing),
              ),
              _PanelBtn(
                label: '🗑 删除此版本',
                color: const Color(0xFFD98A9E),
                onTap: () => _deleteVersion(viewing),
              ),
            ] else ...[
              // 无当前版本（_viewId == null）
              if (versions.isNotEmpty)
                _PanelBtn(
                  label: '选一个版本作为当前',
                  color: const Color(0xFFC896B4),
                  onTap: _pickCurrentDialog,
                ),
              _PanelBtn(
                label: '📦 存为新版本',
                color: const Color(0xFF7FA88A),
                onTap: _saveNewVersion,
              ),
            ],
          ],
        ),
      ],
    );
  }

  String _versionLabel(SettingVersion v) {
    final t = v.createdAt;
    return '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}

class _VersionChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _VersionChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFFC896B4)
              : Colors.white.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? const Color(0xFFC896B4)
                : const Color(0xFFC896B4).withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF6A4A52),
          ),
        ),
      ),
    );
  }
}

class _PanelBtn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _PanelBtn({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF5A4A52),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _FieldBox extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final VoidCallback onChanged;
  final int maxLines;

  const _FieldBox({
    required this.label,
    required this.ctrl,
    required this.onChanged,
    this.maxLines = 3,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF5A4A52),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            maxLines: maxLines,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(fontSize: 13, color: Color(0xFF3D2C33)),
            onChanged: (_) => onChanged(),
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchTile({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF3D2C33),
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: const Color(
                              0xFF8A7A80,
                            ).withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 40,
                height: 22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: value
                      ? const Color(0xFFE8A0B8).withValues(alpha: 0.5)
                      : const Color(0xFF5A4A52).withValues(alpha: 0.12),
                ),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 200),
                      left: value ? 20 : 2,
                      top: 2,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? const Color(0xFFE8A0B8).withValues(alpha: 0.2)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              color: active ? const Color(0xFFB48296) : const Color(0xFF8A7A80),
            ),
          ),
        ),
      ),
    );
  }
}
