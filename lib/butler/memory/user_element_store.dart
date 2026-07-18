/// 用户要素存储层
///
/// 所有用户要素的增删改查、向量搜索、合并去重。
/// 真机上对接 SQLite，当前版本用内存模拟。

import 'user_element.dart';
import 'embedding_engine.dart';

/// 用户要素存储接口
abstract class IUserElementStore {
  Future<void> init();
  Future<void> insert(UserElement element);
  Future<void> insertAll(List<UserElement> elements);

  /// 搜最相关的要素（向量 + 关键词双路检索）
  Future<List<UserElement>> searchRelevant(String query, {int maxResults = 5});

  /// 按维度获取所有活跃要素
  Future<List<UserElement>> getByDimension(UserDimension dimension);

  /// 获取所有活跃要素
  Future<List<UserElement>> getAllActive();

  /// 更新确认时间（对话中印证了这条要素）
  Future<void> confirmElement(String id);

  /// 标记要素为不活跃（衰减归档）
  Future<void> deactivate(String id);

  /// 彻底删除
  Future<void> delete(String id);

  /// 要素总数
  Future<int> count();

  /// 运行衰减检查（标记超期的为不活跃）
  Future<int> runDecayCheck();
}

/// 用户要素存储实现（内存版）
class UserElementStore implements IUserElementStore {
  final List<UserElement> _elements = [];
  late IEmbeddingEngine _embedder;

  @override
  Future<void> init() async {
    _embedder = await EmbeddingEngineFactory.getPreferred();
  }

  @override
  Future<void> insert(UserElement element) async {
    // 计算向量（如果还没有）
    if (element.embedding == null) {
      final vec = await _embedder.embed(element.content);
      _elements.add(UserElement(
        id: element.id,
        dimension: element.dimension,
        content: element.content,
        source: element.source,
        importance: element.importance,
        triggerWords: element.triggerWords,
        embedding: vec,
        discoveredAt: element.discoveredAt,
        lastConfirmedAt: element.lastConfirmedAt,
        lastUsedAt: element.lastUsedAt,
        confirmCount: element.confirmCount,
        isActive: element.isActive,
      ));
    } else {
      _elements.add(element);
    }

    // 入库后自动检查合并
    await _mergeDuplicates();
  }

  @override
  Future<void> insertAll(List<UserElement> elements) async {
    for (final e in elements) {
      await insert(e);
    }
  }

  @override
  Future<List<UserElement>> searchRelevant(String query, {int maxResults = 5}) async {
    final active = _elements.where((e) => e.isActive).toList();
    if (active.isEmpty) return [];

    final queryVec = await _embedder.embed(query);

    // 双路检索：向量相似度 + 关键词命中
    final scored = <_ScoredElement>[];

    for (final element in active) {
      double vectorScore = 0;
      if (element.embedding != null) {
        vectorScore = VectorUtils.cosineSimilarity(queryVec, element.embedding!);
      }

      // 关键词命中加分
      double keywordScore = 0;
      for (final word in element.triggerWords) {
        if (query.contains(word)) {
          keywordScore += 0.3;
        }
      }

      // 发现很久没见过但内容匹配的，给个新鲜度加成
      final freshnessBonus = element.freshnessScore;

      // 综合得分
      final totalScore = vectorScore * 0.6 + keywordScore + freshnessBonus * 0.2;

      scored.add(_ScoredElement(element: element, score: totalScore));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    // 取 topN，并做"意不去重"：相似要素只留一条
    final result = <UserElement>[];
    for (final s in scored) {
      if (result.length >= maxResults) break;

      // 检查是否和已选的要素意思重复
      bool isDuplicate = false;
      if (s.element.embedding != null) {
        for (final selected in result) {
          if (selected.embedding != null &&
              VectorUtils.isSemanticallySimilar(s.element.embedding!, selected.embedding!, threshold: 0.85)) {
            isDuplicate = true;
            break;
          }
        }
      }

      if (!isDuplicate) {
        result.add(s.element);
        // 更新 lastUsedAt
        _markUsed(s.element.id);
      }
    }

    return result;
  }

  @override
  Future<List<UserElement>> getByDimension(UserDimension dimension) async {
    return _elements.where((e) => e.isActive && e.dimension == dimension).toList();
  }

  @override
  Future<List<UserElement>> getAllActive() async {
    return _elements.where((e) => e.isActive).toList();
  }

  @override
  Future<void> confirmElement(String id) async {
    final idx = _elements.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      _elements[idx].lastConfirmedAt = DateTime.now();
      _elements[idx].confirmCount++;
    }
  }

  @override
  Future<void> deactivate(String id) async {
    final idx = _elements.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      _elements[idx] = UserElement(
        id: _elements[idx].id,
        dimension: _elements[idx].dimension,
        content: _elements[idx].content,
        source: _elements[idx].source,
        importance: _elements[idx].importance,
        triggerWords: _elements[idx].triggerWords,
        embedding: _elements[idx].embedding,
        discoveredAt: _elements[idx].discoveredAt,
        lastConfirmedAt: _elements[idx].lastConfirmedAt,
        lastUsedAt: _elements[idx].lastUsedAt,
        confirmCount: _elements[idx].confirmCount,
        isActive: false,
      );
    }
  }

  @override
  Future<void> delete(String id) async {
    _elements.removeWhere((e) => e.id == id);
  }

  @override
  Future<int> count() async => _elements.length;

  @override
  Future<int> runDecayCheck() async {
    int count = 0;
    for (final e in _elements) {
      if (e.isActive && e.isStale) {
        await deactivate(e.id);
        count++;
      }
    }
    return count;
  }

  void _markUsed(String id) {
    final idx = _elements.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      _elements[idx].lastUsedAt = DateTime.now();
    }
  }

  /// 自动合并：向量相似度 > 0.9 的合并为一条
  Future<void> _mergeDuplicates() async {
    bool merged = false;
    for (int i = 0; i < _elements.length; i++) {
      if (!_elements[i].isActive || _elements[i].embedding == null) continue;
      for (int j = i + 1; j < _elements.length; j++) {
        if (!_elements[j].isActive || _elements[j].embedding == null) continue;
        if (VectorUtils.isSemanticallySimilar(
            _elements[i].embedding!, _elements[j].embedding!, threshold: 0.9)) {
          // 合并：保留重要性更高的，内容取新的
          final keeper = _elements[i].importance >= _elements[j].importance ? i : j;
          final removed = keeper == i ? j : i;

          _elements[keeper] = UserElement(
            id: _elements[keeper].id,
            dimension: _elements[keeper].dimension,
            content: _elements[removed].content, // 取更新的表述
            source: _elements[keeper].source,
            importance: (_elements[keeper].importance + _elements[removed].importance) / 2,
            triggerWords: _elements[keeper].triggerWords,
            embedding: _elements[keeper].embedding,
            discoveredAt: _elements[keeper].discoveredAt,
            lastConfirmedAt: DateTime.now(),
            lastUsedAt: _elements[keeper].lastUsedAt,
            confirmCount: _elements[keeper].confirmCount + _elements[removed].confirmCount,
            isActive: true,
          );

          _elements.removeAt(removed);
          merged = true;
          break; // 一个合并完就重新遍历
        }
      }
      if (merged) break;
    }
    if (merged) await _mergeDuplicates(); // 递归直到没有可合并的
  }
}

class _ScoredElement {
  final UserElement element;
  final double score;
  _ScoredElement({required this.element, required this.score});
}
