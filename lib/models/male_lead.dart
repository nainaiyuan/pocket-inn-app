/// 男主 —— 顶层角色
class MaleLead {
  final String id;
  String name;
  String avatarPath; // 头像图片路径（本地文件或 asset）
  String backgroundPath; // 全局聊天背景（Persona 没有单独背景时继承此值）
  List<Persona> personas; // 该男主下的所有形象

  MaleLead({
    required this.id,
    required this.name,
    this.avatarPath = '',
    this.backgroundPath = '',
    List<Persona>? personas,
  }) : personas = personas ?? [];

  MaleLead copyWith({
    String? id,
    String? name,
    String? avatarPath,
    String? backgroundPath,
    List<Persona>? personas,
  }) {
    return MaleLead(
      id: id ?? this.id,
      name: name ?? this.name,
      avatarPath: avatarPath ?? this.avatarPath,
      backgroundPath: backgroundPath ?? this.backgroundPath,
      personas: personas ?? List.from(this.personas),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatarPath': avatarPath,
        'backgroundPath': backgroundPath,
        'personas': personas.map((p) => p.toJson()).toList(),
      };

  factory MaleLead.fromJson(Map<String, dynamic> json) => MaleLead(
        id: json['id'] as String,
        name: json['name'] as String,
        avatarPath: json['avatarPath'] as String? ?? '',
        backgroundPath: json['backgroundPath'] as String? ?? '',
        personas: (json['personas'] as List<dynamic>?)
                ?.map((e) => Persona.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

/// 形象 —— 男主的一个身份/设定
class Persona {
  final String id;
  final String maleLeadId; // 所属男主 ID
  String name; // 形象名称（如"校园版"、"吸血鬼"）
  String avatarPath; // 形象头像（可选，不设则用男主头像）
  String backgroundPath; // 聊天背景图片路径（可选）
  String prompt; // 该形象的 prompt
  String greeting; // 首次对话开场白
  String description; // 简短描述（卡片上用）
  DateTime createdAt;

  Persona({
    required this.id,
    required this.maleLeadId,
    required this.name,
    this.avatarPath = '',
    this.backgroundPath = '',
    this.prompt = '',
    this.greeting = '',
    this.description = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Persona copyWith({
    String? id,
    String? maleLeadId,
    String? name,
    String? avatarPath,
    String? backgroundPath,
    String? prompt,
    String? greeting,
    String? description,
    DateTime? createdAt,
  }) {
    return Persona(
      id: id ?? this.id,
      maleLeadId: maleLeadId ?? this.maleLeadId,
      name: name ?? this.name,
      avatarPath: avatarPath ?? this.avatarPath,
      backgroundPath: backgroundPath ?? this.backgroundPath,
      prompt: prompt ?? this.prompt,
      greeting: greeting ?? this.greeting,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'maleLeadId': maleLeadId,
        'name': name,
        'avatarPath': avatarPath,
        'backgroundPath': backgroundPath,
        'prompt': prompt,
        'greeting': greeting,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Persona.fromJson(Map<String, dynamic> json) => Persona(
        id: json['id'] as String,
        maleLeadId: json['maleLeadId'] as String,
        name: json['name'] as String,
        avatarPath: json['avatarPath'] as String? ?? '',
        backgroundPath: json['backgroundPath'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        greeting: json['greeting'] as String? ?? '',
        description: json['description'] as String? ?? '',
        createdAt: json['createdAt'] != null
            ? DateTime.parse(json['createdAt'] as String)
            : null,
      );
}
