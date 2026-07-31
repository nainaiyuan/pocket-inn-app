import 'dart:convert';

/// 管家记忆节点
/// 每条记忆 = 用户说的一条有价值的信息
class ButlerMemory {
  final String id;
  final String sessionId;       // 属于哪个会话
  final String content;         // 记忆内容（原始，未假面化）
  final String maskedContent;   // 假面化后的内容（发给 AI 用的版本）
  final String topic;           // 话题标签（如 'family', 'mood', 'health'）
  final String importance;      // 'core' | 'normal' | 'temp'
  final List<String> keywords;  // 关键词，用于搜索
  final String? source;         // 来源男主ID（null=用户主动记录）
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isArchived;        // 是否已归档（标记删除）

  ButlerMemory({
    required this.id,
    required this.sessionId,
    required this.content,
    this.maskedContent = '',
    this.topic = '',
    this.importance = 'normal',
    this.keywords = const [],
    this.source,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isArchived = false,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'content': content,
    'maskedContent': maskedContent,
    'topic': topic,
    'importance': importance,
    'keywords': jsonEncode(keywords),
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'isArchived': isArchived ? 1 : 0,
  };

  factory ButlerMemory.fromJson(Map<String, dynamic> json) => ButlerMemory(
    id: json['id'] as String,
    sessionId: json['sessionId'] as String,
    content: json['content'] as String,
    maskedContent: json['maskedContent'] as String? ?? '',
    topic: json['topic'] as String? ?? '',
    importance: json['importance'] as String? ?? 'normal',
    keywords: (json['keywords'] is String)
        ? (jsonDecode(json['keywords'] as String) as List).cast<String>()
        : [],
    source: json['source'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    isArchived: json['isArchived'] == 1,
  );
}
