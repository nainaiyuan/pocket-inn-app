/// 数据导出/导入服务
///
/// 完整的管家数据导出工具。
/// 导出为 JSON 文件（zip 打包），可从文件恢复全部数据。
///
/// 用途：
///   1. 换手机时迁移数据
///   2. 重装 APP 后恢复
///   3. 手动备份保底
///
/// 对比 FragmentExportService（只导出碎片）：
///   - 这里导出管家 ALL 数据（基线+规律+记忆+要素+弧线+碎片+总结）

import 'dart:convert';
import 'dart:io';

// ─── 导出/导入的回调 ───
typedef DataExportProgressCallback = void Function(String message, double progress);

// ─── 数据模型 ───

/// 完整用户数据包
class UserDataPackage {
  static const String kVersion = '1.0.0';

  final String version;
  final DateTime exportedAt;
  final String appName; // 导出来源APP名称

  // 情绪数据
  final MoodData? mood;
  // 规律数据
  final PatternData? patterns;
  // 用户记忆
  final List<Map<String, dynamic>> memories;
  // 用户要素
  final List<Map<String, dynamic>> userElements;
  // 碎片
  final List<Map<String, dynamic>> fragments;
  // 对话总结
  final List<Map<String, dynamic>> conversationSummaries;
  // 男主列表
  final List<Map<String, dynamic>> characters;

