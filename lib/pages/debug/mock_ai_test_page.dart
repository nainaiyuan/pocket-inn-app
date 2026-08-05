/// 模拟 AI 测试页（2026-08-05 14:28 用户：测试的东西集中到"测 bug 那里"，
/// 平时关掉，不要散落在配置页/聊天页）。
///
/// 收录（从 AI 配置页挪过来）：
/// - 测试模式开关（默认关：mock 隐藏、不注册路由、聊天页不可见；
///   开：mock 可选 + 聊天弹层出现"🚀 一键验收"）
/// - 5 个固定形态模拟 AI 一览 + 主实例设置（记忆模式/思考链/工具）
library;

import 'package:flutter/material.dart';

import '../../ai_provider/ai_provider_manager.dart';
import '../../ai_provider/mock_ai_provider.dart';

/// 🧪 模拟 AI 测试页 —— 调试工具箱入口
class MockAiTestPage extends StatefulWidget {
  const MockAiTestPage({super.key});

  @override
  State<MockAiTestPage> createState() => _MockAiTestPageState();
}

class _MockAiTestPageState extends State<MockAiTestPage> {
  AIProviderManager get manager => AIProviderManager.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🧪 模拟 AI 测试')),
      body: ValueListenableBuilder<int>(
        valueListenable: manager.changeNotifier,
        builder: (context, _, __) {
          final testMode = AIProviderManager.testModeEnabled;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ---- 测试模式开关（默认关）----
              Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                color: testMode
                    ? const Color(0xFFE8F5E9).withValues(alpha: 0.7)
                    : Colors.white.withValues(alpha: 0.8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SwitchListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  title: const Text('测试模式', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    testMode
                        ? '开：模拟 AI 出现在聊天页 AI 列表，可切换对话'
                        : '关：模拟 AI 平时隐藏，不参与聊天（默认）',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.4),
                  ),
                  value: testMode,
                  onChanged: (v) => AIProviderManager.setTestModeEnabled(v),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '📌 平时保持关闭；需要测试对话/记忆/工具链路时打开，'
                '到聊天页切换成模拟 AI（或点"🚀 一键验收"自动跑 5 个形态）。'
                '模拟 AI 不联网、不花 token。',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.5),
              ),
              const SizedBox(height: 12),
              _buildMockCard(),
            ],
          );
        },
      ),
    );
  }

  /// 内置模拟 AI 卡片（8-04 20:35 用户：本地 AI 测各种配置组合；
  /// 8-05 14:28 从 AI 配置页挪到调试工具箱）：
  /// 显示 5 个固定形态变体 + 主实例手动设置（记忆模式/思考链/工具）
  Widget _buildMockCard() {
    final mock = manager.builtinMockConfig;
    final isStateful = mock.isStateful;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: const Color(0xFFF3E8FF).withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.science, size: 20, color: Colors.purple),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '🧪 内置模拟 AI（${AIProviderManager.builtinMockVariants.length} 个固定形态）',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '一键切换即测：不同 记忆/思考链/工具 组合的对话与切换逻辑，'
                        '不联网不花 token',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final v in AIProviderManager.builtinMockVariants) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.circle,
                        size: 8,
                        color: v.isStateful ? Colors.orange : Colors.blueGrey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${v.name}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (v.id == AIProviderManager.builtinMockId)
                      Text(
                        isStateful ? '（手动：有记忆 ${mock.refreshHours}h）' : '（手动：无记忆）',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 2),
            Row(
              children: [
                Text(
                  '主实例开关：思考链 ${MockAIProvider.simulateReasoning ? '开' : '关'}'
                  ' ｜ 工具 ${MockAIProvider.simulateTools ? '开' : '关'}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _openMockSettings,
                  child: const Text('⚙️ 设置主实例'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// mock 设置 dialog：记忆模式 + 空闲超时 + 思考链 + 工具调用
  Future<void> _openMockSettings() async {
    final mock = manager.builtinMockConfig;
    var memoryMode = mock.memoryMode;
    var refreshHours = mock.refreshHours?.toString() ?? '24';
    var reasoning = MockAIProvider.simulateReasoning;
    var tools = MockAIProvider.simulateTools;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('🧪 模拟 AI 设置', style: TextStyle(fontSize: 17)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('模拟各种 AI 形态，测对话/记忆/工具链路：',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: memoryMode,
                  decoration: const InputDecoration(
                    labelText: '后台记忆模式',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'stateless', child: Text('无后台记忆（每次全量带，DeepSeek 等）')),
                    DropdownMenuItem(value: 'stateful', child: Text('有后台记忆（服务端记得，prompt 轻量）')),
                  ],
                  onChanged: (v) => setDialogState(() => memoryMode = v ?? 'stateless'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: TextEditingController(text: refreshHours),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '空闲超时（小时，有后台记忆时用）',
                    border: OutlineInputBorder(),
                    isDense: true,
                    helperText: '超过此时长没聊 → AI 服务端已忘 → 带恢复包+摘要接上',
                  ),
                  onChanged: (v) => refreshHours = v,
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('思考链（reasoning_content）', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('关 = 模拟无思考链模型', style: TextStyle(fontSize: 11)),
                  value: reasoning,
                  onChanged: (v) => setDialogState(() => reasoning = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('工具调用', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('关 = 模拟不支持 function calling 的模型', style: TextStyle(fontSize: 11)),
                  value: tools,
                  onChanged: (v) => setDialogState(() => tools = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                manager.updateBuiltinMock(
                  memoryMode: memoryMode,
                  refreshHours: int.tryParse(refreshHours.trim()),
                );
                MockAIProvider.simulateReasoning = reasoning;
                MockAIProvider.simulateTools = tools;
                setState(() {});
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
