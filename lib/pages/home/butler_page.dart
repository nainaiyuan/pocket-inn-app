import 'package:flutter/material.dart';

import '../../ai_provider/ai_provider_manager.dart';
import '../../butler/modules/butler_module_hub.dart';
import '../ai_config_page.dart';
import '../butler_modules_page.dart';
import '../butler_task_page.dart';
import '../debug/debug_toolbox_page.dart';
import '../mood_analysis_page.dart';
import '../pattern_memory_page.dart';

/// 管家页面（设置中心）：AI 配置入口 + 管家能力卡片。
class ButlerPage extends StatelessWidget {
  const ButlerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFFFDF7F9),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '管家中心',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2,
                      color: const Color(0xFF6A4A5A).withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'AI 配置 · 情绪分析 · 规律 · 日志 · 记忆 · 任务',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 1,
                      color: const Color(0xFF5A4A52).withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  // ---- AI 配置（主入口）----
                  _EntryCard(
                    icon: Icons.hub_outlined,
                    iconColor: const Color(0xFFA8D0A8),
                    title: 'AI 配置',
                    subtitleBuilder: (context) => ValueListenableBuilder<int>(
                      valueListenable: AIProviderManager.instance.changeNotifier,
                      builder: (context, _, __) {
                        final manager = AIProviderManager.instance;
                        final usable = manager.usableProviderNames(null);
                        if (usable.isEmpty) {
                          return const Text(
                            '⚠️ 还没有可用的 AI，点这里配置',
                            style: TextStyle(color: Color(0xFFE07A7A), fontSize: 12),
                          );
                        }
                        return Text(
                          '可用：${usable.join('、')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
                          ),
                        );
                      },
                    ),
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AiConfigPage()),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ---- 管家模块（真功能）----
                  _EntryCard(
                    icon: Icons.widgets_outlined,
                    iconColor: const Color(0xFFC896B4),
                    title: '管家模块',
                    subtitleBuilder: (context) {
                      final hub = ButlerModuleHub.instance;
                      final modules = hub.registry.all;
                      final activeCount =
                          modules.where((m) => m.isActive).length;
                      return Text(
                        '$activeCount/${modules.length} 个模块运行中：'
                        '${modules.map((m) => m.name).join('、')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
                        ),
                      );
                    },
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ButlerModulesPage(
                          hub: ButlerModuleHub.instance,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ---- 管家能力（占位）----
                  _EntryCard(
                    icon: Icons.auto_awesome_outlined,
                    iconColor: const Color(0xFFC896B4),
                    title: '情感基线',
                    subtitle: '你的整体情绪状态、月度趋势、触发因素',
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const MoodAnalysisPage()),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _EntryCard(
                    icon: Icons.route_outlined,
                    iconColor: const Color(0xFFC8A8D8),
                    title: '规律与记忆',
                    subtitleBuilder: (context) {
                      return Text(
                        '管家发现的情绪规律 + 男主记住的事，可看可改',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.5),
                        ),
                      );
                    },
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PatternMemoryPage(
                          hub: ButlerModuleHub.instance,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _EntryCard(
                    icon: Icons.task_alt_outlined,
                    iconColor: const Color(0xFFA0C8E0),
                    title: '任务',
                    subtitle: '管家帮你做的事（温控、关键词收集等）',
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ButlerTaskPage()),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ---- 调试工具箱（8-04：所有测 bug 工具集中在这里）----
                  _EntryCard(
                    icon: Icons.build_circle_outlined,
                    iconColor: const Color(0xFFD8A8C8),
                    title: '调试工具箱',
                    subtitle: '日志、API 记录、一键自检、AI 能力检测…全在这',
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const DebugToolboxPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.subtitleBuilder,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget Function(BuildContext)? subtitleBuilder;
  final void Function(BuildContext)? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap == null ? null : () => onTap!(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF5A4A52),
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (subtitleBuilder != null)
                      subtitleBuilder!(context)
                    else if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.45),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
