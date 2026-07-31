import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../ai_provider/ai_provider_manager.dart';
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
          builder: (context, _, __) {
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
              child: ListView(
                children: [
                  for (final config in manager.providers) _buildRow(config, candidates),
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
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
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
      subtitle: Text(
        [
          config.model,
          config.type == ProviderType.local ? '本地' : null,
          if (!enabled) '已禁用',
          if (state?.health == ProviderHealth.cooling) '冷却中',
        ].whereType<String>().join(' · '),
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: enabled ? null : Colors.grey),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
