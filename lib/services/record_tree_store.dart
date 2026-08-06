import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 🌳 男主自管分类记录（8-06 18:41-19:21 用户设计）
///
/// 核心：
/// - **分类树**：归属(用户/男主/其他) → 关系(家人/亲戚) → 对象(妈妈) → 类别(喜好)
///   男主按格式模板猜，可随时改（家人→亲戚）、加（前面加大类）、细分
/// - **记录条目**：挂在分类节点下，多组关键词（a+b / a+b+c / b+d 任一命中即调出）
///   + 原话/时间（多条单句合并进同一分类）
/// - **查**：关键词命中条目（组 ⊆ 输入词）；对象名查候选分类路径（用户·家人·妈妈…）
/// - **改分类影响用户 → 弹窗审批**（男主先查后改，改对用户确认才生效）
class RecordTreeStore {
  RecordTreeStore._();
  static final RecordTreeStore instance = RecordTreeStore._();

  static const _key = 'record_tree_v1';

  static RecordTree? _cache;

  /// 同步读缓存（prompt 注入用；未加载过返回 null）
  static RecordTree? cached() => _cache;

  static Future<RecordTree> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    RecordTree tree;
    if (raw != null && raw.isNotEmpty) {
      try {
        tree = RecordTree.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw) as Map));
      } catch (_) {
        tree = RecordTree();
      }
    } else {
      tree = RecordTree();
    }
    _cache = tree;
    return tree;
  }

  static Future<void> save(RecordTree tree) async {
    _cache = tree;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(tree.toJson()));
  }

  static String newId(String prefix) => '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

  // ─── 节点操作 ───

  /// 找节点：按路径（[用户, 家人, 妈妈]），不存在返回 null
  static RecordNode? nodeByPath(RecordTree tree, List<String> path) {
    RecordNode? found;
    var children = tree.roots;
    for (final name in path) {
      found = children.where((n) => n.name == name).firstOrNull;
      if (found == null) return null;
      children = tree.childrenOf(found.id);
    }
    return found;
  }

  /// 节点路径文本（用户·家人·妈妈）
  static String pathText(RecordTree tree, String nodeId) {
    final parts = <String>[];
    var id = nodeId;
    var guard = 0;
    while (id.isNotEmpty && guard < 20) {
      final n = tree.nodeById(id);
      if (n == null) break;
      parts.insert(0, n.name);
      id = n.parentId ?? '';
      guard++;
    }
    return parts.join('·');
  }

  /// 候选分类路径：名字含 [keyword] 的所有节点路径（查"妈妈" → 用户·家人·妈妈 / 用户·亲戚·妈妈）
  static List<String> candidatePaths(RecordTree tree, String keyword) {
    final out = <String>[];
    void walk(List<RecordNode> nodes) {
      for (final n in nodes) {
        if (n.name.contains(keyword)) {
          out.add(pathText(tree, n.id));
        }
        walk(tree.childrenOf(n.id));
      }
    }

    walk(tree.roots);
    return out;
  }

  /// 找记录：任一关键词组 ⊆ 输入词集合 → 命中（同分类下的记录一起返回）
  static List<RecordEntry> matchEntries(RecordTree tree, List<String> words) {
    final set = words.toSet();
    final hits = <RecordEntry>[];
    for (final e in tree.entries) {
      for (final g in e.keywordGroups) {
        if (g.every(set.contains)) {
          hits.add(e);
          break;
        }
      }
    }
    return hits;
  }
}

/// 分类树 + 记录
class RecordTree {
  List<RecordNode> nodes;
  List<RecordEntry> entries;

  RecordTree({List<RecordNode>? nodes, List<RecordEntry>? entries})
      : nodes = nodes ?? _defaultNodes(),
        entries = entries ?? [];

  static List<RecordNode> _defaultNodes() {
    // 预置归属根：用户 / 男主 / 其他
    final now = DateTime.now();
    return [
      RecordNode(
          id: 'root_user', name: '用户', parentId: null,
          createdAt: now),
      RecordNode(
          id: 'root_male', name: '男主', parentId: null,
          createdAt: now),
      RecordNode(
          id: 'root_other', name: '其他', parentId: null,
          createdAt: now),
    ];
  }

  List<RecordNode> get roots =>
      nodes.where((n) => n.parentId == null).toList();

  List<RecordNode> childrenOf(String parentId) =>
      nodes.where((n) => n.parentId == parentId).toList();

  RecordNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// 加节点（path 是父路径，name 是新节点名）；父不存在自动创建
  RecordNode ensureNode(List<String> path, String name) {
    var parentId = _ensurePath(path);
    final exist = nodes
        .where((n) => n.parentId == parentId && n.name == name)
        .firstOrNull;
    if (exist != null) return exist;
    final node = RecordNode(
      id: RecordTreeStore.newId('rn'),
      name: name,
      parentId: parentId,
      createdAt: DateTime.now(),
    );
    nodes.add(node);
    return node;
  }

