/// 桌宠模块 — 互动事件总线
///
/// 用户对小人做的每件事（点击/拖动/抚摸/投喂）都变成 [PetInteractionEvent]，
/// 通过这个总线流进管家 —— 男主由此"看得见"用户怎么跟小人互动。
library;

import 'dart:async';

import 'pet_models.dart';

class PetEventBus {
  final StreamController<PetInteractionEvent> _controller =
      StreamController<PetInteractionEvent>.broadcast(sync: true);

  /// 事件流（管家订阅）
  Stream<PetInteractionEvent> get stream => _controller.stream;

  /// 最近事件（管家取上下文用，最多保留 50 条）
  final List<PetInteractionEvent> _recent = [];
  static const int _maxRecent = 50;

  List<PetInteractionEvent> get recent => List.unmodifiable(_recent);

  void emit(PetInteractionEvent event) {
    _recent.add(event);
    if (_recent.length > _maxRecent) {
      _recent.removeAt(0);
    }
    _controller.add(event);
  }

  /// 近 N 条事件的人话摘要（拼进 Prompt 用）
  String recentSummary({int count = 5}) {
    final list = _recent.length > count
        ? _recent.sublist(_recent.length - count)
        : _recent;
    if (list.isEmpty) return '';
    return '近期小人互动：${list.map((e) => e.summary).join('；')}';
  }

  void dispose() {
    _controller.close();
  }
}
