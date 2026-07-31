import 'package:flutter/material.dart';

import '../ai_provider/ai_provider_manager.dart';
import '../ai_provider/failover_router.dart';
import '../ai_provider/models.dart';
import '../utils/debug_logger.dart';

/// AI 配置页（管家页入口）：
/// - 全局默认自动切换开关
/// - Provider 列表：启用开关 / 优先级排序 / 测试连接 / 状态
/// - 自定义 Provider 槽位：编辑 / 删除 / 新建
/// - 一键恢复默认
class AiConfigPage extends StatefulWidget {
  const AiConfigPage({super.key});

  @override
  State<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends State<AiConfigPage> {
  final manager = AIProviderManager.instance;
  String? _testingId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('AI 配置'),
        actions: [
          IconButton(
            tooltip: '恢复默认',
            icon: const Icon(Icons.restart_alt),
            onPressed: _confirmReset,
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: manager.changeNotifier,
        builder: (context, _, __) {
          final providers = manager.providers;
          final states = {
            for (final s in manager.providerStates) s.config.id: s,
          };
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              // ---- 全局默认 ----
              _sectionTitle('全局设置'),
              Card(
                elevation: 0,
                color: Colors.white.withValues(alpha: 0.8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile.adaptive(
                  title: const Text('默认自动切换'),
                  subtitle: const Text('男主没单独设置时，不可用是否自动换下一个'),
                  value: manager.autoSwitchFor(null),
                  onChanged: (v) => manager.setAutoSwitch(null, v),
                ),
              ),
              const SizedBox(height: 16),

              // ---- Provider 列表 ----
              _sectionTitle('Provider（点箭头调优先级，勾选启用）'),
              for (var i = 0; i < providers.length; i++)
                _buildProviderRow(providers[i], i, providers.length, states),
              const SizedBox(height: 16),

              // ---- 自定义槽位 ----
              _sectionTitle('自定义 Provider'),
              Card(
                elevation: 0,
                color: Colors.white.withValues(alpha: 0.8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    if (manager.customProvider != null)
                      ListTile(
                        leading: const Icon(Icons.edit_outlined),
                        title: Text(manager.customProvider!.name),
                        subtitle: Text(
                          '${manager.customProvider!.model}\n'
                          '${manager.customProvider!.baseUrl}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '编辑',
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _openCustomForm(existing: manager.customProvider),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () async {
                                await manager.removeCustomProvider();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('已删除自定义 Provider')),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                      )
                    else
                      ListTile(
                        leading: const Icon(Icons.add_circle_outline),
                        title: const Text('添加自定义 Provider'),
                        subtitle: const Text('支持任意 OpenAI 兼容接口（云端或本地）'),
                        onTap: () => _openCustomForm(),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
            color: const Color(0xFF6A4A5A).withValues(alpha: 0.5),
          ),
        ),
      );

  Widget _buildProviderRow(
    AIProviderConfig config,
    int index,
    int total,
    Map<String, AIProviderState> states,
  ) {
    final state = states[config.id];
    final isCustom = config.isCustom;

    Color dotColor;
    String? statusText;
    switch (state?.health) {
      case ProviderHealth.healthy:
        dotColor = Colors.green;
        statusText = '正常';
      case ProviderHealth.cooling:
        dotColor = Colors.orange;
        statusText = state?.lastError ?? '冷却中';
      case ProviderHealth.disabled:
        dotColor = Colors.grey;
        statusText = '已禁用';
      default:
        dotColor = config.enabled ? Colors.grey : Colors.grey.shade300;
        statusText = config.enabled ? '待验证' : '已禁用';
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: Colors.white.withValues(alpha: 0.8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            // 优先级箭头
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 24),
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  onPressed: index == 0 ? null : () => _move(index, index - 1),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 24),
                  icon: const Icon(Icons.arrow_downward, size: 16),
                  onPressed: index == total - 1 ? null : () => _move(index, index + 1),
                ),
              ],
            ),
            // 启用开关
            Switch.adaptive(
              value: config.enabled,
              onChanged: (v) => manager.setEnabled(config.id, v),
            ),
            // 信息
            Expanded(
              child: InkWell(
                onTap: isCustom ? () => _openCustomForm(existing: config) : null,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              config.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          if (isCustom) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFFC896B4).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                '自定义',
                                style: TextStyle(fontSize: 9, color: Color(0xFF9A6A86)),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${config.model} · ${config.baseUrl}',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (statusText != null && statusText.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 11,
                              color: dotColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // 状态点
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Tooltip(
                message: statusText ?? '',
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                ),
              ),
            ),
            // 测试
            IconButton(
              icon: _testingId == config.id
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check, size: 20),
              tooltip: '测试连接',
              onPressed: _testingId != null ? null : () => _test(config),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _move(int from, int to) async {
    final providers = manager.providers;
    final list = List<String>.of([for (final p in providers) p.id]);
    final moved = list.removeAt(from);
    list.insert(to, moved);
    await manager.setPriority(list);
    DebugLogger.log('AI管理', '优先级调整: ${list.join(' > ')}');
  }

  Future<void> _test(AIProviderConfig config) async {
    setState(() => _testingId = config.id);
    final result = await manager.testProvider(config.id);
    if (!mounted) return;
    setState(() => _testingId = null);
    DebugLogger.log('AI管理', '测试 ${config.name}: ${result.success ? '✅' : '❌'} ${result.message}');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success ? '✅ ${config.name} 连接正常' : '❌ ${config.name}：${result.message}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('恢复默认配置？'),
        content: const Text('会重置所有 Provider 为出厂预设、清空优先级与男主绑定。\nAPI Key 也会被清掉。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await manager.resetToDefaults();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已恢复默认配置')),
        );
      }
    }
  }

  Future<void> _openCustomForm({AIProviderConfig? existing}) async {
    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _CustomProviderForm(existing: existing),
    );
    if (result == null) return;
    await manager.saveCustomProvider(
      name: result['name'] ?? '',
      baseUrl: result['baseUrl'] ?? '',
      apiKey: result['apiKey'] ?? '',
      model: result['model'] ?? '',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(existing == null ? '已添加自定义 Provider' : '已保存修改')),
      );
    }
  }
}

/// 自定义 Provider 表单（名称 / 地址 / Key / 模型）。
class _CustomProviderForm extends StatefulWidget {
  const _CustomProviderForm({this.existing});

  final AIProviderConfig? existing;

  @override
  State<_CustomProviderForm> createState() => _CustomProviderFormState();
}

class _CustomProviderFormState extends State<_CustomProviderForm> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? 'https://');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.existing == null ? '添加自定义 Provider' : '编辑自定义 Provider',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '任意 OpenAI 兼容接口：填地址 + Key + 模型名即可。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称', hintText: '例如：我的中转'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: '接口地址',
              hintText: 'https://api.example.com/v1',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API Key', hintText: 'sk-...'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _model,
            decoration: const InputDecoration(labelText: '模型名', hintText: 'gpt-4o-mini'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                if (_name.text.trim().isEmpty ||
                    _baseUrl.text.trim().isEmpty ||
                    _model.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('名称、地址、模型名必填')),
                  );
                  return;
                }
                Navigator.of(context).pop({
                  'name': _name.text,
                  'baseUrl': _baseUrl.text,
                  'apiKey': _apiKey.text,
                  'model': _model.text,
                });
              },
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
