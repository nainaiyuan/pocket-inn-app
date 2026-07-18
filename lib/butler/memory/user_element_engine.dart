/// 用户要素整体入口
///
/// 封装用户要素系统的三个核心组件，对外暴露统一API。
/// 调度引擎通过这个入口访问用户要素。

import 'user_element.dart';
import 'user_element_store.dart';
import 'user_element_discoverer.dart';
import '../mood_analysis/mood_interface.dart';

/// 用户要素引擎（统一入口）
class UserElementEngine {
  final IUserElementStore store;
  final UserElementDiscoverer discoverer;

  UserElementEngine(this.store) : discoverer = UserElementDiscoverer(store);

  bool _initialized = false;

  /// 初始化
  Future<void> init() async {
    if (_initialized) return;
    await store.init();
    _initialized = true;
  }

  /// 处理用户输入：ONNX情绪语义分析 → 发现要素 → 检索相关要素
  /// 返回两个列表：
  ///   [0] = 新发现的要素（刚入库的）
  ///   [1] = 最相关的已有要素（准备推给男主的）
  Future<(List<UserElement>, List<UserElement>)> processInput({
    required String userInput,
    MoodResult? moodResult,
    int maxRelated = 5,
  }) async {
    // 1. ONNX语义分析 + 关键词 发现新要素
    final newElements = await discoverer.analyze(
      userInput: userInput,
      moodResult: moodResult,
    );

    // 2. 搜索最相关的已有要素
    final related = await store.searchRelevant(userInput, maxResults: maxRelated);

    return (newElements, related);
  }

  /// 搜索用户要素（供调度引擎调用）
  Future<List<UserElement>> search(String query, {int maxResults = 5}) async {
    return store.searchRelevant(query, maxResults: maxResults);
  }

  /// 对话中确认了某条要素（更新可信度）
  Future<void> confirm(String elementId) async {
    await store.confirmElement(elementId);
  }

  /// 运行衰减检查
  Future<int> runDecayCheck() async {
    return store.runDecayCheck();
  }

  /// 获取统计数据
  Future<Map<String, dynamic>> getStats() async {
    final total = await store.count();
    final byDim = <String, int>{};
    for (final dim in UserDimension.values) {
      final elements = await store.getByDimension(dim);
      if (elements.isNotEmpty) {
        byDim[dim.label] = elements.length;
      }
    }
    return {
      'total': total,
      'by_dimension': byDim,
    };
  }
}
