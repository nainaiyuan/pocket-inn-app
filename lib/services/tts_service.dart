/// TTS 服务 — 统一管理语音合成和播放
///
/// 职责：
/// - 管理 TTS 引擎实例（当前是 TtsRemoteImpl）
/// - 提供播放队列（逐句播放，不重叠）
/// - 提供全局开关（静音/取消）
/// - 和 Butler 情绪联动（根据情绪调语速音量）
///
/// 使用方式：
///   final tts = getIt<TtsService>();
///   await tts.speak('宝宝，我在这里。');
///
/// 以后换 TTS 引擎，只需要改 [_createEngine] 方法。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:audioplayers/audioplayers.dart';

import '../butler/butler.dart';
import 'tts_remote_impl.dart';
import '../管家模块/管家核心/底层工具箱/语音接口/tts_interface.dart';

class TtsService {
  TtsService._();

  static final TtsService instance = TtsService._();

  // ─── 引擎 ───
  TtsInterface? _engine;

  /// 当前 TTS 引擎（外部可访问）
  TtsInterface? get engine => _engine;

  // ─── 播放状态 ───
  final AudioPlayer _player = AudioPlayer();
  bool _isSpeaking = false;
  bool _muted = false;

  /// 播放队列（先进先出）
  final List<String> _queue = [];
  bool _isProcessing = false;

  // ─── 回调 ───
  /// 开始说话时触发（参数：文本）
  void Function(String text)? onSpeakStart;

  /// 说话结束时触发
  void Function()? onSpeakEnd;

  // ─── 配置 ───
  /// TTS 服务器地址（启动后可通过设置页面修改）
  String _serverUrl = 'http://localhost:8766';

  String get serverUrl => _serverUrl;

  set serverUrl(String url) {
    _serverUrl = url;
    if (_engine is TtsRemoteImpl) {
      (_engine as TtsRemoteImpl).serverUrl = url;
    }
  }

  /// 是否静音
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

    // 监听播放完成
    _player.onPlayerComplete.listen((_) {
      _isSpeaking = false;
      onSpeakEnd?.call();
      _processQueue();
    });
  }

  /// 创建 TTS 引擎实例
  ///
  /// 以后换引擎（如 TtsLocalImpl），改这里就行。
  TtsInterface _createEngine() {
    return TtsRemoteImpl();
  }

  /// 检查能否连接 TTS 服务
  Future<bool> checkConnection() async {
    if (_engine is TtsRemote) {
      return (_engine as TtsRemote).checkConnection();
    }
    return false;
  }

  // ─── 说 ───

  /// 立刻说话（打断当前播放）
  Future<void> speak(String text) async {
    if (_muted || text.isEmpty) return;
    if (_engine == null) return;

    // 停止当前
    await _stopSpeaking();

    // 应用情绪调参
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

  /// 加入队列（当前播完再说）
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
      // 等当前播完
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _isProcessing = false;
  }

  void _applyMoodToEngine() {
    if (_engine == null) return;
    try {
      final butler = GetIt.instance<Butler>();
      final mood = butler.currentMood;
      _engine!.applyMood(mood);
    } catch (_) {
      // Butler 没注册时忽略
    }
  }

  // ─── 释放 ───
  Future<void> dispose() async {
    await _stopPlaying();
    _player.dispose();
    await _engine?.dispose();
  }
}
