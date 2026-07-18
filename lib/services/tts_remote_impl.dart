/// TTS Remote 实现 — 调用远端语音合成服务
///
/// 支持两种后端：
/// 1. 自建 TTS 服务（HTTP API，返回 WAV）
/// 2. 兼容 OpenAI TTS API（返回音频）
///
/// 配置：设置 [serverUrl] 指向你的 TTS 后端地址
///
/// 以后找到新的 TTS API 了，只需要改 [_doHttpSynthesize] 里的请求格式
/// 对外接口不变，APP 其他代码不用动。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../管家模块/管家核心/底层工具箱/语音接口/tts_interface.dart';

class TtsRemoteImpl implements TtsRemote {
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
  String? _currentAudioSample; // 参考音频路径（克隆用）

  /// 音频输出目录
  String? _outputDir;

  /// 计数器，避免文件名重复
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

    // 获取临时目录存放音频文件
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

    // 切分长文本
    if (text.length > maxCharsPerRequest) {
      // 太长时只合成本地听，返回第一段
      text = text.substring(0, maxCharsPerRequest);
    }

    final wavBytes = await _doHttpSynthesize(text);

    // 保存到临时文件
    _fileCounter++;
    final outPath = p.join(_outputDir!, 'tts_${_fileCounter}_${DateTime.now().millisecondsSinceEpoch}.wav');
    await File(outPath).writeAsBytes(wavBytes);
    return outPath;
  }

  // ─── 流式合成 ───
  @override
  Stream<String> synthesizeStream(String text) async* {
    if (_outputDir == null) throw StateError('TTS not initialized');

    // 按标点切分句子
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
        // 某句失败不影响后续
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
  List<String> get availableVoices => ['default']; // 未来可扩展

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
    // 可选：清理临时文件
  }

  // ══════════════════════════════════════════════
  // 内部实现 — 未来换 API 只改这里
  // ══════════════════════════════════════════════

  /// 实际 HTTP 请求合成
  ///
  /// 默认使用自建 TTS 服务的 JSON API 格式：
  ///   POST {serverUrl}/synthesize
  ///   {"text": "...", "speed": 1.0}
  ///   返回 audio/wav
  ///
  /// 如果你换成别的 TTS API（如 OpenAI、Azure），
  /// 重写这个方法即可，保持返回 WAV 字节。
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

      // 读取 WAV 字节
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
