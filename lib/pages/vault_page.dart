import 'package:flutter/material.dart';

import '../butler/vault/vault_manager.dart';

/// 保险箱页面
/// 用户手动操作的私密文件存储区
class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final VaultManager _vaultManager = VaultManager();
  List<VaultEntry> _entries = [];
  bool _locked = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    if (_locked) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    await _vaultManager.initialize();
    final entries = _vaultManager.listFiles();
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _toggleLock() {
    setState(() => _locked = !_locked);
    if (!_locked) _loadEntries();
  }

  Future<void> _addFile() async {
    // TODO: 接入 file_picker，让用户选真实文件
    // 当前：演示弹窗
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加到保险箱'),
        content: const Text('选择一个文件存入保险箱'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('需要 file_picker 依赖才能选择文件')),
              );
            },
            child: const Text('选择文件'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('保险箱'),
        actions: [
          IconButton(
            icon: Icon(_locked ? Icons.lock : Icons.lock_open),
            onPressed: _toggleLock,
            tooltip: _locked ? '解锁' : '锁定',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _locked
              ? _buildLockedView(theme)
              : _entries.isEmpty
                  ? _buildEmptyView(theme)
                  : _buildFileList(theme),
      floatingActionButton: _locked
          ? null
          : FloatingActionButton.extended(
              onPressed: _addFile,
              icon: const Icon(Icons.add),
              label: const Text('添加文件'),
            ),
    );
  }

  Widget _buildLockedView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('保险箱已锁定', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '点击右上角解锁查看',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inventory_2_outlined, size: 64,
              color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('保险箱是空的', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '点击下方按钮添加你的私密文件',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '管家不会看到保险箱里的内容',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(
              _fileIcon(entry.fileType),
              color: theme.colorScheme.primary,
            ),
            title: Text(entry.fileName),
            subtitle: Text(
              '${entry.category} · ${_formatSize(entry.fileSize)}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showFileMenu(entry),
            ),
            onTap: () => _openFile(entry),
          ),
        );
      },
    );
  }

  IconData _fileIcon(String type) {
    switch (type) {
      case 'image':
        return Icons.image;
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.audiotrack;
      case 'text':
        return Icons.description;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _showFileMenu(VaultEntry entry) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开'),
              onTap: () {
                Navigator.pop(ctx);
                _openFile(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openFile(VaultEntry entry) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('打开文件: ${entry.fileName}')),
    );
  }

  void _confirmDelete(VaultEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除 "${entry.fileName}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await _vaultManager.deleteEntry(entry.id);
              Navigator.pop(ctx);
              _loadEntries();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
