import 'dart:math';

/// 模拟AI回复（开发阶段用，以后替换为真实API调用）
class AiChatService {
  static final AiChatService _instance = AiChatService._();
  factory AiChatService() => _instance;
  AiChatService._();

  final _rng = Random();
  final _greetings = [
    '嗯，我在听呢。',
    '你今天看起来心情不错。',
    '我在想你说过的话。',
    '你来了。',
    '我一直在等你。',
  ];

  final _responses = [
    '这样啊…我明白了。',
    '你能这么想，我很开心。',
    '让我想想该怎么回答你。',
    '你总是能让我意外。',
    '这个问题的答案…可能你自己心里已经有数了。',
    '我记在心里了。',
    '你相信缘分吗？',
    '有时候沉默也是一种回答。',
    '我会一直在这里。',
    '今天的月色真美。',
  ];

  /// 模拟回复（按文本长度做点变化）
  Future<String> generateReply(String message, String personaId) async {
    // 模拟网络延迟
    await Future.delayed(const Duration(milliseconds: 800));

    if (message.length < 3) {
      return _greetings[_rng.nextInt(_greetings.length)];
    }
    return _responses[_rng.nextInt(_responses.length)];
  }
}
