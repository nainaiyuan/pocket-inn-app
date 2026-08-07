import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../ai_provider/ai_provider_manager.dart';

/// 📚 设定版本管理（8-06 17:46-18:24 用户）
///
/// 男主设定 / 用户设定 = 可版本化的数据：
/// - 当前版（current）+ 历史版本堆叠（versions）+ 变更日志（changelog）
/// - 变更日志**只追加不删**（版本文件可删，但"改过什么"永远查得到）
/// - 版本不自动清理，用户看着删不删
/// - 男主可查历史（query_setting_history 工具）
/// - 改完 prompt 注入「设定变更摘要」（男主知道自己的演变史）
class SettingVersionStore {
  SettingVersionStore._();
  static final SettingVersionStore instance = SettingVersionStore._();

  static const male = 'male';
  static const user = 'user';

  static final Map<String, SettingBook> _cache = {};

  /// 同步读缓存（prompt 注入用；未加载过返回 null）
  static SettingBook? cached(String personaId) => _cache[personaId];

  static String _key(String personaId) => 'setting_versions_$personaId';

  /// 8-07 14:03：测试空间设定初始化——首次进入测试空间时，
  /// 从真实设定复制当前版（男主在测试里看到/改的是副本，退出测试模式即删）
  static Future<void> ensureTestCopy(String realPid) async {
    final testPid = '$realPid${AIProviderManager.mockTestSuffix}';
    final test = await load(testPid);
    if (test.currentMale.trim().isEmpty && test.currentUser.trim().isEmpty) {
      final real = await load(realPid);
      if (real.currentMale.trim().isNotEmpty) {
        await saveNewVersion(
          testPid,
          male,
          real.currentMale,
          note: '测试空间初始化（复制自真实设定）',
        );
      }
      if (real.currentUser.trim().isNotEmpty) {
        await saveNewVersion(
          testPid,
          user,
          real.currentUser,
          note: '测试空间初始化（复制自真实设定）',
        );
      }
    }
  }

  /// 8-07 14:03：按测试标签 __test 删除所有测试空间的设定版本
  /// （退出测试模式/清空测试数据时调用；真实设定零接触）
  static Future<void> deleteTestData() async {
    final p = await SharedPreferences.getInstance();
    final keys = p
        .getKeys()
        .where(
          (k) =>
              k.startsWith('setting_versions_') &&
              k.endsWith(AIProviderManager.mockTestSuffix),
        )
        .toList();
    for (final k in keys) {
      await p.remove(k);
      _cache.remove(k.substring('setting_versions_'.length));
    }
  }

  /// 单角色版本簿
  static Future<SettingBook> load(String personaId) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key(personaId));
    SettingBook book;
    if (raw != null && raw.isNotEmpty) {
      try {
        book = SettingBook.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      } catch (_) {
        book = SettingBook();
      }
    } else {
      book = SettingBook();
    }
    _cache[personaId] = book;
    return book;
  }

  static Future<void> _save(String personaId, SettingBook book) async {
    _cache[personaId] = book;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(personaId), jsonEncode(book.toJson()));
  }

  /// 覆盖当前版（不产生新版本）
  static Future<void> saveCurrent(
    String personaId,
    String type,
    String content,
  ) async {
    final book = await load(personaId);
    book.setCurrent(type, content);
    await _save(personaId, book);
  }

  /// 存为新版本（旧当前自动进历史堆叠）
  static Future<SettingVersion> saveNewVersion(
    String personaId,
    String type,
    String content, {
    String? note,
  }) async {
    final book = await load(personaId);
    final v = book.pushVersion(type, content, note: note);
    await _save(personaId, book);
    return v;
  }

  /// 8-07 18:0x 修复：右页手动「存为新版本」= 编辑框内容只存进历史堆叠，
  /// **不改变当前版**——否则连续存两个版本时，旧当前会重复进历史
  /// （a1=X 存完当前=X，再存 a2=Y 时旧当前还是 X → a2 也变成 X，a1/a2 相同）
  static Future<SettingVersion> saveAsVersion(
    String personaId,
    String type,
    String content, {
    String? note,
  }) async {
    final book = await load(personaId);
    final v = book.addHistoryVersion(type, content, note: note);
    await _save(personaId, book);
    return v;
  }

  /// 选用某个历史版本为当前（旧当前进历史）
  static Future<void> applyVersion(String personaId, String versionId) async {
    final book = await load(personaId);
    book.applyVersion(versionId);
    await _save(personaId, book);
  }

  /// 删除某个历史版本（当前版不可删；变更日志保留）
  static Future<bool> deleteVersion(String personaId, String versionId) async {
    final book = await load(personaId);
    final ok = book.deleteVersion(versionId);
    if (ok) await _save(personaId, book);
    return ok;
  }

  /// 追加变更日志（只追加不删）
  static Future<void> addChangelog(
    String personaId,
    String type,
    String summary,
  ) async {
    final book = await load(personaId);
    book.changelog.insert(
      0,
      ChangeEntry(time: DateTime.now(), type: type, summary: summary),
    );
    await _save(personaId, book);
  }

  static String newId() => 'sv_${DateTime.now().microsecondsSinceEpoch}';

  /// 同步版摘要（从缓存读，prompt 注入用）
  static String summaryTextSync(String personaId) {
    final book = _cache[personaId];
    if (book == null || book.changelog.isEmpty) return '';
    final buf = StringBuffer();
    for (final e in book.changelog.take(5)) {
      final t = e.time;
      final ts =
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')} '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
      buf.writeln('- $ts ${e.type == male ? '男主设定' : '用户设定'}：${e.summary}');
    }
    return buf.toString();
  }

  /// 变更摘要（prompt 注入用）：最近 5 条
  static Future<String> summaryText(String personaId) async {
    final book = await load(personaId);
    if (book.changelog.isEmpty) return '';
    final buf = StringBuffer();
    for (final e in book.changelog.take(5)) {
      final t = e.time;
      final ts =
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')} '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
      buf.writeln('- $ts ${e.type == male ? '男主设定' : '用户设定'}：${e.summary}');
    }
    return buf.toString();
  }
}

