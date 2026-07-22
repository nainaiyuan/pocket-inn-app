import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/male_lead.dart';

/// 角色数据服务 —— 存储所有男主及其形象
class CharacterService {
  static const _key = 'male_leads';

  // 单例
  static final CharacterService _instance = CharacterService._();
  factory CharacterService() => _instance;
  static CharacterService get instance => _instance;
  CharacterService._();

  List<MaleLead> _leads = [];
  bool _loaded = false;

  List<MaleLead> get leads => List.unmodifiable(_leads);

  /// 加载数据
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json != null && json.isNotEmpty) {
      final list = jsonDecode(json) as List<dynamic>;
      _leads = list
          .map((e) => MaleLead.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    _loaded = true;
  }

  /// 保存数据
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_leads.map((l) => l.toJson()).toList());
    await prefs.setString(_key, json);
  }

  /// 添加男主
  Future<void> addMaleLead(MaleLead lead) async {
    _leads.add(lead);
    await _save();
  }

  /// 删除男主（连带所有形象）
  Future<void> deleteMaleLead(String id) async {
    _leads.removeWhere((l) => l.id == id);
    await _save();
  }

  /// 更新男主
  Future<void> updateMaleLead(MaleLead lead) async {
    final idx = _leads.indexWhere((l) => l.id == lead.id);
    if (idx >= 0) {
      _leads[idx] = lead;
      await _save();
    }
  }

  /// 获取男主
  MaleLead? getMaleLead(String id) {
    try {
      return _leads.firstWhere((l) => l.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 添加形象
  Future<void> addPersona(String maleLeadId, Persona persona) async {
    final lead = getMaleLead(maleLeadId);
    if (lead != null) {
      lead.personas.add(persona);
      await _save();
    }
  }

  /// 更新形象
  Future<void> updatePersona(String maleLeadId, Persona persona) async {
    final lead = getMaleLead(maleLeadId);
    if (lead != null) {
      final idx = lead.personas.indexWhere((p) => p.id == persona.id);
      if (idx >= 0) {
        lead.personas[idx] = persona;
        await _save();
      }
    }
  }

  /// 删除形象
  Future<void> deletePersona(String maleLeadId, String personaId) async {
    final lead = getMaleLead(maleLeadId);
    if (lead != null) {
      lead.personas.removeWhere((p) => p.id == personaId);
      await _save();
    }
  }

  // ═══════════════════════════════════════
  // 以下方法供旧代码兼容（initialize / clearAllData / loadById / loadAllSummaries）
  // ═══════════════════════════════════════

  /// 初始化（旧代码兼容）
  Future<void> initialize() async {
    await load();
  }

  /// 清除所有数据
  Future<void> clearAllData() async {
    _leads.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// 根据ID加载角色（旧代码兼容）
  Future<MaleLead?> loadById(String id) async {
    await load();
    return getMaleLead(id);
  }

  /// 加载所有角色摘要（旧代码兼容）
  Future<List<MaleLead>> loadAllSummaries() async {
    await load();
    return List.from(_leads);
  }

  // ═══════════════════════════════════════
  // 卡片功能（char_list_page 兼容）
  // ═══════════════════════════════════════

  /// 从卡片数据创建角色（旧代码兼容）
  Future<MaleLead?> createFromCard(Map<String, dynamic> cardData) async {
    final lead = MaleLead.fromJson(cardData);
    await addMaleLead(lead);
    return lead;
  }

  /// 更新卡片（旧代码兼容）
  Future<void> updateCard(String id, Map<String, dynamic> cardData) async {
    final lead = getMaleLead(id);
    if (lead != null) {
      lead.name = cardData['name'] as String? ?? lead.name;
      lead.avatarPath = cardData['avatarPath'] as String? ?? lead.avatarPath;
      await _save();
    }
  }

  /// 构建空卡片（旧代码兼容）
  MaleLead buildEmptyCard() {
    return MaleLead(id: '', name: '新角色');
  }

  /// 导出到JSON文件（旧代码兼容）
  Future<String> exportToJsonFile(String id) async => '';
  /// 导出到PNG文件（旧代码兼容）
  Future<String> exportToPngFile(String id) async => '';
  /// 从文件导入（旧代码兼容）
  Future<MaleLead?> importFromFile(String path) async => null;
  /// 删除角色（旧代码兼容-返回是否成功）
  Future<bool> delete(String id) async {
    deleteMaleLead(id);
    return true;
  }
}
