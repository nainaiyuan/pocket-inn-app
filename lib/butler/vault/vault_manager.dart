/// 保险箱管理器
///
/// 用户手动操作的私密文件存储区。
/// 管家核心不会读取保险箱内容，仅由 vault_page 调用。
/// 当前为骨架实现，后续接入 file_picker + 加密存储。

class VaultManager {
  final List<VaultEntry> _entries = [];

  Future<void> initialize() async {
    // TODO: 从加密存储加载文件列表
  }

  List<VaultEntry> listFiles() {
    return List.unmodifiable(_entries);
  }

  Future<void> addEntry(VaultEntry entry) async {
    _entries.add(entry);
    // TODO: 写入加密存储
  }

  Future<void> deleteEntry(String id) async {
    _entries.removeWhere((e) => e.id == id);
    // TODO: 从加密存储删除
  }

  Future<void> clear() async {
    _entries.clear();
    // TODO: 清空加密存储
  }
}

class VaultEntry {
  final String id;
  final String fileName;
  final int fileSize;
  final String fileType; // image, video, audio, text, other
  final String category; // 用户自定义分类

  const VaultEntry({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.fileType,
    required this.category,
  });
}
