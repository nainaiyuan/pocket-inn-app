import 'package:flutter/material.dart';

/// 管家页面（设置中心占位）
class ButlerPage extends StatelessWidget {
  const ButlerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _FrostPage(
      label: '✦ 管家',
      title: '管家中心',
      subtitle: '情绪分析 · 规律 · 日志 · 记忆 · 任务',
    );
  }
}

class _FrostPage extends StatelessWidget {
  final String label;
  final String title;
  final String subtitle;

  const _FrostPage({
    required this.label,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey(title),
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.4),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFC896B4).withValues(alpha: 0.08),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 40),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 4,
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 3,
                  color: Color(0xFF6A4A5A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: const Color(0xFF5A4A52).withValues(alpha: 0.35),
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
