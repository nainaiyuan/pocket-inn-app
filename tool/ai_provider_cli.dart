// ignore_for_file: avoid_print

/// AI Provider 调试工具（纯 Dart，无需 Flutter，无需编译）。
///
/// 运行：dart run tool/ai_provider_cli.dart
/// 功能：预设列表 / 填 Key / 真实聊天 / 故障切换演示 / 男主绑定
/// 状态：存到 tool/ai_provider_cli_state.json（含 Key，仅本机使用）
library;

import 'dart:convert';
import 'dart:io';

import 'package:pocket_inn/ai_provider/failover_router.dart';
import 'package:pocket_inn/ai_provider/models.dart';
import 'package:pocket_inn/ai_provider/provider_presets.dart';

const String _stateFile = 'tool/ai_provider_cli_state.json';

List<AIProviderConfig> _configs = [];
final FailoverRouter _router = FailoverRouter();

/// 自动切换开关（对应 APP 里男主的 autoSwitch 设置）。
bool _autoSwitch = true;

Future<void> main() async {
  _configs = await _loadState();
  _syncRouter();
  print('══════════════════════════════════════════');
  print('  AI Provider 调试工具');
  print('  预设 ${kAIProviderPresets.length} 个 + 自定义槽位');
  print('══════════════════════════════════════════');
  while (true) {
    print('');
    print('1. 查看预设列表（含健康状态）');
    print('2. 填 / 改 API Key');
    print('3. 发送测试消息（真实调用，故障自动切换）');
    print('4. 故障切换演示（故意弄坏前两个，看自动切换）');
    print('5. 男主绑定测试');
    print('6. 启用 / 禁用某个 Provider');
    print('7. 手动排序（输入新顺序）');
    print('8. 自动切换: ${_autoSwitch ? '开' : '关'}（关=失败直接报错，对应APP弹窗）');
    print('0. 退出');
    final choice = _ask('选择: ');
    switch (choice) {
      case '1':
        _listAll();
      case '2':
        await _editKey();
      case '3':
        await _sendMessage(forceFailTop: 0, personaId: null);
      case '4':
        await _sendMessage(forceFailTop: 2, personaId: null);
      case '5':
        await _bindingTest();
      case '6':
        await _toggleEnabled();
      case '7':
        await _reorder();
      case '8':
        _autoSwitch = !_autoSwitch;
        await _saveState();
        print('✅ 自动切换 → ${_autoSwitch ? '开（失败自动换下一个）' : '关（失败直接报错，APP 会弹窗提示）'}');
      case '0':
        print('再见 👋');
        return;
      default:
        print('无效选择');
    }
  }
}

// ---------------------------------------------------------------------------
// 菜单
// ---------------------------------------------------------------------------

void _listAll() {
  print('');
  print(' #  名称                类型   Key   状态      优先级  模型');
  print('─' * 78);
  for (var i = 0; i < _configs.length; i++) {
    final c = _configs[i];
    final s = _router.stateOf(c.id);
    final health = s == null
        ? '?'
        : !c.enabled
            ? '已禁用'
            : s.isInCooldown
                ? '冷却中'
                : s.health == ProviderHealth.healthy
                    ? '健康'
                    : '待用';
    final keyMark = c.apiKey.isEmpty ? ' 无' : ' 有';
    print(
      '${i.toString().padLeft(2)} ${c.name.padRight(18)} ${c.type.name.padRight(4)} $keyMark  $health   ${c.priority.toString().padLeft(4)}      ${c.model}',
    );
    if (c.note.isNotEmpty) {
      print('      ↳ ${c.baseUrl}  (${c.note})');
    } else {
      print('      ↳ ${c.baseUrl}');
    }
  }
}

Future<void> _editKey() async {
  _listAll();
  final idx = int.tryParse(_ask('填哪个（序号）: ') ?? '');
  if (idx == null || idx < 0 || idx >= _configs.length) {
    print('序号无效');
    return;
  }
  final c = _configs[idx];
  final key = _ask('输入 ${c.name} 的 API Key（直接回车 = 清空）: ') ?? '';
  _configs[idx] = c.copyWith(apiKey: key.trim());
  _syncRouter();
  await _saveState();
  print('✅ 已保存（存于 $_stateFile）');
}

