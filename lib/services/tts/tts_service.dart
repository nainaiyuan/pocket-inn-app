/// TTS 服务 — 统一管理语音合成和播放
///
/// 职责：
/// - 管理 TTS 引擎实例
/// - 播放队列（逐句播放，不重叠）
/// - 全局开关（静音/取消）
/// - 和 Butler 情绪联动
///
/// 使用方式：
///   final tts = getIt<TtsService>();
///   await tts.speak('宝宝，我在这里。');
///
/// 🔌 以后换 TTS 引擎，改 [_createEngine] 方法

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:get_it/get_it.dart';

import '../butler/butler.dart' show Butler;
import 'tts_interface.dart';
import 'tts_remote_impl.dart';
import 'tts_local_impl.dart';

class TtsService {
  TtsService._();

  static final TtsService instance = TtsService._();

  // ─── 引擎 ───
  TtsInterface? _engine;

  /// 当前 TTS 引擎
  TtsInterface? get engine => _engine;

  // ─── 播放 ───
  final AudioPlayer _player = AudioPlayer();
  bool _isSpeaking = false;

  /// 是否正在播放语音
  bool get isSpeaking => _isSpeaking;

  bool _muted = false;

  /// 播放队列
  final List<String> _queue = [];
  bool _isProcessing = false;

  // ─── 回调 ───
  void Function(String text)? onSpeakStart;
  void Function()? onSpeakEnd;

  // ─── 配置 ───
  String _serverUrl = 'http://localhost:8766';

  String get serverUrl => _serverUrl;

  set serverUrl(String url) {
    _serverUrl = url;
    if (_engine is TtsRemoteImpl) {
      (_engine as TtsRemoteImpl).serverUrl = url;
    }
  }

  bool get muted => _muted;

  set muted(bool value) {
    _muted = value;
    if (value && _isSpeaking) {
      _stopSpeaking();
    }
  }

  // ─── 初始化 ───
  Future<void> init({String? serverUrl}) async {
    if (serverUrl != null) _serverUrl = serverUrl;
    _engine = _createEngine();
    await _engine!.init(serverUrl: _serverUrl);

    _player.onPlayerComplete.listen((_) {
      _isSpeaking = false;
      onSpeakEnd?.call();
      // 播放完后清一下旧文件
      _cleanOldFiles();
      _processQueue();
    });
  }

  /// 清理旧音频文件（播放完 5 分钟后删除）
  Future<void> _cleanOldFiles() async {
    if (_engine is TtsRemoteImpl) {
      await (_engine as TtsRemoteImpl).cleanOldFiles(5);
    } else if (_engine is TtsLocalImpl) {
      await (_engine as TtsLocalImpl).cleanOldFiles(5);
    }
  }

  /// 🔌 创建 TTS 引擎 — 以后换引擎只改这里
  TtsInterface _createEngine() {
    return TtsRemoteImpl();
  }

  /// 检查连接
  Future<bool> checkConnection() async {
    if (_engine is TtsRemote) {
      return (_engine as TtsRemote).checkConnection();
    }
    return false;
  }

  // ─── 说 ───

  /// 立刻说话（打断当前）
  Future<void> speak(String text) async {
    if (_muted || text.isEmpty) return;
    if (_engine == null) return;

    await _stopSpeaking();
    _applyMoodToEngine();

    try {
      onSpeakStart?.call(text);
      final audioPath = await _engine!.synthesize(text);
      _isSpeaking = true;
      await _player.play(DeviceFileSource(audioPath));
    } catch (e) {
      print('TTS speak error: $e');
      _isSpeaking = false;
      onSpeakEnd?.call();
    }
  }

  /// 加入队列（等当前播完）
  Future<void> enqueue(String text) async {
    if (_muted || text.isEmpty) return;
    if (_engine == null) return;

    _queue.add(text);
    if (!_isProcessing) {
      _processQueue();
    }
  }

  /// 清空队列
  void clearQueue() {
    _queue.clear();
  }

  /// 停止说话
  Future<void> stop() async {
    await _stopSpeaking();
    clearQueue();
  }

  // ─── 内部 ───
  Future<void> _stopSpeaking() async {
    try {
      await _player.stop();
    } catch (_) {}
    _isSpeaking = false;
  }

  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    while (_queue.isNotEmpty && !_muted) {
      final text = _queue.removeAt(0);
      await speak(text);
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _isProcessing = false;
  }

  void _applyMoodToEngine() {
    if (_engine == null) return;
    try {
      GetIt.instance<Butler>();
      // 当前用固定情绪值，以后可从 Butler 获取
      _engine!.applyMood(0.5);
    } catch (_) {}
  }

  // ─── 释放 ───
  Future<void> dispose() async {
    await _stopSpeaking();
    _player.dispose();
    await _engine?.dispose();
  }
}
