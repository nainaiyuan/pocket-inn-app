/// 故障切换路由器（纯 Dart）。
///
/// 职责：
/// 1. 按「能力 + 优先级」解析可用的 Provider 列表；
/// 2. 调用失败 → 标记冷却（默认 60s）→ 自动尝试下一个；
/// 3. 冷却到期自动恢复尝试，不会永久锁死；
/// 4. 男主绑定：绑定的顺序优先于全局优先级，且是白名单。
library;

import 'dart:async';

import 'models.dart';

/// 单个 Provider 的运行时状态（不序列化，重启后归零）。
class AIProviderState {
  AIProviderState({required this.config});

  AIProviderConfig config;

  ProviderHealth health = ProviderHealth.unknown;
  DateTime? cooldownUntil;
  int consecutiveFailures = 0;
  DateTime? lastSuccessAt;
  String? lastError;

  bool get isEnabled => config.enabled;

  /// 冷却期内返回 true；到期后自动清除冷却并恢复为 unknown（等待重试）。
  bool get isInCooldown {
    final until = cooldownUntil;
    if (until == null) {
      return false;
    }
    if (DateTime.now().isBefore(until)) {
      return true;
    }
    cooldownUntil = null;
    health = ProviderHealth.unknown;
    return false;
  }

  /// 可用 = 启用 + 不在冷却 + 已填 API Key（本地 Provider 不需要 Key）。
  bool get isUsable =>
      isEnabled &&
      !isInCooldown &&
      (config.type == ProviderType.local || config.apiKey.trim().isNotEmpty);

  void markFailure(Object error, Duration cooldown) {
    consecutiveFailures++;
    cooldownUntil = DateTime.now().add(cooldown);
    health = ProviderHealth.cooling;
    lastError = error.toString();
  }

  void markSuccess() {
    consecutiveFailures = 0;
    cooldownUntil = null;
    lastSuccessAt = DateTime.now();
    lastError = null;
    health = ProviderHealth.healthy;
  }
}

class FailoverRouter {
  FailoverRouter({this.cooldownDuration = const Duration(seconds: 60)});

  /// 失败后的冷却时长，期间路由跳过该 Provider。
  final Duration cooldownDuration;

  final Map<String, AIProviderState> _states = {};

  void register(AIProviderConfig config) {
    _states[config.id] = AIProviderState(config: config);
  }

  void unregister(String id) {
    _states.remove(id);
  }

  void clear() {
    _states.clear();
  }

  AIProviderState? stateOf(String id) => _states[id];

  List<AIProviderState> get allStates => List.unmodifiable(_states.values);

  /// 解析可用的 Provider（按优先级升序 / 绑定顺序），已过滤：
  /// 禁用的、冷却中的、不具备 [capability] 的。
  List<AIProviderState> resolve({
    String? personaId,
    AICapability capability = AICapability.chat,
    List<PersonaAIBinding> bindings = const [],
  }) {
    final binding = _findBinding(bindings, personaId);
    final hasBinding = binding != null && !binding.followsGlobal;
    List<AIProviderState> ordered = const [];
    if (hasBinding) {
      // 男主绑定：优先列表 + 用户自定义顺序（8-05 16:36 用户改：
      // 不再是死白名单——全挂时回退全局，绑定 AI 坏了自动换没绑定的，省 token）
      ordered = [];
      for (final id in binding.providerIds) {
        final state = _states[id];
        if (state != null && !ordered.contains(state)) {
          ordered.add(state);
        }
      }
    }
    final usable = [
      for (final state in ordered)
        if (state.isUsable && state.config.capabilities.contains(capability))
          state,
    ];
    if (hasBinding && usable.isNotEmpty) return usable;
    // 无绑定，或绑定内的全挂/不可用 → 全局：按 priority 升序，
    // 同优先级按名字稳定排序。绑定里失败的已在冷却中自动排除，
    // 绑定里仍可用的按 priority 自然排前（优先绑定语义保留）。
    final global = _states.values.toList()
      ..sort((a, b) {
        final byPriority = a.config.priority.compareTo(b.config.priority);
        return byPriority != 0
            ? byPriority
            : a.config.name.compareTo(b.config.name);
      });
    return [
      for (final state in global)
        if (state.isUsable && state.config.capabilities.contains(capability))
          state,
    ];
  }

