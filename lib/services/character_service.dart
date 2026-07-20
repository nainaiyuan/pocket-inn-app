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
}
