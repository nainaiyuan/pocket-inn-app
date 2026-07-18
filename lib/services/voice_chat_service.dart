/// 语音聊天服务 — 管理 TTS 自动朗读
///
/// 职责：
/// - 自动朗读开关（全局）
/// - 当 AI 回复完成时，自动调用 TTS 朗读
/// - 打电话模式（预留，以后加 ASR）
///
/// 使用方式：
///   final vo = getIt<VoiceChatService>();
///   vo.autoSpeak = true;          // 开启自动朗读
///   vo.onAssistantReply(text);    // AI 回复完成后调用
///
/// 🔌 以后加 ASR，在这里加 startListening() / stopListening()

import '../services/tts/tts_service.dart';

/// ASR（语音转文字）接口 — 预留
///
/// 以后找到 ASR 方案了，实现这个接口
abstract class AsrInterface {
  Future<void> init();
  Stream<String> startListening();
  Future<void> stopListening();
  Future<void> dispose();
}

/// ASR 空实现（未接入时用）
class AsrNullImpl implements AsrInterface {
  @override
  Future<void> init() async {}

  @override
  Stream<String> startListening() => const Stream.empty();

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {}
}

class VoiceChatService {
  VoiceChatService._();

  static final VoiceChatService instance = VoiceChatService._();

  // ─── TTS 自动朗读 ───

  /// 是否自动朗读 AI 回复
  bool autoSpeak = false;

  /// 是否正在朗读中
  bool get isSpeaking => _ttsService.isSpeaking;

  /// 静音（关闭所有语音输出）
  bool get muted => _ttsService.muted;

  set muted(bool value) {
    _ttsService.muted = value;
  }

  /// TTS 服务引用
  TtsService get _ttsService => TtsService.instance;

  // ─── ASR（预留） ───
  AsrInterface _asr = AsrNullImpl();
  bool _isListening = false;

  /// 当前 ASR 引擎
  AsrInterface get asr => _asr;

  /// 设置 ASR 引擎（以后接入具体方案时调用）
  void setAsr(AsrInterface asr) {
    _asr.dispose();
    _asr = asr;
  }

  // ─── 初始化 ───
  Future<void> init() async {
    // ASR 延迟初始化，等有具体方案再调
  }

  // ─── AI 回复完成时触发自动朗读 ───

  /// 当 AI 回复完成时调用
  ///
  /// [replyText] 是经过 MaskEngine 处理后的最终显示文本
  /// 保证读到的是用户看到的
  void onAssistantReply(String replyText) {
    if (!autoSpeak || muted) return;
    if (replyText.isEmpty) return;

    // 去 Markdown 标记，只读纯文本
    final cleanText = _stripMarkdown(replyText);
    if (cleanText.isEmpty) return;

    // 切分长文本，避免一次读太长
    _ttsService.enqueue(cleanText);
  }

  /// 停止朗读
  Future<void> stopSpeaking() async {
    await _ttsService.stop();
  }

  // ─── 打电话模式（预留） ───

  /// 开始语音输入
  Future<void> startListening() async {
    if (_isListening) return;
    _isListening = true;
    // TODO: 以后接入 ASR 后实现
  }

  /// 停止语音输入
  Future<void> stopListening() async {
    if (!_isListening) return;
    _isListening = false;
    // TODO: 以后接入 ASR 后实现
  }

  // ─── 工具 ───

  /// 去除 Markdown 标记，只保留纯文本
  String _stripMarkdown(String text) {
    return text
        .replaceAll(RegExp(r'#{1,6}\s+'), '') // 标题
        .replaceAll(RegExp(r'\*{1,3}(.+?)\*{1,3}'), r'$1') // 粗斜体
        .replaceAll(RegExp(r'`{1,3}[^`]*`{1,3}'), '') // 代码
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1') // 链接
        .replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]+\)'), '') // 图片
        .replaceAll(RegExp(r'>\s+'), '') // 引用
        .replaceAll(RegExp(r'[-*+]\s+'), '') // 列表
        .replaceAll(RegExp(r'\d+\.\s+'), '') // 数字列表
        .replaceAll(RegExp(r'```[\s\S]*?```'), '') // 代码块
        .replaceAll(RegExp(r'\n{2,}'), '\n') // 多余空行
        .trim();
  }

  // ─── 释放 ───
  Future<void> dispose() async {
    await _asr.dispose();
  }
}
