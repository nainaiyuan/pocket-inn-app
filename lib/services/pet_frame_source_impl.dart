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

  /// 清理 file_picker 选图后留在系统 cache 的副本。
  ///
  /// 8-14 13:3x 用户反馈：相册里同一个文件越来越多——荣耀图库会索引
  /// 应用 cache 目录，每次选图 file_picker 都留一份副本 → 相册堆积。
  /// 选图完成（bytes 已进内存）后调用，删掉这些副本。
  static Future<void> cleanupFilePickerCache() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'file_picker'));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 选图后立即把 FilePicker 临时文件复制进应用私有目录（`__pick_cache`）。
  ///
  /// 8-14 06:52 根因修复：FilePicker 的临时文件在系统 cache/ 下，
  /// 选完图到点保存之间（几十秒）可能被系统清理 → 保存时源文件
  /// PathNotFoundException。复制到应用 files/ 后源文件稳定，不再依赖
  /// 系统临时目录。每次调用会清空上次的暂存。
  static Future<List<String>> stagePickedFiles(List<String> srcPaths) async {
    final root = await rootPath();
    final cacheDir = Directory(p.join(root, '__pick_cache'));
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
    await cacheDir.create(recursive: true);
    final out = <String>[];
    for (var i = 0; i < srcPaths.length; i++) {
      final src = srcPaths[i];
      if (src.isEmpty) continue;
      final target =
          p.join(cacheDir.path, '${i.toString().padLeft(3, '0')}_${p.basename(src)}');
      await File(src).copy(target);
      out.add(target);
    }
    return out;
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
