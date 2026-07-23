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

  /// FilePicker 操作完毕后需要重置手势（由 ChatPage 监听并复位 _pointerId）
  bool get needsGestureReset => _needsGestureReset;
  bool _needsGestureReset = false;

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
    // 从 lead.personas 列表中找到对应 id 的 Persona，确保写的是正确的对象
    final idx = _lead!.personas.indexWhere((p) => p.id == _persona!.id);
    if (idx >= 0) {
      _lead!.personas[idx].avatarPath = path;
      // 同步更新 state 的引用指向正确的对象
      _persona = _lead!.personas[idx];
      await _charSvc.updatePersona(_lead!.id, _lead!.personas[idx]);
    } else {
      // fallback: 直接改 _persona
      _persona!.avatarPath = path;
      await _charSvc.updatePersona(_lead!.id, _persona!);
    }
    await DebugLogger.log('STATE', 'updateAvatar path=$path');
    notifyListeners();
  }

  // 背景
  Future<void> updateBackground(String path) async {
    if (_persona == null || _lead == null) return;
    _bgFile = File(path);
    // 从 lead.personas 列表中找到对应 id 的 Persona
    final idx = _lead!.personas.indexWhere((p) => p.id == _persona!.id);
    if (idx >= 0) {
      _lead!.personas[idx].backgroundPath = path;
      _persona = _lead!.personas[idx];
      await _charSvc.updatePersona(_lead!.id, _lead!.personas[idx]);
    } else {
      _persona!.backgroundPath = path;
      await _charSvc.updatePersona(_lead!.id, _persona!);
    }
    await DebugLogger.log('STATE', 'updateBackground path=$path');
    notifyListeners();
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

  /// 强制对外通知 UI 刷新（给左侧栏等外部组件用）
  void notifyUI() {
    _loadBgFile();
    notifyListeners();
  }

  /// 标记需要复位手势（左侧栏的 FilePicker 返回后调用）
  void requestGestureReset() {
    _needsGestureReset = true;
    notifyListeners();
  }

  /// ChatPage 读取后自动消费
  void consumeGestureReset() {
    _needsGestureReset = false;
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
    if (_persona == null) {
      _bgFile = null;
      return;
    }
    // 1. Persona 有自己的背景 → 用 Persona 的
    if (_persona!.backgroundPath.isNotEmpty) {
      final f = File(_persona!.backgroundPath);
      if (f.existsSync()) { _bgFile = f; return; }
    }
    // 2. 兼容旧数据：从 LocalStorageService 按规则路径找
    final personaBg = _localStore.getBackgroundFile(_lead!.id, _persona!.id);
    if (personaBg != null && personaBg.existsSync()) { _bgFile = personaBg; return; }
    // 3. 没有 → 继承立绘（MaleLead）的全局背景
    if (_lead!.backgroundPath.isNotEmpty) {
      final f = File(_lead!.backgroundPath);
      if (f.existsSync()) { _bgFile = f; return; }
    }
    // 4. 都无
    _bgFile = null;
  }

  /// 设置立绘全局背景（影响所有未单独设背景的 Persona）
  Future<void> updateLeadBackground(String path) async {
    if (_lead == null) return;
    _lead!.backgroundPath = path;
    await _charSvc.updateMaleLead(_lead!);
    _loadBgFile();
    await DebugLogger.log('STATE', 'updateLeadBackground path=$path');
    notifyListeners();
  }
}
