import 'package:flutter/material.dart';

import '../ai_provider/capability_probe.dart';

/// 能力灯（通用组件，2026-08-04）：AI 配置页 / 聊天弹层共用。
/// 展示：系别标签（OpenAI 系/Claude 系/…）+ 能用哪个亮哪个。
/// - 原生工具 / 思考链 / 流式：支持的亮绿色圆点 + 文字，不支持的**不显示**
/// - 一个都不支持 → 显示"⚠️ 仅文本协议（AI 可能不配合）"
/// - 还没探测过 → 显示"未检测" + 重测按钮
/// - 信号台（🛰 重测）按钮：保底，用户觉得能力灯不对就再点一次
class CapabilityLights extends StatelessWidget {
  const CapabilityLights({
    super.key,
    this.caps,
    this.probing = false,
    this.onRetest,
    this.compact = false,
  });

  /// 能力画像；null = 还没探测过
  final AIProviderCapabilities? caps;

  /// 正在探测中（添加后自动测 / 手动重测）
  final bool probing;

  /// 信号台重测回调；null = 不显示重测按钮
  final VoidCallback? onRetest;

  /// 紧凑模式（列表行内用，缩小间距）
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fontSize = compact ? 10.0 : 11.0;

    if (caps == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (probing) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
            Text(
              '检测中…',
              style: TextStyle(fontSize: fontSize, color: colorScheme.outline),
            ),
          ] else ...[
            Text(
              '未检测',
              style: TextStyle(fontSize: fontSize, color: colorScheme.outline),
            ),
            if (onRetest != null) ...[
              const SizedBox(width: 4),
              _RetestButton(onPressed: onRetest, compact: compact),
            ],
          ],
        ],
      );
    }

    final lights = <Widget>[
      _light(context, colorScheme, '工具', caps!.toolFormat == 'openai', fontSize),
      _light(context, colorScheme, '思考链', caps!.supportsReasoning, fontSize),
      _light(context, colorScheme, '流式', caps!.supportsStreaming, fontSize),
    ];
    final anySupported = caps!.toolFormat == 'openai' ||
        caps!.supportsReasoning ||
        caps!.supportsStreaming;

    return Wrap(
      spacing: compact ? 6 : 8,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 6, vertical: 1),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: 0.25),
            ),
          ),
          child: Text(
            caps!.systemLabel,
            style: TextStyle(
              fontSize: compact ? 9 : 10,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ),
        if (anySupported)
          ...lights
        else
          Text(
            '⚠️ 仅文本协议（AI 可能不配合）',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: Colors.orange.shade800,
            ),
          ),
        if (probing) ...[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ] else if (onRetest != null)
          _RetestButton(onPressed: onRetest, compact: compact),
      ],
    );
  }

  Widget _light(
    BuildContext context,
    ColorScheme colorScheme,
    String label,
    bool supported,
    double fontSize,
  ) {
    if (!supported) {
      // 不能用的不显示（能用哪个亮哪个）
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: fontSize, color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 信号台小按钮：🛰 重测能力（保底，觉得不对再点一次）。
class _RetestButton extends StatelessWidget {
  const _RetestButton({this.onPressed, this.compact = false});

  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sensors, size: compact ? 11 : 13, color: colorScheme.outline),
            const SizedBox(width: 2),
            Text(
              '重测',
              style: TextStyle(
                fontSize: compact ? 9 : 10,
                color: colorScheme.outline,
                decoration: TextDecoration.underline,
                decorationColor: colorScheme.outline.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
