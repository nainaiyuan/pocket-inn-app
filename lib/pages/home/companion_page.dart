import 'package:flutter/material.dart';

/// 陪伴页面（3D 男主互动空间占位）
class CompanionPage extends StatelessWidget {
  const CompanionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _FrostPage(
      label: '✦ 陪伴',
      title: '陪伴空间',
      subtitle: '3D 互动 · 未来升级',
      child: _CompanionBody(),
    );
  }
}

class _CompanionBody extends StatelessWidget {
  const _CompanionBody();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      height: 200,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(70).copyWith(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
        color: const Color(0xFFFFC8D2).withValues(alpha: 0.2),
        border: Border.all(
          color: const Color(0xFFFFC8D2).withValues(alpha: 0.25),
        ),
      ),
      child: const Center(
        child: Text(
          '✦ 3D 男主 ✦',
          style: TextStyle(
            color: Color(0xFFB48296),
            fontSize: 11,
            letterSpacing: 3,
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃页面模板
class _FrostPage extends StatelessWidget {
  final String label;
  final String title;
  final String subtitle;
  final Widget child;

  const _FrostPage({
    required this.label,
    required this.title,
    required this.subtitle,
    required this.child,
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
              child,
              const SizedBox(height: 20),
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
