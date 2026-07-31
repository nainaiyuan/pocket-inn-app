/// 禁区拦截模块 — 用户不想聊的内容，直接拦住
///
/// 禁区 = 用户明确设置的拦截模式（存 BlocklistStore）。
/// 命中禁区 → 消息被拦截，不发给男主，也不发给 AI。
///
/// 内置默认禁区：身份证号、手机号（隐私保护）。
library;

import '../modules/butler_module.dart';
import '../storage/blocklist_store.dart';
import '../storage/storage_registry.dart';

/// 禁区数据源接口 — 模块只依赖这个接口，不直接依赖 SQLite
/// 测试时可注入内存实现
abstract class BlocklistDataSource {
  /// 检查文本是否命中禁区，返回命中的模式
  Future<List<BlocklistPattern>> match(String text);
}

/// 默认实现：走 BlocklistStore（SQLite）
class BlocklistStoreDataSource implements BlocklistDataSource {
  final BlocklistStore store;
  BlocklistStoreDataSource({BlocklistStore? store})
    : store = store ?? StorageRegistry.instance.blocklist;

  @override
  Future<List<BlocklistPattern>> match(String text) => store.match(text);
}

/// 禁区拦截模块
class BlocklistModule extends ButlerModule {
  final BlocklistDataSource _dataSource;

  /// 内置默认禁区（隐私信息，永远拦截）
  static final List<RegExp> _builtinPatterns = [
    // 身份证号（18位）
    RegExp(r'\b\d{17}[\dXx]\b'),
    // 手机号（11位，1开头）
    RegExp(r'\b1[3-9]\d{9}\b'),
  ];

  /// [dataSource] 可注入自定义数据源（测试用）；默认走 SQLite
  BlocklistModule({BlocklistDataSource? dataSource})
    : _dataSource = dataSource ?? BlocklistStoreDataSource();

  @override
  String get id => 'blocklist';

  @override
  String get name => '禁区拦截';

  @override
  String get description => '拦截用户不想聊的内容和隐私信息（身份证/手机号等）';

  @override
  ButlerModuleStage get stage => ButlerModuleStage.guard;

  @override
  bool get enabled => true;

  @override
  Future<ButlerModuleResult> onUserMessage(
    ButlerContext context,
    String text,
  ) async {
    // 1. 内置隐私模式
    for (final pattern in _builtinPatterns) {
      if (pattern.hasMatch(text)) {
        return ButlerModuleResult(
          text: '',
          blocked: true,
          blockReason: '检测到隐私信息（身份证/手机号），已拦截，不会发送给男主。',
        );
      }
    }

    // 2. 用户自定义禁区
    final matched = await _dataSource.match(text);
    if (matched.isNotEmpty) {
      final labels = matched
          .map((m) => m.label.isEmpty ? m.pattern : m.label)
          .join('、');
      return ButlerModuleResult(
        text: '',
        blocked: true,
        blockReason: '命中禁区（$labels），已拦截，不会发送。',
      );
    }

    return ButlerModuleResult.pass(text);
  }
}