Future<void> _sendMessage({
  required int forceFailTop,
  required String? personaId,
}) async {
  final message = _ask('输入测试消息: ') ?? '你好，请用一句话介绍你自己';
  if (message.trim().isEmpty) {
    print('消息为空，用默认消息');
  }

  // 故障切换演示：把前 forceFailTop 个的 Key 临时弄成错的
  final backups = <String, String>{};
  if (forceFailTop > 0) {
    for (var i = 0; i < forceFailTop && i < _configs.length; i++) {
      final c = _configs[i];
      if (!c.enabled) {
        continue;
      }
      backups[c.id] = c.apiKey;
      _configs[i] = c.copyWith(apiKey: 'sk-wrong-key-${c.id}');
      print('⚠️  已把「${c.name}」的 Key 临时改错，用来演示切换');
    }
    _syncRouter();
  }

  final stopwatch = Stopwatch()..start();
  try {
    final result = await _router.executeWithFailover(
      personaId: personaId,
      bindings: _bindings,
      allowFailover: _autoSwitch,
      action: (config) async {
        final text = await _chatOnce(config, message.trim());
        return AIProviderResult(text: text);
      },
    );
    stopwatch.stop();
    print('');
    print('✅ 回复来自: ${result.providerName}（耗时 ${stopwatch.elapsedMilliseconds}ms）');
    if (result.failedProviders.isNotEmpty) {
      print('⚠️  期间失败并跳过的: ${result.failedProviders.join('、')}');
    }
    print('─' * 50);
    print(result.text);
    print('─' * 50);
  } on AIProviderUnavailableException catch (e) {
    stopwatch.stop();
    print('');
    print('❌ ${e.toString()}');
    print('   💡 自动切换已关闭 → APP 会弹窗「当前 AI 不可用」让用户检查');
  } on AIAllProvidersFailedException catch (e) {
    stopwatch.stop();
    print('');
    print('❌ ${e.toString()}');
    if (e.tried.isNotEmpty) {
      print('   尝试过的: ${e.tried.join('、')}');
    }
    if (e.lastError != null) {
      print('   最后错误: ${e.lastError}');
    }
    print('   💡 提示：先去菜单 2 填好至少一个真实 API Key');
  } finally {
    // 还原 Key
    if (backups.isNotEmpty) {
      for (var i = 0; i < _configs.length; i++) {
        final original = backups[_configs[i].id];
        if (original != null) {
          _configs[i] = _configs[i].copyWith(apiKey: original);
        }
      }
      _syncRouter();
      print('（已还原演示用的 Key）');
    }
  }
}

Future<void> _bindingTest() async {
  print('');
  print('男主绑定 = 给某个男主指定「白名单 + 顺序」，不设则跟随全局');
  _listAll();
  final picks = _ask('输入要给男主用的序号（逗号分隔，如 3,1）: ') ?? '';
  final personaId = 'debug-persona';
  final ids = <String>[];
  for (final part in picks.split(',')) {
    final idx = int.tryParse(part.trim());
    if (idx != null && idx >= 0 && idx < _configs.length) {
      ids.add(_configs[idx].id);
    }
  }
  if (ids.isEmpty) {
    _bindings.removeWhere((b) => b.personaId == personaId);
    print('绑定已清空（该男主跟随全局）');
    return;
  }
  _bindings.removeWhere((b) => b.personaId == personaId);
  _bindings.add(PersonaAIBinding(personaId: personaId, providerIds: ids));
  print('✅ 男主 debug-persona 绑定为: ${ids.join('、')}');
  final msg = _ask('发条消息测试（回车用默认）: ') ?? '你好';
  await _sendMessageRaw(personaId: personaId, message: msg.trim());
}

Future<void> _sendMessageRaw({
  required String personaId,
  required String message,
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final result = await _router.executeWithFailover(
      personaId: personaId,
      bindings: _bindings,
      allowFailover: _autoSwitch,
      action: (config) async {
        final text = await _chatOnce(config, message);
        return AIProviderResult(text: text);
      },
    );
    stopwatch.stop();
    print('✅ 回复来自: ${result.providerName}（耗时 ${stopwatch.elapsedMilliseconds}ms）');
    print('─' * 50);
    print(result.text);
    print('─' * 50);
  } on AIProviderUnavailableException catch (e) {
    print('❌ ${e.toString()}');
    print('   💡 自动切换已关闭 → APP 会弹窗「当前 AI 不可用」让用户检查');
  } on AIAllProvidersFailedException catch (e) {
    print('❌ ${e.toString()}');
    if (e.lastError != null) {
      print('   最后错误: ${e.lastError}');
    }
  }
}

