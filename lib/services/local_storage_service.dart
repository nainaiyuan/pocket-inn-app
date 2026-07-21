import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 本地文件存储服务
///
/// APP 内部目录结构：
/// {appDir}/
///   avatars/       ← 角色立绘（leadId.jpg）和形象头像（leadId_personaId.jpg）
///   backgrounds/  ← 聊天背景图（leadId_personaId.jpg）
class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._();
  factory LocalStorageService() => _instance;
  LocalStorageService._();

  Directory? _appDir;

  /// 初始化（确保目录存在）
  Future<void> init() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    _appDir = appDocDir;

    // 创建子目录
    await Directory('${appDocDir.path}/avatars').create(recursive: true);
    await Directory('${appDocDir.path}/backgrounds').create(recursive: true);
  }

  // ─── 路径生成 ───

  String _avatarPath(String leadId) => '${_appDir!.path}/avatars/$leadId.jpg';
  String _personaAvatarPath(String leadId, String personaId) =>
      '${_appDir!.path}/avatars/${leadId}_$personaId.jpg';
  String _bgPath(String leadId, String personaId) =>
      '${_appDir!.path}/backgrounds/${leadId}_$personaId.jpg';

  // ─── 立绘 ───

  /// 复制图片到内部存储，返回新路径
  Future<String> saveLeadAvatar(String leadId, File source) async {
    final dest = _avatarPath(leadId);
    await source.copy(dest);
    return dest;
  }

  String getLeadAvatarPath(String leadId) => _avatarPath(leadId);

  Future<bool> leadAvatarExists(String leadId) async {
    return File(_avatarPath(leadId)).exists();
  }

  /// 获取立绘 File（如果存在）
  File? getLeadAvatarFile(String leadId) {
    final f = File(_avatarPath(leadId));
    return f.existsSync() ? f : null;
  }

  // ─── 形象头像 ───

  Future<String> savePersonaAvatar(String leadId, String personaId, File source) async {
    final dest = _personaAvatarPath(leadId, personaId);
    await source.copy(dest);
    return dest;
  }

  String getPersonaAvatarPath(String leadId, String personaId) =>
      _personaAvatarPath(leadId, personaId);

  File? getPersonaAvatarFile(String leadId, String personaId) {
    final f = File(_personaAvatarPath(leadId, personaId));
    return f.existsSync() ? f : null;
  }

  // ─── 聊天背景 ───

  Future<String> saveBackground(String leadId, String personaId, File source) async {
    final dest = _bgPath(leadId, personaId);
    await source.copy(dest);
    return dest;
  }

  String getBackgroundPath(String leadId, String personaId) =>
      _bgPath(leadId, personaId);

  File? getBackgroundFile(String leadId, String personaId) {
    final f = File(_bgPath(leadId, personaId));
    return f.existsSync() ? f : null;
  }

  // ─── 清理 ───

  Future<void> deleteLeadAvatar(String leadId) async {
    final f = File(_avatarPath(leadId));
    if (await f.exists()) await f.delete();
  }

  Future<void> deleteBackground(String leadId, String personaId) async {
    final f = File(_bgPath(leadId, personaId));
    if (await f.exists()) await f.delete();
  }
}
