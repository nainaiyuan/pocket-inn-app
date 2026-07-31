import 'package:flutter/material.dart';
import '../services/music_player_service.dart';

/// 音乐播放器页面
/// 后台轮放 BGM，跨页面不中断
class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage> {
  final MusicPlayerService _music = MusicPlayerService.instance;

  @override
  void initState() {
    super.initState();
    _music.addListener(_onMusicChanged);
    _music.initialize();

    // 演示：填充默认曲目（等用户自己放音乐文件）
    if (_music.playlist.isEmpty) {
      _music.setPlaylist([
        const MusicTrack(
          id: 'demo_1',
          title: '示例曲目 1',
          artist: 'PocketInn',
          filePath: 'music/demo_1.mp3',
        ),
        const MusicTrack(
          id: 'demo_2',
          title: '示例曲目 2',
          artist: 'PocketInn',
          filePath: 'music/demo_2.mp3',
        ),
      ]);
    }
  }

  @override
  void dispose() {
    _music.removeListener(_onMusicChanged);
    super.dispose();
  }

  void _onMusicChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = _music.currentTrack;

    return Scaffold(
      appBar: AppBar(title: const Text('音乐播放器')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 专辑封面占位
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.music_note,
                size: 80,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 24),
            // 曲目名称
            Text(
              track?.title ?? '未选择音乐',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              track?.artist ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            // 控制按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous, size: 36),
                  onPressed: _music.playlist.isEmpty ? null : () => _music.previous(),
                ),
                const SizedBox(width: 16),
                _buildPlayButton(theme),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.skip_next, size: 36),
                  onPressed: _music.playlist.isEmpty ? null : () => _music.next(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 随机播放开关
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('随机播放', style: theme.textTheme.bodySmall),
                Switch(
                  value: _music.shuffle,
                  onChanged: (_) => _music.toggleShuffle(),
                ),
              ],
            ),
            const SizedBox(height: 32),
            // 播放列表
            Text('播放列表', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: _music.playlist.isEmpty
                  ? Center(
                      child: Text(
                        '还没有音乐，放入 .mp3 文件后就会出现',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _music.playlist.length,
                      itemBuilder: (context, index) {
                        final t = _music.playlist[index];
                        final isCurrent = t == _music.currentTrack;
                        return ListTile(
                          leading: Icon(
                            isCurrent
                                ? Icons.play_arrow
                                : Icons.music_note_outlined,
                            color: isCurrent
                                ? theme.colorScheme.primary
                                : null,
                          ),
                          title: Text(t.title),
                          subtitle: Text(t.artist),
                          selected: isCurrent,
                          onTap: () => _music.play(track: t),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayButton(ThemeData theme) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(
          _music.isPlaying ? Icons.pause : Icons.play_arrow,
          size: 32,
          color: theme.colorScheme.onPrimary,
        ),
        onPressed: () {
          if (_music.isPlaying) {
            _music.pause();
          } else if (_music.state == MusicPlayerState.paused) {
            _music.resume();
          } else {
            _music.play();
          }
        },
      ),
    );
  }
}
