import '../models/character_card.dart';
import 'character_service.dart';

class ResolvedChatCharacter {
  const ResolvedChatCharacter({
    required this.id,
    required this.name,
    required this.description,
    required this.cardJson,
    this.imagePath,
    this.thumbnailPath,
    this.isAssetImage = false,
    this.sourceLabel = '真实角色',
  });

  final String id;
  final String name;
  final String description;
  final Map<String, dynamic> cardJson;
  final String? imagePath;
  final String? thumbnailPath;
  final bool isAssetImage;
  final String sourceLabel;
}

class ChatCharacterResolver {
  ChatCharacterResolver._();

  static final ChatCharacterResolver instance = ChatCharacterResolver._();

  Future<ResolvedChatCharacter?> resolveById(String characterId) async {
    final realRecord = await CharacterService.instance.loadById(characterId);
    if (realRecord != null) {
      return _fromRecord(realRecord as dynamic);
    }
    return null;
  }

  Future<List<ResolvedChatCharacter>> loadAllOptions() async {
    final options = <ResolvedChatCharacter>[];

    final summaries = await CharacterService.instance.loadAllSummaries();
    for (final summary in summaries) {
      final record = await CharacterService.instance.loadById(summary.id);
      if (record == null) {
        continue;
      }
      options.add(_fromRecord(record as dynamic));
    }

    return options;
  }

  ResolvedChatCharacter _fromRecord(dynamic record) {
    final id = record.id is String ? record.id as String : '';
    final name = record.name is String && (record.name as String).isNotEmpty
        ? record.name as String
        : '未命名角色';
    final desc = record.description is String ? record.description as String : '';
    return ResolvedChatCharacter(
      id: id,
      name: name,
      description: desc,
      cardJson: {},
      imagePath: null,
      thumbnailPath: null,
      sourceLabel: '真实角色',
    );
  }
}
