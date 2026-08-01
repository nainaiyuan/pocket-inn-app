import 'package:flutter/material.dart';

import '../../butler/skills/butler_skill.dart';
import '../../butler/skills/butler_skill_registry.dart';
import '../../butler/tools/butler_tool.dart';
import '../../butler/tools/butler_tool_registry.dart';

/// 管家技能库 — 流程/技能总览（独立模块）
///
/// 展示所有已注册技能：每个技能的流程图（步骤链）+ 触发词 + 描述，
/// 以及所有管家工具。以后加技能/加流程，注册后自动出现在这里。
/// 入口：调试日志页 → 「技能库」按钮。
class ButlerSkillLibraryPage extends StatelessWidget {
  const ButlerSkillLibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final skills = ButlerSkillRegistry.instance.all;
    final tools = ButlerToolRegistry.instance.all;

    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        elevation: 0,
        title: const Text(
          '管家技能库',
          style: TextStyle(
            color: Color(0xFF6A4A5A),
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF6A4A5A)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '🧩 技能（遇到相关场景自动触发）',
            style: TextStyle(
              color: Color(0xFF6A4A5A),
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          if (skills.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '暂无技能（初始化管家后自动注册）',
                style: TextStyle(color: Colors.black38, fontSize: 12),
              ),
            )
          else
            for (final skill in skills) _SkillCard(skill: skill),
          const SizedBox(height: 24),
          const Text(
            '🔧 管家工具（模块 = 工具）',
            style: TextStyle(
              color: Color(0xFF6A4A5A),
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          if (tools.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '暂无工具',
                style: TextStyle(color: Colors.black38, fontSize: 12),
              ),
            )
          else
            for (final tool in tools) _ToolCard(tool: tool),
        ],
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  final ButlerSkill skill;

  const _SkillCard({required this.skill});

  @override
  Widget build(BuildContext context) {
    // 技能流程图：触发词 → 步骤链
    final steps = skill.flowSteps;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8D5DE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '🎯 ${skill.name}',
                style: const TextStyle(
                  color: Color(0xFF6A4A5A),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              if (skill.isFallback)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8D5DE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '兜底',
                    style: TextStyle(color: Color(0xFF6A4A5A), fontSize: 10),
                  ),
                )
              else
                Text(
                  '优先级 ${skill.priority}',
                  style: const TextStyle(
                    color: Colors.black38,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            skill.description,
            style: const TextStyle(color: Colors.black54, fontSize: 11),
          ),
          if (!skill.isFallback) ...[
            const SizedBox(height: 8),
            // 流程图（步骤链）
            Row(
              children: [
                const Text(
                  '触发: ',
                  style: TextStyle(color: Colors.black38, fontSize: 10),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final t in skill.triggers)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFDF0F5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            t,
                            style: const TextStyle(
                              color: Color(0xFFC896B4),
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 8),
              // 流程图：步骤节点 + 箭头
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < steps.length; i++) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFDF7F9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE8D5DE)),
                      ),
                      child: Text(
                        steps[i],
                        style: const TextStyle(
                          color: Color(0xFF6A4A5A),
                          fontSize: 10,
                        ),
                      ),
                    ),
                    if (i < steps.length - 1)
                      const Text(
                        '→',
                        style: TextStyle(color: Color(0xFFC896B4), fontSize: 10),
                      ),
                  ],
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  final ButlerTool tool;

  const _ToolCard({required this.tool});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8D5DE)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('🔧 ', style: TextStyle(fontSize: 13)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tool.name,
                  style: const TextStyle(
                    color: Color(0xFF6A4A5A),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tool.description,
                  style: const TextStyle(color: Colors.black45, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
