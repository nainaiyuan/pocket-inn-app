/// 嵌入向量引擎接口及工具
///
/// 用于将文本转为向量（embedding）并计算相似度。
/// 当前仅提供内存实现，未来可接入 ONNX 模型。

import 'user_element.dart';

/// 嵌入向量引擎接口
abstract class IEmbeddingEngine {
  /// 将文本转换为向量
  Future<List<double>> embed(String text);

  /// 向量维度
  int get dimension;
}

/// 嵌入向量引擎工厂
class EmbeddingEngineFactory {
  /// 获取推荐的嵌入引擎
  static Future<IEmbeddingEngine> getPreferred() async {
    return MemoryEmbeddingEngine();
  }
}

/// 向量计算工具
class VectorUtils {
  /// 计算余弦相似度
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dotProduct = 0;
    double normA = 0;
    double normB = 0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA == 0 || normB == 0) return 0.0;
    return dotProduct / (normA * normB).clamp(1e-10, double.infinity);
  }

  /// 检查两个向量是否语义相似（超过阈值）
  static bool isSemanticallySimilar(
    List<double> a,
    List<double> b, {
    double threshold = 0.8,
  }) {
    return cosineSimilarity(a, b) >= threshold;
  }
}

/// 内存嵌入引擎（简单实现）
class MemoryEmbeddingEngine implements IEmbeddingEngine {
  final int _dimension = 64;

  @override
  int get dimension => _dimension;

  @override
  Future<List<double>> embed(String text) async {
    // 简单的哈希向量：将文本映射到 _dimension 维向量
    // 仅用于测试/占位
    final vec = List.filled(_dimension, 0.0);

    final bytes = text.codeUnits;
    for (int i = 0; i < bytes.length; i++) {
      final idx = i % _dimension;
      vec[idx] += (bytes[i] % 10) / 10.0;
    }

    // 归一化
    final norm = vec.fold(0.0, (sum, v) => sum + v * v);
    if (norm > 0) {
      final scale = 1.0 / norm;
      for (int i = 0; i < _dimension; i++) {
        vec[i] *= scale;
      }
    }

    return vec;
  }
}
