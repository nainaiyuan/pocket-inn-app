import 'package:flutter/material.dart';

/// ✦ 设计感切换按钮 —— 聊天页入口 / 陪伴页切回 共用的同一个组件
///
/// 8-05 23:48 用户：切回来的按钮也要和入口那个好看的一样 →
/// 抽成共享组件，两处完全一致（尺寸/渐变/阴影/图标全统一）。
class CompanionToggleButton extends StatelessWidget {
  final VoidCallback onTap;

  const CompanionToggleButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFD9A0C0), Color(0xFFC896B4)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFC896B4).withValues(alpha: 0.30),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(
          Icons.auto_awesome,
          size: 19,
          color: Colors.white,
        ),
      ),
    );
  }
}
