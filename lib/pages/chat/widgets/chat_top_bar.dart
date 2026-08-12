import 'package:flutter/material.dart';
import 'companion_toggle_button.dart';
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
  /// 8-05 23:45 用户：右上角三个点 → 设计感按钮 → 进陪伴三页。
  /// （原 onMenuTap=开设定右页，设定入口挪到陪伴页的小齿轮）
  final VoidCallback onCompanionTap;
  final VoidCallback onAiTap;
  final VoidCallback? onNameChanged; // 改名后通知上层刷新

  const ChatTopBar({
    super.key,
    required this.currentLead,
    required this.currentPersona,
    required this.onTapAvatar,
    required this.onCompanionTap,
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
                      Row(
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
                          const SizedBox(width: 5),
                          // 在线状态灯（绿=主 AI 可用 / 黄=备胎顶着 / 红=无可用 AI）
                          _AiStatusDot(personaId: _personaId),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          // 8-05 23:45：✦ 设计感按钮 → 陪伴三页（共享组件，和陪伴页
          // 切回按钮完全一致——23:48 用户：切回来的也要一样好看）
          Padding(
            padding: const EdgeInsets.all(4),
            child: CompanionToggleButton(onTap: widget.onCompanionTap),
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
/// 男主名字旁的在线状态灯（灰=没配置 AI / 绿=能用 / 红=出故障 / 紫=测试中）。
/// 纯状态展示，配置入口在右页 AI 区。
class _AiStatusDot extends StatelessWidget {
  const _AiStatusDot({required this.personaId});

  final String? personaId;

  @override
  Widget build(BuildContext context) {
    final manager = AIProviderManager.instance;
    return ValueListenableBuilder<int>(
      valueListenable: manager.changeNotifier,
      builder: (context, _, _) {
        final id = manager.lastProviderFor(personaId);
        AIProviderConfig? current;
        for (final config in manager.providers) {
          if (config.id == id) {
            current = config;
            break;
          }
        }
        final bound = manager.bindingFor(personaId ?? '') ?? const [];
        // 没勾选任何 AI = 没配置
        final configured = bound.isNotEmpty;
        // 当前 AI 是否就绪（本地 Provider 不需要 Key）
        final currentReady =
            current != null &&
            (current.type == ProviderType.local ||
                current.apiKey.trim().isNotEmpty);
        // 有没有任何一个绑定的 AI 可用
        var anyReady = currentReady;
        if (!anyReady) {
          for (final bid in bound) {
            for (final config in manager.providers) {
              if (config.id == bid &&
                  config.enabled &&
                  (config.type == ProviderType.local ||
                      config.apiKey.trim().isNotEmpty)) {
                anyReady = true;
                break;
              }
            }
            if (anyReady) break;
          }
        }
        final Color color;
        if (AIProviderManager.testModeEnabled) {
          color = const Color(0xFF7B6A8F); // 紫：测试中
        } else if (!configured) {
          color = const Color(0xFFB8ACB2); // 灰：没配置 AI
        } else if (anyReady) {
          color = const Color(0xFF7AA87A); // 绿：能用
        } else {
          color = const Color(0xFFE07A7A); // 红：配了但出故障
        }
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.45),
                blurRadius: 4,
                spreadRadius: 0.5,
              ),
            ],
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
