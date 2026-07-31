/// 用户要素发现器
///
/// 从对话中自动发现用户的特征、习惯、模式，写入用户要素库。
///
/// 发现策略（三路融合）：
/// 1. ONNX 情绪语义 — 用情绪模型的标签+极性判断用户状态
/// 2. 关键词触发 — 检测具体事件（经期、怕什么、喜欢什么）
/// 3. 场景关联 — 时间+天气+场景组合

import 'user_element.dart';
import 'user_element_store.dart';
import '../mood_analysis/mood_interface.dart';

/// 用户要素发现器
class UserElementDiscoverer {
  final IUserElementStore _store;

  /// 记录最近发现的要素ID，避免同条对话重复发现
  final Set<String> _recentlyDiscovered = {};

  UserElementDiscoverer(this._store);

  /// 从用户输入 + 情绪分析结果中分析并发现要素
  /// 返回新发现的要素列表
  Future<List<UserElement>> analyze({
    required String userInput,
    MoodResult? moodResult,
  }) async {
    final discovered = <UserElement>[];

    // 策略1: ONNX 情绪语义分析
    if (moodResult != null) {
      final semanticElements = _detectByMoodSemantic(userInput, moodResult);
      for (final e in semanticElements) {
        if (_recentlyDiscovered.contains(e.id)) continue;
        await _store.insert(e);
        _recentlyDiscovered.add(e.id);
        discovered.add(e);
      }
    }

    // 策略2: 关键词触发检测（补漏）
    final keywordElements = _detectByKeywords(userInput);
    for (final e in keywordElements) {
      if (_recentlyDiscovered.contains(e.id)) continue;
      await _store.insert(e);
      _recentlyDiscovered.add(e.id);
      discovered.add(e);
    }

    return discovered;
  }

  /// ============================================================
  /// 策略1：ONNX 情绪语义分析
  /// ============================================================
  List<UserElement> _detectByMoodSemantic(String input, MoodResult mood) {
    final result = <UserElement>[];

    // 用情绪标签判断用户状态
    final labels = mood.dimensions.keys.toList();

    // ---- 依恋/渴望 ----
    if (labels.contains('渴望') || labels.contains('爱意') ||
        labels.contains('依恋') || labels.contains('思念')) {
      // 检查是否有"要你"、"抱"、"想"这类指向具体动作的表达
      if (_matchesAny(input, ['要你', '要抱', '抱我', '亲', '吻', '进来', '想要'])) {
        result.add(UserElement(
          id: _genId('mood_desire'),
          dimension: UserDimension.relation,
          content: '用户亲密需求高时，渴望肢体接触和靠近',
          source: '情绪语义',
          triggerWords: ['要', '想要', '抱', '亲'],
        ));
      }

      // 检查是否有特定场景触发
      if (_matchesAny(input, ['下雨', '晚上', '一个', '孤单', '寂寞'])) {
        result.add(UserElement(
          id: _genId('scene_lonely_seek'),
          dimension: UserDimension.scene,
          content: '用户孤单/独处时依恋感上升，渴望陪伴',
          source: '情绪语义',
          triggerWords: ['孤单', '寂寞', '一个人', '下雨'],
        ));
      }
    }

    // ---- 脆弱/伤心 ----
    if (labels.contains('伤心') || labels.contains('悲伤') ||
        labels.contains('脆弱') || labels.contains('失望')) {
      result.add(UserElement(
        id: _genId('mood_vulnerable'),
        dimension: UserDimension.mood,
        content: '用户脆弱伤心时需要温柔的安慰和陪伴',
        source: '情绪语义',
        triggerWords: ['伤心', '难过', '脆弱', '失望', '哭'],
      ));
    }

    // ---- 烦躁/生气 ----
    if (labels.contains('愤怒') || labels.contains('烦躁') ||
        labels.contains('厌烦') || labels.contains('不耐烦')) {
      result.add(UserElement(
        id: _genId('mood_angry'),
        dimension: UserDimension.mood,
        content: '用户烦躁生气时，需要耐心倾听和安抚',
        source: '情绪语义',
        triggerWords: ['烦', '生气', '愤怒', '受不了', '讨厌'],
      ));
    }

    // ---- 焦虑/不安 ----
    if (labels.contains('焦虑') || labels.contains('紧张') ||
        labels.contains('害怕') || labels.contains('恐惧')) {
      // 提取害怕的具体对象
      final fear = _extractAfterWord(input, ['怕', '害怕', '担心', '紧张']);
      if (fear.isNotEmpty) {
        result.add(UserElement(
          id: _genId('mood_fear_${fear.hashCode}'),
          dimension: UserDimension.preference,
          content: '用户怕$fear',
          source: '情绪语义',
          triggerWords: ['怕', '害怕', '担心', fear],
        ));
      } else {
        result.add(UserElement(
          id: _genId('mood_anxious'),
          dimension: UserDimension.mood,
          content: '用户焦虑不安时，需要安全感和稳定的陪伴',
          source: '情绪语义',
          triggerWords: ['焦虑', '不安', '紧张', '担心'],
        ));
      }
    }

    // ---- 开心/幸福 ----
    if (labels.contains('喜悦') || labels.contains('幸福') ||
        labels.contains('满足') || labels.contains('安心')) {
      // 提取开心原因
      final reason = _extractAfterWord(input, ['喜欢', '开心', '幸福', '开心因为', '因为']);
      // 提取喜欢的具体对象
      final like = _extractAfterWord(input, ['喜欢', '爱吃', '爱喝', '最爱', '爱']);
      if (like.isNotEmpty) {
        result.add(UserElement(
          id: _genId('preference_like_${like.hashCode}'),
          dimension: UserDimension.preference,
          content: '用户喜欢$like',
          source: '情绪语义',
          triggerWords: ['喜欢', '爱', like],
        ));
      }
    }

    // ---- 生理不适 ----
    if (labels.contains('痛苦') || labels.contains('不舒服') ||
        labels.contains('疼痛')) {
      if (_matchesAny(input, ['肚子', '经期', '姨妈', '生理'])) {
        result.add(UserElement(
          id: _genId('physiology_menses'),
          dimension: UserDimension.physiology,
          content: '用户经期身体不适，需要被照顾',
          source: '情绪语义+关键词',
          triggerWords: ['经期', '肚子疼', '生理期'],
        ));
      }
    }

    // ---- 高 arousal + 亲密 ----
    if (mood.concentrationValue > 65 &&
        (labels.contains('渴望') || labels.contains('爱意') || labels.contains('亲密'))) {
      result.add(UserElement(
        id: _genId('mood_high_attachment'),
        dimension: UserDimension.relation,
        content: '用户亲密互动时投入度高，沉浸在情感交流中',
        source: '情绪语义',
        triggerWords: [],
      ));
    }

    return result;
  }

