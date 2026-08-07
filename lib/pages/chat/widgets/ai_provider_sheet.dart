import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../ai_provider/ai_provider_manager.dart';

import '../../../ai_provider/failover_router.dart';
import '../../../ai_provider/models.dart';
import '../../../utils/debug_logger.dart';
import '../../../widgets/capability_lights.dart';
import '../../ai_config_page.dart';

/// 聊天页的 AI 设置弹层：
/// - 顶部大卡片：当前用的 AI（明显展示）
/// - 自动切换开关（关 = 不可用时弹窗，不偷偷换人）
/// - 候选 Provider 勾选列表（按尝试顺序，勾选的优先试）
/// - 入口：去管家页配置 API / 单家测试
Future<void> showAiProviderSheet({
  required BuildContext context,
  required String personaId,
  required String personaName,
  /// 8-04 21:1x 用户：一键验收 → 自动切换各模拟 AI 跑真实对话。
  /// 点「🚀 一键验收」→ 关弹层 → 回调聊天页跑验收流程（对话显示在聊天框）。
  Future<void> Function()? onAcceptance,
  /// 8-07 14:03 用户：一键测设定 → 真实 AI 通道自动发测试指令，
  /// 测设定段落化（update_setting tag 定位 + 多轮审批弹窗）。
  Future<void> Function()? onTestSetting,
  Future<void> Function()? onTestAllTools,
  /// 8-05 21:36 用户：假窗口满·手动触发总结（验证后拆）。
  /// 点「🧪 假窗口满」→ 关弹层 → 回调聊天页直接跑一遍总结流程。
  Future<void> Function()? onForceSummarize,
}) {
  final manager = AIProviderManager.instance;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final colorScheme = Theme.of(sheetContext).colorScheme;
      final screenHeight = MediaQuery.of(sheetContext).size.height;
      return SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: manager.changeNotifier,
          builder: (context, _, _) {
            return _AiProviderSheetBody(
              personaId: personaId,
              personaName: personaName,
              colorScheme: colorScheme,
              maxHeight: screenHeight * 0.72,
              onAcceptance: onAcceptance,
              onTestSetting: onTestSetting,
              onTestAllTools: onTestAllTools,
              onForceSummarize: onForceSummarize,
            );
          },
        ),
      );
    },
  );
}

class _AiProviderSheetBody extends StatefulWidget {
  const _AiProviderSheetBody({
    required this.personaId,
    required this.personaName,
    required this.colorScheme,
    required this.maxHeight,
    this.onAcceptance,
    this.onTestSetting,
    this.onTestAllTools,
    this.onForceSummarize,
  });

  final String personaId;
  final String personaName;
  final ColorScheme colorScheme;
  final double maxHeight;
  final Future<void> Function()? onAcceptance;
  final Future<void> Function()? onTestSetting;
  final Future<void> Function()? onTestAllTools;
  final Future<void> Function()? onForceSummarize;

  @override
  State<_AiProviderSheetBody> createState() => _AiProviderSheetBodyState();
}

class _AiProviderSheetBodyState extends State<_AiProviderSheetBody> {
  final manager = AIProviderManager.instance;
  bool _testing = false;

  // 8-04 16:0x：能力灯不再自维护 _capsCache —— 统一从
  // manager.capabilityStateFor(id) 读单一数据源（配置页/聊天弹层共用），
  // 监听 capabilityNotifier 自动刷新，任何一处检测完这里跟着变。

  /// 正在自动探测的 provider（8-04 15:0x：打开弹层对未检测的自动测，
  /// 能力灯不等第一次对话）
  final Set<String> _autoProbing = {};

  @override
  void initState() {
    super.initState();
    // 冷启动防空白：把持久化能力缓存载入单一数据源（不触发网络）
    unawaited(manager.refreshCapabilityState());
    _autoProbeMissing();
  }

