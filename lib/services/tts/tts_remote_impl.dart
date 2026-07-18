/// TTS Remote 实现 — 调用远端语音合成服务
///
/// 支持两种后端：
/// 1. 自建 TTS 服务（HTTP API，返回 WAV）
/// 2. 以后可适配任意兼容 HTTP 的 TTS API
///
/// 配置：设置 [serverUrl] 指向你的 TTS 后端地址
///
/// 🔌 以后换 TTS API 只改 [_doHttpSynthesize] 方法

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tts_interface.dart';

class TtsRemoteImpl extends TtsRemote {
  // ─── 配置 ───
  @override
  String serverUrl = 'http://localhost:8766';

  @override
  int maxCharsPerRequest = 200;

  @override
  double speed = 1.0;

  @override
  double volume = 1.0;

  @override
  double pitch = 1.0;

  // ─── 状态 ───
  String _currentVoiceId = 'default';
  String? _currentAudioSample;

  /// 音频输出目录
  String? _outputDir;

  /// 计数器
  int _fileCounter = 0;

  // ─── 初始化 ───
  @override
  Future<void> init({
    String? modelPath,
    String? serverUrl,
    String? voicePath,
  }) async {
    if (serverUrl != null) this.serverUrl = serverUrl;
    if (voicePath != null) _currentAudioSample = voicePath;

    final dir = await getTemporaryDirectory();
    _outputDir = p.join(dir.path, 'tts_output');
    final outDir = Directory(_outputDir!);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
  }

  @override
  bool get isOffline => false;

  @override
  String get engineName => 'TtsRemote: $serverUrl';

  // ─── 合成（完整） ───
  @override
  Future<String> synthesize(String text) async {
    if (_outputDir == null) throw StateError('TTS not initialized');

    if (text.length > maxCharsPerRequest) {
      text = text.substring(0, maxCharsPerRequest);
    }

    final wavBytes = await _doHttpSynthesize(text);

    _fileCounter++;
    final outPath = p.join(
      _outputDir!,
      'tts_${_fileCounter}_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await File(outPath).writeAsBytes(wavBytes);
    return outPath;
  }

  // ─── 流式合成 ───
  @override
  Stream<String> synthesizeStream(String text) async* {
    if (_outputDir == null) throw StateError('TTS not initialized');

    final sentences = text.split(RegExp(r'(?<=[。！？，.!?,])'));
    for (final sentence in sentences) {
      final trimmed = sentence.trim();
      if (trimmed.isEmpty) continue;

      try {
        final wavBytes = await _doHttpSynthesize(trimmed);
        _fileCounter++;
        final outPath = p.join(_outputDir!, 'tts_${_fileCounter}_stream.wav');
        await File(outPath).writeAsBytes(wavBytes);
        yield outPath;
      } catch (e) {
        print('TTS stream segment error: $e');
      }
    }
  }

  // ─── 音色 ───
  @override
  Future<void> setVoice(String voiceId, {String? audioSample}) async {
    _currentVoiceId = voiceId;
    if (audioSample != null) _currentAudioSample = audioSample;
  }

  @override
  List<String> get availableVoices => ['default'];

  // ─── 情绪调参 ───
  @override
  void applyMood(double moodScore) {
    // 调语速音量
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

  // ─── 连接检查 ───
  @override
  Future<bool> checkConnection() async {
    try {
      final url = Uri.parse('$serverUrl/health');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(url);
      final response = await request.close();
      client.close();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ─── 释放 ───
  @override
  Future<void> dispose() async {
    await cleanOldFiles(0); // 清理所有临时文件
  }

  // ─── 临时文件管理 ───

  /// 清理 [minutes] 分钟前的旧音频文件
  /// 默认 5 分钟：播放完 5 分钟后删除
  /// 传 0 = 删除所有
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
      if (deleted > 0) {
        print('TTS: 清理 $deleted 个旧音频文件');
      }
    } catch (e) {
      print('TTS: 清理出错 $e');
    }
  }

  // ═══════════════════════════════════════
  // 🔌 内部 — 换 TTS API 只改这里
  // ═══════════════════════════════════════

  /// 实际 HTTP 请求合成
  ///
  /// 默认格式（自建 TTS 服务）：
  ///   POST {serverUrl}/synthesize
  ///   {"text": "...", "speed": 1.0}
  ///   → 返回 audio/wav 字节
  ///
  /// 换别的 API（如 OpenAI、Azure），重写这个方法。
  Future<List<int>> _doHttpSynthesize(String text) async {
    final url = Uri.parse('$serverUrl/synthesize');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    try {
      final request = await client.postUrl(url);
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Accept', 'audio/wav');

      final body = jsonEncode({
        'text': text,
        'speed': speed,
        'num_steps': 4,
      });
      request.write(body);

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw Exception('TTS API error ${response.statusCode}: $errorBody');
      }

      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close();
    }
  }
}
