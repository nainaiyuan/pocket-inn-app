/// 管家模块接口 — 所有管家功能的标准形状
///
/// 设计原则：
/// 1. 每个功能 = 一个独立模块文件，互不 import
/// 2. 模块之间只通过 [ButlerContext] 传递数据
/// 3. 每个模块有独立开关，默认全开，随时能关
/// 4. 模块抛异常不阻塞消息（由管线执行器兜底）
library;

/// 消息方向
enum ButlerFlow {
  /// 用户 → 男主（发消息，可改文本/拦截）
  outgoing,

  /// 男主 → 用户（AI 回复，可改文本）
  incoming,
}

/// 模块在管线中的执行位置
enum ButlerModuleStage {
  /// 最先跑：禁区拦截、假面层（改文本）
  guard,

  /// 中间跑：情绪分析、规律检索（读文本，产上下文）
  analyze,

  /// 最后跑：记忆写入、互动记录（收尾）
  persist,
}

/// 模块执行结果：允许/修改/拦截
class ButlerModuleResult {
  /// 处理后的文本（未修改则等于原文）
  final String text;

  /// 是否拦截（true = 消息不继续往下走，也不发给男主）
  final bool blocked;

  /// 拦截时给用户的提示
  final String? blockReason;

  /// 模块产出的上下文片段（拼进 Prompt 用）
  final List<String> contextFragments;

  /// 模块产出的结构化数据（给其他模块/存储用）
  final Map<String, dynamic> data;

  ButlerModuleResult({
    required this.text,
    this.blocked = false,
    this.blockReason,
    this.contextFragments = const [],
    this.data = const {},
  });

  ButlerModuleResult.pass(String text)
    : this(text: text);

  bool get wasModified => text != _originalText;

  /// 记录原始文本用于比较（由管线设置）
  String _originalText = '';
  void attachOriginal(String original) => _originalText = original;
}

/// 对话结束信息
class ConversationEndInfo {
  /// 本次会话的所有用户消息
  final List<String> userMessages;

  /// 本次会话的所有男主回复
  final List<String> characterReplies;

  /// 会话时长（分钟）
  final int durationMinutes;

  const ConversationEndInfo({
    required this.userMessages,
    required this.characterReplies,
    required this.durationMinutes,
  });
}

/// 管家模块抽象接口
///
/// 实现示例：
/// ```dart
/// class BlocklistModule extends ButlerModule {
///   @override
///   String get id => 'blocklist';
///   @override
///   String get name => '禁区拦截';
///   @override
///   ButlerModuleStage get stage => ButlerModuleStage.guard;
/// }
/// ```
abstract class ButlerModule {
  /// 唯一标识（英文，如 'blocklist'）
  String get id;

  /// 显示名（中文，管家页展示用）
  String get name;

  /// 说明文字
  String get description;

  /// 执行位置
  ButlerModuleStage get stage;

  /// 是否启用（默认 true）
  ///
  /// 子类可覆盖实现自己的逻辑（如依赖配置），
  /// 但 UI 开关通过 [setEnabled] 强制覆盖。
  /// 最终生效值 = [userEnabled] && [enabled]
  bool get enabled => true;

  /// 用户开关（UI 控制，持久化）。
  /// true = 用户没关（模块自己的 enabled 说了算）；
  /// false = 用户明确关掉（无论模块逻辑如何都不跑）。
  bool userEnabled = true;

  /// 设置用户开关（UI 调用）
  void setUserEnabled(bool value) => userEnabled = value;

  /// 最终是否执行（用户开关 && 模块自身逻辑）
  bool get isActive => userEnabled && enabled;

  /// 用户 → 男主：处理用户消息
  /// 返回 [ButlerModuleResult]（默认原样通过）
  Future<ButlerModuleResult> onUserMessage(
    ButlerContext context,
    String text,
  ) async {
    return ButlerModuleResult.pass(text);
  }

  /// 男主 → 用户：处理 AI 回复
  Future<ButlerModuleResult> onAssistantReply(
    ButlerContext context,
    String text,
  ) async {
    return ButlerModuleResult.pass(text);
  }

  /// 对话结束（5分钟无消息触发）
  Future<void> onConversationEnd(
    ButlerContext context,
    ConversationEndInfo info,
  ) async {}
}

/// 管线上下文 — 模块之间传递数据的唯一载体
///
/// 任何模块想给别的模块/Prompt 拼装器传数据，都塞进这里：
/// - [fragments]：文本片段（拼 Prompt 用）
/// - [data]：结构化数据（给存储/其他模块用）
class ButlerContext {
  /// 用户 ID（预留多用户）
  final String userId;

  /// 当前男主 ID
  final String characterId;

  /// 当前会话 ID
  final String sessionId;

  /// 模块产出的文本片段（按加入顺序，拼 Prompt 时按序输出）
  final List<ButlerFragment> fragments;

  /// 模块产出的结构化数据
  final Map<String, dynamic> data;

  /// 是否被拦截（禁区命中等）
  bool blocked;
  String? blockReason;

  ButlerContext({
    required this.userId,
    required this.characterId,
    required this.sessionId,
    List<ButlerFragment>? fragments,
    Map<String, dynamic>? data,
    this.blocked = false,
    this.blockReason,
  }) : fragments = fragments ?? [],
       data = data ?? {};

  /// 添加文本片段（拼 Prompt 用）
  void addFragment({
    required String source,
    required String content,
  }) {
    fragments.add(ButlerFragment(source: source, content: content));
  }

  /// 读取结构化数据
  T? getData<T>(String key) => data[key] as T?;

  /// 写入结构化数据
  void setData(String key, dynamic value) => data[key] = value;
}

/// Prompt 片段
class ButlerFragment {
  /// 来源说明（如 "情绪分析"、"记忆检索"）
  final String source;

  /// 片段内容
  final String content;

  const ButlerFragment({required this.source, required this.content});
}
