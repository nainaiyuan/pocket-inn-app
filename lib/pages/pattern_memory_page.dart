import 'package:flutter/material.dart';

import '../../butler/memory/user_memory.dart';
import '../../butler/modules/butler_module_hub.dart';
import '../../butler/patterns/pattern_engine.dart';

/// 规律与记忆管理页
///
/// 两个 tab：
/// - 规律：管家发现的 + 用户手动添加的规律（关键词组合 → 情绪），可删可加
/// - 记忆：男主记住的用户的事，可改可删可加
///
/// 用户说了算：规律不想要就删，想加就手动加。
class PatternMemoryPage extends StatefulWidget {
  final ButlerModuleHub hub;

  const PatternMemoryPage({super.key, required this.hub});

  @override
  State<PatternMemoryPage> createState() => _PatternMemoryPageState();
}

class _PatternMemoryPageState extends State<PatternMemoryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  PatternEngine get _engine => widget.hub.sharedPatternEngine!;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '规律与记忆',
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
        bottom: TabBar(
          controller: _tabController,
          labelColor: const Color(0xFFC896B4),
          unselectedLabelColor: const Color(0xFF6A4A5A).withValues(alpha: 0.5),
          indicatorColor: const Color(0xFFC896B4),
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          tabs: const [
            Tab(text: '规律'),
            Tab(text: '记忆'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _PatternTab(engine: _engine),
          _MemoryTab(hub: widget.hub),
        ],
      ),
    );
  }
}

// ==================== 规律 Tab ====================

class _PatternTab extends StatelessWidget {
  final PatternEngine engine;

  const _PatternTab({required this.engine});

  @override
  Widget build(BuildContext context) {
    final confirmed = engine.confirmedPatterns;
    final unconfirmed = engine.patterns.where((p) => !p.confirmed).toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              _HintCard(
                icon: Icons.auto_awesome,
                text:
                    '规律是管家发现的：聊到某些关键词组合时你的情绪会怎么变。\n不想要的规律可以直接删；也可以手动添加你确定的规律。',
              ),
              const SizedBox(height: 14),
              if (confirmed.isNotEmpty) ...[
                const _SectionTitle('已确认的规律', 'confirmed'),
                const SizedBox(height: 8),
                for (final p in confirmed) ...[
                  _PatternCard(pattern: p, engine: engine),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 8),
              ],
              if (unconfirmed.isNotEmpty) ...[
                const _SectionTitle('观察中（还没确认）', 'pending'),
                const SizedBox(height: 8),
                for (final p in unconfirmed) ...[
                  _PendingPatternCard(pattern: p),
                  const SizedBox(height: 8),
                ],
              ],
              if (confirmed.isEmpty && unconfirmed.isEmpty)
                const _EmptyState(
                  icon: Icons.travel_explore,
                  text: '还没有规律。\n多和男主聊天，管家会慢慢发现你的情绪规律。',
                ),
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
                  '手动添加规律',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: () => _showAddPatternDialog(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showAddPatternDialog(BuildContext context) {
    final keywordsCtrl = TextEditingController();
    final angerCtrl = TextEditingController();
    final sadCtrl = TextEditingController();
    final joyCtrl = TextEditingController();
    final attachCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '添加规律',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '关键词（至少2个，用空格或逗号分开）',
                style: TextStyle(fontSize: 12, color: Color(0xFF6A4A5A)),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: keywordsCtrl,
                decoration: _inputDeco('例：加班 累'),
              ),
              const SizedBox(height: 14),
              const Text(
                '情绪偏移（0~100，可留空）',
                style: TextStyle(fontSize: 12, color: Color(0xFF6A4A5A)),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: angerCtrl,
                      keyboardType: TextInputType.number,
                      decoration: _inputDeco('愤怒 +'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: sadCtrl,
                      keyboardType: TextInputType.number,
                      decoration: _inputDeco('悲伤 +'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: joyCtrl,
                      keyboardType: TextInputType.number,
                      decoration: _inputDeco('喜悦 +'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: attachCtrl,
                      keyboardType: TextInputType.number,
                      decoration: _inputDeco('依恋 +'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Color(0xFF6A4A5A))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              final keywords = keywordsCtrl.text
                  .split(RegExp(r'[\s,，、]+'))
                  .where((k) => k.isNotEmpty)
                  .toList();
              if (keywords.length < 2) {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(const SnackBar(content: Text('至少输入 2 个关键词')));
                return;
              }
              final shifts = <String, double>{};
              void addShift(String key, String raw) {
                final v = double.tryParse(raw.trim());
                if (v != null && v != 0) shifts[key] = v;
              }

              addShift('愤怒', angerCtrl.text);
              addShift('悲伤', sadCtrl.text);
              addShift('喜悦', joyCtrl.text);
              addShift('依恋', attachCtrl.text);

              engine.addManualPattern(
                keywords,
                shifts: shifts.isEmpty ? null : shifts,
              );
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已添加规律：${keywords.join('+')}')),
              );
            },
            child: const Text(
              '添加',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDeco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 12,
        color: Color(0xFF6A4A5A).withValues(alpha: 0.3),
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

class _PatternCard extends StatelessWidget {
  final PatternStats pattern;
  final PatternEngine engine;

  const _PatternCard({required this.pattern, required this.engine});

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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        pattern.keywords.join(' + '),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF5A4A52),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (pattern.source == 'manual')
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFFC896B4,
                          ).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '手动',
                          style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFFC896B4),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  _emotionText(pattern),
                  style: TextStyle(
                    fontSize: 12,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '命中 ${pattern.count} 次 · 置信度 ${(pattern.confidence * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.35),
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
            tooltip: '删除规律',
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
    );
  }

  String _emotionText(PatternStats p) {
    final parts = <String>[];
    if (p.shiftAnger.abs() > 5) parts.add('愤怒${_fmt(p.shiftAnger)}');
    if (p.shiftSad.abs() > 5) parts.add('悲伤${_fmt(p.shiftSad)}');
    if (p.shiftJoy.abs() > 5) parts.add('喜悦${_fmt(p.shiftJoy)}');
    if (p.shiftAttachment.abs() > 5) parts.add('依恋${_fmt(p.shiftAttachment)}');
    if (parts.isEmpty) return '无明显情绪偏移';
    return '→ ${parts.join('、')}';
  }

  String _fmt(double v) =>
      v > 0 ? '+${v.toStringAsFixed(0)}' : v.toStringAsFixed(0);

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '删除这条规律？',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: Text(
          '「${pattern.keywords.join(' + ')}」\n删掉后管家不会再按它预测你的情绪。',
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
              engine.deletePattern(pattern.comboKey);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('规律已删除')));
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
}

class _PendingPatternCard extends StatelessWidget {
  final PatternStats pattern;

