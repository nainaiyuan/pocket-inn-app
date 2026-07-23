import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../../models/chat_message.dart';

/// 聊天消息持久化服务（文件存储）
class ChatStorageService {
  static final ChatStorageService _instance = ChatStorageService._();
  factory ChatStorageService() => _instance;
  ChatStorageService._();

  String _key(String personaId) => 'chat_messages_$personaId';

  Future<File> _getFile(String personaId) async {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/_data');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/${_key(personaId)}.json');
  }

  /// 加载某个角色的聊天记录（最多200条）
  Future<List<ChatMessage>> loadMessages(String personaId) async {
    try {
      final file = await _getFile(personaId);
      if (!await file.exists()) return [];
      final json = await file.readAsString();
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// 保存消息列表
  Future<void> saveMessages(String personaId, List<ChatMessage> messages) async {
    try {
      final file = await _getFile(personaId);
      // 只保留最近200条
      final trimmed = messages.length > 200
          ? messages.sublist(messages.length - 200)
          : messages;
      final json = jsonEncode(trimmed.map((m) => m.toJson()).toList());
      await file.writeAsString(json);
    } catch (_) {}
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
    try {
      final file = await _getFile(personaId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