  /// ============================================================
  /// 策略2：关键词触发检测（补漏，覆盖情绪模型没捕捉到的）
  /// ============================================================
  List<UserElement> _detectByKeywords(String input) {
    final result = <UserElement>[];

    // 生理周期
    if (_matchesAny(input, ['经期', '来姨妈', '月经', '大姨妈'])) {
      result.add(UserElement(
        id: _genId('kw_physiology_menses'),
        dimension: UserDimension.physiology,
        content: '用户在经期，情绪和身体有变化',
        source: '关键词',
        triggerWords: ['经期', '生理期', '姨妈'],
      ));
    }
    if (_matchesAny(input, ['经前', '快来了'])) {
      result.add(UserElement(
        id: _genId('kw_physiology_pms'),
        dimension: UserDimension.physiology,
        content: '用户处于经前期，情绪可能敏感',
        source: '关键词',
        triggerWords: ['经前', '快来'],
      ));
    }

    // 场景
    if (_matchesAny(input, ['下雨', '下雨天', '雨声', '雨天'])) {
      result.add(UserElement(
        id: _genId('kw_scene_rainy'),
        dimension: UserDimension.scene,
        content: '下雨天用户的情绪和行为有规律性变化',
        source: '关键词',
        triggerWords: ['下雨', '雨天', '雨'],
      ));
    }
    if (_matchesAny(input, ['晚上', '深夜', '睡不着', '失眠', '熬夜'])) {
      result.add(UserElement(
        id: _genId('kw_scene_night'),
        dimension: UserDimension.scene,
        content: '深夜时段用户活跃，容易找男主聊天',
        source: '关键词',
        triggerWords: ['晚上', '深夜', '失眠', '熬夜'],
      ));
    }

    return result;
  }

  /// ============================================================
  /// 辅助方法
  /// ============================================================
  bool _matchesAny(String input, List<String> keywords) {
    for (final k in keywords) {
      if (input.contains(k)) return true;
    }
    return false;
  }

  String _extractAfterWord(String input, List<String> afterWords) {
    for (final w in afterWords) {
      final idx = input.indexOf(w);
      if (idx >= 0) {
        final after = input.substring(idx + w.length).trim();
        final endIdx = after.indexOf(RegExp(r'[，。！？、；：]'));
        final result = endIdx > 0 ? after.substring(0, endIdx).trim() : after;
        if (result.isNotEmpty && result.length < 20) return result;
      }
    }
    return '';
  }

  String _genId(String prefix) {
    return '${prefix}_${DateTime.now().millisecondsSinceEpoch}';
  }
}
