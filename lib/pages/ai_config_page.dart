import 'package:flutter/material.dart';

import '../ai_provider/ai_provider_manager.dart';
import '../ai_provider/failover_router.dart';
import '../ai_provider/models.dart';
import '../ai_provider/provider_presets.dart';
import '../utils/debug_logger.dart';

/// AI 配置页（管家页入口）：
/// - 全局默认自动切换开关
/// - 「我的 AI」列表：只显示用户添加过的（名字是用户取的），
///   没配置的预设不出现
/// - 添加 AI：从预设模板选（地址/模型帮填好，只需命名 + Key）或自定义
/// - 每个 AI 可：开关 / 排序 / 测试 / 编辑 / 删除
/// - 清空所有 AI 配置
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
            tooltip: '清空所有 AI',
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

              // ---- 我的 AI ----
              _sectionTitle('我的 AI（点编辑可改名）'),
              if (providers.isEmpty)
                Card(
                  elevation: 0,
                  color: Colors.white.withValues(alpha: 0.6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                    child: Column(
                      children: [
                        Icon(
                          Icons.hub_outlined,
                          size: 36,
                          color: const Color(0xFFC896B4).withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '还没有 AI',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '点下面「添加 AI」：选个预设只需填名字和 Key，\n或者自己填地址、Key、模型名',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                for (var i = 0; i < providers.length; i++)
                  _buildProviderRow(providers[i], i, providers.length, states),
              const SizedBox(height: 16),

              // ---- 添加 AI ----
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _openAddSheet,
                  icon: const Icon(Icons.add),
                  label: const Text('添加 AI'),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '预设只是帮你填好地址和模型，名字和 Key 由你定；没添加的不会显示在这里。',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  height: 1.4,
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

    Color dotColor;
    String? statusText;
    final missingKey = config.enabled &&
        config.apiKey.trim().isEmpty &&
        config.type != ProviderType.local;
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
        dotColor = missingKey
            ? Colors.orange
            : (config.enabled ? Colors.grey : Colors.grey.shade300);
        statusText = missingKey
            ? '未填 Key（编辑填写）'
            : (config.enabled ? '待验证' : '已禁用');
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
                        if (config.type == ProviderType.local) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8AA8C8).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '本地',
                              style: TextStyle(fontSize: 9, color: Color(0xFF5A7A9A)),
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
                    if (statusText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          statusText,
                          style: TextStyle(fontSize: 11, color: dotColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // 状态点
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Tooltip(
                message: statusText,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                ),
              ),
            ),
            // 编辑
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: '编辑',
              onPressed: () => _openEditForm(config),
            ),
            // 删除
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除',
              onPressed: () => _confirmDelete(config),
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

  Future<void> _confirmDelete(AIProviderConfig config) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('删除「${config.name}」？'),
        content: const Text('删除后这个 AI 从列表消失，男主绑定里也会移除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await manager.removeProvider(config.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除「${config.name}」')),
        );
      }
    }
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('清空所有 AI？'),
        content: const Text('会删除全部 AI 配置和男主绑定。\n（只是清掉配置，不会动聊天记录）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await manager.resetToDefaults();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空所有 AI 配置')),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 添加 / 编辑
  // ---------------------------------------------------------------------------

  Future<void> _openAddSheet() async {
    final addedIds = {for (final p in manager.providers) p.id};
    final selected = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _TemplatePickerSheet(addedIds: addedIds),
    );
    if (selected == null || !mounted) return;
    if (selected is AIProviderPreset) {
      await _openForm(preset: selected);
    } else {
      // 自定义
      await _openForm();
    }
  }

  Future<void> _openEditForm(AIProviderConfig config) async {
    await _openForm(existing: config);
  }

  Future<void> _openForm({
    AIProviderPreset? preset,
    AIProviderConfig? existing,
  }) async {
    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ProviderForm(preset: preset, existing: existing),
    );
    if (result == null || !mounted) return;

    final name = result['name'] ?? '';
    final baseUrl = result['baseUrl'] ?? '';
    final apiKey = result['apiKey'] ?? '';
    final model = result['model'] ?? '';

    if (existing != null) {
      // 编辑：整体保存
      await manager.saveProvider(
        existing.copyWith(
          name: name,
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
        ),
      );
      DebugLogger.log('AI管理', '编辑 AI: $name');
    } else if (preset != null) {
      await manager.addProviderFromPreset(preset, name: name, apiKey: apiKey);
    } else {
      // 自定义添加
      await manager.saveProvider(
        AIProviderConfig(
          id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
          name: name.isEmpty ? '自定义' : name,
          type: ProviderType.cloud,
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
          isCustom: true,
          enabled: true,
          priority: 500,
        ),
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
    }
  }
}

/// 添加时的模板选择：预设列表（已添加的置灰）+ 自定义。
class _TemplatePickerSheet extends StatelessWidget {
  const _TemplatePickerSheet({required this.addedIds});

