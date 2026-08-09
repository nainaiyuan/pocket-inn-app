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
    // 8-10 01:3x（用户：档位全内置，只填模型，配置页可选，即时生效）：
    // 思考档位 'auto'/'off'/'low'/'high'/'max'（默认 auto，管家自动映射）
    @JsonKey(defaultValue: 'auto') @Default('auto') String thinkingLevel,
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
    // 8-10 01:3x（用户：档位全内置，用户只填模型；配置页可选档位，
    // 即时生效；男主不能自己切）：
    // 思考档位按模型系映射注入（各家参数名/格式不同，只注入"确定认识"
    // 的参数，不认识的参数可能 400 → 不注入，跟随服务端默认）：
    // - DeepSeek：thinking.type + reasoning_effort + max_tokens 8192
    // - OpenAI 系（o1/o3/o4 等）：reasoning_effort（low/medium/high）
    // - Claude/Gemini/其他：不注入（参数名不兼容，跟随服务端默认）
    // 档位：auto=管家自动 / off=关闭 / low=轻快 / high=平衡 / max=深度
    final level = thinkingLevel.isEmpty ? 'auto' : thinkingLevel;
    final isDeepSeek = baseUrl.toLowerCase().contains('deepseek');
    final isOpenAI =
        baseUrl.toLowerCase().contains('openai') ||
        model.toLowerCase().startsWith('o1') ||
        model.toLowerCase().startsWith('o3') ||
        model.toLowerCase().startsWith('o4') ||
        model.toLowerCase().startsWith('gpt');
    // 旧配置 thinkingEnabled 兼容：显式 true/false 覆盖档位（自动档位
    // 无 thinkingEnabled 时生效；旧配置迁移后 thinkingLevel 已带值，
    // 这里只兜底 ResolvedApiConfig 直接构造的场景）
    final effectiveLevel = thinkingEnabled == null
        ? level
        : (thinkingEnabled! ? 'high' : 'off');
    if (effectiveLevel == 'off') {
      // 关闭思考
      if (isDeepSeek) {
        body['thinking'] = {'type': 'disabled'};
      }
      // 其他家：无通用"关闭思考"参数 → 不注入（跟随服务端默认）
    } else {
      final deep = effectiveLevel == 'max'
          ? 'max'
          : (effectiveLevel == 'low' ? 'low' : 'high');
      if (isDeepSeek) {
        body['thinking'] = {'type': 'enabled'};
        // 8-09 22:5x（用户：V4 有思考链却看不到）：DeepSeek V4 思考模式
        // 需要 reasoning_effort（non-thinking/high/max）控制深度，只带
        // thinking:{type:enabled} 可能按默认深度（低/不思考）跑 → 无
        // reasoning_content。8-10 01:3x：档位映射 low→low / high→high /
        // max→max。
        // 8-10 00:4x（用户：男主结尾思考了却不说话——V4 思考耗输出预算，
        // 正文被截断成空/残缺"<"）：思考模式必须给足 max_tokens——
        // 思考（reasoning_content）和正文共用一个输出预算，默认值被思考
        // 吃光 → 正文 0 token → 男主"思考了但没说话"，退出标记出不来、
        // 流程不结束、下一个大流程不触发。8192 = 思考 high + 正常回复
        // 都留足。
        body['reasoning_effort'] = deep;
        body['max_tokens'] = 8192;
      } else if (isOpenAI) {
        // OpenAI o 系列：reasoning_effort 只认 low/medium/high（无 max）
        body['reasoning_effort'] = deep == 'max' ? 'high' : deep;
      }
      // Claude/Gemini/其他：不注入（参数名不兼容，跟随服务端默认）
    }
    return body;
  }
}