  /// 非流式调用：按顺序尝试，失败自动切换下一个。
  ///
  /// [isAbort] 用于识别「用户主动取消」类异常（如
  /// ChatCompletionCancelledException），遇到时直接抛出、不切换。
  /// [allowFailover] 为 false 时：第一个 Provider 失败就立刻抛出
  /// [AIProviderUnavailableException]（不尝试下一个，不静默换人）。
  Future<AIProviderResult> executeWithFailover({
    String? personaId,
    AICapability capability = AICapability.chat,
    List<PersonaAIBinding> bindings = const [],
    bool allowFailover = true,
    required Future<AIProviderResult> Function(AIProviderConfig config)
        action,
    bool Function(Object error)? isAbort,
  }) async {
    final ordered = resolve(
      personaId: personaId,
      capability: capability,
      bindings: bindings,
    );
    if (ordered.isEmpty) {
      throw const AIAllProvidersFailedException();
    }

    final failed = <String>[];
    Object? lastError;
    for (final state in ordered) {
      final config = state.config;
      try {
        final result = await action(config);
        state.markSuccess();
        return result.copyWith(
          providerId: config.id,
          providerName: config.name,
          failedProviders: failed,
        );
      } on Object catch (error) {
        if (isAbort?.call(error) ?? false) {
          rethrow;
        }
        // 不自动切换时：标记失败（零冷却，重试仍走同一家），
        // 然后立刻抛错让 UI 弹窗，绝不偷偷换 Provider。
        state.markFailure(error, allowFailover ? cooldownDuration : Duration.zero);
        if (!allowFailover) {
          throw AIProviderUnavailableException(
            providerName: config.name,
            cause: error,
          );
        }
        failed.add(config.name);
        lastError = error;
      }
    }
    throw AIAllProvidersFailedException(
      tried: failed,
      lastError: lastError,
    );
  }

  /// 流式调用：失败切换只发生在「首个字节之前」。
  /// 一旦已经吐字再断流，属于真故障，直接抛错不静默切换。
  /// [allowFailover] 为 false 时：首个字节前的失败也直接抛
  /// [AIProviderUnavailableException]，不尝试下一个。
  Stream<AIProviderResult> streamWithFailover({
    String? personaId,
    AICapability capability = AICapability.chat,
    List<PersonaAIBinding> bindings = const [],
    bool allowFailover = true,
    required Stream<AIProviderResult> Function(AIProviderConfig config)
        action,
    bool Function(Object error)? isAbort,
  }) async* {
    final ordered = resolve(
      personaId: personaId,
      capability: capability,
      bindings: bindings,
    );
    if (ordered.isEmpty) {
      throw const AIAllProvidersFailedException();
    }

    final failed = <String>[];
    Object? lastError;
    for (final state in ordered) {
      final config = state.config;
      var emittedAny = false;
      try {
        await for (final chunk in action(config)) {
          emittedAny = emittedAny || chunk.text.isNotEmpty;
          yield chunk.copyWith(
            providerId: config.id,
            providerName: config.name,
            failedProviders: failed,
          );
        }
        state.markSuccess();
        return;
      } on Object catch (error) {
        if (isAbort?.call(error) ?? false) {
          rethrow;
        }
        state.markFailure(error, allowFailover ? cooldownDuration : Duration.zero);
        if (!allowFailover) {
          throw AIProviderUnavailableException(
            providerName: config.name,
            cause: error,
          );
        }
        if (emittedAny) {
          rethrow;
        }
        failed.add(config.name);
        lastError = error;
      }
    }
    throw AIAllProvidersFailedException(
      tried: failed,
      lastError: lastError,
    );
  }

  PersonaAIBinding? _findBinding(
    List<PersonaAIBinding> bindings,
    String? personaId,
  ) {
    if (personaId == null || personaId.isEmpty) {
      return null;
    }
    for (final binding in bindings) {
      if (binding.personaId == personaId) {
        return binding;
      }
    }
    return null;
  }
}
