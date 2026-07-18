/// TTS 设置页面 — 配置语音合成服务器
///
/// 以后找到 TTS API 了，在这里填地址：端口就能用。
///
/// 入口：在 APP 设置菜单里加一个 "语音合成" 选项跳转到这里

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../services/tts_service.dart';

class TtsSettingsPage extends StatefulWidget {
  const TtsSettingsPage({super.key});

  @override
  State<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<TtsSettingsPage> {
  final _tts = getIt<TtsService>();
  late TextEditingController _urlController;
  bool _isChecking = false;
  bool? _connectionOk;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: _tts.serverUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('语音合成设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── 服务器地址 ───
          Text('TTS 服务器地址', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              hintText: 'http://192.168.1.100:8766',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.link),
                onPressed: _checkConnection,
              ),
            ),
            onChanged: (_) {
              _connectionOk = null;
              setState(() {});
            },
          ),
          const SizedBox(height: 4),
          Text(
            '输入你的 TTS 服务器地址，点击右侧链接图标测试连接',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          // ─── 连接状态 ───
          if (_isChecking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          if (_connectionOk == true)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 20),
                  SizedBox(width: 8),
                  Text('连接成功', style: TextStyle(color: Colors.green)),
                ],
              ),
            ),
          if (_connectionOk == false)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.error, color: Colors.red, size: 20),
                  SizedBox(width: 8),
                  Text('无法连接', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),

          const SizedBox(height: 24),

          // ─── 保存 ───
          FilledButton.icon(
            onPressed: _saveUrl,
            icon: const Icon(Icons.save),
            label: const Text('保存'),
          ),

          const SizedBox(height: 32),

          // ─── 测试说话 ───
          Text('测试', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _connectionOk == true ? _testSpeak : null,
            icon: const Icon(Icons.volume_up),
            label: const Text('说一句测试'),
          ),

          const SizedBox(height: 32),

          // ─── 说明 ───
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('支持的 TTS 后端',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  const Text(
                    '1. 自建 TTS 服务（推荐）\n'
                    '   在另一台电脑上跑 tts_server.py，'
                    '填它的 IP:端口\n\n'
                    '2. 云端 TTS API\n'
                    '   以后找到合适的 API，改 tts_remote_impl.dart 适配\n\n'
                    '3. 本地离线模型\n'
                    '   如果要在平板上跑，需要 TtsLocalImpl（预留）',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _checkConnection() async {
    setState(() {
      _isChecking = true;
      _connectionOk = null;
    });

    _tts.serverUrl = _urlController.text.trim();
    final ok = await _tts.checkConnection();

    setState(() {
      _isChecking = false;
      _connectionOk = ok;
    });
  }

  void _saveUrl() {
    _tts.serverUrl = _urlController.text.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }

  Future<void> _testSpeak() async {
    await _tts.speak('你好，语音合成服务连接正常。');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在播放测试语音...')),
    );
  }
}
