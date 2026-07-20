/// 聊天消息模型
class ChatMessage {
  final String id;
  final String personaId; // 发送者（null = 用户）
  final String text;
  final String? imageUrl;
  final DateTime timestamp;
  final MessageStatus status;

  const ChatMessage({
    required this.id,
    this.personaId,
    required this.text,
    this.imageUrl,
    required this.timestamp,
    this.status = MessageStatus.sent,
  });

  ChatMessage copyWith({MessageStatus? status, String? text}) {
    return ChatMessage(
      id: id,
      personaId: personaId,
      text: text ?? this.text,
      imageUrl: imageUrl,
      timestamp: timestamp,
      status: status ?? this.status,
    );
  }

  bool get isUser => personaId == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'personaId': personaId,
        'text': text,
        'imageUrl': imageUrl,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status.index,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        personaId: json['personaId'] as String?,
        text: json['text'] as String,
        imageUrl: json['imageUrl'] as String?,
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        status: MessageStatus.values[json['status'] as int? ?? 1],
      );
}

enum MessageStatus {
  sending,
  sent,
  failed,
}
