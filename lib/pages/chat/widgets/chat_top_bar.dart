import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ai_provider/ai_provider_manager.dart';
import '../../../ai_provider/models.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';
import '../state/chat_presence.dart';

/// 聊天页顶部栏 —— 角色名居中，点击进秘密基地，长按改名；
/// 名字下方显示当前 AI（明显、可点击进 AI 设置）。
class ChatTopBar extends StatefulWidget {
  final MaleLead? currentLead;
  final Persona? currentPersona;
  final VoidCallback onTapAvatar;
  final VoidCallback onMenuTap;
  final VoidCallback onAiTap;
  final VoidCallback? onNameChanged; // 改名后通知上层刷新

  const ChatTopBar({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onTapAvatar,
    required this.onMenuTap,
    required this.onAiTap,
    this.onNameChanged,
  });

  @override
  State<ChatTopBar> createState() => _ChatTopBarState();
}

class _ChatTopBarState extends State<ChatTopBar> {
  late String _displayName;

  @override
  void initState() {
    super.initState();
    _displayName = _resolveDisplayName();
  }

  @override
  void didUpdateWidget(ChatTopBar old) {
    super.didUpdateWidget(old);
    final newName = _resolveDisplayName();
    if (_displayName != newName) {
      _displayName = newName;
    }
  }

  String _resolveDisplayName() {
    // 始终显示当前 Persona 的名字
    if (widget.currentPersona != null &&
        widget.currentPersona!.name.isNotEmpty) {
      return widget.currentPersona!.name;
    }
    return widget.currentLead?.name ?? '沈星回';
  }

  String? get _personaId => widget.currentPersona?.id;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        8,
        MediaQuery.of(context).padding.top + 4,
        8,
        8,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0xFF5A4A52).withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: GestureDetector(
              onTap: widget.onTapAvatar,
              onLongPress: () => _renameLead(context),
              // 拟人化状态：男主输入中 → 顶部中央显示"正在输出"（仿微信）
              // 8-03 18:2x：用户要求"正在输出"放正中间（原来偏右）
              child: ListenableBuilder(
                listenable: ChatPresence.instance,
                builder: (context, _) {
                  final typing = ChatPresence.instance.isTyping;
                  if (typing) {
                    // 绝对居中（Align 撑满 Expanded）
                    return const Align(
                      alignment: Alignment.center,
                      child: _TypingIndicator(),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6A4A5A),
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _AiBadge(personaId: _personaId, onTap: widget.onAiTap),
                    ],
                  );
                },
              ),
            ),
          ),
          GestureDetector(
            onTap: widget.onMenuTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.more_horiz_rounded,
                color: const Color(0xFF6A4A5A).withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _renameLead(BuildContext context) {
    HapticFeedback.mediumImpact();
    final persona = widget.currentPersona;
    final lead = widget.currentLead;
    if (persona == null && lead == null) return;
    final ctrl = TextEditingController(text: _displayName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('修改角色名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入新名字',
            border: InputBorder.none,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty) {
                // 统一改 Persona 名字（包括默认 Persona）
                persona!.name = newName;
                CharacterService().updatePersona(lead!.id, persona);
                setState(() => _displayName = newName);
                widget.onNameChanged?.call();
              }
              Navigator.pop(ctx);
            },
            child: const Text(
              '确定',
              style: TextStyle(
                color: Color(0xFFE8A0B8),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「当前 AI」小徽章：显示这个男主现在用的是哪家，点击进 AI 设置。
/// 没配置时显示醒目的"AI 未配置"。
class _AiBadge extends StatelessWidget {
  const _AiBadge({required this.personaId, required this.onTap});

  final String? personaId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final manager = AIProviderManager.instance;
    return ValueListenableBuilder<int>(
      valueListenable: manager.changeNotifier,
      builder: (context, _, __) {
        final id = manager.lastProviderFor(personaId);
        AIProviderConfig? current;
        for (final config in manager.providers) {
          if (config.id == id) {
            current = config;
            break;
          }
        }
        final anyUsable = manager.hasUsable(personaId);
        // 当前这个 AI 是否真能用（本地 Provider 不需要 Key）
        final currentReady =
            current != null &&
            (current.type == ProviderType.local ||
                current.apiKey.trim().isNotEmpty);
        final Color color;
        final String label;
        // 8-05 16:36 用户：测试模式开着时，顶栏一眼看出在测试
        if (AIProviderManager.testModeEnabled) {
          color = const Color(0xFF7B6A8F);
          label = '🧪 测试中';
        } else if (current == null || !anyUsable) {
          color = const Color(0xFFE07A7A);
          label = '未配置';
        } else if (!currentReady) {
          color = const Color(0xFFE0A050);
          label = '${current.name}（未填 Key）';
        } else {
          color = const Color(0xFF7AA87A);
          label = current.name;
        }
        return GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, size: 10, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "正在输入…" 打字指示器（三个跳动圆点，仿微信）
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '正在输出',
          style: TextStyle(
            fontSize: 11,
            color: const Color(0xFF6A4A5A).withValues(alpha: 0.35),
          ),
        ),
        const SizedBox(width: 4),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                // 三个点依次跳动：每个点相位差 120°
                final phase = (t - i * 0.33) % 1.0;
                final height =
                    3.0 + 3.0 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Container(
                    width: 4,
                    height: height,
                    decoration: BoxDecoration(
                      color: const Color(0xFF6A4A5A).withValues(alpha: 0.35),
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ],
    );
  }
}
