/// 保险箱存储 — 加密文件索引表（vault_index 表）
///
/// 保险箱 = 用户的重要文件（照片/文档/音频），加密后存本地。
/// 这里只存索引，文件本体加密存放，路径由 SecureVault 管理。
library;

import 'package:sqflite/sqflite.dart';

import 'butler_store.dart';

/// 保险箱条目
class VaultEntry {
  final String id;
  final String fileName;
  final String fileType; // image / document / audio / other
  final int fileSize;
  final String category;
  final String? note;

  const VaultEntry({
    required this.id,
    required this.fileName,
    this.fileType = 'other',
    this.fileSize = 0,
    this.category = '默认',
    this.note,
    this.createdAt,
    this.lastAccessedAt,
  });

  /// 创建时间（可空，默认取当前时间）
  final DateTime? createdAt;

  /// 最后访问时间（可空，默认取当前时间）
  final DateTime? lastAccessedAt;

  DateTime get createdTime => createdAt ?? DateTime.now();
  DateTime get lastAccessTime => lastAccessedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'fileType': fileType,
    'fileSize': fileSize,
    'category': category,
    'note': note,
    'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
    'lastAccessedAt': (lastAccessedAt ?? DateTime.now()).toIso8601String(),
  };

  factory VaultEntry.fromJson(Map<String, dynamic> json) => VaultEntry(
    id: json['id'] as String,
    fileName: json['fileName'] as String,
    fileType: json['fileType'] as String? ?? 'other',
    fileSize: json['fileSize'] as int? ?? 0,
    category: json['category'] as String? ?? '默认',
    note: json['note'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    lastAccessedAt: DateTime.tryParse(json['lastAccessedAt'] as String? ?? ''),
  );
}

/// 保险箱存储
class VaultStore extends ButlerStore {
  @override
  String get id => 'vault';

  @override
  String get name => '保险箱';

  static const String table = 'vault_index';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        fileName TEXT NOT NULL,
        fileType TEXT DEFAULT 'other',
        fileSize INTEGER DEFAULT 0,
        category TEXT DEFAULT '默认',
        note TEXT,
        createdAt TEXT NOT NULL,
        lastAccessedAt TEXT NOT NULL
      )
    ''');
  }

  /// 添加条目
  Future<void> add(VaultEntry entry) async {
    await insert(table, entry.toJson());
  }

  /// 全部条目（按时间倒序）
  Future<List<VaultEntry>> all() async {
    final results = await db.query(table, orderBy: 'createdAt DESC');
    return results.map((r) => VaultEntry.fromJson(r)).toList();
  }

  /// 按分类查询
  Future<List<VaultEntry>> byCategory(String category) async {
    final results = await db.query(
      table,
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'createdAt DESC',
    );
    return results.map((r) => VaultEntry.fromJson(r)).toList();
  }

  /// 删除条目
  Future<void> remove(String id) async {
    await delete(table, where: 'id = ?', whereArgs: [id]);
  }

  /// 更新访问时间
  Future<void> touch(String id) async {
    await update(
      table,
      {'lastAccessedAt': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