Future<void> _toggleEnabled() async {
  _listAll();
  final idx = int.tryParse(_ask('切换哪个（序号）: ') ?? '');
  if (idx == null || idx < 0 || idx >= _configs.length) {
    print('序号无效');
    return;
  }
  final c = _configs[idx];
  _configs[idx] = c.copyWith(enabled: !c.enabled);
  _syncRouter();
  await _saveState();
  print('✅ ${c.name} → ${c.enabled ? '已禁用' : '已启用'}');
}

Future<void> _reorder() async {
  _listAll();
  final input = _ask('输入新顺序（序号，逗号分隔，如 5,0,1,2,3,4）: ') ?? '';
  final order = <int>[];
  for (final part in input.split(',')) {
    final idx = int.tryParse(part.trim());
    if (idx != null && idx >= 0 && idx < _configs.length && !order.contains(idx)) {
      order.add(idx);
    }
  }
  if (order.isEmpty) {
    print('输入无效');
    return;
  }
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  _configs = [
    for (var i = 0; i < _configs.length; i++)
      _configs[i].copyWith(priority: rank[i] ?? (1000 + i)),
  ];
  _syncRouter();
  await _saveState();
  print('✅ 排序已保存');
}

// ---------------------------------------------------------------------------
// 最小 OpenAI 兼容客户端（只用于调试，正式版走 AIProviderManager）
// ---------------------------------------------------------------------------

Future<String> _chatOnce(AIProviderConfig config, String userText) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final request = await client.postUrl(uri).timeout(
          const Duration(seconds: 15),
        );
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.headers.set('Accept', 'application/json');
    if (config.apiKey.trim().isNotEmpty) {
      request.headers.set('Authorization', 'Bearer ${config.apiKey.trim()}');
    }
    request.add(
      utf8.encode(
        jsonEncode({
          'model': config.model,
          'messages': [
            {'role': 'system', 'content': '你是测试助手，请简短回答。'},
            {'role': 'user', 'content': userText},
          ],
          'stream': false,
          'max_tokens': 300,
        }),
      ),
    );
    final response = await request.close().timeout(
          const Duration(seconds: 90),
        );
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'HTTP ${response.statusCode}: ${_truncate(body, 200)}',
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('返回不是 JSON 对象');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('返回缺少 choices');
    }
    final message = (choices.first as Map<String, dynamic>)['message'];
    final content = message is Map<String, dynamic> ? message['content'] : null;
    final text = content?.toString().trim() ?? '';
    if (text.isEmpty) {
      throw const FormatException('返回空内容');
    }
    return text;
  } finally {
    client.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

final List<PersonaAIBinding> _bindings = [];

String? _ask(String label) {
  stdout.write(label);
  return stdin.readLineSync();
}

String _truncate(String value, int maxLength) {
  if (value.length <= maxLength) {
    return value;
  }
  return '${value.substring(0, maxLength)}...';
}

void _syncRouter() {
  _router.clear();
  for (final config in _configs) {
    _router.register(config);
  }
}

Future<List<AIProviderConfig>> _loadState() async {
  final file = File(_stateFile);
  if (!await file.exists()) {
    return defaultProviderConfigs();
  }
  try {
    final decoded = jsonDecode(await file.readAsString());
    // 兼容两种格式：老版 List / 新版 Map{autoSwitch, configs}
    if (decoded is Map<String, dynamic>) {
      _autoSwitch = decoded['autoSwitch'] as bool? ?? true;
      final raw = decoded['configs'];
      if (raw is List) {
        return _decodeConfigList(raw);
      }
      return defaultProviderConfigs();
    }
    if (decoded is List) {
      return _decodeConfigList(decoded);
    }
    return defaultProviderConfigs();
  } on Object {
    print('⚠️  状态文件损坏，已重置为默认配置');
    return defaultProviderConfigs();
  }
}

List<AIProviderConfig> _decodeConfigList(List<dynamic> decoded) {
  final configs = <AIProviderConfig>[];
  for (final item in decoded) {
    if (item is Map<String, dynamic>) {
      configs.add(AIProviderConfig.fromJson(item));
    }
  }
  if (configs.isEmpty) {
    return defaultProviderConfigs();
  }
  return configs;
}

Future<void> _saveState() async {
  await File(_stateFile).writeAsString(
    jsonEncode({
      'autoSwitch': _autoSwitch,
      'configs': [for (final config in _configs) config.toJson()],
    }),
  );
}
