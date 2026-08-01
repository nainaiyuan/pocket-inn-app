/// 价格表：按 Provider 计算每轮 API 真实成本（元/百万 token）。
///
/// DeepSeek V4 现价（2026-08）：输入 miss ¥1、命中 ~¥0.1、输出 ¥2。
/// 其他 AI 保守默认：输入 ¥3、命中 ¥0.3、输出 ¥6。
/// 价格会变——这里集中管理，改一个数字即可全局生效。
/// （后续可扩展：用户自定义价格覆盖，存 SharedPreferences JSON）
class PriceTable {
  static final PriceTable instance = PriceTable._();
  PriceTable._();

  /// 元 / 百万 token
  static const Map<String, double> _deepseek = {
    'input': 1.0, // 缓存未命中输入
    'hit': 0.1, // 缓存命中输入
    'output': 2.0,
  };

  static const Map<String, double> _default = {
    'input': 3.0,
    'hit': 0.3,
    'output': 6.0,
  };

  Map<String, double> _pricesFor(String providerName) {
    final n = providerName.toLowerCase();
    if (n.contains('deepseek')) return _deepseek;
    return _default;
  }

  /// 计算单次请求成本（元）。
  ///
  /// [hit] 缓存命中输入 token 数（usage.prompt_cache_hit_tokens）
  /// [miss] 缓存未命中输入 token 数（usage.prompt_cache_miss_tokens）
  /// [output] 输出 token 数（usage.completion_tokens）
  double costFor({
    required String providerName,
    required int hit,
    required int miss,
    required int output,
  }) {
    final p = _pricesFor(providerName);
    return (hit * p['hit']! + miss * p['input']! + output * p['output']!) /
        1000000;
  }

  /// 缓存命中率（0~1）。无输入时为 0。
  double hitRate(int hit, int miss) {
    final total = hit + miss;
    if (total == 0) return 0;
    return hit / total;
  }
}
