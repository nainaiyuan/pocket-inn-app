import 'package:flutter/material.dart';

import '../butler/risk_filter_wordlist.dart';
import '../butler/risk_word_store.dart';
import '../services/chat_character_resolver.dart' show ChatCharacterResolver;

/// 敏感词管理页 — 用户可配置的敏感词表
///
/// - 预置词（爸爸/妈妈等测试词 + 动作/身体词）：可删可改
/// - 每个词可设：分类（辅助判定）、强度（hard/soft）、替换词、冷却分钟
/// - 白名单：命中词被覆盖时不触发（"亲爱的"里的"亲"）
/// - 存储：SharedPreferences（删了真删）
class RiskWordsPage extends StatefulWidget {
  const RiskWordsPage({super.key});

  @override
  State<RiskWordsPage> createState() => _RiskWordsPageState();
}

class _RiskWordsPageState extends State<RiskWordsPage> {
  List<RiskWord> _words = [];
  List<String> _exceptions = [];
  bool _loading = true;
  bool _enabled = true;
  List<_CharToggle> _characters = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final words = await RiskWordStore.instance.loadWords();
    final exceptions = await RiskWordStore.instance.loadExceptions();
    final enabled = RiskWordStore.instance.cachedEnabled;
    // 加载所有男主（每男主一个开关：本地 AI 男主可关闭屏蔽）
    final chars = <_CharToggle>[];
    try {
      for (final c in await ChatCharacterResolver.instance.loadAllOptions()) {
        chars.add(
          _CharToggle(
            id: c.id,
            name: c.name,
            disabled: RiskWordStore.instance.isCharacterDisabled(c.id),
          ),
        );
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _words = words;
        _exceptions = exceptions;
        _enabled = enabled;
        _characters = chars;
        _loading = false;
      });
    }
  }

  /// 开关区：全局启用 + 每男主开关 + 固定格式说明
  Widget _buildToggleSection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF6A4A5A).withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            activeTrackColor: const Color(0xFFC896B4),
            title: const Text(
              '启用敏感词屏蔽',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6A4A5A),
              ),
            ),
            subtitle: const Text(
              '关闭后所有男主都不做敏感词判定（固定格式仍检测）',
              style: TextStyle(fontSize: 11, color: Color(0xFF6A4A5A)),
            ),
            onChanged: (v) async {
              await RiskWordStore.instance.setEnabled(v);
              if (mounted) setState(() => _enabled = v);
            },
          ),
          const Divider(height: 12, color: Color(0xFFF0E4EA)),
          if (_characters.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '还没有男主，聊天后这里会出现每个男主的开关',
                style: TextStyle(fontSize: 11, color: Color(0xFF6A4A5A)),
              ),
            )
          else
            ..._characters.map(
              (c) => SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: !c.disabled,
                activeTrackColor: const Color(0xFFC896B4),
                title: Text(
                  c.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6A4A5A),
                  ),
                ),
                subtitle: const Text(
                  '本地 AI 男主可关掉（不需要屏蔽词）',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6A4A5A)),
                ),
                onChanged: (v) async {
                  await RiskWordStore.instance
                      .setCharacterDisabled(c.id, !v);
                  if (mounted) {
                    setState(() {
                      c.disabled = !v;
                    });
                  }
                },
              ),
            ),
          const SizedBox(height: 4),
          const Text(
            '疑似敏感格式（手机号/身份证/银行卡/邮箱/11位以上长数字）：不受以上开关'
            '影响，任何男主发送前都会弹窗问"发不发、记不记"，默认不发送（本地不记录原文）',
            style: TextStyle(fontSize: 11, height: 1.5, color: Color(0xFF6A4A5A)),
          ),
          const SizedBox(height: 4),
          const Text(
            '注意：家人称呼（如爸爸/妈妈）若已在假面层配置为身份，会先被假面层替换成代号'
            '（如 [family1]），敏感词不生效；男主被要求念出代号时会直接念真实称呼'
            '（参考信息里每轮都有代号对应的身份说明）',
            style: TextStyle(fontSize: 11, height: 1.5, color: Color(0xFF6A4A5A)),
          ),
        ],
      ),
    );
  }

  Future<void> _save(List<RiskWord> words) async {
    await RiskWordStore.instance.saveWords(words);
    if (mounted) setState(() => _words = List.of(words));
  }

  void _confirmDelete(RiskWord w) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDF7F9),
        title: const Text(
          '删除敏感词',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
        content: Text('确定删除"${w.word}"吗？删了之后这个词不再触发挖空。'),
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
              backgroundColor: const Color(0xFFE07A7A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _save(_words.where((x) => x.word != w.word).toList());
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showAddDialog() {
    final wordCtrl = TextEditingController();
    final replCtrl = TextEditingController();
    String category = '亲密';
    String kind = 'hard';
    int coolDown = 10;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFFFDF7F9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            '添加敏感词',
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
                    controller: wordCtrl,
                    decoration: _deco('敏感词（如：亲 / 爸爸 / 前任）'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: _deco('分类（辅助判定）'),
                    items: const [
                      DropdownMenuItem(value: '亲密', child: Text('亲密')),
                      DropdownMenuItem(value: '身体', child: Text('身体')),
                      DropdownMenuItem(value: '家人', child: Text('家人')),
                      DropdownMenuItem(value: '脏话', child: Text('脏话')),
                      DropdownMenuItem(value: '其他', child: Text('其他')),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => category = v ?? '亲密'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: kind,
                    decoration: _deco('强度'),
                    items: const [
                      DropdownMenuItem(
                        value: 'severe',
                        child: Text('最高敏（任何场景都挖，求知也不放）'),
                      ),
                      DropdownMenuItem(
                        value: 'hard',
                        child: Text('强（需公式强度达标，求知可放）'),
                      ),
                      DropdownMenuItem(value: 'soft', child: Text('弱（需搭配或浓度达标）')),
                    ],
                    onChanged: (v) => setDialogState(() => kind = v ?? 'hard'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int>(
                    initialValue: coolDown,
                    decoration: _deco('持续窗口（聊到该词后多久算持续中，强度+1）'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('0 分钟（不累计持续时间）')),
                      DropdownMenuItem(value: 5, child: Text('5 分钟')),
                      DropdownMenuItem(value: 10, child: Text('10 分钟')),
                      DropdownMenuItem(value: 30, child: Text('30 分钟')),
                      DropdownMenuItem(value: 60, child: Text('60 分钟')),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => coolDown = v ?? 10),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: replCtrl,
                    decoration: _deco(
                      '替换词（可选）——填了就直接替换成这个词；不填就挖空成 [PRIVACY_MARK]',
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
                final word = wordCtrl.text.trim();
                if (word.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('先填敏感词')),
                  );
                  return;
                }
                if (_words.any((x) => x.word == word)) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('这个词已经在了')),
                  );
                  return;
                }
                final repl = replCtrl.text.trim();
                Navigator.pop(ctx);
                _save([
                  ..._words,
                  RiskWord(
                    word,
                    kind: kind,
                    category: category,
                    replacement: repl.isEmpty ? null : repl,
                    coolDownMinutes: coolDown,
                  ),
                ]);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  void _showExceptionsDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFFFDF7F9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            '白名单（例外词组）',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A4A5A),
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '敏感词在这些词组里出现时不触发挖空（如"亲爱的"里的"亲"）。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6A4A5A)),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in _exceptions)
                      Chip(
                        label: Text(e),
                        backgroundColor: const Color(0xFFF1E3EA),
                        deleteIcon: defaultExceptions.contains(e)
                            ? null
                            : const Icon(Icons.close, size: 14),
                        onDeleted: defaultExceptions.contains(e)
                            ? null
                            : () async {
                                await RiskWordStore.instance
                                    .removeException(e);
                                if (ctx.mounted) {
                                  setDialogState(() {
                                    _exceptions = RiskWordStore
                                        .instance.cachedExceptions;
                                  });
                                }
                              },
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrl,
                  decoration: _deco('加白名单词组（如：亲爱的）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                '完成',
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
              onPressed: () async {
                final p = ctrl.text.trim();
                if (p.isEmpty) return;
                await RiskWordStore.instance.addException(p);
                if (ctx.mounted) {
                  setDialogState(() {
                    _exceptions = RiskWordStore.instance.cachedExceptions;
                    ctrl.clear();
                  });
                }
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        foregroundColor: const Color(0xFF6A4A5A),
        elevation: 0,
        title: const Text(
          '敏感词',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFC896B4)),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '聊到敏感词时挖空成 [PRIVACY_MARK]，男主理解情绪、不脑补内容。'
                          '综合公式判定：词强度+情感浓度+基线偏离+持续时间+话题浓度-求知，'
                          '≥5 直接屏蔽、3-4 弹窗问你、<3 放行；最高敏词任何场景都挖。',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: const Color(0xFF6A4A5A)
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _showExceptionsDialog,
                        child: const Text(
                          '白名单',
                          style: TextStyle(
                            color: Color(0xFFC896B4),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // ---- 开关：全局 + 按男主 ----
                _buildToggleSection(),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    itemCount: _words.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '共 ${_words.length} 个敏感词',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF6A4A5A),
                                  ),
                                ),
                              ),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFC896B4),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: _showAddDialog,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加敏感词'),
                              ),
                            ],
                          ),
                        );
                      }
                      final w = _words[i - 1];
                      return Card(
                        color: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: const Color(0xFF6A4A5A)
                                .withValues(alpha: 0.08),
                          ),
                        ),
                        child: ListTile(
                          title: Text(
                            w.word,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF6A4A5A),
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                _tag(w.category),
                                _tag(w.isHard ? '强' : '弱'),
                                _tag(
                                  w.replacement != null
                                      ? '替换：${w.replacement}'
                                      : '挖空',
                                ),
                                if (w.isSevere) _tag('最高敏'),
                                _tag('持续 ${w.coolDownMinutes}分'),
                              ],
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Color(0xFFE07A7A),
                            ),
                            onPressed: () => _confirmDelete(w),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF1E3EA),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Color(0xFF6A4A5A)),
      ),
    );
  }

  InputDecoration _deco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 13,
        color: const Color(0xFF6A4A5A).withValues(alpha: 0.45),
      ),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}

/// 男主开关项（每男主：是否关闭敏感词屏蔽）
class _CharToggle {
  final String id;
  final String name;
  bool disabled;

  _CharToggle({required this.id, required this.name, required this.disabled});
}
