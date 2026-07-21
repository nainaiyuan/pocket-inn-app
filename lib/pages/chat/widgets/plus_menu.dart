import 'package:flutter/material.dart';

/// 加号菜单 —— 功能区入口
class PlusMenu extends StatelessWidget {
  final VoidCallback onDismiss;
  final VoidCallback? onPickAvatar;

  const PlusMenu({
    super.key,
    required this.onDismiss,
    this.onPickAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      child: Container(
        color: Colors.black.withValues(alpha: 0.15),
        child: Stack(
          children: [
            // 菜单卡片
            Align(
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () {}, // 阻止透传
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDF8FA),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _MenuItem(
                            icon: Icons.image_outlined,
                            label: '背景',
                            onTap: () {
                              onDismiss();
                            },
                          ),
                          _MenuItem(
                            icon: Icons.portrait_outlined,
                            label: '换头像',
                            onTap: () {
                              onDismiss();
                              onPickAvatar?.call();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF0E8EC).withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: const Color(0xFF6A4A5A)),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6A4A5A)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
