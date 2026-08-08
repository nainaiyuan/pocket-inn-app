import 'package:flutter/material.dart';
import '../chat/companion_page.dart';

import '../ai_config_page.dart';
import '../api_request_log_page.dart';
import '../butler/butler_self_test_page.dart';
import '../butler/butler_skill_library_page.dart';
import '../chat/gesture_test_page.dart';
import '../chat/widgets/debug_log_sheet.dart';
import 'chat_storage_self_test_page.dart';
import 'fix_verify_page.dart';
import 'mock_ai_test_page.dart';

/// 🧰 调试工具箱 —— 所有"测 bug 工具"的集中入口（2026-08-04 用户要求）。
///
/// 规则（用户定的，8-04）：**每完成一个功能模块，必须配一个能快速定位
/// 问题的自检/调试工具，并在这里登记一项**。修 bug 永远有据可查，不靠猜。
///
/// 本页只做"聚合导航"，不复制任何工具的实现。以后要把整个工具箱扒下来
/// 放到别的项目，复制本目录 + 各工具页面即可。
class DebugToolboxPage extends StatelessWidget {
  const DebugToolboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🧰 调试工具箱')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('AI 链路', [
            _Entry(
              icon: Icons.psychology_alt,
              iconColor: const Color(0xFF7C9FD8),
              title: 'AI 管理',
              subtitle: '配置 / 测试连接 / 能力探测（工具·思考链·流式）',
              page: const AiConfigPage(),
            ),
            _Entry(
              icon: Icons.science,
              iconColor: const Color(0xFF7C9FD8),
              title: '模拟 AI 测试',
              subtitle: '测试模式开关 + 5 个固定形态模拟 AI（平时隐藏，测试时打开）',
              page: const MockAiTestPage(),
            ),
            _Entry(
              icon: Icons.dns,
              iconColor: const Color(0xFF7C9FD8),
              title: 'API 请求日志',
              subtitle: '最近请求/响应原始记录，找接口问题',
              page: const ApiRequestLogPage(),
            ),
          ]),
          _section('管家', [
            _Entry(
              icon: Icons.healing,
              iconColor: const Color(0xFFD8A8C8),
              title: '一键自检',
              subtitle: '管家模块健康检查（规律/记忆/情绪）',
              page: const ButlerSelfTestPage(),
            ),
            _Entry(
              icon: Icons.extension,
              iconColor: const Color(0xFFD8A8C8),
              title: '技能库',
              subtitle: '管家技能/模板管理',
              page: const ButlerSkillLibraryPage(),
            ),
          ]),
          _section('聊天', [
            _Entry(
              icon: Icons.forum_outlined,
              iconColor: const Color(0xFFD8A85C),
              title: '聊天记录自检',
              subtitle: '对话落库/加载/persona 归属/完整内容收录（8-04 用户报"退出后对话全没了"）',
              page: const ChatStorageSelfTestPage(),
            ),
            _Entry(
              icon: Icons.verified_outlined,
              iconColor: const Color(0xFF7FA8D8),
              title: '🛠 修复验证中心',
              subtitle: '8-08 全部修复点的自动用例 + 男主实时状态 + 一键复制结果',
              page: const FixVerifyPage(),
            ),
          ]),
          _section('系统', [
            _Entry(
              icon: Icons.bug_report,
              iconColor: const Color(0xFF9FC87C),
              title: '运行日志',
              subtitle: '实时调试日志（按标签过滤 + 流程视图）',
              onTap: (context) => showDebugLogSheet(context),
            ),
            _Entry(
              icon: Icons.gesture,
              iconColor: const Color(0xFF9FC87C),
              title: '手势测试',
              subtitle: '三页手势滑动调试（孤儿页面，收编于此）',
              page: const GestureTestPage(),
            ),
            _Entry(
              icon: Icons.auto_awesome,
              iconColor: const Color(0xFFC896B4),
              title: '陪伴三页预览',
              subtitle: '左「他」中「我们」右「你」（8-05 搭的骨架，内容占位）',
              page: const CompanionPage(),
            ),
          ]),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '📌 规则：每完成一个功能模块，就要配一个测 bug 工具并登记在这里。'
              '以后修 bug 先看日志/自检，不靠猜。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<_Entry> entries) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 56),
                entries[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.page,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? page;

  /// 打开方式：优先 [page]（push 路由），否则用 [onTap]（如弹 sheet）。
  final void Function(BuildContext context)? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: iconColor.withValues(alpha: 0.12),
        child: Icon(icon, size: 20, color: iconColor),
      ),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () {
        final p = page;
        if (p != null) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => p));
        } else {
          onTap?.call(context);
        }
      },
    );
  }
}
