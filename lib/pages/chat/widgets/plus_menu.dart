import 'package:flutter/material.dart';

/// [+] 弹出菜单
///
/// 背景图  | 换头像
/// ───────┼───────
/// 相册   | 表情包
/// 红包   | 打电话
class PlusMenu extends StatelessWidget {
  final VoidCallback onDismiss;

  const PlusMenu({
    super.key,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 半透明遮罩
        GestureDetector(
          onTap: onDismiss,
          child: Container(color: Colors.transparent),
        ),
        // 菜单
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + 70,
          right: 16,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                ),
              ),
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _MenuItem(
                          icon: Icons.wallpaper_outlined,
                          label: '背景图',
                          onTap: () {
                            onDismiss();
                            // TODO: 设置聊天背景
                          },
                        ),
                        const SizedBox(width: 8),
                        _MenuItem(
                          icon: Icons.portrait_outlined,
                          label: '换头像',
                          onTap: () {
                            onDismiss();
                            // TODO: 换男主头像
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _MenuItem(
                          icon: Icons.photo_library_outlined,
                          label: '相册',
                          onTap: () {
                            onDismiss();
                            // TODO: 打开相册
                          },
                        ),
                        const SizedBox(width: 8),
                        _MenuItem(
                          icon: Icons.emoji_emotions_outlined,
                          label: '表情包',
                          onTap: () {
                            onDismiss();
                            // TODO: 打开表情面板
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _MenuItem(
                          icon: Icons.card_giftcard_outlined,
                          label: '红包',
                          onTap: () {
                            onDismiss();
                            // TODO: 发红包
                          },
                        ),
                        const SizedBox(width: 8),
                        _MenuItem(
                          icon: Icons.phone_outlined,
                          label: '打电话',
                          onTap: () {
                            onDismiss();
                            // TODO: 打电话
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
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
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 22,
                color: const Color(0xFFB48296).withValues(alpha: 0.6),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: const Color(0xFF6A4A5A).withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
