import 'package:flutter/foundation.dart';
import '../../../models/male_lead.dart';
import '../../../services/character_service.dart';
import '../../../services/local_storage_service.dart';

/// 当前角色统一状态
class CurrentCharacterState extends ChangeNotifier {
  final CharacterService _charSvc = CharacterService();
  final LocalStorageService _localStore = LocalStorageService();

  MaleLead? _lead;
  Persona? _persona;

  MaleLead? get lead => _lead;
  Persona? get persona => _persona;
  CharacterService get characterService => _charSvc;
  LocalStorageService get localStorageService => _localStore;

  Future<void> init() async {
    await _localStore.init();
    await _charSvc.load();
  }

  void setCurrent(MaleLead l, Persona p) {
    _lead = l;
    _persona = p;
    notifyListeners();
  }

  Future<void> updateAvatar(String path) async {
    if (_persona == null || _lead == null) return;
    _persona!.avatarPath = path;
    await _charSvc.updatePersona(_lead!.id, _persona!);
    notifyListeners();
  }
}
