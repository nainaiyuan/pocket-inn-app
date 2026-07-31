import 'dart:async';
import 'package:flutter/foundation.dart';

/// 音乐播放器状态
enum MusicPlayerState { stopped, playing, paused }

/// 音乐条目
class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final String filePath; // assets 或文件路径
  final Duration? duration;

  const MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.filePath,
    this.duration,
  });
}

/// 音乐播放器服务
/// 单例，跨页面保持播放状态
class MusicPlayerService extends ChangeNotifier {
  MusicPlayerService._();

  static final MusicPlayerService instance = MusicPlayerService._();

  MusicPlayerState _state = MusicPlayerState.stopped;
  MusicTrack? _currentTrack;
  List<MusicTrack> _playlist = [];
  int _currentIndex = 0;
  bool _shuffle = false;

  // 实际播放器实例（初始化时创建）
  // dynamic _player; // audioplayers 的 AudioPlayer 实例

  MusicPlayerState get state => _state;
  MusicTrack? get currentTrack => _currentTrack;
  List<MusicTrack> get playlist => List.unmodifiable(_playlist);
  bool get isPlaying => _state == MusicPlayerState.playing;
  bool get shuffle => _shuffle;

  /// 初始化播放器
  Future<void> initialize() async {
    // TODO: 初始化 audioplayers
    // _player = AudioPlayer();
    // _player!.onPlayerStateChanged.listen(_onPlayerStateChanged);
    // _player!.onPositionChanged.listen(_onPositionChanged);
    // _player!.onPlayerComplete.listen(_onComplete);
    notifyListeners();
  }

  /// 设置播放列表
  void setPlaylist(List<MusicTrack> tracks, {int startIndex = 0}) {
    _playlist = List.from(tracks);
    _currentIndex = startIndex.clamp(0, _playlist.length - 1);
    notifyListeners();
  }

  /// 播放指定曲目
  Future<void> play({MusicTrack? track}) async {
    if (track != null) {
      _currentTrack = track;
      _currentIndex = _playlist.indexOf(track);
    } else if (_currentTrack == null && _playlist.isNotEmpty) {
      _currentTrack = _playlist[0];
      _currentIndex = 0;
    }

    if (_currentTrack == null) return;

    // TODO: 实际播放
    // await _player!.stop();
    // await _player!.play(AssetSource(_currentTrack!.filePath));

    _state = MusicPlayerState.playing;
    notifyListeners();
  }

  /// 暂停
  Future<void> pause() async {
    if (_state != MusicPlayerState.playing) return;
    // await _player!.pause();
    _state = MusicPlayerState.paused;
    notifyListeners();
  }

  /// 恢复
  Future<void> resume() async {
    if (_state != MusicPlayerState.paused) return;
    // await _player!.resume();
    _state = MusicPlayerState.playing;
    notifyListeners();
  }

  /// 停止
  Future<void> stop() async {
    // await _player!.stop();
    _state = MusicPlayerState.stopped;
    notifyListeners();
  }

  /// 下一首
  Future<void> next() async {
    if (_playlist.isEmpty) return;

    if (_shuffle) {
      _currentIndex = (_currentIndex + 1) % _playlist.length;
    } else {
      _currentIndex = (_currentIndex + 1) % _playlist.length;
    }

    _currentTrack = _playlist[_currentIndex];
    await play();
  }

  /// 上一首
  Future<void> previous() async {
    if (_playlist.isEmpty) return;

    _currentIndex = (_currentIndex - 1 + _playlist.length) % _playlist.length;
    _currentTrack = _playlist[_currentIndex];
    await play();
  }

  /// 切换随机播放
  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  /// 设置音量（0.0 ~ 1.0）
  Future<void> setVolume(double volume) async {
    // await _player!.setVolume(volume.clamp(0.0, 1.0));
  }

  /// 释放资源
  Future<void> dispose() async {
    // await _player?.dispose();
    _state = MusicPlayerState.stopped;
    _currentTrack = null;
  }
}