  /// 打开弹层：对还没探测过的 provider 自动实测（用户要求
  /// "自动测还是要测的"，信号台按钮只是保底）。
  /// 结果由 manager 写进单一数据源并广播，能力灯自动点亮。
  Future<void> _autoProbeMissing() async {
    final probing = <String>{};
    for (final provider in manager.providers) {
      if (manager.capabilityStateFor(provider.id) == null) {
        probing.add(provider.id);
      }
    }
    if (mounted) {
      setState(() => _autoProbing.addAll(probing));
    }
    for (final id in probing) {
      unawaited(
        manager.capabilitiesFor(id).then((_) {
          if (!mounted) return;
          setState(() => _autoProbing.remove(id));
        }).catchError((Object _) {
          if (!mounted) return;
          setState(() => _autoProbing.remove(id));
        }),
      );
    }
  }

  /// 信号台：手动重测单个 AI 的能力（保底，用户觉得不对再点）。
  Future<void> _reprobe(String id) async {
    setState(() => _autoProbing.add(id));
    final caps = await manager.reprobeProvider(id);
    if (!mounted) return;
    setState(() => _autoProbing.remove(id));
    final config = _configById(id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🔍 ${config?.name ?? id} 能力检测完成：${caps.capabilitySummary}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  AIProviderConfig? _configById(String id) {
    for (final config in manager.providers) {
      if (config.id == id) {
        return config;
      }
    }
    return null;
  }

  AIProviderState? _stateById(String id) {
    for (final state in manager.providerStates) {
      if (state.config.id == id) {
        return state;
      }
    }
    return null;
  }

  void _toggle(String id, bool checked) {
    final candidates = [for (final c in manager.candidatesFor(widget.personaId)) c.id];
    final allEnabled = [
      for (final p in manager.providers)
        if (p.enabled) p.id,
    ];
    List<String> next;
    if (checked) {
      next = [...candidates, id];
    } else {
      next = [for (final x in candidates) if (x != id) x];
      if (next.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('至少保留一个候选 AI'), duration: Duration(seconds: 2)),
        );
        return;
      }
    }
    if (listEquals(next, allEnabled)) {
      manager.clearPersonaBinding(widget.personaId);
      DebugLogger.log('AI管理', '${widget.personaName} 勾选=全部，恢复跟随全局');
    } else {
      manager.setPersonaBinding(widget.personaId, next);
      DebugLogger.log('AI管理', '${widget.personaName} 候选更新: ${next.join('、')}');
    }
  }

  bool _isMockId(String id) =>
      id == AIProviderManager.builtinMockId ||
      id.startsWith('builtin-mock');

