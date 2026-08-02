import 'package:flutter/material.dart';

import '../butler/mask_engine.dart' show MaskEngine;
import '../butler/modules/butler_module_hub.dart';
import '../butler/storage/identity_store.dart';

/// 假面层管理页 — 可替换的身份规则
///
/// 用户身边真实的人（老板、前任、闺蜜）→ 替换成代号（[亲属A]、[朋友B]），
/// 男主 AI 只看到代号，看不到真实身份。
///
/// 用户 8-03 00:07：添加身份不用写描述——代号 = 类别+字母自动生成
/// （亲属A/B/C，轮完 AA/AB 一直轮），这里看、添加、删除身份。
class MaskRulesPage extends StatefulWidget {
  final ButlerModuleHub hub;

  const MaskRulesPage({super.key, required this.hub});

  @override
  State<MaskRulesPage> createState() => _MaskRulesPageState();
}

class _MaskRulesPageState extends State<MaskRulesPage> {
  @override
  void initState() {
    super.initState();
    MaskEngine.loadHintsEveryTurn();
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
          // 每次都附上情绪参考开关（DeepSeek 无后台记忆 → 每次带，命中缓存）
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Card(
              color: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: const Color(0xFF6A4A5A).withValues(alpha: 0.08),
                ),
              ),
              child: SwitchListTile(
                value: MaskEngine.hintsEveryTurn,
                activeTrackColor: const Color(0xFFC896B4),
                title: const Text(
                  '每次都附上情绪参考',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A5A),
                  ),
                ),
                subtitle: const Text(
                  'DeepSeek 没有后台记忆，每轮都带上规律参考（同样内容命中缓存更省钱）；'
                  '有后台记忆的模型可关掉，只带一次',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6A4A5A)),
                ),
                onChanged: (v) async {
                  await MaskEngine.setHintsEveryTurn(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
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
                const SizedBox(height: 8),
                // 待确认的 #代号# 记忆（男主写的，用户确认后才生效）
                _PendingMemoriesSection(hub: widget.hub),
                const SizedBox(height: 8),
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
    String category = 'family';
    String gender = 'female';

    // 用户 8-03 00:07：去掉"给男主假面层角色的描述"——直接是亲属A/B/C，
    // 代号由管家按类别+字母自动生成，不需要用户写描述。
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
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
                    controller: labelCtrl,
                    decoration: _deco('怎么称呼 ta？（如：妈妈 / 老板 / 前任）'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: _deco('类别（代号按类别轮换：亲属A/B/C → AA/AB…）'),
                    items: [
                      const DropdownMenuItem(value: 'family', child: Text('家人（亲属A/B/C…）')),
                      const DropdownMenuItem(value: 'friend', child: Text('朋友（朋友A/B/C…）')),
                      const DropdownMenuItem(value: 'work', child: Text('工作（同事A/B/C…）')),
                      const DropdownMenuItem(value: 'stranger', child: Text('其他（某人A/B/C…）')),
                    ],
                    onChanged: (v) => setDialogState(() => category = v ?? 'family'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: gender,
                    decoration: _deco('性别（男主会用她/他称呼）'),
                    items: const [
                      DropdownMenuItem(value: 'female', child: Text('女（她）')),
                      DropdownMenuItem(value: 'male', child: Text('男（他）')),
                      DropdownMenuItem(value: '', child: Text('不填（ta）')),
                    ],
                    onChanged: (v) => setDialogState(() => gender = v ?? 'female'),
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
                final entry = IdentityEntry(
                  id: '${category}_${DateTime.now().millisecondsSinceEpoch}',
                  realLabel: label,
                  category: category,
                  gender: gender,
                  // 用户 8-03：不再要描述，代号 = 类别+字母自动生成
                  descriptions: const [],
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
        ),
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
                      (entry.gender == 'female'
                          ? ' · 女'
                          : entry.gender == 'male'
                              ? ' · 男'
                              : ''),
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                  ),
                ),
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

/// 待确认的 #代号# 记忆区块（用户 18:58：男主写什么都要用户确认）
class _PendingMemoriesSection extends StatefulWidget {
  final ButlerModuleHub hub;

  const _PendingMemoriesSection({required this.hub});

  @override
  State<_PendingMemoriesSection> createState() =>
      _PendingMemoriesSectionState();
}

class _PendingMemoriesSectionState extends State<_PendingMemoriesSection> {
  List<IdentityMemory> _pending = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = widget.hub.sharedMaskEngine?.identityStore;
    if (store == null) return;
    final list = await store.pendingMemories();
    if (mounted) setState(() => _pending = list);
  }

  /// 确认/拒绝后刷新
  Future<void> _update(IdentityMemory mem, String status) async {
    final store = widget.hub.sharedMaskEngine?.identityStore;
    if (store == null) return;
    await store.updateMemoryStatus(mem.id, status);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_pending.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFC896B4).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFC896B4).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.rate_review_outlined,
                color: Color(0xFFC896B4),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                '男主想记住的事（${_pending.length} 条待确认）',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6A4A5A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '男主在聊天里写了 #代号# 记忆。确认后才会生效（下次轮换到新代号时告诉他）；'
            '不确认就一直放着，不会泄露。',
            style: TextStyle(fontSize: 11, height: 1.5, color: Color(0xFF6A4A5A)),
          ),
          const SizedBox(height: 10),
          for (final mem in _pending) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mem.content,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: Color(0xFF5A4A52),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => _update(mem, 'rejected'),
                        child: const Text(
                          '丢弃',
                          style: TextStyle(fontSize: 12, color: Color(0xFFE07A7A)),
                        ),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFC896B4),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          minimumSize: const Size(0, 30),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => _update(mem, 'confirmed'),
                        child: const Text(
                          '确认记住',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
