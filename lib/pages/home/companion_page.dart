import 'package:flutter/material.dart';

/// 陪伴页面
///
/// 3D 男主互动空间（未来用 Unity 嵌入）
/// 当前为占位页面
class CompanionPage extends StatelessWidget {
  const CompanionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFFFD6E0).withValues(alpha: 0.3),
            const Color(0xFFD6C8E8).withValues(alpha: 0.15),
          ],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),

          // 立绘占位
          Container(
            width: 160,
            height: 240,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(80).copyWith(
                bottomLeft: Radius.circular(28),
                bottomRight: Radius.circular(28),
              ),
              color: const Color(0xFFFFC8D2).withValues(alpha: 0.15),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFE8A0B8).withValues(alpha: 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                Icons.auto_awesome_outlined,
                size: 48,
                color: const Color(0xFFB48296).withValues(alpha: 0.25),
              ),
            ),
          ),

          const SizedBox(height: 24),

          Text(
            '✦ 陪伴空间 ✦',
            style: TextStyle(
              fontSize: 15,
              letterSpacing: 4,
              color: const Color(0xFF6A4A5A).withValues(alpha: 0.4),
            ),
          ),

          const SizedBox(height: 8),

          Text(
            '3D 互动世界',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              color: const Color(0xFF5A4A52).withValues(alpha: 0.2),
            ),
          ),

          const Spacer(),

          // 底部提示
          Text(
            '未来将嵌入 Unity 3D 引擎',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              color: const Color(0xFF5A4A52).withValues(alpha: 0.12),
            ),
          ),

          const SizedBox(height: 100),
        ],
      ),
    );
  }
}
