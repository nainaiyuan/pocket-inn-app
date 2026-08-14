import 'dart:async';

import 'scene_models.dart';

/// 场景数据访问接口（PetStore 实现；单测用内存假实现）
abstract class SceneStore {
  Future<List<PetNode>> nodesForScene(String sceneId);
  Future<List<PetChoice>> choicesForNode(String nodeId);
}

/// 8-15 02:4x 全屏场景 P0：节点运行器（16 号冲刺安排 P0 核心）
///
/// 职责：节点流程推进 + WAIT_USER 真阻塞。
/// 纯 Dart 逻辑，不依赖 Flutter/引擎——动作播放由 UI 层通过
/// onNodeEntered 回调执行，播完调 [nodeContentDone]。
///
/// 铁律（冲刺安排 §四）：
/// - WAIT_USER 节点：不能被自动播放推进 / 不能被自主行动推进 /
///   不能被计时器误触发 / 刷新页面不跳过——必须等用户完成指定操作
/// - 任何内部推进入口先查 [_waiting]，waiting 时一律拒绝
class SceneDirector {
  final SceneStore store;
  final PetScene scene;

  SceneDirector({required this.store, required this.scene});

  PetNode? _current;
  bool _waiting = false;
  bool _finished = false;
  Timer? _timer;

  PetNode? get current => _current;

  /// 是否正在等待用户操作（WAIT_USER 阻塞中）
  bool get waiting => _waiting;

  bool get finished => _finished;

  // ===== UI 回调 =====

  /// 节点进入：UI 在此播动作组/互动组/显示内容
  void Function(PetNode node)? onNodeEntered;

  /// 弹卡片（choice 节点带选项列表）
  void Function(PetNode node, List<PetChoice> choices)? onCard;

  /// 流程结束（end 节点 / 链走完）
  void Function()? onFinished;

  // ===== 启动 =====

  Future<void> start(String startNodeId) async {
    _timer?.cancel();
    _finished = false;
    _waiting = false;
    await _enter(startNodeId);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _waiting = false;
    _finished = true;
    _current = null;
  }

  // ===== 节点进入 =====

  Future<void> _enter(String nodeId) async {
    if (_finished) return;
    final nodes = await store.nodesForScene(scene.sceneId);
    PetNode? node;
    for (final n in nodes) {
      if (n.nodeId == nodeId) {
        node = n;
        break;
      }
    }
    if (node == null) {
      _finished = true;
      onFinished?.call();
      return;
    }
    _current = node;

    if (node.type == PetNodeType.end) {
      _finished = true;
      onFinished?.call();
      return;
    }

    // WAIT_USER 语义：auto 继续条件的节点不需要等用户
    _waiting = node.waitUser && node.continueType != PetContinueType.auto;

    // 通知 UI 播内容/显示
    onNodeEntered?.call(node);

    // 按继续条件挂接推进方式
    switch (node.continueType) {
      case PetContinueType.auto:
        // 等 UI 播完内容（nodeContentDone）→ 推进 targetNode
        break;
      case PetContinueType.choice:
        final choices = await store.choicesForNode(node.nodeId);
        onCard?.call(node, choices);
        break;
      case PetContinueType.click:
      case PetContinueType.clickTarget:
        onCard?.call(node, const []);
        break;
      case PetContinueType.freeInput:
        // AI 节点：UI 显示输入框，用户输入后由 UI 调 advanceAfterAI
        onCard?.call(node, const []);
        break;
      case PetContinueType.timer:
        // 计时继续（系统计时，AI 不负责计时）；waitUser=true 时仍等用户
        final secs = _parseSeconds(node.content);
        final target = node.targetNode;
        if (!_waiting && secs > 0) {
          _timer = Timer(Duration(seconds: secs), () {
            _timer = null;
            _advance(target);
          });
        }
        break;
      default:
        // 未实现条件（condition/moveTo/drag/minigame）：先按 auto 走，
        // 模型已支持，后续版本逐个实现
        break;
    }
  }

  // ===== UI 层回调（内容播完 / 用户操作） =====

  /// 内容播放完成（auto 节点 UI 播完动作组后调用）→ 推进
  Future<void> nodeContentDone() async {
    final node = _current;
    if (node == null || _finished) return;
    if (_waiting) return; // 铁律：WAIT_USER 时任何推进无效
    if (node.continueType != PetContinueType.auto) return;
    await _advance(node.targetNode);
  }

  /// 用户点击（click / clickTarget 继续条件）
  Future<void> userClick() async {
    final node = _current;
    if (node == null || _finished || !_waiting) return;
    if (node.continueType != PetContinueType.click &&
        node.continueType != PetContinueType.clickTarget) {
      return;
    }
    _waiting = false;
    await _advance(node.targetNode);
  }

  /// 用户选择选项（choice 继续条件）
  Future<void> userChoose(String choiceId) async {
    final node = _current;
    if (node == null || _finished || !_waiting) return;
    if (node.continueType != PetContinueType.choice) return;
    final choices = await store.choicesForNode(node.nodeId);
    PetChoice? picked;
    for (final c in choices) {
      if (c.choiceId == choiceId) {
        picked = c;
        break;
      }
    }
    if (picked == null) return;
    _waiting = false;
    await _advance(picked.targetNode);
  }

  /// AI 自由聊天完成（freeInput 节点：UI 拿到 AI 回应后调用）
  Future<void> advanceAfterAI() async {
    final node = _current;
    if (node == null || _finished || !_waiting) return;
    if (node.continueType != PetContinueType.freeInput) return;
    _waiting = false;
    await _advance(node.targetNode);
  }

  // ===== 内部推进（统一闸门） =====

  Future<void> _advance(String? target) async {
    if (_waiting) return; // 铁律：WAIT_USER 阻塞中，谁来都推不动
    if (_finished) return;
    if (target == null || target.isEmpty) {
      _finished = true;
      onFinished?.call();
      return;
    }
    await _enter(target);
  }

  int _parseSeconds(String? content) {
    if (content == null || content.isEmpty) return 0;
    final n = int.tryParse(content.trim());
    return n ?? 0;
  }
}
