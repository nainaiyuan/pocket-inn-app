/// 健康检查服务
///
/// 启动时检查管家各模块是否正常。
/// 也可以被手动调用，随时看系统状态。
///
/// 检查项：
///   - 情绪模型文件（ONNX）是否存在
///   - 管家核心模块是否全部初始化
///   - 数据库是否正常
///   - 目录结构是否完整
///   - 各引擎状态是否健康

import 'dart:io';

/// 单条检查结果
class HealthCheckItem {
  final String name;
  final bool passed;
  final String? detail;
  final HealthSeverity severity;

  HealthCheckItem({
    required this.name,
    required this.passed,
    this.detail,
    this.severity = HealthSeverity.normal,
  });

  String get statusLabel => passed ? '✅ 通过' : '❌ 异常';
}

/// 检查结果聚合
class HealthReport {
  final DateTime checkedAt;
  final List<HealthCheckItem> items;
  final int durationMs;

  HealthReport({
    required this.checkedAt,
    required this.items,
    required this.durationMs,
  });

  /// 是否所有检查通过
  bool get allPassed => items.every((i) => i.passed);

  /// 严重问题数
  int get criticalCount => items.where((i) => !i.passed && i.severity == HealthSeverity.critical).length;

  /// 警告数
  int get warningCount => items.where((i) => !i.passed && i.severity == HealthSeverity.warning).length;

  /// 合规提示数
  int get infoCount => items.where((i) => i.severity == HealthSeverity.info).length;

  /// 人类可读摘要
  String toReadable() {
    final buf = StringBuffer();
    buf.writeln('🩺 健康检查报告（${checkedAt.toString().substring(0, 19)}）');
    buf.writeln('━━━━━━━━━━━━━━━━━━━━━━━━');

    for (final item in items) {
      buf.writeln('${item.statusLabel} ${item.name}');
      if (item.detail != null && item.detail!.isNotEmpty) {
        buf.writeln('   └ ${item.detail}');
      }
    }

    buf.writeln('━━━━━━━━━━━━━━━━━━━━━━━━');
    if (allPassed) {
      buf.writeln('🎉 全部通过（${durationMs}ms）');
    } else {
      buf.writeln('⚠️ 异常 ${items.where((i) => !i.passed).length} 项，'
          '其中严重 $criticalCount / 警告 $warningCount（${durationMs}ms）');
    }

    return buf.toString();
  }

  /// 摘要版（适合 UI 显示）
  String toSummary() {
    if (allPassed) return '✅ 全部正常';
    final failed = items.where((i) => !i.passed).toList();
    return '⚠️ ${failed.length} 项异常（严重 $criticalCount）';
  }
}

enum HealthSeverity {
  critical, // 必须修复，否则无法正常运行
  warning,  // 功能受限，但可以运行
  normal,   // 正常
  info,     // 仅信息，不判定通过/失败
}

/// 健康检查器
class HealthCheckService {
  String? _basePath;

  HealthCheckService({String? basePath}) : _basePath = basePath;

  /// 设置管家数据目录
  void setBasePath(String path) {
    _basePath = path;
  }

  /// 执行全部健康检查
  Future<HealthReport> checkAll() async {
    final start = DateTime.now();
    final items = <HealthCheckItem>[];

    items.addAll(await _checkFileSystem());
    items.addAll(await _checkModelFiles());
    items.addAll(await _checkDatabase());
    items.addAll(await _checkDirectories());

    final duration = DateTime.now().difference(start).inMilliseconds;

    return HealthReport(
      checkedAt: DateTime.now(),
      items: items,
      durationMs: duration,
    );
  }

  /// 检查文件系统基础
  Future<List<HealthCheckItem>> _checkFileSystem() async {
    final items = <HealthCheckItem>[];

    // 数据目录
    if (_basePath == null || _basePath!.isEmpty) {
      items.add(HealthCheckItem(
        name: '数据目录路径',
        passed: false,
        detail: '未设置 basePath，请调用 setBasePath()',
        severity: HealthSeverity.critical,
      ));
      return items;
    }

    final dir = Directory(_basePath!);
    final exists = await dir.exists();
    items.add(HealthCheckItem(
      name: '数据目录存在性',
      passed: exists,
      detail: exists ? _basePath : '目录不存在: $_basePath',
      severity: HealthSeverity.critical,
    ));

    // 读写权限
    if (exists) {
      final canRead = await _checkReadable(_basePath!);
      final canWrite = await _checkWritable(_basePath!);
      items.add(HealthCheckItem(
        name: '目录读取权限',
        passed: canRead,
        detail: canRead ? null : '无法读取目录',
        severity: HealthSeverity.critical,
      ));
      items.add(HealthCheckItem(
        name: '目录写入权限',
        passed: canWrite,
        detail: canWrite ? null : '无法写入目录（数据导出/导入会失败）',
        severity: HealthSeverity.critical,
      ));
    }

    return items;
  }

