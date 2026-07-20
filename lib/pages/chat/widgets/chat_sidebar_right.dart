import 'package:flutter/material.dart';

/// 右滑侧边栏 —— 当前角色设置
///
/// API密钥 → 设备开关 → Prompt编辑区 → 屏蔽词
class ChatSidebarRight extends StatefulWidget {
  const ChatSidebarRight({super.key});

  @override
  State<ChatSidebarRight> createState() => _ChatSidebarRightState();
}

class _ChatSidebarRightState extends State<ChatSidebarRight> {
  final _promptCtrl = TextEditingController();

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF5F0F2),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 56),

            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    '设置',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6A4A5A).withValues(alpha: 0.6),
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 设置列表
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  // API密钥
                  _SectionCard(
                    title: 'API 密钥',
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.vpn_key_outlined,
                            size: 18,
                            color: const Color(0xFFB48296).withValues(alpha: 0.4),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '未设置',
                              style: TextStyle(
                                fontSize: 14,
                                color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: const Color(0xFF5A4A52).withValues(alpha: 0.15),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 设备开关
                  _SectionCard(
                    title: '设备连接',
                    child: Column(
                      children: [
                        _SwitchTile(label: '小玩具', value: false),
                        _SwitchTile(label: '智能家居', value: false),
                        _SwitchTile(label: '机器人', value: false),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Prompt编辑区
                  _SectionCard(
                    title: '角色设定',
                    child: Container(
                      height: 160,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _promptCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: '在这里自由书写男主的设定…\n管家会帮你整理分类',
                          hintStyle: TextStyle(
                            color: const Color(0xFF5A4A52).withValues(alpha: 0.12),
                            fontSize: 13,
                            height: 1.5,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: TextStyle(
                          fontSize: 13,
                          color: const Color(0xFF5A4A52).withValues(alpha: 0.7),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 屏蔽词
                  _SectionCard(
                    title: '屏蔽词',
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.shield_outlined,
                            size: 18,
                            color: const Color(0xFFB48296).withValues(alpha: 0.4),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '未设置屏蔽词',
                              style: TextStyle(
                                fontSize: 14,
                                color: const Color(0xFF5A4A52).withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: const Color(0xFF5A4A52).withValues(alpha: 0.15),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置分区卡片
class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF6A4A5A).withValues(alpha: 0.5),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// 开关行
class _SwitchTile extends StatelessWidget {
  final String label;
  final bool value;

  const _SwitchTile({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            Icons.circle_outlined,
            size: 14,
            color: const Color(0xFFB48296).withValues(alpha: 0.3),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: const Color(0xFF5A4A52).withValues(alpha: 0.6),
              ),
            ),
          ),
          Container(
            width: 40,
            height: 22,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              color: value
                  ? const Color(0xFFE8A0B8).withValues(alpha: 0.4)
                  : const Color(0xFF5A4A52).withValues(alpha: 0.08),
            ),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  left: value ? 20 : 2,
                  top: 2,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
