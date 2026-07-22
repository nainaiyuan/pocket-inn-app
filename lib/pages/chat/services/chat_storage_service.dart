import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../models/chat_message.dart';

/// 聊天消息持久化服务
class ChatStorageService {
  static final ChatStorageService _instance = ChatStorageService._();
  factory ChatStorageService() => _instance;
  ChatStorageService._();

  String _key(String personaId) => 'chat_messages_$personaId';

  /// 加载某个角色的聊天记录（最多200条）
  Future<List<ChatMessage>> loadMessages(String personaId) async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key(personaId));
    if (json == null) return [];
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 保存消息列表
  Future<void> saveMessages(String personaId, List<ChatMessage> messages) async {
    final prefs = await SharedPreferences.getInstance();
    // 只保留最近200条
    final trimmed = messages.length > 200
        ? messages.sublist(messages.length - 200)
        : messages;
    final json = jsonEncode(trimmed.map((m) => m.toJson()).toList());
    await prefs.setString(_key(personaId), json);
  }

  /// 追加一条消息
  Future<void> appendMessage(String personaId, ChatMessage message) async {
    final msgs = await loadMessages(personaId);
    msgs.add(message);
    await saveMessages(personaId, msgs);
  }

  /// 更新一条消息的状态
  Future<void> updateMessage(
      String personaId, String messageId, ChatMessage updated) async {
    final msgs = await loadMessages(personaId);
    final idx = msgs.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      msgs[idx] = updated;
      await saveMessages(personaId, msgs);
    }
  }

  /// 批量删除消息
  Future<void> deleteMessages(String personaId, List<String> messageIds) async {
    final msgs = await loadMessages(personaId);
    msgs.removeWhere((m) => messageIds.contains(m.id));
    await saveMessages(personaId, msgs);
  }

  /// 删除某个角色的所有聊天记录
  Future<void> deleteAllMessages(String personaId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(personaId));
  }
}
