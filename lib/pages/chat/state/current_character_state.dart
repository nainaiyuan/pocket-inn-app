import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';
import '../../../services/local_storage_service.dart';
import '../../../utils/debug_logger.dart';

/// 当前角色统一状态 — 唯一角色数据源
class CurrentCharacterState extends ChangeNotifier {
  final CharacterService _charSvc = CharacterService();
  final LocalStorageService _localStore = LocalStorageService();

  MaleLead? _lead;
  Persona? _persona;
  File? _bgFile;

  // ---- getter ----
  MaleLead? get lead => _lead;
  Persona? get persona => _persona;
  String? get leadId => _lead?.id;
  String? get personaId => _persona?.id;
  String? get personaName => _persona?.name;
  bool get hasLead => _lead != null;
  bool get hasPersona => _persona != null;
  String get effectiveAvatarPath => _persona?.avatarPath ?? _lead?.avatarPath ?? '';
  File? get bgFile => _bgFile;

  CharacterService get characterService => _charSvc;
  LocalStorageService get localStorageService => _localStore;

  // ---- 初始化 ----
  Future<void> init() async {
    await _localStore.init();
    await _charSvc.load();
    await DebugLogger.log('STATE', 'init done, leads=${_charSvc.leads.length}');
  }

  /// 尝试自动选中第一个角色（首次加载时）
  Future<bool> tryAutoSelect() async {
    if (_charSvc.leads.isEmpty) {
      // 无任何角色
      _lead = null;
      _persona = null;
      _bgFile = null;
      notifyListeners();
      await DebugLogger.log('STATE', 'tryAutoSelect: no leads');
      return false;
    }
    final first = _charSvc.leads.first;
    final p = first.personas.isNotEmpty ? first.personas.first : null;
    if (p != null) {
      _lead = first;
      _persona = p;
      _loadBgFile();
      notifyListeners();
      await DebugLogger.log('STATE', 'tryAutoSelect: lead=${first.id} persona=${p.id}');
      return true;
    }
    // 有 lead 但无 persona → 创建默认
    return false;
  }

  // ---- 设置当前角色 ----
  void setCurrent(MaleLead l, Persona p) {
    _lead = l;
    _persona = p;
    _loadBgFile();
    notifyListeners();
    DebugLogger.log('STATE', 'setCurrent lead=${l.id} persona=${p.id}');
  }

  void switchPersona(Persona p) {
    if (_lead == null) return;
    _persona = p;
    _loadBgFile();
    notifyListeners();
    DebugLogger.log('STATE', 'switchPersona p=${p.id}');
  }

  // ---- 图片更新 ----
  // 当前 MaleLead 和 Persona 都只用 avatarPath 字段
  // illustrationPath/backgroundPath 等后续模型升级后再加

  Future<void> updateAvatar(String path) async {
    if (_persona == null || _lead == null) return;
    _persona!.avatarPath = path;
    await _charSvc.updatePersona(_lead!.id, _persona!);
    await DebugLogger.log('STATE', 'updateAvatar path=$path');
    // 延迟一帧通知，避免 Image.file 加载与新文件写入竞争
    Future.microtask(() => notifyListeners());
  }

  // 背景
  Future<void> updateBackground(String path) async {
    if (_persona == null || _lead == null) return;
    _bgFile = File(path);
    await DebugLogger.log('STATE', 'updateBackground path=$path');
    Future.microtask(() => notifyListeners());
  }

  void clearCurrent() {
    _lead = null;
    _persona = null;
    _bgFile = null;
    notifyListeners();
    DebugLogger.log('STATE', 'clearCurrent');
  }

  Future<void> deleteCurrent() async {
    final lid = _lead?.id;
    if (lid == null) return;
    await _charSvc.deleteMaleLead(lid);
    _lead = null;
    _persona = null;
    _bgFile = null;
    notifyListeners();
    await DebugLogger.log('STATE', 'deleteCurrent lid=$lid');
  }

  Future<MaleLead> createLeadWithDefaultPersona(String name) async {
    final newLead = MaleLead(id: DateTime.now().millisecondsSinceEpoch.toString(), name: name);
    final defaultPersona = Persona(
      id: '${newLead.id}_default',
      maleLeadId: newLead.id,
      name: '默认',
    );
    newLead.personas.add(defaultPersona);
    await _charSvc.addMaleLead(newLead);
    await _charSvc.load();
    _lead = newLead;
    _persona = defaultPersona;
    notifyListeners();
    await DebugLogger.log('STATE', 'createLead name=$name id=${newLead.id}');
    return newLead;
  }

  // ---- 背景文件 ----
  void _loadBgFile() {
    // 当前模型没有 backgroundPath 字段，暂用 LocalStorageService 的路径
    _bgFile = null;
  }
}
