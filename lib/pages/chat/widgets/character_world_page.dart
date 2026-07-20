import 'package:flutter/material.dart';
import '../../../models/male_lead.dart';

/// 男主的小世界 —— 点头像进入
///
/// 藏起来的彩蛋：日记、约定、故事
class CharacterWorldPage extends StatelessWidget {
  final MaleLead lead;
  final Persona persona;

  const CharacterWorldPage({
    super.key,
    required this.lead,
    required this.persona,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F0F2),
      body: SafeArea(
        child: Column(
          children: [
            // 头顶返回+名字
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: const Color(0xFF6A4A5A).withValues(alpha: 0.4),
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  Text(
                    '${lead.name}的小世界',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6A4A5A).withValues(alpha: 0.6),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 内容卡片
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  _WorldCard(
                    icon: Icons.menu_book_rounded,
                    title: '日记',
                    subtitle: '${lead.name}视角记录的日常',
                    color: const Color(0xFFE8A0B8),
                  ),
                  const SizedBox(height: 12),
                  _WorldCard(
                    icon: Icons.favorite_outline_rounded,
                    title: '约定',
                    subtitle: '你们之间的约定和承诺',
                    color: const Color(0xFFC8A8D8),
                  ),
                  const SizedBox(height: 12),
                  _WorldCard(
                    icon: Icons.auto_stories_rounded,
                    title: '故事',
                    subtitle: '属于你们的故事集',
                    color: const Color(0xFFA8C8D8),
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

class _WorldCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  const _WorldCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.1),
            ),
            child: Icon(
              icon,
              color: color.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6A4A5A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: const Color(0xFF5A4A52).withValues(alpha: 0.25),
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: const Color(0xFF5A4A52).withValues(alpha: 0.15),
          ),
        ],
      ),
    );
  }
}
