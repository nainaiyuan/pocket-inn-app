import 'package:shared_preferences/shared_preferences.dart';

/// 🔧 工具目录（8-06 21:54 用户：不把全量工具写进 prompt——
/// 动态分类：男主看概览（每类干啥的+几个），细节自己查；
/// 常用工具他自己维护（manage_frequent_tools），概览里全量注入）
///
/// 结构：分类（人话，男主看得懂）→ 工具名 → 一句话说明。
/// 分类概览 = 注入 prompt 的默认形态；查详情 = list_tools {category}/{name}
class ToolCatalog {
  ToolCatalog._();

  /// 分类表（顺序即注入顺序）。说明用男主视角的人话。
  static const Map<String, Map<String, String>> categories = {
    '记忆': {
      'record_memory': '记她的事（喜好/约定/日常/事实，自动提取关键词）',
      'recall_memory': '查以前记的关于她的事',
      'save_identity_memory': '记代号人物（家人A/朋友B）的事',
      'write_diary': '写日记存档',
      'query_diary': '按关键词翻日记',
    },
    '通知互动': {
      'notify_user': '弹窗通知她（她能看到）',
      'countdown_card': '发计时卡片（倒计时提醒）',
      'manage_task': '管任务/卡片（撤销/调整/回应）',
    },
    '设定': {
      'update_setting': '改设定（必须她审批）',
      'query_setting_history': '查设定变更历史',
      'request_permission': '申请某能力免审批',
    },
    '分类记录': {
      'query_record': '查分类记录/候选分类路径',
      'add_record': '记分类记录（你自己整理）',
      'manage_record_tree': '调分类（改名/挪动/删除，必须她审批）',
    },
    '排查反馈': {
      'query_logs': '查系统日志（排查问题用）',
      'report_bug': '报 bug 给她',
    },
    '自管理': {
      'manage_pad': '整理便签（当前任务模块，你自己维护）',
      'continue_speaking': '继续说（不等她回，自动再生成一轮）',
      'resolve_pending': '标记待回复处理结果（回了的编号）',
      'manage_frequent_tools': '维护常用工具表（add/remove/list）',
      'list_tools': '查工具（分类/单个/概览）',
    },
  };

  static List<String> get allNames {
    final list = <String>[];
    for (final tools in categories.values) {
      list.addAll(tools.keys);
    }
    return list;
  }

  static int get totalCount => allNames.length;

  /// 分类概览（注入 prompt / list_tools 无参数）：'记忆 5 个：记她的事…'
  static String overview() {
    final lines = categories.entries.map((e) {
      final descs = e.value.values.take(2).join(' / ');
      return '- ${e.key} ${e.value.length} 个：$descs…';
    }).join('\n');
    return '你有 $totalCount 个工具，按分类组织（详细用法调 list_tools '
        '{category} 查，查完结果会记住，不用反复查）：\n$lines';
  }

  /// 某分类详情：'【记忆 5 个】\n- record_memory：…'；分类不存在返回 null
  static String? categoryDetail(String category) {
    final tools = categories[category];
    if (tools == null) return null;
    final lines = tools.entries
        .map((e) => '- ${e.key}：${e.value}')
        .join('\n');
    return '【$category ${tools.length} 个】\n$lines';
  }

  /// 单个工具详情；不存在返回 null
  static String? toolDetail(String name) {
    for (final tools in categories.values) {
      final desc = tools[name];
      if (desc != null) return '- $name：$desc';
    }
    return null;
  }
}

/// ⭐ 常用工具表（8-06 21:54 用户：给男主一个维护的地方，
/// 常用工具放概览里全量注入，不常用的按分类查）
class FrequentToolsStore {
  FrequentToolsStore._();

  static const _maxEntries = 8;

  static String _key(String personaId) => 'frequent_tools_$personaId';

  static final Map<String, List<String>> _memCache = {};

  static Future<void> _save(String personaId, List<String> list) async {
    _memCache[personaId] = list;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(personaId), list.join(','));
  }

  static Future<void> warm(String personaId) async {
    if (personaId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key(personaId));
    _memCache[personaId] = (raw == null || raw.isEmpty)
        ? <String>[]
        : raw.split(',').where((n) => n.isNotEmpty).toList();
  }

  static List<String> list(String personaId) =>
      List.of(_memCache[personaId] ?? const []);

  /// 常用工具文本（注入用）：'⭐ 常用：record_memory（记她的事）…'；空返回 null
  static String? text(String personaId) {
    final names = list(personaId);
    if (names.isEmpty) return null;
    final lines = names.map((n) {
      final desc = ToolCatalog.toolDetail(n);
      return desc ?? '- $n';
    }).join('\n');
    return '【你常用的工具】（你维护的，每次都在这；想不起来别的就调 '
        'list_tools 查分类）\n$lines';
  }

  /// 添加（不存在才加，满上限挤掉最旧的）；返回成功与否
  static Future<bool> add(String personaId, String name) async {
    if (!ToolCatalog.allNames.contains(name)) return false;
    final list = List<String>.from(_memCache[personaId] ?? const <String>[]);
    list.remove(name);
    list.insert(0, name);
    if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
    await _save(personaId, list);
    return true;
  }

  static Future<bool> remove(String personaId, String name) async {
    final list = List<String>.from(_memCache[personaId] ?? const <String>[]);
    final ok = list.remove(name);
    if (ok) await _save(personaId, list);
    return ok;
  }
}
