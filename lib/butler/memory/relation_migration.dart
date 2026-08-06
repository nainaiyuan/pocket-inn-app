/// 旧记忆迁移 → 关系网（8-07 01:23 用户："把所有的做好"）
///
/// 旧 UserMemory 格式：[谁] [和谁] [什么时间] [做了什么] [感受]，
/// 没有原话/归属/拆好的 谁→谁→什么。
/// 迁移规则（一次跑完，幂等，旧库不清空）：
/// - subject → 统一'用户'（旧数据是'我'）
/// - predicate → 从 action 提动词（喜欢/讨厌/去/学…），提不出用'提到'
/// - object → action 剩余部分
/// - quote → 完整原句（toSentence），旧记忆没有逐字原话
/// - time → 旧 time（上周/去年…）
/// - 归属 → 共同（旧数据不知道是哪个男主聊的）
/// - category → '记忆'
///
/// 标记存 SharedPreferences（relation_migration_v1_done），跑过不再跑。
/// 全程异步 + 容错：失败静默，绝不影响正式使用。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../modules/butler_module_hub.dart';
import '../storage/storage_registry.dart';
import 'relation_record.dart';
import 'user_memory.dart';

class RelationMigration {
  RelationMigration._();

  static const String _doneKey = 'relation_migration_v1_done';

  /// 已迁移过？
  static Future<bool> isDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_doneKey) ?? false;
  }

  /// 把旧记忆全量转成关系记录（幂等：跑过就跳过）
  /// 在管家中心打开时异步调用，失败静默。
  static Future<void> migrateLegacyMemories() async {
    try {
      if (await isDone()) return;

      // 旧记忆（UserMemoryManager 已 attach 全局存储）
      final hub = ButlerModuleHub.instance;
      final manager = hub.sharedMemoryManager;
      if (manager == null) return;

      final oldList = manager.getAll();
      if (oldList.isEmpty) {
        await _markDone();
        return;
      }

      final store = StorageRegistry.instance.relations;
      var saved = 0;
      for (final m in oldList) {
        try {
          await store.save(_toRelation(m));
          saved++;
        } catch (_) {
          // 单条失败跳过，不中断整体
        }
      }
      await _markDone();
      print('[RelationMigration] ✅ 旧记忆迁移完成：$saved/${oldList.length} 条 → 关系网');
    } catch (e) {
      print('[RelationMigration] ⚠️ 迁移跳过（不影响使用）: $e');
    }
  }

  /// 单条转换
  static RelationRecord _toRelation(UserMemory m) {
    final (predicate, object) = _splitVerb(m.action);
    return RelationRecord(
      id: 'mig_${m.id}',
      subject: '用户',
      predicate: predicate,
      object: object,
      quote: m.toSentence(),
      time: m.time,
      characterId: null, // 旧数据无归属 → 共同
      category: '记忆',
      createdAt: m.createdAt,
    );
  }

  /// 从动作句提动词：'喜欢猫' → (喜欢, 猫)；提不出 → ('提到', 原句)
  static (String, String) _splitVerb(String action) {
    const verbs = [
      '不喜欢', '讨厌', '喜欢', '想去做', '想去', '想学', '想买', '想养',
      '去', '学', '养', '买', '吃', '喝', '看', '听', '玩', '做', '写',
      '读', '种', '参加', '加入', '开始', '喜欢上', '迷上', '爱上',
      '在', '有', '是', '最近在', '最近开始',
    ];
    for (final v in verbs) {
      if (action.startsWith(v) && action.length > v.length) {
        return (v, action.substring(v.length));
      }
    }
    return ('提到', action);
  }

  static Future<void> _markDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_doneKey, true);
  }
}
