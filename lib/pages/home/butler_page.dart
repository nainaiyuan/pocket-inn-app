import 'package:flutter/material.dart';

import '../../ai_provider/ai_provider_manager.dart';
import '../../butler/modules/butler_module_hub.dart';
import '../ai_config_page.dart';
import '../butler_modules_page.dart';
import '../butler_task_page.dart';
import '../debug/debug_toolbox_page.dart';
import '../mood_analysis_page.dart';
import '../pattern_memory_page.dart';

/// 管家中心（设置中心）：分类分区版。
///
/// 8-07 00:49 用户：原来 6 个入口平铺（"啥都堆在一起，一个框一个框"），
/// 要求分类放好、方便看、好看，任务入口突出。
/// 分区：💗 情绪与记忆 / 📋 任务与流程 / 🤖 AI 与管家模块 / 🔧 诊断与排查
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
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
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
                    '情绪 · 记忆 · 任务 · AI · 排查，分好类了，慢慢逛',
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
                  // ================= 💗 情绪与记忆 =================
                  const _SectionHeader(
                    icon: Icons.favorite_outline,
                    title: '情绪与记忆',
                    color: Color(0xFFC896B4),
                  ),
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
                    subtitle: '管家发现的情绪规律 + 男主记住的事，可看可改',
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PatternMemoryPage(
                          hub: ButlerModuleHub.instance,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ================= 📋 任务与流程 =================
                  const _SectionHeader(
                    icon: Icons.task_alt_outlined,
                    title: '任务与流程',
                    color: Color(0xFF8FB8D8),
                  ),
                  _EntryCard(
                    icon: Icons.task_alt_outlined,
                    iconColor: const Color(0xFF8FB8D8),
                    title: '任务',
                    subtitle: '创建任务 · 待处理 / 进行中 / 已完成，管家帮你做的事都在这',
                    onTap: (context) => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ButlerTaskPage()),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ================= 🤖 AI 与管家模块 =================
                  const _SectionHeader(
                    icon: Icons.hub_outlined,
                    title: 'AI 与管家模块',
                    color: Color(0xFFA8D0A8),
                  ),
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
                  const SizedBox(height: 18),

                  // ================= 🔧 诊断与排查 =================
                  const _SectionHeader(
                    icon: Icons.build_circle_outlined,
                    title: '诊断与排查',
                    color: Color(0xFFD8A8C8),
                  ),
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

/// 分区标题：左侧竖条 + 图标 + 文字（8-07 00:49 用户：分类放好、方便看）
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.color,
  });

  final IconData icon;
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: const Color(0xFF5A4A52).withValues(alpha: 0.75),
            ),
          ),
        ],
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
      color: Colors.white.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(18),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap == null ? null : () => onTap!(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: iconColor.withValues(alpha: 0.18),
            ),
            boxShadow: [
              BoxShadow(
                color: iconColor.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: iconColor.withValues(alpha: 0.15),
                  ),
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
                          height: 1.4,
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
