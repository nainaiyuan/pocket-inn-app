import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'api_config.freezed.dart';
part 'api_config.g.dart';

/// 单个模型条目。一个 [ApiConfig]（Provider）下可包含多个模型，
/// 每个模型携带自己的 [customBody]，跟随模型本身。
@freezed
abstract class ApiModel with _$ApiModel {
  const ApiModel._();

  const factory ApiModel({
    @JsonKey(defaultValue: '') required String id,
    @JsonKey(defaultValue: '') required String modelId,
    @JsonKey(defaultValue: '') @Default('') String customBody,
    // 8-09 17:0x（用户设计定稿）：思考模式开关——同一个模型有思考/不思考
    // 两种模式（DeepSeek V3.2 后请求参数控制）时用户可切换。
    // null = 未设置（跟随服务端默认/customBody）；true = 强制开思考；
    // false = 强制关思考（完全不思考，更快更省）。
    @JsonKey() bool? thinkingEnabled,
  }) = _ApiModel;

  factory ApiModel.fromJson(Map<String, dynamic> json) =>
      _$ApiModelFromJson(json);

  Map<String, dynamic> parseCustomBody() {
    final source = customBody.trim();
    if (source.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw FormatException('自定义 body 必须是 JSON 对象');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

/// API 提供方。持有 baseUrl / apiKey 与一组模型列表。
///
/// 选择状态由全局 [lib/data/api_configs.dart] 中的
/// `selectedApiModelIdNotifier` 维护，本类不持有任何"激活"标志。
@freezed
abstract class ApiConfig with _$ApiConfig {
  const ApiConfig._();

  const factory ApiConfig({
    @JsonKey(defaultValue: '') required String id,
    @JsonKey(defaultValue: '未命名配置') required String name,
    @JsonKey(defaultValue: '') required String baseUrl,
    @JsonKey(defaultValue: '') required String apiKey,
    @JsonKey(defaultValue: <ApiModel>[])
    @Default(<ApiModel>[])
    List<ApiModel> models,
  }) = _ApiConfig;

  factory ApiConfig.fromJson(Map<String, dynamic> json) =>
      _$ApiConfigFromJson(json);

  /// 将本 provider 与指定 [model] 组合成 [ResolvedApiConfig]，供 service 层调用。
  ResolvedApiConfig resolve(ApiModel model) => ResolvedApiConfig(
        id: id,
        name: name,
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model.modelId,
        customBody: model.customBody,
      );

  /// 用于仅需 provider 信息（如 fetchModels）的场景：取首个 model，
  /// 若列表为空则用空 model 占位，service 内部会处理空 model 情况。
  ResolvedApiConfig resolveFirstOrEmpty() => models.isEmpty
      ? resolve(const ApiModel(id: '', modelId: '', customBody: ''))
      : resolve(models.first);
}

/// Provider + 选定 model 的组合，作为 [OpenAICompatibleApiService] 的统一入参。
@freezed
abstract class ResolvedApiConfig with _$ResolvedApiConfig {
  const ResolvedApiConfig._();

  const factory ResolvedApiConfig({
    @JsonKey(defaultValue: '') required String id,
    @JsonKey(defaultValue: '未命名配置') required String name,
    @JsonKey(defaultValue: '') required String baseUrl,
    @JsonKey(defaultValue: '') required String apiKey,
    @JsonKey(defaultValue: '') required String model,
    @JsonKey(defaultValue: '') @Default('') String customBody,
    // 8-09 17:0x：思考模式开关（见 ApiModel.thinkingEnabled 注释）
    @JsonKey() bool? thinkingEnabled,
  }) = _ResolvedApiConfig;

  factory ResolvedApiConfig.fromJson(Map<String, dynamic> json) =>
      _$ResolvedApiConfigFromJson(json);

  Map<String, dynamic> parseCustomBody() {
    final source = customBody.trim();
    if (source.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw FormatException('自定义 body 必须是 JSON 对象');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> buildRequestBody({
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? defaults,
    List<Map<String, dynamic>>? tools,
  }) {
    final body = <String, dynamic>{
      if (defaults != null) ...defaults,
      'model': model,
      'messages': messages,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
    };
    body.addAll(parseCustomBody());
    // 8-09 17:0x（用户设计定稿）：思考模式显式开关——true 注入开启参数、
    // false 注入关闭参数（DeepSeek V3.2 格式 thinking.type），显式值覆盖
    // customBody 里的旧配置（customBody 链路已断，这里兜底补齐）。
    // null = 不注入，跟随服务端默认。
    if (thinkingEnabled != null) {
      body['thinking'] = {
        'type': thinkingEnabled! ? 'enabled' : 'disabled',
      };
    }
    return body;
  }
}
