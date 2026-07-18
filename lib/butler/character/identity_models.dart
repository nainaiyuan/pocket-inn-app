/// 男主身份数据模型

/// 记忆贯通度
/// 一个身份的设定记忆能够被其他身份看到多少
enum MemoryLinkage {
  /// 所有身份都共通知晓
  all,

  /// 只知道自己的事
  current,

  /// 知道指定的几个身份的事
  selected;

  String get label {
    switch (this) {
      case MemoryLinkage.all:
        return '全部贯通';
      case MemoryLinkage.current:
        return '仅自己';
      case MemoryLinkage.selected:
        return '选择性贯通';
    }
  }
}

/// 身份信息
class IdentityInfo {
  final String characterId;
  final String identityId;
  final String identityName;
  final MemoryLinkage linkage;
  final Set<String> selectedIds;  // 当 linkage=selected 时，这里存可以访问的身份ID列表
  final bool isMain;

  IdentityInfo({
    required this.characterId,
    required this.identityId,
    required this.identityName,
    this.linkage = MemoryLinkage.current,
    this.selectedIds = const {},
    this.isMain = false,
  });

  /// 检查这个身份是否能访问指定身份的记忆
  bool canAccess(String targetIdentityId) {
    if (identityId == targetIdentityId) return true;
    switch (linkage) {
      case MemoryLinkage.all:
        return true;
      case MemoryLinkage.current:
        return false;
      case MemoryLinkage.selected:
        return selectedIds.contains(targetIdentityId);
    }
  }

  Map<String, dynamic> toMap() => {
    'character_id': characterId,
    'identity_id': identityId,
    'identity_name': identityName,
    'memory_linkage': linkage.name,
    'selected_ids': selectedIds.join(','),
    'is_main': isMain ? 1 : 0,
  };

  factory IdentityInfo.fromMap(Map<String, dynamic> map, String charId) => IdentityInfo(
    characterId: charId,
    identityId: map['identity_id'] as String,
    identityName: map['identity_name'] as String,
    linkage: MemoryLinkage.values.firstWhere(
      (l) => l.name == (map['memory_linkage'] as String? ?? 'current'),
    ),
    selectedIds: (map['selected_ids'] as String? ?? '').split(',').where((s) => s.isNotEmpty).toSet(),
    isMain: (map['is_main'] as int?) == 1,
  );
}
