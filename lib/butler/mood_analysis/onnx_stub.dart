/// ONNX Runtime 类型桩 — 编译占位
///
/// 提供 onnxruntime 所需的类型定义，使得 mood_analyzer_onnx.dart
/// 在不依赖真实 onnxruntime 包的情况下也能编译通过。
/// 实际运行时，flutter build web 会在 web 环境下替换为真实实现。

class OrtEnv {
  OrtEnv._();
  static final OrtEnv instance = OrtEnv._();
}

class OrtSessionOptions {
  void setIntraOpNumThreads(int n) {}
  void free() {}
}

enum TensorElementType { int64, float32 }

class OrtTensor {
  final List<dynamic> data;
  final List<int> shape;
  final TensorElementType elementType;

  OrtTensor._({
    required this.data,
    required this.shape,
    required this.elementType,
  });

  factory OrtTensor.fromList(
    List<dynamic> data,
    List<int> shape,
    TensorElementType elementType,
  ) {
    return OrtTensor._(data: data, shape: shape, elementType: elementType);
  }
}

class OrtSession {
  final Map<String, OrtTensor> _outputs;

  OrtSession._(this._outputs);

  factory OrtSession.fromBuffer(List<int> bytes, OrtSessionOptions options) {
    // 桩实现：仅编译用，实际不会加载模型
    return OrtSession._({
      'logits': OrtTensor.fromList(
        List.filled(31, 0.0),
        [1, 31],
        TensorElementType.float32,
      ),
    });
  }

  Map<String, OrtTensor> run(Map<String, OrtTensor> inputs) {
    return _outputs;
  }

  void release() {}
}