/// 一个角色的版本簿
class SettingBook {
  String currentMale; // 当前男主设定
  String currentUser; // 当前用户设定
  List<SettingVersion> versions; // 历史版本（堆叠，新的在前）
  List<ChangeEntry> changelog; // 变更日志（只追加）

  SettingBook({
    this.currentMale = '',
    this.currentUser = '',
    List<SettingVersion>? versions,
    List<ChangeEntry>? changelog,
  }) : versions = versions ?? [],
       changelog = changelog ?? [];

  String currentOf(String type) =>
      type == SettingVersionStore.male ? currentMale : currentUser;

  void setCurrent(String type, String content) {
    if (type == SettingVersionStore.male) {
      currentMale = content;
    } else {
      currentUser = content;
    }
  }

  /// 存新版本：旧当前进历史堆叠，新内容成当前
  SettingVersion pushVersion(String type, String content, {String? note}) {
    final old = currentOf(type);
    if (old.trim().isNotEmpty) {
      versions.insert(
        0,
        SettingVersion(
          id: SettingVersionStore.newId(),
          type: type,
          content: old,
          createdAt: DateTime.now(),
          note: note,
        ),
      );
    }
    setCurrent(type, content);
    return SettingVersion(
      id: SettingVersionStore.newId(),
      type: type,
      content: content,
      createdAt: DateTime.now(),
      note: note,
      isCurrent: true,
    );
  }

  /// 8-07 18:0x 修复：只进历史堆叠，当前版不动
  /// （右页手动存版本用；返回的新版本 id 用于 UI 定位）
  SettingVersion addHistoryVersion(
    String type,
    String content, {
    String? note,
  }) {
    final v = SettingVersion(
      id: SettingVersionStore.newId(),
      type: type,
      content: content,
      createdAt: DateTime.now(),
      note: note,
    );
    versions.insert(0, v);
    return v;
  }

  /// 选用历史版本为当前（旧当前进历史）
  void applyVersion(String versionId) {
    final idx = versions.indexWhere((v) => v.id == versionId);
    if (idx < 0) return;
    final v = versions.removeAt(idx);
    final old = currentOf(v.type);
    if (old.trim().isNotEmpty) {
      versions.insert(
        0,
        SettingVersion(
          id: SettingVersionStore.newId(),
          type: v.type,
          content: old,
          createdAt: DateTime.now(),
          note: '（原当前版，被 v${v.id} 替换）',
        ),
      );
    }
    setCurrent(v.type, v.content);
  }

  /// 删除历史版本（当前版不可删）
  bool deleteVersion(String versionId) {
    final before = versions.length;
    versions.removeWhere((v) => v.id == versionId);
    return versions.length != before;
  }

  Map<String, dynamic> toJson() => {
    'currentMale': currentMale,
    'currentUser': currentUser,
    'versions': versions.map((v) => v.toJson()).toList(),
    'changelog': changelog.map((e) => e.toJson()).toList(),
  };

  factory SettingBook.fromJson(Map<String, dynamic> j) => SettingBook(
    currentMale: j['currentMale']?.toString() ?? '',
    currentUser: j['currentUser']?.toString() ?? '',
    versions:
        (j['versions'] as List?)
            ?.map(
              (e) =>
                  SettingVersion.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList() ??
        [],
    changelog:
        (j['changelog'] as List?)
            ?.map(
              (e) => ChangeEntry.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList() ??
        [],
  );
}

/// 一个设定版本
class SettingVersion {
  final String id;
  final String type; // male / user
  final String content;
  final DateTime createdAt;
  final String? note; // 版本备注（男主写的：改了什么/为什么）
  final bool isCurrent; // 仅展示用（pushVersion 返回时标记）

  SettingVersion({
    required this.id,
    required this.type,
    required this.content,
    required this.createdAt,
    this.note,
    this.isCurrent = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'note': note,
  };

  factory SettingVersion.fromJson(Map<String, dynamic> j) => SettingVersion(
    id: j['id']?.toString() ?? '',
    type: j['type']?.toString() ?? 'male',
    content: j['content']?.toString() ?? '',
    createdAt:
        DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
    note: j['note']?.toString(),
  );
}

/// 变更日志条目（只追加不删）
class ChangeEntry {
  final DateTime time;
  final String type; // male / user
  final String summary; // 改了什么（男主自己总结）

  ChangeEntry({required this.time, required this.type, required this.summary});

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'type': type,
    'summary': summary,
  };

  factory ChangeEntry.fromJson(Map<String, dynamic> j) => ChangeEntry(
    time: DateTime.tryParse(j['time']?.toString() ?? '') ?? DateTime.now(),
    type: j['type']?.toString() ?? 'male',
    summary: j['summary']?.toString() ?? '',
  );
}