  final Set<String> addedIds;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择 AI 来源',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '预设 = 地址和模型已帮你填好，只需命名 + Key',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final preset in kAIProviderPresets)
                    _templateTile(
                      context,
                      icon: preset.type == ProviderType.local
                          ? Icons.laptop_mac_outlined
                          : Icons.cloud_outlined,
                      title: preset.name,
                      subtitle: '${preset.model} · ${preset.baseUrl}',
                      note: preset.note,
                      added: addedIds.contains(preset.id),
                      onTap: addedIds.contains(preset.id)
                          ? null
                          : () => Navigator.of(context).pop(preset),
                    ),
                  const Divider(height: 24),
                  _templateTile(
                    context,
                    icon: Icons.tune,
                    title: '自定义',
                    subtitle: '自己填地址、Key、模型名',
                    note: '任意 OpenAI 兼容接口（云端或本地）',
                    added: false,
                    onTap: () => Navigator.of(context).pop('custom'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _templateTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String note,
    required bool added,
    required VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: onTap != null,
      leading: Icon(
        icon,
        color: added
            ? Colors.grey.shade400
            : Theme.of(context).colorScheme.primary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: added ? Colors.grey.shade400 : null,
              ),
            ),
          ),
          if (added) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '已添加',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitle,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          if (note.isNotEmpty)
            Text(
              note,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
            ),
        ],
      ),
      trailing: Icon(Icons.chevron_right, color: Colors.grey.shade400),
      onTap: onTap,
    );
  }
}

/// AI 表单：预设添加（名字 + Key，地址模型只读） / 自定义（全填） / 编辑（全可改）。
class _ProviderForm extends StatefulWidget {
  const _ProviderForm({this.preset, this.existing});

  /// 非空 = 从预设模板添加
  final AIProviderPreset? preset;

  /// 非空 = 编辑现有
  final AIProviderConfig? existing;

  @override
  State<_ProviderForm> createState() => _ProviderFormState();
}

class _ProviderFormState extends State<_ProviderForm> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;

  bool _customModel = false;

  bool get _isLocal =>
      widget.preset?.type == ProviderType.local ||
      widget.existing?.type == ProviderType.local;

  /// 模型下拉选项：预设添加用预设的列表；编辑时按 id 反查预设列表。
  List<String> get _modelOptions {
    final preset = widget.preset;
    if (preset != null) {
      return preset.models.isNotEmpty ? preset.models : [preset.model];
    }
    final existing = widget.existing;
    if (existing != null) {
      for (final p in kAIProviderPresets) {
        if (p.id == existing.id) {
          return p.models.isNotEmpty ? p.models : [p.model];
        }
      }
    }
    return const [];
  }

  @override
  void initState() {
    super.initState();
    final preset = widget.preset;
    final existing = widget.existing;
    _name = TextEditingController(
      text: existing?.name ?? preset?.name ?? '',
    );
    _baseUrl = TextEditingController(
      text: existing?.baseUrl ?? preset?.baseUrl ?? 'https://',
    );
    _apiKey = TextEditingController(text: existing?.apiKey ?? '');
    final currentModel = existing?.model ?? preset?.model ?? '';
    // 当前模型在预置列表里 → 下拉选中；否则 → 自定义输入
    _customModel = !_modelOptions.contains(currentModel);
    _model = TextEditingController(text: currentModel);
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
    final preset = widget.preset;
    final editing = widget.existing != null;
    final showBaseFields = preset == null; // 预设添加时地址模型锁定

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              editing
                  ? '编辑 AI'
                  : (preset != null ? '添加「${preset.name}」' : '添加自定义 AI'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (preset != null && !editing) ...[
              const SizedBox(height: 4),
              Text(
                '地址已帮你填好（${preset.baseUrl}），只需取个名字、选模型${_isLocal ? '' : '和 Key'}。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名字（你说了算）',
                hintText: '例如：我的 DeepSeek',
              ),
            ),
            const SizedBox(height: 8),
            if (showBaseFields) ...[
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: '接口地址',
                  hintText: 'https://api.example.com/v1',
                ),
              ),
              const SizedBox(height: 8),
            ] else if (editing) ...[
              // 编辑预设添加的 AI：地址可改
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(labelText: '接口地址'),
              ),
              const SizedBox(height: 8),
            ],
            // ---- 模型：下拉选（厂商常用列表）+ 自定义 ----
            if (_modelOptions.isNotEmpty && !_customModel)
              DropdownButtonFormField<String>(
                value: _model.text,
                decoration: const InputDecoration(labelText: '模型'),
                items: [
                  for (final m in _modelOptions)
                    DropdownMenuItem(value: m, child: Text(m)),
                  const DropdownMenuItem(
                    value: '__custom__',
                    child: Text('自定义…（厂商更新了模型名就选这个）'),
                  ),
                ],
                onChanged: (value) {
                  if (value == '__custom__') {
                    setState(() {
                      _customModel = true;
                      _model.text = '';
                    });
                  } else if (value != null) {
                    setState(() => _model.text = value);
                  }
                },
              )
            else ...[
              TextField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '模型名',
                  hintText: '厂商最新模型名，如 deepseek-v4-flash',
                ),
              ),
              if (_modelOptions.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _customModel = false;
                        _model.text = _modelOptions.first;
                      });
                    },
                    icon: const Icon(Icons.format_list_bulleted, size: 16),
                    label: const Text('从常用列表选'),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            if (!_isLocal) ...[
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-...',
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  if (_name.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('取个名字吧')),
                    );
                    return;
                  }
                  if (showBaseFields &&
                      (_baseUrl.text.trim().isEmpty || _model.text.trim().isEmpty)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('地址、模型名必填')),
                    );
                    return;
                  }
                  if (!showBaseFields &&
                      !editing &&
                      _model.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('选个模型吧（或自定义填）')),
                    );
                    return;
                  }
                  if (!_isLocal && _apiKey.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('云端 AI 需要 API Key')),
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
      ),
    );
  }
}
