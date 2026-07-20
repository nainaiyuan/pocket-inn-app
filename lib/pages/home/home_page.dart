import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../pages/chat/chat_page.dart';
import 'companion_page.dart';
import 'gallery_page.dart';
import 'butler_page.dart';
import 'profile_page.dart';
import 'widgets/floating_navigator.dart';

/// 主页 —— 5页面 + 悬浮导航球
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  // 5 个页面配置
  static const _pages = <_PageConfig>[
    _PageConfig('陪伴', Icons.star_border, Color(0xFFE8A0B8)),
    _PageConfig('资料', Icons.collections_bookmark_outlined, Color(0xFFC8A8D8)),
    _PageConfig('聊天', Icons.chat_bubble_outline, Color(0xFFA0C8E0)),
    _PageConfig('管家', Icons.settings_outlined, Color(0xFFA8D0A8)),
    _PageConfig('我的', Icons.person_outline, Color(0xFFD8A8C8)),
  ];

  void _switchPage(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFff5f7),
      body: Stack(
        children: [
          // 页面内容
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.95, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: child,
                ),
              );
            },
            child: _buildPage(_currentIndex),
          ),

          // 悬浮导航球
          Positioned(
            right: 24,
            bottom: 160,
            child: FloatingNavigator(
              pageCount: _pages.length,
              currentIndex: _currentIndex,
              pageIcons: _pages.map((p) => p.icon).toList(),
              pageColors: _pages.map((p) => p.color).toList(),
              onPageSelected: _switchPage,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 0: return const CompanionPage();
      case 1: return const GalleryPage();
      case 2: return const ChatPage();
      case 3: return const ButlerPage();
      case 4: return const ProfilePage();
      default: return const SizedBox.shrink();
    }
  }
}

class _PageConfig {
  final String label;
  final IconData icon;
  final Color color;
  const _PageConfig(this.label, this.icon, this.color);
}
