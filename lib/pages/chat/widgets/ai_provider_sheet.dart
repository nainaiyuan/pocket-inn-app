import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../ai_provider/ai_provider_manager.dart';
import '../../../ai_provider/capability_probe.dart';
import '../../../ai_provider/failover_router.dart';
import '../../../ai_provider/models.dart';
import '../../../utils/debug_logger.dart';
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
  });

  final String personaId;
  final String personaName;
  final ColorScheme colorScheme;
  final double maxHeight;

  @override
  State<_AiProviderSheetBody> createState() => _AiProviderSheetBodyState();
}

class _AiProviderSheetBodyState extends State<_AiProviderSheetBody> {
  final manager = AIProviderManager.instance;
  bool _testing = false;

  /// providerId → 能力画像（只读缓存，打开弹层时加载，不触发探测）
  Map<String, AIProviderCapabilities> _capsCache = {};

  /// 正在自动探测的 provider（8-04 15:0x：打开弹层对未检测的自动测，
  /// 能力灯不等第一次对话）
  final Set<String> _autoProbing = {};

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
  }

  /// 打开弹层：缓存命中的直接用；缓存 miss 的自动实测（用户要求
  /// "自动测还是要测的"，信号台按钮只是保底）。
  Future<void> _loadCapabilities() async {
    final map = <String, AIProviderCapabilities>{};
    final probing = <String>{};
    for (final provider in manager.providers) {
      final caps = await manager.cachedCapabilitiesFor(provider.id);
      if (caps != null) {
        map[provider.id] = caps;
      } else {
        probing.add(provider.id);
        // 未检测 → 自动探测（miss 才发请求，结果自动回写缓存）
        unawaited(
          manager.capabilitiesFor(provider.id).then((c) {
            if (!mounted) return;
            setState(() {
              _capsCache[provider.id] = c;
              _autoProbing.remove(provider.id);
            });
          }).catchError((Object _) {
            if (!mounted) return;
            setState(() => _autoProbing.remove(provider.id));
          }),
        );
      }
    }
    if (mounted) {
      setState(() {
        _capsCache = map;
        _autoProbing
          ..clear()
          ..addAll(probing);
      });
    }
  }

  /// 信号台：手动重测单个 AI 的能力（保底，用户觉得不对再点）。
  Future<void> _reprobe(String id) async {
    setState(() => _autoProbing.add(id));
    final caps = await manager.reprobeProvider(id);
    if (!mounted) return;
    setState(() {
      _capsCache[id] = caps;
      _autoProbing.remove(id);
    });
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

  Future<void> _test(String id) async {
    setState(() => _testing = true);
    final result = await manager.testProvider(id);
    if (!mounted) return;
    setState(() => _testing = false);
    final config = _configById(id);
    // 测试会顺带做能力探测 → 刷新缓存展示
    await _loadCapabilities();
    if (!mounted) return;
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
                  : ListView(
                      children: [
                        for (final config in manager.providers)
                          _buildRow(config, candidates),
                      ],
                    ),
            ),
            const SizedBox(height: 8),

            // ---- 底部按钮 ----
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
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
          _CapabilityLights(
            caps: _capsCache[config.id],
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

/// 能力灯（2026-08-04 通用适配层）：系别标签 + 能用哪个亮哪个。
/// - 原生工具 / 思考链 / 流式：支持的亮绿色圆点 + 文字，不支持的**不显示**
/// - 一个都不支持 → 显示"⚠️ 仅文本协议（AI 可能不配合）"
/// - 还没探测过 → 显示"未检测" + 自动探测中/重测按钮
/// - 信号台按钮（🛰 重测）：保底，用户觉得能力灯不对就再点一次
class _CapabilityLights extends StatelessWidget {
  const _CapabilityLights({this.caps, this.probing = false, this.onRetest});

  final AIProviderCapabilities? caps;

  /// 正在探测中（添加后自动测 / 手动重测）
  final bool probing;

  /// 信号台重测回调
  final VoidCallback? onRetest;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (caps == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (probing) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
            Text(
              '检测中…',
              style: TextStyle(fontSize: 11, color: colorScheme.outline),
            ),
          ] else ...[
            Text(
              '未检测',
              style: TextStyle(fontSize: 11, color: colorScheme.outline),
            ),
            const SizedBox(width: 4),
            _RetestButton(onPressed: onRetest),
          ],
        ],
      );
    }

    final lights = <Widget>[
      _light(context, colorScheme, '工具', caps!.toolFormat == 'openai'),
      _light(context, colorScheme, '思考链', caps!.supportsReasoning),
      _light(context, colorScheme, '流式', caps!.supportsStreaming),
    ];
    final anySupported = caps!.toolFormat == 'openai' ||
        caps!.supportsReasoning ||
        caps!.supportsStreaming;

    return Wrap(
      spacing: 8,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: 0.25),
            ),
          ),
          child: Text(
            caps!.systemLabel,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ),
        if (anySupported)
          ...lights
        else
          Text(
            '⚠️ 仅文本协议（AI 可能不配合）',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.orange.shade800,
            ),
          ),
        if (probing) ...[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ] else
          _RetestButton(onPressed: onRetest),
      ],
    );
  }

  Widget _light(
    BuildContext context,
    ColorScheme colorScheme,
    String label,
    bool supported,
  ) {
    if (!supported) {
      // 不能用的不显示（能用哪个亮哪个）
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 信号台小按钮：🛰 重测能力（保底，觉得不对再点一次）。
class _RetestButton extends StatelessWidget {
  const _RetestButton({this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sensors, size: 13, color: colorScheme.outline),
            const SizedBox(width: 2),
            Text(
              '重测',
              style: TextStyle(
                fontSize: 10,
                color: colorScheme.outline,
                decoration: TextDecoration.underline,
                decorationColor: colorScheme.outline.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
