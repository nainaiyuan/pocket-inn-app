import 'package:flutter/material.dart';

import '../../butler/modules/butler_module.dart';
import '../../butler/modules/butler_module_hub.dart';
import 'mask_rules_page.dart';
import 'risk_words_page.dart';
import 'system_view_page.dart';

/// 管家模块管理页 — 显示所有模块 + 开关
///
/// 每个模块一行：图标 + 名字 + 说明 + 开关。
/// 开关状态持久化，重启 APP 保持。
class ButlerModulesPage extends StatefulWidget {
  final ButlerModuleHub hub;

  const ButlerModulesPage({super.key, required this.hub});

  @override
  State<ButlerModulesPage> createState() => _ButlerModulesPageState();
}

class _ButlerModulesPageState extends State<ButlerModulesPage> {
  late Future<void> _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = widget.hub.loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '管家模块',
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
      body: FutureBuilder<void>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFC896B4)),
            );
          }
          final modules = widget.hub.registry.all;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              _Header(),
              const SizedBox(height: 12),
              for (final module in modules) ...[
                _ModuleCard(
                  module: module,
                  hub: widget.hub,
                  onChanged: (value) => _toggle(module, value),
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
              _RiskWordsEntry(),
              const SizedBox(height: 8),
              _SystemViewEntry(),
              const SizedBox(height: 8),
              _Note(),
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggle(ButlerModule module, bool value) async {
    setState(() {});
    await widget.hub.setModuleEnabled(module.id, value);
    if (mounted) setState(() {});
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFC896B4).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          Icon(Icons.widgets_outlined, color: Color(0xFFC896B4), size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '模块化管家',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5A4A52),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '每个能力都是独立模块，可以单独开关。\n关掉 = 那个功能完全不起作用。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: Color(0xFF5A4A52),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  final ButlerModule module;
  final ButlerModuleHub hub;
  final ValueChanged<bool> onChanged;

  const _ModuleCard({
    required this.module,
    required this.hub,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final active = module.isActive;
    final canManage = module.id == 'mask';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active
              ? const Color(0xFFC896B4).withValues(alpha: 0.3)
              : Colors.black12,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: canManage
            ? () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => MaskRulesPage(hub: hub)))
            : null,
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _iconColor(module).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_icon(module), color: _iconColor(module), size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        module.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: active
                              ? const Color(0xFF5A4A52)
                              : const Color(0xFF5A4A52).withValues(alpha: 0.4),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _stageLabel(module.stage),
                        style: TextStyle(
                          fontSize: 10,
                          color: const Color(
                            0xFF5A4A52,
                          ).withValues(alpha: 0.35),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    module.description,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: active,
              activeTrackColor: const Color(0xFFC896B4),
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(ButlerModule module) {
    switch (module.id) {
      case 'blocklist':
        return Icons.block_outlined;
      case 'mask':
        return Icons.face_retouching_natural_outlined;
      case 'mood':
        return Icons.sentiment_satisfied_alt_outlined;
      case 'calibrator':
        return Icons.thermostat_outlined;
      default:
        return Icons.extension_outlined;
    }
  }

  static Color _iconColor(ButlerModule module) {
    switch (module.id) {
      case 'blocklist':
        return const Color(0xFFE07A7A);
      case 'mask':
        return const Color(0xFFA8C8E0);
      case 'mood':
        return const Color(0xFFC896B4);
      case 'calibrator':
        return const Color(0xFFE0A060);
      default:
        return const Color(0xFFA0C8A0);
    }
  }

  static String _stageLabel(ButlerModuleStage stage) {
    switch (stage) {
      case ButlerModuleStage.guard:
        return '前置 · 拦截/改写';
      case ButlerModuleStage.analyze:
        return '分析 · 读上下文';
      case ButlerModuleStage.persist:
        return '收尾 · 存记忆';
    }
  }
}

class _RiskWordsEntry extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: const Color(0xFF6A4A5A).withValues(alpha: 0.08),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const RiskWordsPage()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFC896B4).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.privacy_tip_outlined,
                  color: Color(0xFFC896B4),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '敏感词配置',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6A4A5A),
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '自己填敏感词、分类、替换词、冷却时间',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6A4A5A),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFFC896B4),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemViewEntry extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: const Color(0xFF6A4A5A).withValues(alpha: 0.08),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SystemViewPage()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFC896B4).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.article_outlined,
                  color: Color(0xFFC896B4),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '系统提示查看',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6A4A5A),
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '看每次聊天到底带了什么系统信息（模板+人设+注入）',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6A4A5A),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFFC896B4),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        '提示：模块是管家的"零件"。以后每加一个新能力（记忆、规律、碎片……），都会自动出现在这里，随时可以单独开关。',
        style: TextStyle(
          fontSize: 11,
          height: 1.5,
          color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
        ),
      ),
    );
  }
}