  const _PendingPatternCard({required this.pattern});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pattern.keywords.join(' + '),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF5A4A52),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '命中 ${pattern.count} 次 · 再聊聊就能确认',
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.hourglass_top,
            color: const Color(0xFF5A4A52).withValues(alpha: 0.25),
            size: 18,
          ),
        ],
      ),
    );
  }
}

// ==================== 记忆 Tab ====================

class _MemoryTab extends StatefulWidget {
  final ButlerModuleHub hub;

  const _MemoryTab({required this.hub});

  @override
  State<_MemoryTab> createState() => _MemoryTabState();
}

class _MemoryTabState extends State<_MemoryTab> {
  late Future<void> _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  Future<void> _load() async {
    final manager = widget.hub.sharedMemoryManager!;
    await manager.loadFromStore();
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.hub.sharedMemoryManager!;
    final memories = manager.getAll();

    return Column(
      children: [
        Expanded(
          child: FutureBuilder<void>(
            future: _loadFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: CircularProgressIndicator(color: Color(0xFFC896B4)),
                );
              }
              if (memories.isEmpty) {
                return const _EmptyState(
                  icon: Icons.book_outlined,
                  text: '还没有记忆。\n男主记住你的事会显示在这里。',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                itemCount: memories.length,
                itemBuilder: (context, i) {
                  final m = memories[i];
                  return _MemoryCard(
                    memory: m,
                    onChanged: () => setState(() {}),
                  );
                },
              );
            },
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
                  '添加记忆',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: () => _showAddDialog(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showAddDialog() {
    final actionCtrl = TextEditingController();
    final withWhomCtrl = TextEditingController();
    final timeCtrl = TextEditingController();
    final feelingCtrl = TextEditingController();
    final categoryCtrl = TextEditingController(text: '日常');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '添加记忆',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: actionCtrl, decoration: _deco('做了什么（必填）')),
              const SizedBox(height: 8),
              TextField(controller: withWhomCtrl, decoration: _deco('和谁（可选）')),
              const SizedBox(height: 8),
              TextField(
                controller: timeCtrl,
                decoration: _deco('什么时间（可选，如"上周"）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: feelingCtrl,
                decoration: _deco('感受（可选，如"很开心"）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: categoryCtrl,
                decoration: _deco('分类（默认"日常"）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Color(0xFF6A4A5A))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              final action = actionCtrl.text.trim();
              if (action.isEmpty) {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(const SnackBar(content: Text('"做了什么"不能为空')));
                return;
              }
              final tags = <String>[
                if (withWhomCtrl.text.trim().isNotEmpty)
                  withWhomCtrl.text.trim(),
                if (timeCtrl.text.trim().isNotEmpty) timeCtrl.text.trim(),
                categoryCtrl.text.trim(),
              ];
              final memory = UserMemory(
                id: 'm_${DateTime.now().millisecondsSinceEpoch}',
                withWhom: withWhomCtrl.text.trim().isEmpty
                    ? null
                    : withWhomCtrl.text.trim(),
                time: timeCtrl.text.trim().isEmpty
                    ? null
                    : timeCtrl.text.trim(),
                action: action,
                feeling: feelingCtrl.text.trim().isEmpty
                    ? null
                    : feelingCtrl.text.trim(),
                category: categoryCtrl.text.trim().isEmpty
                    ? '日常'
                    : categoryCtrl.text.trim(),
                tags: tags,
                isUserCreated: true,
              );
              widget.hub.sharedMemoryManager!.add(memory);
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
    );
  }

  InputDecoration _deco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 12,
        color: Color(0xFF6A4A5A).withValues(alpha: 0.3),
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

class _MemoryCard extends StatelessWidget {
  final UserMemory memory;
  final VoidCallback onChanged;

  const _MemoryCard({required this.memory, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  memory.toSentence(),
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Color(0xFF5A4A52),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      memory.category,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFFC896B4),
                      ),
                    ),
                    if (memory.isUserCreated) ...[
                      const SizedBox(width: 6),
                      const Text(
                        '手动',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFFC896B4),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.edit_outlined,
              color: const Color(0xFF6A4A5A).withValues(alpha: 0.4),
              size: 18,
            ),
            tooltip: '编辑',
            onPressed: () => _showEditDialog(context),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline,
              color: Color(0xFFE07A7A),
              size: 20,
            ),
            tooltip: '删除',
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context) {
    final actionCtrl = TextEditingController(text: memory.action);
    final withWhomCtrl = TextEditingController(text: memory.withWhom ?? '');
    final timeCtrl = TextEditingController(text: memory.time ?? '');
    final feelingCtrl = TextEditingController(text: memory.feeling ?? '');
    final categoryCtrl = TextEditingController(text: memory.category);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '编辑记忆',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: actionCtrl, decoration: _deco('做了什么')),
              const SizedBox(height: 8),
              TextField(controller: withWhomCtrl, decoration: _deco('和谁')),
              const SizedBox(height: 8),
              TextField(controller: timeCtrl, decoration: _deco('什么时间')),
              const SizedBox(height: 8),
              TextField(controller: feelingCtrl, decoration: _deco('感受')),
              const SizedBox(height: 8),
              TextField(controller: categoryCtrl, decoration: _deco('分类')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Color(0xFF6A4A5A))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC896B4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              // 使用 manager 的 update 方法
              final manager = _managerOf(context);
              manager.update(
                memory.id,
                withWhom: withWhomCtrl.text.trim().isEmpty
                    ? null
                    : withWhomCtrl.text.trim(),
                time: timeCtrl.text.trim().isEmpty
                    ? null
                    : timeCtrl.text.trim(),
                action: actionCtrl.text.trim(),
                feeling: feelingCtrl.text.trim().isEmpty
                    ? null
                    : feelingCtrl.text.trim(),
                category: categoryCtrl.text.trim().isEmpty
                    ? '日常'
                    : categoryCtrl.text.trim(),
              );
              Navigator.pop(ctx);
              onChanged();
            },
            child: const Text(
              '保存',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // 通过 context 找到 hub（从 _MemoryTab 传下来的方式）
  UserMemoryManager _managerOf(BuildContext context) {
    // 找 _MemoryTabState 持有的 hub
    final tabState = context.findAncestorStateOfType<_MemoryTabState>();
    return tabState!.widget.hub.sharedMemoryManager!;
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '删除这条记忆？',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: Text(
          '「${memory.toSentence()}」\n删除后男主就记不得这件事了。',
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
              _managerOf(context).delete(memory.id);
              Navigator.pop(ctx);
              onChanged();
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

  InputDecoration _deco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 12,
        color: Color(0xFF6A4A5A).withValues(alpha: 0.3),
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

// ==================== 公共组件 ====================

class _HintCard extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HintCard({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFC896B4).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFC896B4), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Color(0xFF5A4A52),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final String type;

  const _SectionTitle(this.text, this.type);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: type == 'confirmed'
              ? const Color(0xFFC896B4)
              : const Color(0xFF5A4A52).withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(
          children: [
            Icon(
              icon,
              size: 48,
              color: const Color(0xFFC896B4).withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
