/// 用户记忆 — 专门管"用户想让男主记住的事"
///
/// 来源：
///   1. 对话后男主返回的总结
///   2. 用户手动添加/修改
///
/// 每条记忆按固定模板存，方便检索和整理。
///
/// 模板：
///   [谁] [和谁] [什么时间] [做了/经历了] [什么事] [感受/结果]
///
/// 例子：
///   "我和朋友上周去了新开的猫咖，很开心"
///   "我在公司年会上抽中了一等奖，特别惊喜"
///   "我最近在学做甜点，做得一般但很有趣"
///
/// 男主每次聊到时可以看到这些 → 显得他记得用户的事。

/// 用户记忆模板字段
class UserMemory {
  final String id;
  final String subject;   // 谁（默认"我"）
  final String? withWhom; // 和谁（朋友、家人、同事等）
  String? time;           // 什么时间（上周、去年、3月等）
  final String action;    // 做了什么
  final String? feeling;  // 感受/结果
  final String category;  // 分类（社交、工作、兴趣、健康、家庭等）
  final List<String> tags; // 标签，方便检索
  final DateTime createdAt;
  DateTime updatedAt;
  bool isUserCreated; // true=用户自己加的，false=男主总结的

  UserMemory({
    required this.id,
    this.subject = '我',
    this.withWhom,
    this.time,
    required this.action,
    this.feeling,
    required this.category,
    this.tags = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isUserCreated = false,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// 按模板格式化为完整句子
  String toSentence() {
    final parts = <String>[subject];
    if (withWhom != null) parts.add('和$withWhom');
    if (time != null) parts.add(time!);
    parts.add(action);
    if (feeling != null) parts.add('，$feeling');
    return parts.join('');
  }

  /// 格式化为上下文（给男主看的）
  String toContext() {
    return '（[用户] $subject${withWhom != null ? "和$withWhom" : ""}${time != null ? time! : ""}$action${feeling != null ? "，$feeling" : ""}）';
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'subject': subject,
    'with_whom': withWhom,
    'time': time,
    'action': action,
    'feeling': feeling,
    'category': category,
    'tags': tags.join(','),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'is_user_created': isUserCreated ? 1 : 0,
  };

  factory UserMemory.fromMap(Map<String, dynamic> map) => UserMemory(
    id: map['id'] as String,
    subject: map['subject'] as String? ?? '我',
    withWhom: map['with_whom'] as String?,
    time: map['time'] as String?,
    action: map['action'] as String,
    feeling: map['feeling'] as String?,
    category: map['category'] as String,
    tags: (map['tags'] as String?)?.split(',').where((t) => t.isNotEmpty).toList() ?? [],
    createdAt: DateTime.parse(map['created_at'] as String),
    updatedAt: DateTime.parse(map['updated_at'] as String),
    isUserCreated: (map['is_user_created'] as int?) == 1,
  );
}

/// 用户记忆管理器
class UserMemoryManager {
  final List<UserMemory> _memories = [];

  /// 添加一条记忆（男主总结或用户手动）
  void add(UserMemory memory) {
    _memories.add(memory);
  }

  /// 修改一条记忆
  void update(String id, {String? withWhom, String? time, String? action, String? feeling, String? category, List<String>? tags}) {
    final idx = _memories.indexWhere((m) => m.id == id);
    if (idx >= 0) {
      final old = _memories[idx];
      _memories[idx] = UserMemory(
        id: old.id,
        subject: old.subject,
        withWhom: withWhom ?? old.withWhom,
        time: time ?? old.time,
        action: action ?? old.action,
        feeling: feeling ?? old.feeling,
        category: category ?? old.category,
        tags: tags ?? old.tags,
        createdAt: old.createdAt,
        updatedAt: DateTime.now(),
        isUserCreated: true, // 用户改过就标记为用户创建的
      );
    }
  }

  /// 删除一条记忆
  void delete(String id) {
    _memories.removeWhere((m) => m.id == id);
  }

  /// 按关键词/标签搜索记忆
  ///
  /// 双向匹配：
  /// 1. 整句/拆词 contains 匹配记忆内容
  /// 2. 记忆的 tags（关键词）出现在输入里 → 命中（如记忆 tag=咖啡，输入"想喝咖啡"命中）
  List<UserMemory> search(String query) {
    final q = query.toLowerCase();

    final scored = <({UserMemory memory, int hits})>[];
    for (final m in _memories) {
      var hits = 0;

      // 方向1：记忆内容 contains 查询词（整句直接匹配）
      if (_match(m, q)) hits += 2;

      // 方向2：查询拆词，逐词匹配记忆内容
      final words = q
          .split(RegExp(r'[，。！？、,.!?\s]+'))
          .where((w) => w.length >= 2)
          .toList();
      for (final w in words) {
        if (_match(m, w)) hits++;
      }

      // 方向3：记忆 tags 出现在查询里（关键词命中，最重要）
      final tagHits = m.tags.where((t) => t.isNotEmpty && q.contains(t)).length;
      hits += tagHits * 3;

      if (hits > 0) scored.add((memory: m, hits: hits));
    }

    scored.sort((a, b) {
      final byHits = b.hits.compareTo(a.hits);
      if (byHits != 0) return byHits;
      return b.memory.updatedAt.compareTo(a.memory.updatedAt);
    });
    return scored.map((s) => s.memory).toList();
  }

  bool _match(UserMemory m, String q) {
    return m.action.contains(q) ||
        (m.withWhom?.contains(q) ?? false) ||
        (m.feeling?.contains(q) ?? false) ||
        m.tags.any((t) => t.contains(q)) ||
        m.category.contains(q);
  }

  /// 多条件筛选记忆（给可视化页面用）
  /// 所有参数都是可选——传什么就查什么，不传就跳过
  List<UserMemory> filter({
    String? keyword,       // 关键词（匹配 action / feeling / withWhom / tags / category）
    String? characterId,   // 男主ID（只在 future 有 withWhom 映射时生效）
    DateTime? from,        // 起始时间
    DateTime? to,          // 截止时间
    String? category,      // 分类筛选
    String? moodTag,       // 情绪标签
    bool? isUserCreated,   // 用户自己写的 / 男主总结的
    int limit = 50,        // 最多返回条数
  }) {
    var results = _memories.where((m) {
      if (keyword != null && keyword.isNotEmpty) {
        final q = keyword.toLowerCase();
        final matches = m.action.contains(q) ||
            (m.withWhom?.contains(q) ?? false) ||
            (m.feeling?.contains(q) ?? false) ||
            m.tags.any((t) => t.contains(q)) ||
            m.category.contains(q);
        if (!matches) return false;
      }
      if (from != null && m.createdAt.isBefore(from)) return false;
      if (to != null && m.createdAt.isAfter(to)) return false;
      if (category != null && m.category != category) return false;
      if (moodTag != null && !(m.feeling?.contains(moodTag) ?? false)) return false;
      if (isUserCreated != null && m.isUserCreated != isUserCreated) return false;
      return true;
    }).toList();

    results.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (results.length > limit) results = results.sublist(0, limit);
    return results;
  }

  /// 按时间段删除日常记录
  /// 用于用户说"删掉7月10号到15号的记录"
  /// 注意：只删 category='daily' 的日常记录，不删用户手动写的
  /// [excludeKeywords]: 排除列表——包含这些关键词的记录不删
  /// 例如 deleteByDateRange(7/1, 7/31, excludeKeywords: ["猫咪"])
  ///   → 7月记录全删，但提到猫咪的留着
  int deleteByDateRange(DateTime start, DateTime end, {List<String> excludeKeywords = const []}) {
    final before = _memories.length;
    _memories.removeWhere((m) {
      if (m.category != 'daily') return false;
      if (!m.createdAt.isAfter(start) || !m.createdAt.isBefore(end)) return false;
      // 如果记录了关键词，检查是否需要保护
      if (excludeKeywords.isNotEmpty) {
        final content = '${m.action} ${m.feeling ?? ''} ${m.withWhom ?? ''} ${m.tags.join(' ')}'.toLowerCase();
        if (excludeKeywords.any((kw) => content.contains(kw.toLowerCase()))) {
          return false; // 保护——不删
        }
      }
      return true;
    });
    return before - _memories.length;
  }

  /// 按分类获取
  List<UserMemory> getByCategory(String category) {
    return _memories.where((m) => m.category == category).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// 获取全部
  List<UserMemory> getAll() => List.from(_memories)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// 从男主回复中提取用户记忆
  /// 男主回复时可以按模板返回总结：
  ///   #记忆 我和朋友上周去了猫咖 很开心 社交
  UserMemory? extractFromReply(String reply) {
    if (!reply.contains('#记忆')) return null;

    // 格式：#记忆 谁[和谁][什么时间]做了什么 感受 分类
    final lines = reply.split('\n');
    for (final line in lines) {
      if (!line.trim().startsWith('#记忆')) continue;

      final parts = line.replaceFirst('#记忆', '').trim().split(' ');
      if (parts.length < 2) return null;

      final content = parts[0];
      final feeling = parts.length > 1 ? parts[1] : null;
      final category = parts.length > 2 ? parts[2] : '日常';

      // 从内容中尝试解析模板字段
      String? withWhom;
      String? time;
      String action = content;

      // 尝试提取"和XX"部分
      final withMatch = RegExp(r'和(\S+)').firstMatch(content);
      if (withMatch != null) {
        withWhom = withMatch.group(1);
        action = action.replaceAll(withMatch.group(0)!, '').trim();
      }

      // 尝试提取时间词
      const timeWords = ['今天', '昨天', '前天', '上周', '这周', '下周',
        '上个月', '这个月', '去年', '今年', '前几天'];
      for (final tw in timeWords) {
        if (action.startsWith(tw)) {
          time = tw;
          action = action.replaceFirst(tw, '').trim();
          break;
        }
      }

      return UserMemory(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        subject: '我',
        withWhom: withWhom,
        time: time,
        action: action,
        feeling: feeling,
        category: category,
        isUserCreated: false,
      );
    }
    return null;
  }
}
