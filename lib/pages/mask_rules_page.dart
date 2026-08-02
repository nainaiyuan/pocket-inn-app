import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai_provider/ai_provider_manager.dart';
import '../ai_provider/models.dart';
import '../butler/modules/butler_module_hub.dart';
import '../butler/storage/identity_store.dart';

/// 假面层管理页 — 可替换的身份规则
///
/// 用户身边真实的人（老板、前任、闺蜜）→ 替换成代号（[上司1]、[朋友2]），
/// 男主 AI 只看到代号，看不到真实身份。
///
/// 这里可以看、添加、删除身份。
class MaskRulesPage extends StatefulWidget {
  final ButlerModuleHub hub;

  const MaskRulesPage({super.key, required this.hub});

  @override
  State<MaskRulesPage> createState() => _MaskRulesPageState();
}

class _MaskRulesPageState extends State<MaskRulesPage> {
  /// 用户自定义分类（微信分组式：自己填，下次还能选）
  List<String> _customCategories = [];

  @override
  void initState() {
    super.initState();
    _loadCustomCategories();
  }

  Future<void> _loadCustomCategories() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('mask_custom_categories') ?? [];
    if (mounted) setState(() => _customCategories = list);
  }

  /// 添加自定义分类（保存后下次可复用）
  Future<void> _addCustomCategory(String name) async {
    final n = name.trim();
    if (n.isEmpty || _customCategories.contains(n)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'mask_custom_categories',
      [..._customCategories, n],
    );
    if (mounted) setState(() => _customCategories = [..._customCategories, n]);
  }

  /// 新建分类弹窗
  Future<String?> _promptNewCategory(BuildContext ctx) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        title: const Text(
          '新建分类',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: _deco('分类名（如：亲戚 / 同学 / 前任）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text(
              '取消',
              style: TextStyle(color: Color(0xFF6A4A5A)),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.hub.sharedMaskEngine!;
    final identities = engine.allIdentities;

    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '假面层规则',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF6A4A5A)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC896B4).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.visibility_off_outlined,
                        color: Color(0xFFC896B4),
                        size: 18,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '你身边真实的人会被替换成代号，男主只看到代号，保护你的隐私。\n比如「老板」→ [上司1]。',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: Color(0xFF5A4A52),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (identities.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 50),
                      child: Column(
                        children: [
                          Icon(
                            Icons.masks_outlined,
                            size: 48,
                            color: Color(0xFFC896B4),
                          ),
                          SizedBox(height: 12),
                          Text(
                            '还没有身份规则。\n添加一个你想隐藏的人试试。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: const Color(
                                0xFF5A4A52,
                              ).withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  for (final entry in identities) ...[
                    _IdentityCard(
                      entry: entry,
                      code: engine.codeFor(entry.id),
                      onDelete: () => _confirmDelete(entry),
                    ),
                    const SizedBox(height: 8),
                  ],
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC896B4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text(
                    '添加身份',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  onPressed: () => _showAddDialog(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddDialog() {
    final labelCtrl = TextEditingController();
    final describeCtrl = TextEditingController();
    String category = 'family';
    final descCtrls = <TextEditingController>[];
    var generating = false;

    void addDescField() {
      descCtrls.add(TextEditingController());
    }

    addDescField();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // 让管家问 AI 生成中性描述（替代真实称呼的第三方描述）
          Future<void> generateDescriptions() async {
            final label = labelCtrl.text.trim();
            if (label.isEmpty) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('先填真实称呼，管家才知道要生成谁的描述')),
              );
              return;
            }
            if (!AIProviderManager.instance.hasUsable(null)) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('还没配置 AI，去设置里配置后再试')),
              );
              return;
            }
            setDialogState(() => generating = true);
            try {
              // 口语描述 → 管家整理成整套身份（称呼+分类+描述）
              final describeText = describeCtrl.text.trim();
              if (describeText.isNotEmpty) {
                final idResult = await AIProviderManager.instance.chat(
                  null,
                  [
                    AIChatMessage(
                      role: 'system',
                      content:
                          '你是关系整理助手。用户会用口语描述一个人（家人/朋友/同事/前任等）。'
                          '请整理成 JSON，格式：'
                          '{"label":"怎么称呼ta（如 妈妈/老板/闺蜜）","category":"family或friend或work或stranger或简短中文分类",'
                          '"descriptions":["5条中性第三人称描述，每条不超过30字，不出现真实称呼，'
                          '覆盖关系、性格、相处方式、对用户情绪的影响"]}'
                          '只输出 JSON，不要多余文字。',
                    ),
                    AIChatMessage(role: 'user', content: '口语描述：$describeText'),
                  ],
                );
                final jsonStr = idResult.text
                    .replaceAll(RegExp(r'^```json\s*|\s*```$'), '')
                    .trim();
                final start = jsonStr.indexOf('{');
                final end = jsonStr.lastIndexOf('}');
                if (start >= 0 && end > start) {
                  final decoded =
                      jsonDecode(jsonStr.substring(start, end + 1));
                  final genLabel = (decoded['label'] as String?)?.trim() ?? '';
                  final genCategory =
                      (decoded['category'] as String?)?.trim() ?? '';
                  final genDescs = ((decoded['descriptions'] as List?) ?? [])
                      .map((d) => d.toString().trim())
                      .where((d) => d.isNotEmpty && d.length > 3)
                      .toList();
                  if (genLabel.isNotEmpty) {
                    setDialogState(() {
                      labelCtrl.text = genLabel;
                      // 分类：预设或自定义（自定义自动加入列表）
                      const presets = ['family', 'friend', 'work', 'stranger'];
                      if (presets.contains(genCategory)) {
                        category = genCategory;
                      } else if (genCategory.isNotEmpty) {
                        category = genCategory;
                        if (!_customCategories.contains(genCategory)) {
                          _customCategories = [..._customCategories, genCategory];
                          SharedPreferences.getInstance().then((prefs) => prefs
                              .setStringList(
                                  'mask_custom_categories', _customCategories));
                        }
                      }
                      descCtrls
                        ..clear()
                        ..addAll(
                          genDescs.map(
                            (d) => TextEditingController(text: d),
                          ),
                        );
                      if (genDescs.isEmpty) descCtrls.add(TextEditingController());
                      generating = false;
                    });
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('✨ 管家已整理好，确认后可添加')),
                      );
                    }
                    return; // 已回填，不再走下面的描述生成
                  }
                }
                throw Exception('管家返回内容无法解析');
              }
              // 没有口语描述 → 原有逻辑：称呼 → 生成 5 条描述
              final result = await AIProviderManager.instance.chat(
                null,
                [
                  AIChatMessage(
                    role: 'system',
                    content:
                        '你是关系描述生成助手。用户会给你一个真实称呼（如"妈妈"、"老板"），'
                        '请生成 5 条中性的第三人称关系描述，用于聊天时代替真实称呼。'
                        '要求：1) 每条不超过 30 字 2) 绝对不出现真实称呼本身 3) 中性客观，不提具体人名地名'
                        ' 4) 覆盖关系、性格、相处方式、对用户情绪的影响 5) 每条单独一行，不要编号、不要引号。',
                  ),
                  AIChatMessage(role: 'user', content: '真实称呼：$label'),
                ],
              );
              final lines = result.text
                  .split('\n')
                  .map(
                    (s) => s
                        .trim()
                        .replaceFirst(RegExp(r'^\d+[.、)）]\s*'), '')
                        .replaceAll(
                          RegExp('^["\'「『]|["\'」』]\$'),
                          '',
                        ),
                  )
                  .where((s) => s.isNotEmpty && s.length > 3)
                  .take(5)
                  .toList();
              if (lines.isEmpty) throw Exception('AI 返回内容无法解析');
              setDialogState(() {
                // 保留用户已填的，清掉空输入框，填入生成的
                final nonEmpty = descCtrls
                    .where((c) => c.text.trim().isNotEmpty)
                    .toList();
                descCtrls
                  ..clear()
                  ..addAll(nonEmpty);
                for (final line in lines) {
                  descCtrls.add(TextEditingController(text: line));
                }
                generating = false;
              });
            } catch (e) {
              setDialogState(() => generating = false);
              if (ctx.mounted) {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(SnackBar(content: Text('生成失败：$e')));
              }
            }
          }

          return AlertDialog(
          backgroundColor: const Color(0xFFFDF7F9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            '添加身份',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A4A5A),
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: describeCtrl,
                    decoration: _deco(
                      '口语描述 ta（管家自动整理成身份，如：我妈管我管得严，老催我相亲）',
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: generating ? null : generateDescriptions,
                      icon: generating
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFC896B4),
                              ),
                            )
                          : const Icon(Icons.auto_fix_high, size: 16),
                      label: Text(
                        generating ? '整理中…' : '✨ 管家整理成身份',
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFC896B4),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: labelCtrl,
                    decoration: _deco('怎么称呼 ta？（如：妈妈 / 老板 / 前任）'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: _deco('分类（可选，可自定义）'),
                    items: [
                      const DropdownMenuItem(value: 'family', child: Text('家人')),
                      const DropdownMenuItem(value: 'friend', child: Text('朋友')),
                      const DropdownMenuItem(value: 'work', child: Text('工作')),
                      const DropdownMenuItem(value: 'stranger', child: Text('其他')),
                      ..._customCategories.map(
                        (c) => DropdownMenuItem(value: c, child: Text(c)),
                      ),
                      const DropdownMenuItem(
                        value: '__new__',
                        child: Text('＋ 新建分类…'),
                      ),
                    ],
                    onChanged: (v) async {
                      if (v == '__new__') {
                        final name = await _promptNewCategory(ctx);
                        if (name != null && name.isNotEmpty) {
                          await _addCustomCategory(name);
                          if (ctx.mounted) {
                            setDialogState(() => category = name);
                          }
                        }
                      } else {
                        setDialogState(() => category = v ?? 'family');
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '给男主一些关于 ta 的描述（越多越好，每次聊天会随机轮换一条，帮助男主理解你们的关系）：',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: const Color(0xFF6A4A5A).withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < descCtrls.length; i++) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: descCtrls[i],
                            decoration: _deco(
                              '例：我妈妈很唠叨但特别疼我，上周又催我相亲',
                            ),
                          ),
                        ),
                        if (descCtrls.length > 1)
                          IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: Color(0xFFE07A7A),
                              size: 20,
                            ),
                            onPressed: () => setDialogState(() {
                              descCtrls.removeAt(i);
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => setDialogState(addDescField),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text(
                            '再加一条描述',
                            style: TextStyle(fontSize: 12),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFC896B4),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: generating ? null : generateDescriptions,
                          icon: generating
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFFC896B4),
                                  ),
                                )
                              : const Icon(Icons.auto_fix_high, size: 16),
                          label: Text(
                            generating ? '生成中…' : '让管家生成',
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFC896B4),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                '取消',
                style: TextStyle(color: Color(0xFF6A4A5A)),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFC896B4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                final label = labelCtrl.text.trim();
                if (label.isEmpty) {
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(const SnackBar(content: Text('请输入真实称呼')));
                  return;
                }
                final descriptions = descCtrls
                    .map((c) => c.text.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                final entry = IdentityEntry(
                  id: '${category}_${DateTime.now().millisecondsSinceEpoch}',
                  realLabel: label,
                  category: category,
                  descriptions: descriptions,
                );
                widget.hub.sharedMaskEngine!.registerIdentity(entry);
                Navigator.pop(ctx);
                setState(() {});
              },
              child: const Text(
                '添加',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
        },
      ),
    );
  }

  void _confirmDelete(IdentityEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '删除这个身份？',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: Text(
          '「${entry.realLabel}」→ ${_codeOf(entry)}\n删除后聊天时不再自动替换。',
          style: const TextStyle(fontSize: 13, color: Color(0xFF6A4A5A)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Color(0xFF6A4A5A))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE07A7A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              widget.hub.sharedMaskEngine!.unregisterIdentity(entry.id);
              Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text(
              '删除',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  String _codeOf(IdentityEntry entry) =>
      widget.hub.sharedMaskEngine!.codeFor(entry.id) ?? '[?]';

  InputDecoration _deco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 12,
        color: const Color(0xFF6A4A5A).withValues(alpha: 0.3),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  final IdentityEntry entry;
  final String? code;
  final VoidCallback onDelete;

  const _IdentityCard({
    required this.entry,
    required this.code,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFC896B4).withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFC896B4).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              code ?? '[?]',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFFC896B4),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.realLabel,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5A4A52),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _categoryName(entry.category) +
                      (entry.descriptions.isEmpty
                          ? ''
                          : ' · ${entry.descriptions.length} 条描述'),
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                  ),
                ),
                if (entry.descriptions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(
                        0xFFC896B4,
                      ).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '「${entry.descriptions.first}」',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: const Color(
                          0xFF5A4A52,
                        ).withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline,
              color: Color(0xFFE07A7A),
              size: 20,
            ),
            tooltip: '删除',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  static String _categoryName(String category) {
    switch (category) {
      case 'family':
        return '家人';
      case 'friend':
        return '朋友';
      case 'work':
        return '工作';
      case 'stranger':
        return '其他';
      default:
        return category;
    }
  }
}
