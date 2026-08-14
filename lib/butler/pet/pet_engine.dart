/// 桌宠模块 — 帧动画引擎
///
/// 纯 Dart，不依赖 Flutter UI。
/// - [PetAnimPlayer]：帧序列播放器（按 fps 推进，支持 循环/单次/来回）
/// - [PetMoveState]：移动插值（当前位置 → 目标位置，缓动）
/// - [PetFrameSource]：帧图来源抽象（Flutter 实现扫目录自动数帧，测试用内存实现）
library;

import 'dart:math' as math;

import 'pet_models.dart';

/// 帧图来源抽象
///
/// Flutter 实现：扫描应用文档目录 `pet/animations/<actionId>/` 下的图片，
/// 按文件名排序，自动得到帧列表 —— 用户只需把图丢进文件夹。
abstract class PetFrameSource {
  /// 返回动作的帧图路径列表（按文件名排序）；目录不存在返回空列表
  Future<List<String>> framesFor(String actionId);

  /// 该动作是否已有帧图
  Future<bool> hasAction(String actionId);
}

/// 帧序列播放器
class PetAnimPlayer {
  /// 帧图路径列表
  final List<String> frames;

  /// 播放帧率
  final double fps;

  /// 循环方式
  final PetAnimLoop loop;

  int _index = 0;
  double _accumulator = 0;
  bool _forward = true;
  bool _finished = false;
  int _loopCount = 0;

  /// 循环模式下最多循环次数（0 = 无限循环）
  final int maxLoops;

  PetAnimPlayer({
    required this.frames,
    this.fps = 10,
    this.loop = PetAnimLoop.loop,
    this.maxLoops = 0,
  });

  bool get finished => _finished;

  /// 当前帧路径（无帧时返回 null）
  String? get currentFrame =>
      frames.isEmpty ? null : frames[_index.clamp(0, frames.length - 1)];

  /// 当前帧序号
  int get frameIndex => _index;

  /// 帧总数
  int get frameCount => frames.length;

  /// 按时间推进（dt 秒）
  void update(double dt) {
    if (frames.isEmpty || _finished) return;
    final effectiveFps = fps <= 0 ? 10 : fps;
    _accumulator += dt * effectiveFps;

    while (_accumulator >= 1) {
      _accumulator -= 1;
      _advance();
      if (_finished) break;
    }
  }

  void _advance() {
    switch (loop) {
      case PetAnimLoop.loop:
        _index = (_index + 1) % frames.length;
        if (_index == 0) {
          _loopCount++;
          if (maxLoops > 0 && _loopCount >= maxLoops) {
            _finished = true;
          }
        }
        break;
      case PetAnimLoop.once:
        if (_index >= frames.length - 1) {
          _finished = true;
        } else {
          _index++;
        }
        break;
      case PetAnimLoop.pingpong:
        if (_forward) {
          if (_index >= frames.length - 1) {
            _forward = false;
            _index--;
          } else {
            _index++;
          }
        } else {
          if (_index <= 0) {
            _forward = true;
            _index++;
          } else {
            _index--;
          }
        }
        break;
    }
  }

  /// 重置播放
  void reset() {
    _index = 0;
    _accumulator = 0;
    _forward = true;
    _finished = false;
    _loopCount = 0;
  }

  /// 单次播放是否播完（once 模式用）
  bool get playedOnce => _finished;
}

/// 移动状态（位置插值）
/// 移动缓动曲线
enum PetMoveEase {
  /// 匀速
  linear,

  /// 先快后慢（走路）
  easeInOut,

  /// 抛物线（跳）：x 线性 + y 先上后下
  jump,
}

class PetMoveState {
  final PetPoint from;
  final PetPoint to;

  /// 移动耗时（秒）
  final double duration;

  /// 缓动曲线
  final PetMoveEase ease;

  /// 跳跃高度（相对坐标，jump 曲线用）
  final double jumpHeight;

  double _elapsed = 0;

  PetMoveState({
    required this.from,
    required this.to,
    this.duration = 3,
    this.ease = PetMoveEase.easeInOut,
    this.jumpHeight = 0.3,
  });

  bool get finished => _elapsed >= duration;

  /// 当前进度 0~1
  double get progress => duration <= 0 ? 1 : (_elapsed / duration).clamp(0, 1);

  /// 水平缓动进度
  double get eased => switch (ease) {
        PetMoveEase.linear => progress,
        PetMoveEase.easeInOut => _easeInOut(progress),
        PetMoveEase.jump => progress,
      };

  /// 竖直方向额外偏移（jump 曲线：先上后下），相对坐标
  double get jumpOffset =>
      ease == PetMoveEase.jump ? -math.sin(progress * math.pi) * jumpHeight : 0;

  /// 当前位置
  PetPoint get position {
    final e = eased;
    return PetPoint(
      from.x + (to.x - from.x) * e,
      from.y + (to.y - from.y) * e + jumpOffset,
    );
  }

  void update(double dt) {
    _elapsed += dt;
  }

  static double _easeInOut(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // smoothstep
    return t * t * (3 - 2 * t);
  }

  /// 移动方向（用于朝向判断）：正 = 向右，负 = 向左
  double get directionX => to.x - from.x;
}

/// 占位帧图生成（无用户图时的兜底）
///
/// 返回 N 个"占位帧"标识（如 'placeholder:circle:3'），
/// Flutter UI 层识别后画一个简单图形（圆球跳/方块转圈），
/// 让引擎在没有真实帧图时也能跑起来测试。
class PetPlaceholderFrames {
  /// 根据动作生成占位帧标识列表（模拟真实帧序列）
  static List<String> forAction(PetActionDef def) {
    final n = _frameCountFor(def);
    return List.generate(n, (i) => 'placeholder:${def.id}:$i:$n');
  }

  static int _frameCountFor(PetActionDef def) {
    switch (def.id) {
      case 'idle':
        return 4;
      case 'walk':
        return 6;
      case 'run':
        return 8;
      case 'jump':
        return 6;
      case 'spin':
        return 8;
      case 'wave':
        return 5;
      case 'happy':
        return 6;
      case 'turn':
        return 3;
      default:
        return 4;
    }
  }

  /// 占位帧标识 → 绘制参数（UI 层用）
  /// 返回 (动作id, 帧序号, 总帧数)
  static (String, int, int)? parse(String frameId) {
    if (!frameId.startsWith('placeholder:')) return null;
    final parts = frameId.split(':');
    if (parts.length < 4) return null;
    final actionId = parts[1];
    final index = int.tryParse(parts[2]) ?? 0;
    final total = int.tryParse(parts[3]) ?? 1;
    return (actionId, index, total);
  }

  /// 数学辅助：圆跳动（返回 y 偏移比例 0~1）
  static double bounce(int index, int total) {
    final t = index / math.max(1, total - 1);
    return math.sin(t * math.pi); // 0 → 1 → 0
  }

  /// 数学辅助：旋转（返回角度 0~360）
  static double rotate(int index, int total) {
    return 360.0 * index / math.max(1, total);
  }
}