  UserDataPackage({
    required this.version,
    required this.exportedAt,
    required this.appName,
    this.mood,
    this.patterns,
    this.memories = const [],
    this.userElements = const [],
    this.fragments = const [],
    this.conversationSummaries = const [],
    this.characters = const [],
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'exported_at': exportedAt.toIso8601String(),
    'app_name': appName,
    if (mood != null) 'mood': mood!.toJson(),
    if (patterns != null) 'patterns': patterns!.toJson(),
    'memories': memories,
    'user_elements': userElements,
    'fragments': fragments,
    'conversation_summaries': conversationSummaries,
    'characters': characters,
  };

  factory UserDataPackage.fromJson(Map<String, dynamic> json) => UserDataPackage(
    version: json['version'] as String? ?? '1.0.0',
    exportedAt: json['exported_at'] != null
        ? DateTime.parse(json['exported_at'] as String)
        : DateTime.now(),
    appName: json['app_name'] as String? ?? '',
    mood: json['mood'] != null
        ? MoodData.fromJson(json['mood'] as Map<String, dynamic>)
        : null,
    patterns: json['patterns'] != null
        ? PatternData.fromJson(json['patterns'] as Map<String, dynamic>)
        : null,
    memories: (json['memories'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [],
    userElements: (json['user_elements'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [],
    fragments: (json['fragments'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [],
    conversationSummaries: (json['conversation_summaries'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [],
    characters: (json['characters'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [],
  );
}

/// 情绪基线 + 弧线数据
class MoodData {
  final Map<String, double> baseline;          // 情绪基线值
  final int baselineSampleCount;                // 基线样本数
  final String? lastUpdated;                    // 最后更新时间
  final List<Map<String, dynamic>> arcHistory;  // 情绪弧线历史（最近10条）

  MoodData({
    required this.baseline,
    required this.baselineSampleCount,
    this.lastUpdated,
    this.arcHistory = const [],
  });

  Map<String, dynamic> toJson() => {
    'baseline': baseline,
    'baseline_sample_count': baselineSampleCount,
    if (lastUpdated != null) 'last_updated': lastUpdated,
    'arc_history': arcHistory,
  };

  factory MoodData.fromJson(Map<String, dynamic> json) => MoodData(
    baseline: Map<String, double>.from(
        (json['baseline'] as Map?)?.map((k, v) => MapEntry(k, (v as num).toDouble())) ?? {}),
    baselineSampleCount: json['baseline_sample_count'] as int? ?? 0,
    lastUpdated: json['last_updated'] as String?,
    arcHistory: (json['arc_history'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [],
  );
}

/// 规律数据
class PatternData {
  final List<Map<String, dynamic>> patterns;       // 发现的规律
  final int totalArcs;                              // 总弧线数
  final int totalPatterns;                          // 总规律数
  final Map<String, double>? keywordMoodMap;        // 关键词→情绪偏移汇总

  PatternData({
    required this.patterns,
    required this.totalArcs,
    required this.totalPatterns,
    this.keywordMoodMap,
  });

  Map<String, dynamic> toJson() => {
    'patterns': patterns,
    'total_arcs': totalArcs,
    'total_patterns': totalPatterns,
    if (keywordMoodMap != null) 'keyword_mood_map': keywordMoodMap,
  };

  factory PatternData.fromJson(Map<String, dynamic> json) => PatternData(
    patterns: (json['patterns'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [],
    totalArcs: json['total_arcs'] as int? ?? 0,
    totalPatterns: json['total_patterns'] as int? ?? 0,
    keywordMoodMap: json['keyword_mood_map'] != null
        ? Map<String, double>.from(
            (json['keyword_mood_map'] as Map).map((k, v) => MapEntry(k, (v as num).toDouble())))
        : null,
  );
}

/// 导入结果
class ImportResult {
  final bool success;
  final Map<String, int> counts; // 各类数据导入数量
  final String? error;

  ImportResult({
    required this.success,
    this.counts = const {},
    this.error,
  });

  String get summary {
    if (!success) return '导入失败：$error';
    final parts = counts.entries
        .where((e) => e.value > 0)
        .map((e) => '${e.key}: ${e.value}')
        .join('，');
    return '导入完成（$parts）';
  }
}

// ─── 数据导入选项 ───

enum ImportOptions {
  overwrite, // 覆盖已有
  skip,      // 跳过已有
  merge,     // 保留更新时间更近的版本
}

// ─── 主服务 ───

/// 数据导出/导入服务（完整管家数据）
class DataExportService {
  /// 导出整包数据
  ///
  /// 参数说明：
  ///   [dataPackage] — 准备好要导出的 UserDataPackage
  ///   [outputPath] — 写入的目标文件（JSON | .json）
  ///
  /// 返回：写入的文件路径
  Future<String> exportToFile({
    required UserDataPackage dataPackage,
    required String outputPath,
    DataExportProgressCallback? onProgress,
  }) async {
    onProgress?.call('准备导出数据包...', 0.0);

    // 序列化
    onProgress?.call('序列化数据（${_estimateSize(dataPackage)}）...', 0.3);
    final jsonStr = const JsonEncoder.withIndent('  ').convert(dataPackage.toJson());

    // 写入
    onProgress?.call('写入文件...', 0.7);
    final file = File(outputPath);
    await file.writeAsString(jsonStr);

    final size = await file.length();
    onProgress?.call('导出完成（${_formatSize(size)}）', 1.0);

    return outputPath;
  }

  /// 从文件导入数据包
  Future<ImportResult> importFromFile({
    required String filePath,
    required Future<void> Function(UserDataPackage data, ImportOptions options) importHandler,
    ImportOptions options = ImportOptions.merge,
    DataExportProgressCallback? onProgress,
  }) async {
    onProgress?.call('读取文件...', 0.0);

    final file = File(filePath);
    if (!await file.exists()) {
      return ImportResult(success: false, error: '文件不存在：$filePath');
    }

    // 读取
    final content = await file.readAsString();
    onProgress?.call('解析数据包...', 0.2);

    UserDataPackage dataPackage;
    try {
      dataPackage = UserDataPackage.fromJson(jsonDecode(content));
    } catch (e) {
      return ImportResult(success: false, error: '数据包解析失败：$e');
    }

    // 版本检查
    if (!dataPackage.version.startsWith('1.')) {
      return ImportResult(
        success: false,
        error: '不兼容的数据版本：${dataPackage.version}，本程序要求 1.x',
      );
    }

    onProgress?.call('开始导入...', 0.3);

    // 交给回调处理（不同APP导入逻辑不同）
    try {
      await importHandler(dataPackage, options);
    } catch (e) {
      return ImportResult(success: false, error: '导入处理失败：$e');
    }

    final counts = <String, int>{};
    counts['碎片'] = dataPackage.fragments.length;
    counts['记忆'] = dataPackage.memories.length;
    counts['用户要素'] = dataPackage.userElements.length;
    counts['对话总结'] = dataPackage.conversationSummaries.length;

    onProgress?.call('导入完成', 1.0);

    return ImportResult(success: true, counts: counts);
  }

  /// 读取数据包内容（不导入，仅查看）
  Future<UserDataPackage?> readPackage(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return UserDataPackage.fromJson(jsonDecode(content));
    } catch (_) {
      return null;
    }
  }

  /// 估算导出数据量
  String _estimateSize(UserDataPackage pkg) {
    final count = pkg.fragments.length +
        pkg.memories.length +
        pkg.userElements.length +
        pkg.conversationSummaries.length +
        pkg.characters.length;
    if (count < 50) return '小型数据包';
    if (count < 500) return '中型数据包';
    return '大型数据包';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
