/// 桌宠帧源 — 文件系统实现
///
/// 扫描应用文档目录 `pet/animations/<动作id>/` 下的图片，
/// 按文件名排序自动得到帧序列。
/// 用户只需把一摞图片放进对应文件夹（或通过 APP 内多选导入），零配置。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../butler/pet/pet_engine.dart';

class FilePetFrameSource implements PetFrameSource {
  /// 帧图根目录（相对应用文档目录）
  static const String rootRelative = 'pet/animations';

  static const Set<String> _imageExts = {'png', 'jpg', 'jpeg', 'webp', 'gif'};

  /// 帧图根目录绝对路径（不存在则创建）
  static Future<String> rootPath() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, rootRelative));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 某个动作的帧图目录（不存在则创建）
  static Future<String> actionDir(String actionId) async {
    final root = await rootPath();
    final dir = Directory(p.join(root, actionId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  @override
  Future<List<String>> framesFor(String actionId) async {
    final root = await rootPath();
    final dir = Directory(p.join(root, actionId));
    if (!await dir.exists()) return const [];

    final files = await dir
        .list()
        .where((e) => e is File && _isImage(e.path))
        .cast<File>()
        .toList();
    // 按文件名自然排序（001.png < 002.png < 010.png）
    files.sort((a, b) => _naturalCompare(a.path, b.path));
    return files.map((f) => f.path).toList();
  }

  @override
  Future<bool> hasAction(String actionId) async {
    final root = await rootPath();
    final dir = Directory(p.join(root, actionId));
    if (!await dir.exists()) return false;
    await for (final e in dir.list()) {
      if (e is File && _isImage(e.path)) return true;
    }
    return false;
  }

  static bool _isImage(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return _imageExts.contains(ext);
  }

  /// 自然排序：数字按数值比较，其余按字典序
  static int _naturalCompare(String a, String b) {
    final regex = RegExp(r'(\d+|\D+)');
    final aParts = regex.allMatches(a).map((m) => m.group(1)!).toList();
    final bParts = regex.allMatches(b).map((m) => m.group(1)!).toList();
    final len = aParts.length < bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final ap = aParts[i];
      final bp = bParts[i];
      final an = int.tryParse(ap);
      final bn = int.tryParse(bp);
      if (an != null && bn != null) {
        if (an != bn) return an - bn;
      } else {
        final c = ap.compareTo(bp);
        if (c != 0) return c;
      }
    }
    return aParts.length - bParts.length;
  }
}
