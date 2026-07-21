import 'package:flutter/material.dart';

/// 加号菜单 —— 功能区入口（可滑动的横向功能卡片）
class PlusMenu extends StatelessWidget {
  final VoidCallback onDismiss;
  final VoidCallback? onPickAvatar;
  final VoidCallback? onPickBg;
  final VoidCallback? onPickPhoto;

  const PlusMenu({
    super.key,
    required this.onDismiss,
    this.onPickAvatar,
    this.onPickBg,
    this.onPickPhoto,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      child: Container(
        color: Colors.black.withValues(alpha: 0.15),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () {},
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
                            color: const Color(0xFFC8D4E8),
                            onTap: () {
                              onDismiss();
                              onPickBg?.call();
                            },
                          ),
                          _MenuItem(
                            icon: Icons.portrait_outlined,
                            label: '换头像',
                            color: const Color(0xFFE8C8D8),
                            onTap: () {
                              onDismiss();
                              onPickAvatar?.call();
                            },
                          ),
                          _MenuItem(
                            icon: Icons.photo_camera_outlined,
                            label: '拍照',
                            color: const Color(0xFFC8E8D4),
                            onTap: () {
                              onDismiss();
                              // TODO: 调用相机
                            },
                          ),
                          _MenuItem(
                            icon: Icons.photo_library_outlined,
                            label: '相册',
                            color: const Color(0xFFE8E0C8),
                            onTap: () {
                              onDismiss();
                              onPickPhoto?.call();
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
  final Color color;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: const Color(0xFF6A4A5A)),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: Color(0xFF6A4A5A)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
