import 'package:flutter/material.dart';

import '../butler/system_template.dart';

/// 系统提示查看页 — 看每次聊天到底带了什么 system 信息
///
/// 结构：固定模板（管家侧 SystemTemplate）+ 男主专属人设 + 技能注入。
/// 用户后续要调整模板 → 改 lib/butler/system_template.dart 固定段。
class SystemViewPage extends StatefulWidget {
  const SystemViewPage({super.key});

  @override
  State<SystemViewPage> createState() => _SystemViewPageState();
}

class _SystemViewPageState extends State<SystemViewPage> {
  @override
  Widget build(BuildContext context) {
    final content = SystemTemplate.lastBuilt;
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDF7F9),
        foregroundColor: const Color(0xFF6A4A5A),
        elevation: 0,
        title: const Text(
          '系统提示',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6A4A5A),
          ),
        ),
      ),
      body: content == null
          ? const Center(
              child: Text(
                '还没生成过——去和男主聊一句，\n这里就会显示实际发送的系统信息',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: Color(0xFF6A4A5A),
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC896B4)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      '这是最近一次聊天实际发送给男主的系统提示。'
                      '结构 = 固定模板（管家侧，所有男主通用）+ 男主专属人设 + 实时注入。'
                      '固定部分想调整 → 改 SystemTemplate 模板；'
                      '注入部分（身份代号/情绪参考）在聊天时自动拼接。',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: Color(0xFF6A4A5A),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: SelectableText(
                      content,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: Color(0xFF4A3A42),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
