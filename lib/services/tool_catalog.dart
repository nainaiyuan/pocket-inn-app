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
      'record_relation': '记关系（谁→谁→什么+原话+时间+归属，织成关系网）',
      // 8-09 21:3x（t7 三次出现：男主用 query_record 查她的事）：
      // 明确区分——查"她的事"只用 recall_memory，query_record 是查分类树
      'recall_memory': '查她的事（她说过/你记过的喜好、约定、日常、事实）——**查她的事优先用这个**',
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
      // 8-09 21:3x（t7）：明确"不是查她的事"——防止男主选型混乱
      'query_record': '查分类记录树（你自己的知识分类/候选分类路径）——**不是查她的事**，查她的事用 recall_memory',
      'add_record': '记分类记录（你自己整理的知识分类）',
      'manage_record_tree': '调分类（改名/挪动/删除，必须她审批）',
    },
    '排查反馈': {
      'query_logs': '查日志（查系统日志，排查问题用）',
      'report_bug': '报 bug 给她',
    },
    '自管理': {
      'manage_pad': '整理临时记忆（你的便签：随手记的/干到一半的，自己维护）',
      'manage_flow': '旧长任务卡片系统（8-10 已停用：长任务直接做，不用立流程；除非有遗留卡片要收尾，否则不要用）',
      'manage_chat_flow': '调整对话流程（merge 融合步骤/delete 删除步骤/status 查看）',
      'manage_tool_manual': '工具使用手册（格式/示例/坑，add/get/list/remove）',
      'manage_tool_test': '工具测试任务（start/report/status/abort，管家维护清单）',
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

  /// 8-08 15:5x（用户反馈：manage_frequent_tools 传中文名加不进）：
  /// 工具名解析——英文精确 → 中文描述包含匹配（"记她的事"→record_memory）。
  /// 找不到返回 null。
  static String? resolveName(String input) {
    final n = input.trim();
    if (n.isEmpty) return null;
    if (allNames.contains(n)) return n; // 英文精确
    for (final tools in categories.values) {
      for (final entry in tools.entries) {
        final desc = entry.value.replaceAll('（', '').replaceAll('）', '');
        if (desc.contains(n) || n.contains(entry.key)) {
          return entry.key;
        }
      }
    }
    // 再试一次：输入可能带了括号/多余字符（如"record_memory（记她的事）"）
    for (final tools in categories.values) {
      for (final entry in tools.entries) {
        if (n.startsWith(entry.key) || entry.key.startsWith(n)) {
          return entry.key;
        }
      }
    }
    return null;
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
