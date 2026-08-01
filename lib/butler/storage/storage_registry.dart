/// 存储注册中心 — 所有管家数据存储的统一入口
///
/// 用法：
/// ```dart
/// final memoryStore = StorageRegistry.instance.memory;
/// await memoryStore.save(memory);
/// ```
///
/// 加新数据类型 = 新建一个 Store 文件 + 在这里登记一行。
library;

import 'blocklist_store.dart';
import 'butler_store.dart';
import 'emotion_arc_store.dart';
import 'identity_store.dart';
import 'interaction_store.dart';
import 'memory_store.dart';
import 'pattern_store.dart';
import 'trigger_store.dart';
import 'user_memory_store.dart';
import 'vault_store.dart';

/// 存储注册中心（单例）
class StorageRegistry {
  static final StorageRegistry instance = StorageRegistry._();

  StorageRegistry._() {
    _stores = <ButlerStore>[
      MemoryStore(),
      InteractionStore(),
      BlocklistStore(),
      TriggerStore(),
      VaultStore(),
      IdentityStore(),
      PatternStore(),
      UserMemoryStore(),
      EmotionArcStore(),
    ];
  }

  late final List<ButlerStore> _stores;

  // ========== 各 Store 访问器 ==========

  MemoryStore get memory =>
      _store<MemoryStore>('memory');

  InteractionStore get interaction =>
      _store<InteractionStore>('interaction');

  BlocklistStore get blocklist =>
      _store<BlocklistStore>('blocklist');

  TriggerStore get triggers =>
      _store<TriggerStore>('trigger');

  VaultStore get vault =>
      _store<VaultStore>('vault');

  IdentityStore get identity =>
      _store<IdentityStore>('identity');

  PatternStore get patterns =>
      _store<PatternStore>('patterns');

  UserMemoryStore get userMemory =>
      _store<UserMemoryStore>('user_memory');

  EmotionArcStore get emotionArcs =>
      _store<EmotionArcStore>('emotion_arcs');

  // ========== 通用 ==========

  /// 全部 Store
  List<ButlerStore> get all => List.unmodifiable(_stores);

  /// 按 id 查找
  ButlerStore? find(String id) {
    for (final store in _stores) {
      if (store.id == id) return store;
    }
    return null;
  }

  T _store<T extends ButlerStore>(String id) {
    final store = find(id);
    if (store == null) {
      throw StateError('Store 未注册: $id');
    }
    return store as T;
  }
}
