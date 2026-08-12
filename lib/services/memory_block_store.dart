import 'package:shared_preferences/shared_preferences.dart';

/// MemoryBlockStore —— 长期记忆块 + 短期记忆块（8-12 18:0x 用户拍板）
///
/// 用户缓存命中重构：prompt 按变化频率分层，固定区在前、动态区最后。
/// 长期/短期记忆块 = 固定区（历史前）的稳定块：
/// - 【长期记忆】：男主不用查就该知道的用户基础信息（喜好/对待方式/
///   工作习惯）+ 导航（聊到某话题→去哪查用什么命令查），≤500 字预算
/// - 【短期记忆】：男主临时观察到的、还不确定的东西；上下文压缩节点
///   把临时记忆浓缩进来；观察一直稳定 → 升级进长期记忆
/// - 平时冻结（只在压缩节点由男主用 manage_memory_block 更新），
///   内容变了会破坏前缀缓存命中 → 更新必须低频
///
/// 男主自管（manage_memory_block，免审批），管家只做存储。
/// 注入预算：500 字，超了提示精简，不强制。
class MemoryBlockStore {
  static void Function(String tag, String msg)? logSink;
  static void _log(String tag, String msg) => logSink?.call(tag, msg);

  MemoryBlockStore._();

  static const String _prefix = 'memory_block_';
  static const int budget = 500; // 注入预算（字）

  static Map<String, dynamic>? _memCache;

  static String _key(String personaId, String kind) =>
      '$_prefix${kind}_$personaId';

  /// 单例缓存读（warm 后同步读）
  static void warm(String personaId) {
    if (personaId.isEmpty) return;
    _load(personaId);
  }

  /// 8-13 02:2x 本体记忆共享：聚合 Lead 下所有角色的记忆块。
  /// [members] = Lead 下所有 (id, name)；合并各角色 long/short 成一份，
  /// 当前角色的块放最前，其他角色的块带「角色名」前缀标注来源。
  /// 开启后 _sharedIds 非空 → 后续 get/save 都走聚合（写仍写当前角色自己的 key）。
  static void warmShared(List<({String id, String name})> members) {
    _sharedIds = [for (final m in members) m.id];
    _members = members;
    if (members.isEmpty) return;
    _loadAll(members);
  }

  static List<({String id, String name})> _members = const [];

  static List<String> _sharedIds = const [];

  static bool get _isShared => _sharedIds.isNotEmpty;

  static Future<void> _loadAll(List<({String id, String name})> members) async {
    try {
      final p = await SharedPreferences.getInstance();
      final longParts = <String>[];
      final shortParts = <String>[];
      var first = true;
      for (final m in members) {
        final long = p.getString(_key(m.id, 'long')) ?? '';
        final short = p.getString(_key(m.id, 'short')) ?? '';
        if (long.trim().isEmpty && short.trim().isEmpty) continue;
        final tag = first ? '' : '【${m.name}】';
        if (long.trim().isNotEmpty) {
          longParts.add(first ? long : '$tag $long');
        }
        if (short.trim().isNotEmpty) {
          shortParts.add(first ? short : '$tag $short');
        }
        first = false;
      }
      _memCache = {
        'long': longParts.join('\n\n'),
        'short': shortParts.join('\n\n'),
      };
    } catch (e) {
      _memCache = {'long': '', 'short': ''};
    }
  }

  static Future<void> _load(String personaId) async {
    if (personaId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final long = p.getString(_key(personaId, 'long')) ?? '';
      final short = p.getString(_key(personaId, 'short')) ?? '';
      _memCache = {'long': long, 'short': short};
    } catch (e) {
      _memCache = {'long': '', 'short': ''};
    }
  }

  static Future<Map<String, dynamic>> _read(String personaId) async {
    if (personaId.isEmpty) return {'long': '', 'short': ''};
    if (_isShared) {
      // 聚合模式：缓存已含全部角色，直接返回（不覆盖成单角色）
      return _memCache ?? {'long': '', 'short': ''};
    }
    await _load(personaId);
    return _memCache ?? {'long': '', 'short': ''};
  }

  static Future<void> _write(
      String personaId, String kind, String content) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      await p.remove(_key(personaId, kind));
    } else {
      await p.setString(_key(personaId, kind), trimmed);
    }
    if (_memCache == null) _memCache = {'long': '', 'short': ''};
    _memCache![kind] = trimmed;
    if (_isShared) {
      // 聚合模式：写完重聚合，保持缓存含全部角色
      _loadAll(_members);
    }
  }

  /// 覆盖写入（男主 manage_memory_block 用）
  static Future<String> save(String personaId, String kind, String content) async {
    if (personaId.isEmpty) return '参数错误';
    if (kind != 'long' && kind != 'short') return 'kind 只能是 long（长期）/ short（短期）';
    final trimmed = content.trim();
    await _write(personaId, kind, trimmed);
    final label = kind == 'long' ? '长期记忆' : '短期记忆';
    _log('记忆块', '🧠 $label 已更新（${trimmed.length} 字）');
    if (trimmed.length > budget) {
      return '$label已更新（${trimmed.length} 字，超过 $budget 字预算——'
          '注入时会被截断，建议精简，把细节留给工具查）';
    }
    return '$label已更新（${trimmed.length} 字）';
  }

  /// 读取单块（男主 get 用）
  static Future<String> get(String personaId, String kind) async {
    final m = await _read(personaId);
    final label = kind == 'long' ? '长期记忆' : '短期记忆';
    final v = (m[kind] ?? '').toString().trim();
    if (v.isEmpty) return '$label还是空的——把平时观察到的、不用查就该知道的事写进来'
        '（manage_memory_block 动作=set_long 内容=…）';
    return '【$label】\n$v';
  }

  /// 注入文本（固定区，历史前）——有内容注入内容，空注入"（无）"占位，
  /// 保证块数/位置固定（内容低频变，占位永远在）
  static String text(String personaId) {
    final m = _memCache ?? <String, dynamic>{};
    final long = (m['long'] ?? '').toString().trim();
    final short = (m['short'] ?? '').toString().trim();
    final sb = StringBuffer();
    // 长期记忆：预算截断 + 提示（用户：超了提示就好，不强制改）
    sb.writeln('【长期记忆】（男主维护：她不用查就该知道的事——喜好/对待方式/'
        '工作习惯/话题导航。平时冻结，压缩节点才整理更新）');
    if (long.isEmpty) {
      sb.writeln('（无）');
    } else {
      sb.writeln(long.length > budget
          ? '${long.substring(0, budget)}…（超预算截断，用 manage_memory_block '
              '动作=get_long 查全文；建议精简到 $budget 字内）'
          : long);
    }
    sb.writeln('【短期记忆】（男主临时观察、还不确定的事；上下文压缩时浓缩进来；'
        '观察稳定就升级进长期记忆）');
    if (short.isEmpty) {
      sb.writeln('（无）');
    } else {
      sb.writeln(short.length > budget
          ? '${short.substring(0, budget)}…（超预算截断，用 manage_memory_block '
              '动作=get_short 查全文）'
          : short);
    }
    return sb.toString().trim();
  }

  /// 是否有内容（工具 status 用）
  static Future<Map<String, int>> count(String personaId) async {
    final m = await _read(personaId);
    return {
      'long': (m['long'] ?? '').toString().trim().length,
      'short': (m['short'] ?? '').toString().trim().length,
    };
  }
}