  String? _ensurePath(List<String> path) {
    String? parentId;
    for (final name in path) {
      final exist = nodes
          .where((n) => n.parentId == parentId && n.name == name)
          .firstOrNull;
      if (exist != null) {
        parentId = exist.id;
      } else {
        final node = RecordNode(
          id: RecordTreeStore.newId('rn'),
          name: name,
          parentId: parentId,
          createdAt: DateTime.now(),
        );
        nodes.add(node);
        parentId = node.id;
      }
    }
    return parentId;
  }

  /// 改名（保持子树）
  bool renameNode(String nodeId, String newName) {
    final n = nodeById(nodeId);
    if (n == null) return false;
    n.name = newName;
    return true;
  }

  /// 移动节点（换父；挂到新父下，子树跟着走）
  bool moveNode(String nodeId, String newParentId) {
    final n = nodeById(nodeId);
    if (n == null || n.id == newParentId) return false;
    // 防环：新父不能是自己的子孙
    var p = nodeById(newParentId);
    while (p != null) {
      if (p.id == nodeId) return false;
      p = p.parentId == null ? null : nodeById(p.parentId!);
    }
    n.parentId = newParentId;
    return true;
  }

  /// 删节点（子树 + 挂在其下的记录一起删；空树保护：根不可删）
  bool deleteNode(String nodeId) {
    final n = nodeById(nodeId);
    if (n == null || n.parentId == null) return false; // 根不删
    final toDelete = <String>{nodeId};
    // 收集子树
    var changed = true;
    while (changed) {
      changed = false;
      for (final c in nodes) {
        if (c.parentId != null && toDelete.contains(c.parentId)) {
          toDelete.add(c.id);
          changed = true;
        }
      }
    }
    nodes.removeWhere((n) => toDelete.contains(n.id));
    entries.removeWhere((e) => toDelete.contains(e.nodeId));
    return true;
  }

  Map<String, dynamic> toJson() => {
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  factory RecordTree.fromJson(Map<String, dynamic> j) => RecordTree(
        nodes: (j['nodes'] as List?)
                ?.map((e) =>
                    RecordNode.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            [],
        entries: (j['entries'] as List?)
                ?.map((e) =>
                    RecordEntry.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            [],
      );
}

/// 分类节点
class RecordNode {
  String id;
  String name;
  String? parentId;
  final DateTime createdAt;

  RecordNode({
    required this.id,
    required this.name,
    required this.parentId,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'createdAt': createdAt.toIso8601String(),
      };

  factory RecordNode.fromJson(Map<String, dynamic> j) => RecordNode(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        parentId: j['parentId']?.toString(),
        createdAt:
            DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
      );
}

/// 记录条目：挂在分类节点下
class RecordEntry {
  String id;
  String nodeId;
  List<List<String>> keywordGroups; // 多组关键词，任一组全命中即命中
  List<RecordNote> notes; // 原话+时间（多条单句合并进同一分类）
  String? summary; // 一句话说明（男主写的）

  RecordEntry({
    required this.id,
    required this.nodeId,
    List<List<String>>? keywordGroups,
    List<RecordNote>? notes,
    this.summary,
  })  : keywordGroups = keywordGroups ?? [],
        notes = notes ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'nodeId': nodeId,
        'keywordGroups': keywordGroups,
        'notes': notes.map((n) => n.toJson()).toList(),
        'summary': summary,
      };

  factory RecordEntry.fromJson(Map<String, dynamic> j) => RecordEntry(
        id: j['id']?.toString() ?? '',
        nodeId: j['nodeId']?.toString() ?? '',
        keywordGroups: (j['keywordGroups'] as List?)
                ?.map((g) => (g as List).map((w) => w.toString()).toList())
                .toList() ??
            [],
        notes: (j['notes'] as List?)
                ?.map((e) =>
                    RecordNote.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            [],
        summary: j['summary']?.toString(),
      );
}

/// 一条原话（带时间，可溯源）
class RecordNote {
  final String text; // 原话
  final DateTime time;
  final String? source; // 哪来的（聊天/她自己说的…）

  RecordNote({
    required this.text,
    required this.time,
    this.source,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'time': time.toIso8601String(),
        'source': source,
      };

  factory RecordNote.fromJson(Map<String, dynamic> j) => RecordNote(
        text: j['text']?.toString() ?? '',
        time: DateTime.tryParse(j['time']?.toString() ?? '') ?? DateTime.now(),
        source: j['source']?.toString(),
      );
}
