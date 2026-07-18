/// 男主管理模块
///
/// 用户管理所有男主的入口。
///
/// 每个男主（Character）可以有多个身份（Identity）。

import 'identity_models.dart';
/// 身份之间可以设定记忆贯通度：
///   - all：知道所有身份的事
///   - current：只知道自己的事
///   - selected：知道指定的几个身份的事
///
/// 用户还可以：
///   - 新增/删除男主
///   - 给男主新增身份
///   - 切换哪个身份是当前活动的
///   - 查看男主详情（有哪些碎片、多少条规律、记忆数）

/// 男主模型
class Character {
  final String id;
  String name;
  String description;    // 一句话简介
  String? avatarAsset;   // 头像图片路径
  final List<IdentityInfo> identities;
  bool isActive;          // 当前是否是这个男主在对话
  DateTime createdAt;
  DateTime updatedAt;

  /// 统计信息（只读，由外部更新）
  int fragmentCount = 0;
  int patternCount = 0;
  int memoryCount = 0;
  int chatLogCount = 0;

  Character({
    required this.id,
    required this.name,
    this.description = '',
    this.avatarAsset,
    List<IdentityInfo>? identities,
    this.isActive = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : identities = identities ?? [],
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// 当前活动的身份
  IdentityInfo? get activeIdentity {
    try {
      return identities.firstWhere((i) => i.isMain);
    } catch (_) {
      return identities.isNotEmpty ? identities.first : null;
    }
  }

  void setMainIdentity(String identityId) {
    for (int i = 0; i < identities.length; i++) {
      final old = identities[i];
      identities[i] = IdentityInfo(
        characterId: old.characterId,
        identityId: old.identityId,
        identityName: old.identityName,
        linkage: old.linkage,
        selectedIds: old.selectedIds,
        isMain: old.identityId == identityId,
      );
    }
  }
  /// 添加身份
  void addIdentity(IdentityInfo identity) {
    identities.add(identity);
    updatedAt = DateTime.now();
  }

  /// 删除身份
  void removeIdentity(String identityId) {
    identities.removeWhere((i) => i.identityId == identityId);
    updatedAt = DateTime.now();
  }

  /// 更新身份的贯通度设置
  void updateLinkage(String identityId, MemoryLinkage linkage, {Set<String>? selectedIds}) {
    final idx = identities.indexWhere((i) => i.identityId == identityId);
    if (idx >= 0) {
      final old = identities[idx];
      identities[idx] = IdentityInfo(
        characterId: id,
        identityId: old.identityId,
        identityName: old.identityName,
        linkage: linkage,
        selectedIds: selectedIds ?? old.selectedIds,
        isMain: old.isMain,
      );
      updatedAt = DateTime.now();
    }
  }

  /// 检查某个身份是否能访问另一个身份的记忆
  bool canAccess(String fromIdentityId, String toIdentityId) {
    final from = identities.where((i) => i.identityId == fromIdentityId).firstOrNull;
    return from?.canAccess(toIdentityId) ?? false;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'avatar': avatarAsset ?? '',
    'identities': identities.map((i) => i.toMap()).toList(),
    'is_active': isActive ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'stats': {
      'fragments': fragmentCount,
      'patterns': patternCount,
      'memories': memoryCount,
      'chat_logs': chatLogCount,
    },
  };

  factory Character.fromJson(Map<String, dynamic> json) {
    final identitiesRaw = json['identities'] as List? ?? [];
    final stats = json['stats'] as Map<String, dynamic>? ?? {};
    final c = Character(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      avatarAsset: (json['avatar'] as String?)?.isEmpty == true ? null : json['avatar'] as String?,
      identities: identitiesRaw.map((i) => IdentityInfo(
        characterId: json['id'] as String,
        identityId: (i as Map)['identity_id'] as String,
        identityName: i['identity_name'] as String,
        linkage: MemoryLinkage.values.firstWhere(
          (l) => l.name == (i['memory_linkage'] as String? ?? 'current'),
        ),
        selectedIds: (i['selected_ids'] as String? ?? '').split(',').where((s) => s.isNotEmpty).toSet(),
        isMain: (i['is_main'] as int?) == 1,
      )).toList(),
      isActive: (json['is_active'] as int?) == 1,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
    c.fragmentCount = (stats['fragments'] as int?) ?? 0;
    c.patternCount = (stats['patterns'] as int?) ?? 0;
    c.memoryCount = (stats['memories'] as int?) ?? 0;
    c.chatLogCount = (stats['chat_logs'] as int?) ?? 0;
    return c;
  }
}

/// 男主管理器
class CharacterManager {
  final Map<String, Character> _characters = {};
  String? _activeCharacterId;

  /// 添加一个男主
  void addCharacter(Character character) {
    _characters[character.id] = character;
    // 如果是第一个男主，自动设为活动
    if (_characters.length == 1) {
      character.isActive = true;
      _activeCharacterId = character.id;
    }
  }

  /// 删除一个男主
  void removeCharacter(String characterId) {
    _characters.remove(characterId);
    if (_activeCharacterId == characterId) {
      _activeCharacterId = _characters.isNotEmpty ? _characters.keys.first : null;
      if (_activeCharacterId != null) {
        _characters[_activeCharacterId!]!.isActive = true;
      }
    }
  }

  /// 获取所有男主
  List<Character> getAllCharacters() => _characters.values.toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// 获取活动男主
  Character? get activeCharacter => _activeCharacterId != null
      ? _characters[_activeCharacterId]
      : null;

  /// 切换活动男主
  void switchCharacter(String characterId) {
    // 取消旧的活动
    if (_activeCharacterId != null) {
      _characters[_activeCharacterId]!.isActive = false;
    }
    // 设置新的
    if (_characters.containsKey(characterId)) {
      _characters[characterId]!.isActive = true;
      _activeCharacterId = characterId;
    }
  }

  /// 更新男主信息
  void updateCharacter(String characterId, {String? name, String? description, String? avatarAsset}) {
    final c = _characters[characterId];
    if (c != null) {
      if (name != null) c.name = name;
      if (description != null) c.description = description;
      if (avatarAsset != null) c.avatarAsset = avatarAsset;
      c.updatedAt = DateTime.now();
    }
  }

  /// 为男主添加身份
  void addIdentity(String characterId, IdentityInfo identity) {
    _characters[characterId]?.addIdentity(identity);
  }

  /// 删除男主的一个身份
  void removeIdentity(String characterId, String identityId) {
    _characters[characterId]?.removeIdentity(identityId);
  }

  /// 按名字搜索男主
  List<Character> search(String query) {
    final q = query.toLowerCase();
    return _characters.values.where((c) =>
      c.name.toLowerCase().contains(q) ||
      c.description.toLowerCase().contains(q)
    ).toList();
  }

  /// 获取男主的关键信息摘要（给用户看）
  String getCharacterSummary(String characterId) {
    final c = _characters[characterId];
    if (c == null) return '未找到该男主';
    final active = c.activeIdentity;
    return '''
📋 ${c.name}
${c.description}

身份 (${c.identities.length})：
${c.identities.map((i) => '  ${i.isMain ? "★ " : "  "}${i.identityName}（${i.linkage.label}）').join('\n')}

统计：
  🧩 ${c.fragmentCount} 条设定
  📊 ${c.patternCount} 条规律
  💭 ${c.memoryCount} 条记忆
  💬 ${c.chatLogCount} 条对话记录
${active != null ? '\n当前身份：${active.identityName}' : ''}
''';
  }

  /// 所有男主的简要列表
  String getCharacterListDisplay() {
    final chars = getAllCharacters();
    if (chars.isEmpty) return '还没有添加任何男主';
    return chars.map((c) {
      final count = c.identities.length;
      return '${c.isActive ? "▶ " : "  "}${c.name}（${count}个身份${count > 1 ? "s" : ""}）';
    }).join('\n');
  }

  /// 导出为 JSON
  List<Map<String, dynamic>> exportToJson() {
    return _characters.values.map((c) => c.toJson()).toList();
  }

  /// 从 JSON 导入
  void importFromJson(List<Map<String, dynamic>> jsonList) {
    for (final json in jsonList) {
      final c = Character.fromJson(json);
      // 不覆盖已有
      if (!_characters.containsKey(c.id)) {
        _characters[c.id] = c;
      }
    }
  }
}
