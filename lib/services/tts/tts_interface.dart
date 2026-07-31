/// TTS (语音合成) 接口
/// 所有语音引擎统一实现此接口
/// 线上版（调用远端API）和本地版（离线模型）都走同一套方法

abstract class TtsInterface {
  /// 初始化引擎
  /// [modelPath] 本地模型路径（离线版用）
  /// [serverUrl] 服务器地址（线上版用）
  /// [voicePath] 音色参考音频路径（克隆用）
  Future<void> init({String? modelPath, String? serverUrl, String? voicePath});

  /// 获取当前模式
  bool get isOffline;       // true=离线, false=线上
  String get engineName;   // 引擎名称（方便查状态）

  /// 合成语音（完整播报）
  /// [text] 要说的文本
  /// 返回音频文件路径（本地临时文件）
  Future<String> synthesize(String text);

  /// 流式合成（边生成边播）
  /// [text] 要说的文本
  /// [onAudioChunk] 每生成一段音频的回调
  Stream<String> synthesizeStream(String text);

  /// 设置音色（切换男主/克隆）
  /// [voiceId] 预设音色ID
  /// [audioSample] 自定义参考音频（克隆用）
  Future<void> setVoice(String voiceId, {String? audioSample});

  /// 获取当前可用音色列表
  List<String> get availableVoices;

  /// 语速调节（0.5-2.0）
  double speed = 1.0;
  /// 音量调节（0.0-1.0）
  double volume = 1.0;
  /// 音调调节
  double pitch = 1.0;

  /// 根据情绪分调整参数
  void applyMood(double moodScore) {
    if (moodScore > 0.6) {
      speed = 1.2;      // 开心→语速快
      volume = 1.0;
    } else if (moodScore < 0.3) {
      speed = 0.85;     // 低落→语速慢
      volume = 0.75;    // 音量轻柔
    } else {
      speed = 1.0;
      volume = 1.0;
    }
  }

  /// 释放资源
  Future<void> dispose();
}

/// 线上语音合成（调用服务器API）
/// 平板装模型提供服务，手机APP通过网络调用
/// 或直接调用云端的TTS API
abstract class TtsRemote implements TtsInterface {
  /// 服务器地址（平板IP+端口，或云端API地址）
  String get serverUrl;
  set serverUrl(String url);

  /// 连接状态
  Future<bool> checkConnection();

  /// 最大合成字符数（防止一次请求太长）
  int get maxCharsPerRequest;
}

/// 本地语音合成（完全离线）
/// 模型直接跑在设备上，不需要网络
abstract class TtsLocal implements TtsInterface {
  /// 加载模型到内存
  Future<void> loadModel(String modelPath);

  /// 卸载模型释放内存
  Future<void> unloadModel();

  /// 当前内存占用（MB）
  double get memoryUsageMb;

  /// 模型是否已加载
  bool get isModelLoaded;
}
