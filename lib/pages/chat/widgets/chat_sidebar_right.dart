import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../ai_provider/ai_provider_manager.dart';
import '../../../butler/system_template.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';
import '../../../services/setting_version_store.dart';
import '../../../services/tool_approval_store.dart';
import '../../system_view_page.dart';
import '../services/chat_storage_service.dart';
import '../state/current_character_state.dart';
import 'ai_provider_sheet.dart';
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

class _ChatSidebarRightState extends State<ChatSidebarRight> {
  final _service = CharacterService();

  // 开关
  bool _shareMemory = true;
  bool _showingPrompt = true;

  @override
  void initState() {
    super.initState();
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
    // 8-13 02:2x 本体记忆共享开关：从 SharedPreferences 读真实值（默认开）
    final pid = p.id;
    if (pid.isEmpty) return;
    SharedPreferences.getInstance().then((prefs) {
      final v = prefs.getBool('memory_share_$pid') ?? true;
      if (mounted && v != _shareMemory) {
        setState(() => _shareMemory = v);
      }
    });
  }

  @override
  void dispose() {
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

            // ─── 顶部功能区（设备 / AI 工具 / AI 切换）───
            // 8-13 02:0x 用户反馈：不跟随滑动 → 移进下方 ListView 一起滚
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _DeviceZone(),
                  const SizedBox(height: 4),
                  _ToolZone(
                    personaId: widget.currentPersona?.id ?? '',
                    personaName: widget.currentPersona?.name ?? '默认',
                  ),
                  const SizedBox(height: 4),
                  _ApiZone(
                    personaId: widget.currentPersona?.id ?? '',
                    personaName: widget.currentPersona?.name ?? '默认',
                  ),
                  const SizedBox(height: 8),

                  // ─── 角色设定（5个结构化字段） ───
                  _SectionCard(
                    title: isLead ? '角色设定（所有形象的经历同步到本体）' : '角色设定',
                    child: Column(
                      children: [
                        // 8-13 02:0x 用户：删首次问候框（greeting 字段保留存档不再可编辑）
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '系统 Prompt 由管家自动生成（固定模板 + 男主/用户设定 + 实时注入）。'
                                    '固定模板是代码里的默认规则（输出格式、工具用法等），'
                                    '点下方按钮可以看最近一次实际发给男主的完整内容，'
                                    '也可以编辑固定模板或一键恢复默认。',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF8A7A80),
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  // 8-08 22:5x（用户：代码给的设定在框里看不见）：
                                  // 占位文本 → 真入口（查看完整 system + 编辑/恢复固定模板）
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      foregroundColor: const Color(0xFF6A4A5A),
                                      minimumSize: const Size(0, 32),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                    ),
                                    onPressed: () async {
                                      // 侧栏可能没聊过天 → preview 兜底（页面内处理）
                                      await SystemTemplate.loadCoreOverride();
                                      if (!context.mounted) return;
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const SystemViewPage(),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.article_outlined,
                                        size: 16),
                                    label: const Text('查看 / 编辑系统提示',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                ],
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
                        // 8-13 02:0x 用户：删"管家不干预自然语言"；
                        // "本体记忆共享"文案动态显示左页立绘名（Lead）
                        _SwitchTile(
                          label: '本体记忆共享',
                          subtitle: '此角色可查看「${widget.currentLead?.name ?? '本体'}」'
                              '下所有角色的记忆、设定等全部内容（男主读记忆/查设定历史时聚合）',
                          value: _shareMemory,
                          onChanged: (v) {
                            setState(() => _shareMemory = v);
                            final pid = widget.currentPersona?.id ?? '';
                            if (pid.isNotEmpty) {
                              SharedPreferences.getInstance().then((prefs) {
                                prefs.setBool('memory_share_$pid', v);
                              });
                            }
                          },
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
                        ? '连接设备（开发中）'
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

// ─── AI 工具区（免审批开关，per persona） ───
class _ToolZone extends StatefulWidget {
  final String personaId;
  final String personaName;
  const _ToolZone({required this.personaId, required this.personaName});

  @override
  State<_ToolZone> createState() => _ToolZoneState();
}

class _ToolZoneState extends State<_ToolZone> {
  bool _expanded = false;
  final _searchCtrl = TextEditingController();
  final Map<String, bool> _exempt = {}; // 工具名 → 是否免审批

  static const _toolGroups = <String, List<String>>{
    '📝 记忆': [
      'record_memory', 'record_relation', 'recall_memory',
      'save_identity_memory', 'save_summary',
    ],
    '📔 日记与记录': [
      'write_diary', 'query_diary', 'add_record', 'query_record',
      'manage_record_tree',
    ],
    '🧠 临时与记忆块': [
      'manage_pad', 'manage_memory_block', 'manage_tool_cache',
    ],
    '🔍 查询与手册': [
      'list_tools', 'query_tool_formats', 'query_logs',
      'query_setting_history', 'manage_tool_manual',
    ],
    '📋 任务与计划': [
      'manage_task', 'manage_schedule', 'manage_chat_flow',
      'manage_flow', 'resolve_pending',
    ],
    '💬 对话与通知': [
      'notify_user', 'request_permission', 'continue_speaking',
      'request_text_block', 'countdown_card',
    ],
    '⚙️ 工具管理': [
      'manage_frequent_tools', 'manage_tool_test', 'report_bug',
      'update_setting',
    ],
  };

  /// 默认免审批的必要工具（低风险：查询/内部管理/男主自管类）。
  /// 用户可手动关掉任意一个。
  static const _defaultExempt = <String>{
    'list_tools', 'query_tool_formats', 'query_logs', 'query_record',
    'query_setting_history', 'manage_tool_cache', 'manage_pad',
    'manage_memory_block', 'manage_record_tree', 'manage_frequent_tools',
    'resolve_pending', 'save_summary',
  };

  /// 工具中文名（UI 展示用）
  static const _toolNames = <String, String>{
    'record_memory': '记录记忆',
    'record_relation': '记录关系',
    'recall_memory': '回忆记忆',
    'save_identity_memory': '保存身份记忆',
    'save_summary': '保存摘要',
    'write_diary': '写日记',
    'query_diary': '查日记',
    'add_record': '添加记录',
    'query_record': '查记录',
    'manage_record_tree': '管理记录分类',
    'manage_pad': '临时记忆',
    'manage_memory_block': '管理记忆块',
    'manage_tool_cache': '工具缓存',
    'list_tools': '查看工具',
    'query_tool_formats': '查工具格式',
    'query_logs': '查日志',
    'query_setting_history': '查设定历史',
    'manage_tool_manual': '工具手册',
    'manage_task': '任务管理',
    'manage_schedule': '日程管理',
    'manage_chat_flow': '对话流程',
    'manage_flow': '长任务流程',
    'resolve_pending': '处理待办',
    'notify_user': '弹消息提醒',
    'request_permission': '申请免审批',
    'continue_speaking': '继续说话',
    'request_text_block': '文本块输出',
    'countdown_card': '倒计时卡片',
    'manage_frequent_tools': '常用工具',
    'manage_tool_test': '工具测试',
    'report_bug': '报告问题',
    'update_setting': '更新设定',
  };

  /// 工具一句话说明（UI 展示用）
  static const _toolDescs = <String, String>{
    'record_memory': '永久记住她的事（默认要审批）',
    'record_relation': '记录她与别人的关系',
    'recall_memory': '回忆之前记过的事',
    'save_identity_memory': '保存自己的身份记忆',
    'save_summary': '流程结束存摘要',
    'write_diary': '写日记',
    'query_diary': '翻日记',
    'add_record': '往记录里加条目',
    'query_record': '查记录',
    'manage_record_tree': '整理记录分类',
    'manage_pad': '干活中间数据，写完就删',
    'manage_memory_block': '长期/短期记忆块浓缩',
    'manage_tool_cache': '查工具结果缓存',
    'list_tools': '查看有哪些工具/参数',
    'query_tool_formats': '查平台调用格式',
    'query_logs': '看运行日志',
    'query_setting_history': '查设定各版本变更',
    'manage_tool_manual': '记工具用法笔记',
    'manage_task': '待办任务',
    'manage_schedule': '定时日程',
    'manage_chat_flow': '对话流程管理',
    'manage_flow': '旧长任务（已停用）',
    'resolve_pending': '处理遗留待办',
    'notify_user': '弹窗提醒她（默认要审批）',
    'request_permission': '申请某工具免审批',
    'continue_speaking': '主动继续把话说完',
    'request_text_block': '长文本块输出',
    'countdown_card': '倒计时卡片',
    'manage_frequent_tools': '常用工具排序',
    'manage_tool_test': '工具自测',
    'report_bug': '提交问题报告',
    'update_setting': '更新男主设定（默认要审批）',
  };

  List<String> get _allTools => [
        for (final tools in _toolGroups.values) ...tools,
      ];

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final pid = widget.personaId;
    if (pid.isEmpty) return;
    // 首次使用：默认必要工具自动免审批（用户可关）
    final prefs = await SharedPreferences.getInstance();
    final initedKey = 'tool_exempt_inited_$pid';
    final inited = prefs.getBool(initedKey) ?? false;
    if (!inited) {
      for (final t in _defaultExempt) {
        await ToolApprovalStore.setExempt(pid, t, true);
      }
      await prefs.setBool(initedKey, true);
    }
    final map = <String, bool>{};
    for (final t in _allTools) {
      map[t] = await ToolApprovalStore.isExempt(pid, t);
    }
    if (mounted) {
      setState(() {
        _exempt
          ..clear()
          ..addAll(map);
      });
    }
  }

  int get _exemptCount =>
      _exempt.values.where((v) => v).length;

  Future<void> _toggle(String tool, bool value) async {
    setState(() => _exempt[tool] = value);
    await ToolApprovalStore.setExempt(widget.personaId, tool, value);
  }

  @override
  Widget build(BuildContext context) {
    final count = _exemptCount;
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
                    Icons.handyman_outlined,
                    size: 13,
                    color: count > 0
                        ? const Color(0xFFE8A0B8)
                        : const Color(0xFF8A7A80).withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      widget.personaId.isEmpty
                          ? 'AI 工具'
                          : 'AI 工具（$count 个免审批）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: count > 0
                            ? const Color(0xFF6A4A5A)
                            : const Color(0xFF8A7A80).withValues(alpha: 0.5),
                        fontWeight: FontWeight.w500,
                      ),
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
                  Text(
                    '开 = 免审批（男主直接调用）；关 = 每次弹窗要你确认。'
                    '默认已给必要工具开了免审批，可手动关。',
                    style: TextStyle(
                      fontSize: 9,
                      height: 1.4,
                      color: const Color(0xFF8A7A80).withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 搜索框
                  SizedBox(
                    height: 28,
                    child: TextField(
                      controller: _searchCtrl,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF6A4A5A)),
                      decoration: InputDecoration(
                        hintText: '搜索工具…',
                        hintStyle: TextStyle(
                          fontSize: 10,
                          color: const Color(0xFF8A7A80)
                              .withValues(alpha: 0.3),
                        ),
                        prefixIcon: const Icon(Icons.search_rounded,
                            size: 14, color: Color(0xFF8A7A80)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: const Color(0xFF8A7A80)
                                .withValues(alpha: 0.1),
                          ),
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: Scrollbar(
                      child: ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final entry in _toolGroups.entries)
                            ..._buildGroup(entry.key, entry.value),
                        ],
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

  List<Widget> _buildGroup(String title, List<String> tools) {
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? tools
        : tools
            .where((t) =>
                t.contains(q) ||
                (_toolNames[t] ?? '').contains(q))
            .toList();
    if (filtered.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: const Color(0xFFB48296),
            letterSpacing: 0.5,
          ),
        ),
      ),
      for (final t in filtered) _buildToolRow(t),
    ];
  }

  Widget _buildToolRow(String tool) {
    final on = _exempt[tool] ?? false;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _toggle(tool, !on),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: on
              ? const Color(0xFFE8A0B8).withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on
                    ? const Color(0xFFE8A0B8)
                    : const Color(0xFF8A7A80).withValues(alpha: 0.2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _toolNames[tool] ?? tool,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: on
                          ? const Color(0xFF6A4A5A)
                          : const Color(0xFF8A7A80).withValues(alpha: 0.7),
                    ),
                  ),
                  Text(
                    _toolDescs[tool] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: const Color(0xFF8A7A80)
                          .withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // 小号开关
            Transform.scale(
              scale: 0.72,
              child: Switch(
                value: on,
                activeTrackColor: const Color(0xFFE8A0B8),
                activeThumbColor: Colors.white,
                inactiveTrackColor: const Color(0xFF8A7A80)
                    .withValues(alpha: 0.15),
                onChanged: (v) => _toggle(tool, v),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── AI 模型区（per persona 绑定，真实配置） ───
class _ApiZone extends StatefulWidget {
  final String personaId;
  final String personaName;
  const _ApiZone({required this.personaId, required this.personaName});

  @override
  State<_ApiZone> createState() => _ApiZoneState();
}

class _ApiZoneState extends State<_ApiZone> {
  bool _expanded = false;
  final _manager = AIProviderManager.instance;

  String? get _currentId => widget.personaId.isEmpty
      ? null
      : _manager.lastProviderFor(widget.personaId);

  String _providerName(String? id) {
    if (id == null || id.isEmpty) return '未设置';
    for (final p in _manager.providers) {
      if (p.id == id) return p.name;
    }
    return id;
  }

  List<String> get _bound => widget.personaId.isEmpty
      ? const []
      : (_manager.bindingFor(widget.personaId) ?? const []);

  Future<void> _openConfig() async {
    await showAiProviderSheet(
      context: context,
      personaId: widget.personaId,
      personaName: widget.personaName,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _manager.changeNotifier,
      builder: (context, _, _) {
        final curId = _currentId;
        final auto = _manager.autoSwitchFor(widget.personaId);
        final bound = _bound;
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
                        Icons.auto_awesome_outlined,
                        size: 13,
                        color: curId != null
                            ? const Color(0xFFE8A0B8)
                            : const Color(0xFF8A7A80).withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'AI：${_providerName(curId)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: curId != null
                                ? const Color(0xFF6A4A5A)
                                : const Color(0xFF8A7A80)
                                    .withValues(alpha: 0.5),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: auto
                              ? const Color(0xFFE8A0B8).withValues(alpha: 0.12)
                              : const Color(0xFF8A7A80)
                                  .withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          auto ? '自动切换' : '不自动切换',
                          style: TextStyle(
                            fontSize: 9,
                            color: auto
                                ? const Color(0xFFC87090)
                                : const Color(0xFF8A7A80)
                                    .withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                      const Spacer(),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 14,
                          color: const Color(0xFF8A7A80)
                              .withValues(alpha: 0.5),
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
                      // 当前 AI 说明
                      Text(
                        widget.personaId.isEmpty
                            ? '还没有选角色，先从左页选一个角色再配置'
                            : '这个角色（${widget.personaName}）优先用「${_providerName(curId)}」，'
                                '${auto ? "它不可用时自动切换其他 AI" : "不可用时直接报错，不偷偷换"}。',
                        style: TextStyle(
                          fontSize: 9,
                          height: 1.4,
                          color: const Color(0xFF8A7A80).withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 已绑定列表
                      if (bound.isNotEmpty) ...[
                        Text(
                          '已绑定：${bound.map(_providerName).join(' → ')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            height: 1.4,
                            color: const Color(0xFFB48296),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      // 自动切换开关
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _manager.setAutoSwitch(
                            widget.personaId, !auto),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            children: [
                              Icon(
                                Icons.swap_horiz_rounded,
                                size: 12,
                                color: auto
                                    ? const Color(0xFFE8A0B8)
                                    : const Color(0xFF8A7A80)
                                        .withValues(alpha: 0.4),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'AI 不可用时自动切换',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: const Color(0xFF6A4A5A),
                                  ),
                                ),
                              ),
                              Transform.scale(
                                scale: 0.72,
                                child: Switch(
                                  value: auto,
                                  activeTrackColor: const Color(0xFFE8A0B8),
                                  activeThumbColor: Colors.white,
                                  inactiveTrackColor: const Color(0xFF8A7A80)
                                      .withValues(alpha: 0.15),
                                  onChanged: (v) => _manager.setAutoSwitch(
                                      widget.personaId, v),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // 打开完整配置
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFC87090),
                            side: const BorderSide(
                                color: Color(0xFFE8A0B8), width: 0.8),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            minimumSize: const Size(0, 28),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          icon: const Icon(Icons.tune_rounded, size: 12),
                          label: const Text(
                            '打开完整 AI 配置（API Key / 模型 / 顺序）',
                            style: TextStyle(fontSize: 10),
                          ),
                          onPressed: _openConfig,
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
      },
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