  /// 检查情绪分析模型文件
  Future<List<HealthCheckItem>> _checkModelFiles() async {
    final items = <HealthCheckItem>[];

    if (_basePath == null) return items;

    // ONNX 模型
    final modelPath = '$_basePath/onnx_engine/model.onnx';
    final modelFile = File(modelPath);
    final modelExists = await modelFile.exists();

    if (modelExists) {
      final size = await modelFile.length();
      items.add(HealthCheckItem(
        name: 'ONNX 情绪模型',
        passed: size > 0,
        detail: size > 0 ? '模型文件存在（${_formatSize(size)}）' : '模型文件为空',
        severity: HealthSeverity.critical,
      ));
    } else {
      items.add(HealthCheckItem(
        name: 'ONNX 情绪模型',
        passed: false,
        detail: '未找到模型文件（将使用关键字回退模式，情绪分析精度降低）',
        severity: HealthSeverity.warning,
      ));
    }

    // Tokenizer（ONNX 模型依赖）
    final tokenizerPath = '$_basePath/onnx_engine/tokenizer.json';
    final tokenizerFile = File(tokenizerPath);
    final tokenizerExists = await tokenizerFile.exists();

    if (modelExists) {
      items.add(HealthCheckItem(
        name: 'Tokenizer 文件',
        passed: tokenizerExists,
        detail: tokenizerExists ? '存在' : '缺失（ONNX 模型无法分词，但可尝试回退）',
        severity: tokenizerExists ? HealthSeverity.normal : HealthSeverity.warning,
      ));
    }

    // 标签映射
    final labelsPath = '$_basePath/onnx_engine/labels.json';
    final labelsFile = File(labelsPath);
    final labelsExists = await labelsFile.exists();

    if (modelExists) {
      items.add(HealthCheckItem(
        name: '标签映射文件',
        passed: labelsExists,
        detail: labelsExists ? '存在' : '缺失（情绪映射降级）',
        severity: labelsExists ? HealthSeverity.normal : HealthSeverity.warning,
      ));
    }

    return items;
  }

  /// 检查数据库状态
  Future<List<HealthCheckItem>> _checkDatabase() async {
    final items = <HealthCheckItem>[];

    // 注意：当前版本使用模拟存储（内存），无实际数据库文件
    // 当迁移到真 SQLite 后，这里检查 db 文件是否存在、能否打开
    final dbPath = _basePath != null ? '$_basePath/butler.db' : null;

    if (dbPath != null) {
      final dbFile = File(dbPath);
      final dbExists = await dbFile.exists();

      if (dbExists) {
        final size = await dbFile.length();
        items.add(HealthCheckItem(
          name: '数据库文件',
          passed: size > 0,
          detail: size > 0 ? 'SQLite 数据库存在（${_formatSize(size)}）' : '数据库文件为空',
          severity: HealthSeverity.critical,
        ));

        // 检查文件完整性（检查 SQLite header）
        if (size > 100) {
          final raf = await dbFile.open(mode: FileMode.read);
          final header = await raf.read(16);
          await raf.close();
          final headerStr = String.fromCharCodes(header);
          final isSqlite = headerStr.startsWith('SQLite format 3');
          items.add(HealthCheckItem(
            name: '数据库文件完整性',
            passed: isSqlite,
            detail: isSqlite ? '有效的 SQLite 文件' : '文件头异常，数据库可能损坏',
            severity: HealthSeverity.critical,
          ));
        }
      } else {
        // 新项目：数据库尚未创建
        items.add(HealthCheckItem(
          name: '数据库文件',
          passed: true, // 首次运行没有数据库是正常的
          detail: '首次运行，数据库将在初始化时创建',
          severity: HealthSeverity.info,
        ));
      }
    } else {
      items.add(HealthCheckItem(
        name: '数据库路径',
        passed: false,
        detail: '未设置 basePath，无法检查数据库',
        severity: HealthSeverity.warning,
      ));
    }

    return items;
  }

  /// 检查必要目录
  Future<List<HealthCheckItem>> _checkDirectories() async {
    final items = <HealthCheckItem>[];

    if (_basePath == null) return items;

    const dirs = [
      'onnx_engine',
      'data',
      'temp',
      'backup',
    ];

    for (final dirName in dirs) {
      final dir = Directory('$_basePath/$dirName');
      final exists = await dir.exists();

      // onnx_engine 不是必须存在的（可使用关键字回退）
      if (dirName == 'onnx_engine' && !exists) {
        items.add(HealthCheckItem(
          name: '目录: $dirName',
          passed: true,
          detail: '不存在（使用关键字回退模式，无需此目录）',
          severity: HealthSeverity.info,
        ));
        continue;
      }

      items.add(HealthCheckItem(
        name: '目录: $dirName',
        passed: exists,
        detail: exists ? '存在' : '缺失（功能可能受限）',
        severity: dirName == 'data'
            ? HealthSeverity.warning
            : HealthSeverity.info,
      ));
    }

    return items;
  }

  /// 针对 ButlerEngine 的模块初始化检查
  /// 由外部传入初始化的模块列表，检查是否全部就绪
  HealthCheckItem checkModuleInit({
    required String name,
    required bool isInitialized,
    String? detail,
  }) {
    return HealthCheckItem(
      name: '模块: $name',
      passed: isInitialized,
      detail: detail ?? (isInitialized ? '已初始化' : '未初始化（功能不可用）'),
      severity: isInitialized ? HealthSeverity.normal : HealthSeverity.critical,
    );
  }

  // ─── 工具方法 ───

  Future<bool> _checkReadable(String path) async {
    try {
      await Directory(path).stat();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkWritable(String path) async {
    try {
      final testFile = File('$path/.health_check_test');
      await testFile.writeAsString('test');
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