  /// 真实组总开关：一键全选 / 全不选真实 AI（测试 AI 勾选不受影响）。
  void _toggleRealGroup(bool v, List<AIProviderConfig> real) {
    final candidates = [
      for (final c in manager.candidatesFor(widget.personaId)) c.id,
    ];
    final realIds = [for (final c in real) if (c.enabled) c.id];
    final allEnabled = [
      for (final p in manager.providers)
        if (p.enabled) p.id,
    ];
    List<String> next;
    if (v) {
      next = [...candidates];
      for (final id in realIds) {
        if (!next.contains(id)) next.add(id);
      }
    } else {
      next = [for (final x in candidates) if (!realIds.contains(x)) x];
    }
    if (next.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('至少保留一个候选 AI'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (listEquals(next, allEnabled)) {
      manager.clearPersonaBinding(widget.personaId);
    } else {
      manager.setPersonaBinding(widget.personaId, next);
    }
    setState(() {});
  }

  /// 测试组总开关（= 测试模式）：
  /// 开 → 记住该男主【原绑定】、临时改成只勾 mock（测试只走模拟 AI）；
  /// 关 → 原样恢复原绑定（含"跟随全局"状态）——绝不恢复成全选
  /// （16:19 用户：有的男主故意不勾某些 AI）。
  void _toggleTestGroup(bool v) {
    final pid = widget.personaId;
    if (v) {
      AIProviderManager.saveBindingSnapshot(pid, manager.bindingFor(pid));
      AIProviderManager.setTestModeEnabled(true);
      final mockIds = [
        for (final p in manager.providers)
          if (p.enabled && _isMockId(p.id)) p.id,
      ];
      if (mockIds.isNotEmpty) {
        manager.setPersonaBinding(pid, mockIds);
      }
    } else {
      // 统一走 manager.exitTestMode（聊天页横幅退出按钮同款逻辑）
      AIProviderManager.exitTestMode(pid);
    }
    setState(() {});
  }

  Future<void> _test(String id) async {
    setState(() => _testing = true);
    final result = await manager.testProvider(id);
    if (!mounted) return;
    setState(() => _testing = false);
    final config = _configById(id);
    // 测试会顺带做能力探测 → manager 广播，能力灯自动联动刷新
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? '✅ ${config?.name ?? id} 连接正常：${result.message}'
              : '❌ ${config?.name ?? id} 连接失败：${result.message}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 填 / 改 API Key（预设厂商地址和模型已内置，只差 Key）。
  Future<void> _editKey(AIProviderConfig config) async {
    final controller = TextEditingController(text: config.apiKey);
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('${config.name} 的 API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${config.baseUrl}\n模型：${config.model}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (key == null) return;
    await manager.setApiKey(config.id, key);
    if (mounted) {
      DebugLogger.log('AI管理', '已更新 ${config.name} 的 API Key');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API Key 已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final personaId = widget.personaId;
    final autoSwitch = manager.autoSwitchFor(personaId);
    final candidates = manager.candidatesFor(personaId);
    final lastId = manager.lastProviderFor(personaId);
    final lastConfig = lastId == null ? null : _configById(lastId);
    final lastState = lastId == null ? null : _stateById(lastId);
    final followsGlobal =
        manager.bindingFor(personaId) == null ||
            manager.bindingFor(personaId)!.isEmpty;

    Color statusColor(ColorScheme cs) {
      if (lastConfig == null) {
        return cs.outline;
      }
      if (!lastConfig.enabled) {
        return cs.outline;
      }
      if (lastConfig.apiKey.trim().isEmpty &&
          lastConfig.type != ProviderType.local) {
        return Colors.orange;
      }
      switch (lastState?.health) {
        case ProviderHealth.healthy:
          return Colors.green;
        case ProviderHealth.cooling:
          return Colors.orange;
        default:
          return cs.outline;
      }
    }

    String statusLabel() {
      if (lastConfig == null) {
        return '未配置';
      }
      if (!lastConfig.enabled) {
        return '已禁用';
      }
      if (lastConfig.apiKey.trim().isEmpty &&
          lastConfig.type != ProviderType.local) {
        return '未填 Key';
      }
      switch (lastState?.health) {
        case ProviderHealth.healthy:
          return '正常';
        case ProviderHealth.cooling:
          return '刚才失败，冷却中';
        default:
          return '待验证';
      }
    }

    return SizedBox(
      height: widget.maxHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 标题 ----
            Row(
              children: [
                Icon(Icons.hub_outlined, color: widget.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'AI 设置 · ${widget.personaName}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ---- 当前 AI 大卡片 ----
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: statusColor(widget.colorScheme).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: statusColor(widget.colorScheme).withValues(alpha: 0.35),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        lastConfig == null
                            ? Icons.error_outline
                            : Icons.auto_awesome,
                        size: 18,
                        color: statusColor(widget.colorScheme),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '当前 AI',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: widget.colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: statusColor(widget.colorScheme),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusLabel(),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    lastConfig?.name ?? '没有可用的 AI Provider',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: statusColor(widget.colorScheme),
                    ),
                  ),
                  if (lastConfig != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${lastConfig.model} · ${lastConfig.baseUrl}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: widget.colorScheme.onSurfaceVariant,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (lastState?.lastError != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '最近错误：${lastState!.lastError}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: widget.colorScheme.error,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ---- 自动切换 ----
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动切换'),
              subtitle: Text(
                autoSwitch
                    ? '当前 AI 不可用时自动换下一个'
                    : '不可用时弹窗提示，让你检查，不偷偷换人',
              ),
              value: autoSwitch,
              onChanged: (value) => manager.setAutoSwitch(personaId, value),
            ),
            const SizedBox(height: 4),

            // ---- 候选列表 ----
            Row(
              children: [
                Text(
                  '候选 AI（按尝试顺序，勾选的优先）',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: widget.colorScheme.onSurfaceVariant,
                      ),
                ),
                if (followsGlobal) ...[
                  const Spacer(),
                  Text(
                    '跟随全局',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: widget.colorScheme.outline,
                        ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: manager.providers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.hub_outlined,
                            size: 40,
                            color: Theme.of(context)
                                .colorScheme
                                .outline
                                .withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '还没有 AI，去管家页添加',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ],
                      ),
                    )
                  // 监听能力状态广播：任何一处检测完，能力灯自动联动
                  : ValueListenableBuilder<int>(
                      valueListenable: manager.capabilityNotifier,
                      builder: (context, _, __) {
                        // 8-05 16:0x 用户：真实 AI / 测试 AI 分组 + 各一组总开关。
                        // 测试组总开关 = 测试模式：开 → 记住真实组勾选并清空
                        // （测试对话只走模拟 AI，不花真实额度）；关 → 恢复真实组。
                        final real = [
                          for (final c in manager.providers)
                            if (!_isMockId(c.id)) c,
                        ];
                        final mocks = [
                          for (final c in manager.providers)
                            if (_isMockId(c.id)) c,
                        ];
                        return ListView(
                          children: [
                            if (real.isNotEmpty) ...[
                              _GroupHeader(
                                title: '真实 AI',
                                subtitle: '勾选 = 聊天候选，按顺序尝试',
                                value: real
                                    .where((c) => c.enabled)
                                    .every((c) => candidates
                                        .any((x) => x.id == c.id)),
                                onChanged: (v) => _toggleRealGroup(v, real),
                              ),
                              for (final config in real)
                                _buildRow(config, candidates),
                            ],
                            if (mocks.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _GroupHeader(
                                title: '🧪 测试 AI（不联网）',
                                subtitle:
                                    AIProviderManager.testModeEnabled
                                        ? '开 = 测试对话只走模拟 AI，真实 AI 已暂关'
                                        : '关 = 模拟 AI 隐藏；开 = 真实 AI 自动暂关',
                                value: AIProviderManager.testModeEnabled,
                                onChanged: _toggleTestGroup,
                              ),
                              for (final config in mocks)
                                _buildRow(config, candidates),
                            ],
                          ],
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),

            // ---- 底部按钮 ----
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                // 8-04 21:1x 用户：一键验收——自动切 5 个模拟 AI 跑真实对话，
                // 对话显示在聊天框，工具弹窗正常弹（点允许写/允许查即可）。
                // 8-05 14:28 用户：测试模式关 → 不显示验收按钮
                // （模拟 AI 平时隐藏，一键验收是测 bug 工具）
                if (widget.onAcceptance != null &&
                    AIProviderManager.testModeEnabled)
                  FilledButton.icon(
                    onPressed: () {
                      final navigator = Navigator.of(context);
                      final cb = widget.onAcceptance!;
                      navigator.pop();
                      unawaited(cb());
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7B6A8F),
                    ),
                    icon: const Icon(Icons.rocket_launch, size: 18),
                    label: const Text('🚀 一键验收'),
                  ),
                // 8-07 14:03 用户：一键测设定（真实 AI 通道，测设定段落化）——
                // 测试模式关 → 不显示
                if (widget.onTestSetting != null &&
                    AIProviderManager.testModeEnabled)
                  FilledButton.icon(
                    onPressed: () {
                      final navigator = Navigator.of(context);
                      final cb = widget.onTestSetting!;
                      navigator.pop();
                      unawaited(cb());
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D6B),
                    ),
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: const Text('🚀 一键测设定'),
                  ),
                // 8-08 02:3x 用户：一键测全部工具（真实 AI 通道 DeepSeek，
                // 引导批量调用，找"一卡一卡"卡点）——测试模式关 → 不显示
                if (widget.onTestAllTools != null &&
                    AIProviderManager.testModeEnabled)
                  FilledButton.icon(
                    onPressed: () {
                      final navigator = Navigator.of(context);
                      final cb = widget.onTestAllTools!;
                      navigator.pop();
                      unawaited(cb());
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB3593C),
                    ),
                    icon: const Icon(Icons.handyman, size: 18),
                    label: const Text('🚀 一键测全部工具'),
                  ),
                // 8-05 21:36 用户：假窗口满·手动触发总结 → 22:07 放开到
                // 真实 AI 验证通过（真实 DeepSeek 走 save_summary 完整闭环）
                // → 22:40 用户：转正为日常功能「手动精简上下文·省 token」——
                // 随时把当前角色对话压缩成摘要（原文→【男主摘要】，带
                // #编号），不用等窗口满。真实模式由聊天页确认框把关。
                if (widget.onForceSummarize != null)
                  FilledButton.tonalIcon(
                    onPressed: () {
                      final navigator = Navigator.of(context);
                      final cb = widget.onForceSummarize!;
                      navigator.pop();
                      unawaited(cb());
                    },
                    icon: const Icon(Icons.compress, size: 18),
                    label: const Text('🗜️ 精简上下文·省token'),
                  ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    // ⚠️ 不能在 pop 后 await 再检查 context.mounted：
                    // sheet 关闭后 context 已销毁 → mounted=false → 不 push，
                    // 表现为"点了没反应"（用户 8-03 00:07 报）。
                    // 正确做法：pop 前先捕获 navigator，pop 后直接用捕获的
                    // navigator push（同一个根 Navigator，顺序安全）。
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.push(
                      MaterialPageRoute(builder: (_) => const AiConfigPage()),
                    );
                  },
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('去管家页配置 API'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(AIProviderConfig config, List<AIProviderConfig> candidates) {
    final checked = candidates.any((c) => c.id == config.id);
    final state = _stateById(config.id);
    final isCurrent = config.id == manager.lastProviderFor(widget.personaId);
    final enabled = config.enabled;

    Color dotColor;
    switch (state?.health) {
      case ProviderHealth.healthy:
        dotColor = Colors.green;
      case ProviderHealth.cooling:
        dotColor = Colors.orange;
      case ProviderHealth.disabled:
        dotColor = Colors.grey;
      default:
        dotColor = enabled ? Colors.grey : Colors.grey.shade400;
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: checked,
        onChanged: enabled
            ? (value) => _toggle(config.id, value ?? false)
            : null,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              config.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                color: enabled ? null : Colors.grey,
              ),
            ),
          ),
          if (isCurrent) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '在用',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              config.model,
              config.type == ProviderType.local ? '本地' : null,
              if (!enabled) '已禁用',
              if (state?.health == ProviderHealth.cooling) '冷却中',
            ].whereType<String>().join(' · '),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: enabled ? null : Colors.grey),
          ),
          const SizedBox(height: 3),
          // 单一数据源：从 manager 读能力状态（配置页/聊天弹层共用）
          CapabilityLights(
            caps: manager.capabilityStateFor(config.id),
            probing: _autoProbing.contains(config.id),
            onRetest: () => _reprobe(config.id),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (config.type != ProviderType.local)
            IconButton(
              icon: Icon(
                Icons.key,
                size: 18,
                color: config.apiKey.trim().isEmpty
                    ? Colors.orange
                    : Colors.grey.shade400,
              ),
              tooltip: config.apiKey.trim().isEmpty ? '填 API Key' : '修改 API Key',
              onPressed: () => _editKey(config),
            ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: _testing ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ) : const Icon(Icons.network_check, size: 18),
            tooltip: '测试连接',
            onPressed: _testing ? null : () => _test(config.id),
          ),
        ],
      ),
      onTap: enabled ? () => _toggle(config.id, !checked) : null,
    );
  }
}


/// 分组标题 + 一键总开关（8-05 16:0x 用户：真实/测试 AI 分组）
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A5A),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeTrackColor: const Color(0xFF7B6A8F),
          ),
        ],
      ),
    );
  }
}
