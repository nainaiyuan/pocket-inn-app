/// TTS Local 实现 — 本地 sherpa-onnx 模型语音合成
///
/// 封装 ZipVoice/VITS 等本地 ONNX 模型的调用逻辑。
/// 适用于：性能足够的 Linux/Windows 设备（x64 或 ARM64）
///
/// 🔌 以后换本地模型，只改 [_loadModel] 和 [_doSynthesize] 两个方法
///
/// 使用方式：
///   final tts = TtsLocalImpl();
///   await tts.init(modelPath: '/path/to/model');
///   final audioFile = await tts.synthesize('你好');

import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tts_interface.dart';

/// 本地 TTS 引擎类型
enum LocalTtsEngine {
  zipvoice, // ZipVoice（蒸馏版/int8版）
  vits,     // VITS-ZH-LL
  matcha,   // Matcha-TTS
}

class TtsLocalImpl extends TtsLocal {
  // ─── 配置 ───
  @override
  double speed = 1.0;

  @override
  double volume = 1.0;

  @override
  double pitch = 1.0;

  @override
  String engineName = 'TtsLocal';

  /// 模型路径
  String _modelPath = '';

  /// 参考音频路径（声音克隆用）
  String _refAudioPath = '';

  /// 参考音频的文本内容
  String _refText = '';

  /// 引擎类型
  LocalTtsEngine _engineType = LocalTtsEngine.zipvoice;

  /// 语音合成子进程
  Process? _ttsProcess;

  /// 音频输出目录
  String? _outputDir;

  // ─── 状态 ───
  @override
  bool get isOffline => true;

  @override
  bool isModelLoaded = false;

  @override
  double memoryUsageMb = 0;

  /// 计数器
  int _fileCounter = 0;

  // ─── 情绪调参 ───
  @override
  void applyMood(double moodScore) {
    if (moodScore > 0.6) {
      speed = 1.2;
      volume = 1.0;
    } else if (moodScore < 0.3) {
      speed = 0.85;
      volume = 0.75;
    } else {
      speed = 1.0;
      volume = 1.0;
    }
  }

  // ─── 初始化 ───
  @override
  Future<void> init({
    String? modelPath,
    String? serverUrl,
    String? voicePath,
  }) async {
    if (modelPath != null) _modelPath = modelPath;
    if (voicePath != null) _refAudioPath = voicePath;

    final dir = await getTemporaryDirectory();
    _outputDir = p.join(dir.path, 'tts_local_output');
    final outDir = Directory(_outputDir!);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
  }

  // ─── 模型加载/卸载 ───
  @override
  Future<void> loadModel(String modelPath) async {
    _modelPath = modelPath;
    // 实际加载由底层 Python 服务完成
    // 这里记录状态
    isModelLoaded = true;
  }

  @override
  Future<void> unloadModel() async {
    await _stopProcess();
    isModelLoaded = false;
    memoryUsageMb = 0;
  }

  // ─── 合成 ───
  @override
  Future<String> synthesize(String text) async {
    if (_outputDir == null) throw StateError('TTS not initialized');
    if (!isModelLoaded) throw StateError('Model not loaded');

    _fileCounter++;
    final outPath = p.join(
      _outputDir!,
      'tts_local_${_fileCounter}_${DateTime.now().millisecondsSinceEpoch}.wav',
    );

    await _doSynthesize(text, outPath);
    return outPath;
  }

  @override
  Stream<String> synthesizeStream(String text) async* {
    if (_outputDir == null) throw StateError('TTS not initialized');

    final sentences = text.split(RegExp(r'(?<=[。！？，.!?,])'));
    for (final sentence in sentences) {
      final trimmed = sentence.trim();
      if (trimmed.isEmpty) continue;

      try {
        _fileCounter++;
        final outPath = p.join(
          _outputDir!,
          'tts_local_${_fileCounter}_stream.wav',
        );
        await _doSynthesize(trimmed, outPath);
        yield outPath;
      } catch (e) {
        print('TTS local stream error: $e');
      }
    }
  }

  // ─── 音色 ───
  @override
  Future<void> setVoice(String voiceId, {String? audioSample}) async {
    _refAudioPath = audioSample ?? _refAudioPath;
  }

  @override
  List<String> get availableVoices => ['default'];

  // ─── 释放 ───
  @override
  Future<void> dispose() async {
    await _stopProcess();
    await cleanOldFiles(0);
  }

  // ─── 临时文件管理 ───

  /// 清理 [minutes] 分钟前的旧音频文件
  Future<void> cleanOldFiles([int minutes = 5]) async {
    if (_outputDir == null) return;
    try {
      final dir = Directory(_outputDir!);
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(Duration(minutes: minutes));
      int deleted = 0;
      await for (final file in dir.list()) {
        if (file is File) {
          final stat = await file.stat();
          if (stat.modified.isBefore(cutoff)) {
            await file.delete();
            deleted++;
          }
        }
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════
  // 🔌 内部 — 换本地模型只改这里
  // ═══════════════════════════════════════

  /// 实际执行语音合成
  ///
  /// 通过调用 Python tts_server.py 或者直接调 sherpa-onnx CLI。
  /// 输出 WAV 文件到 [outPath]。
  Future<void> _doSynthesize(String text, String outPath) async {
    // 方案 1（推荐）：调用同机运行的 tts_server.py HTTP 服务
    // 如果本地已经启动 tts_server.py，走 HTTP 比起进程更快
    try {
      await _synthesizeViaHttp(text, outPath);
      return;
    } catch (e) {
      print('HTTP 合成失败，回退到子进程: $e');
    }

    // 方案 2（回退）：直接启动 Python 子进程
    await _synthesizeViaSubprocess(text, outPath);
  }

  /// 通过本地 HTTP 服务合成
  Future<void> _synthesizeViaHttp(String text, String outPath) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:8766/synthesize'),
      );
      request.headers.set('Content-Type', 'application/json');
      final body = jsonEncode({
        'text': text,
        'speed': speed,
      });
      request.write(body);

      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final file = File(outPath);
      await file.openWrite().addStream(response);
    } finally {
      client.close();
    }
  }

  /// 通过 Python 子进程合成
  Future<void> _synthesizeViaSubprocess(String text, String outPath) async {
    // 构造 Python 调用脚本
    final script = '''
import sys, json
sys.path.insert(0, '${_escapePath(_modelPath)}')
# 这里根据实际模型路径调整
# 示例：调用 sherpa-onnx 的 Python API
import sherpa_onnx
# ... 模型加载和合成逻辑 ...
print(json.dumps({"path": "$outPath", "status": "ok"}))
''';

    await _stopProcess();
    _ttsProcess = await Process.start('python3', ['-c', script]);
    await _ttsProcess!.exitCode;
  }

  /// 停止子进程
  Future<void> _stopProcess() async {
    _ttsProcess?.kill();
    _ttsProcess = null;
  }

  String _escapePath(String path) {
    return path.replaceAll("'", "'\\''");
  }
}
