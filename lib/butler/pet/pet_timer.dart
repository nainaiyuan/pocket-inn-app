import 'dart:convert';
import 'dart:math';

/// 8-15 04:1x 陪伴计时核心（P2）
///
/// 纯 Dart、无 Flutter 依赖，可单测。设计（用户 8-15 02:49 描述）：
/// - 正计时 / 倒计时（Forest 种树 + 乙游陪伴的结合）
/// - 计时中角色循环演出（UI 层驱动，见 ScenePage）
/// - 预设话术随机间隔弹出（轮询不重复）
/// - 每 N 秒好感度奖励（rewardIntervalSec → rewardAmount）
/// - 倒计时结束 = 完成（大奖励，UI 层发）
///
/// 铁律：AI 不负责计时——本类纯本地状态机，UI 每秒 tick 驱动。
/// 陪伴计时配置（持久化到 pet_timer_settings 表）
class PetTimerSetting {
  final String petId;
  final PetTimerMode mode;
  final int durationSec;
  final int rewardIntervalSec;
  final int rewardAmount;
  final String? linesJson; // JSON 数组字符串：["话1","话2"]

  const PetTimerSetting({
    required this.petId,
    this.mode = PetTimerMode.countdown,
    this.durationSec = 25 * 60,
    this.rewardIntervalSec = 60,
    this.rewardAmount = 1,
    this.linesJson,
  });

  /// 解析话术列表（空/非法 → 空列表 → 用默认句）
  List<String> get lines {
    final raw = linesJson;
    if (raw == null || raw.isEmpty) return const [];
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.map((e) => '$e').toList();
    } catch (_) {}
    return const [];
  }

  PetTimerSetting copyWith({String? linesJson}) => PetTimerSetting(
        petId: petId,
        mode: mode,
        durationSec: durationSec,
        rewardIntervalSec: rewardIntervalSec,
        rewardAmount: rewardAmount,
        linesJson: linesJson ?? this.linesJson,
      );
}

enum PetTimerMode {
  countdown, // 倒计时（默认 25 分钟番茄钟）
  countup; // 正计时（记录陪伴时长）

  static PetTimerMode fromName(String? n) =>
      PetTimerMode.values.firstWhere((e) => e.name == n,
          orElse: () => PetTimerMode.countdown);
}

enum PetTimerState { idle, running, paused, done }

class PetTimerSession {
  PetTimerMode mode;
  int durationSec; // 倒计时总长；正计时时作为"目标提醒点"（0 = 不提醒）
  int rewardIntervalSec; // 每 N 秒发一次奖励（<=0 = 不发）
  int rewardAmount; // 每次奖励好感度
  final List<String> lines; // 预设话术（空 = 用默认句）
  final List<String> defaultLines; // 默认句（无预设时用）

  int elapsedSec = 0;
  PetTimerState state = PetTimerState.idle;

  int _lastRewardSec = 0;
  int _lastLineSec = 0;
  int _lineCursor = 0;
  int _nextLineGapSec = 0; // 下一条话术的随机间隔（秒）

  PetTimerSession({
    this.mode = PetTimerMode.countdown,
    this.durationSec = 25 * 60,
    this.rewardIntervalSec = 60,
    this.rewardAmount = 1,
    List<String>? lines,
    this.defaultLines = const [
      '我在呢，专心做你的事就好。',
      '累了就歇会儿，我等你。',
      '进度不错，继续保持。',
      '要不要喝口水？',
      '抬头看看我，笑一个。',
      '还有我在陪你，不孤单。',
    ],
  }) : lines = lines ?? const [];

  /// 当前显示用时长（倒计时 = 剩余；正计时 = 已过）
  int get displaySec => mode == PetTimerMode.countdown
      ? (durationSec - elapsedSec).clamp(0, durationSec)
      : elapsedSec;

  bool get running => state == PetTimerState.running;
  bool get done => state == PetTimerState.done;

  /// 进度 0~1（倒计时：剩余/总长；正计时：elapsed/目标提醒点，0 时恒 0）
  double get progress {
    if (mode == PetTimerMode.countdown) {
      if (durationSec <= 0) return 0;
      return (durationSec - elapsedSec) / durationSec;
    }
    if (durationSec <= 0) return 0;
    return (elapsedSec % durationSec) / durationSec;
  }

  void start() {
    if (state == PetTimerState.done) {
      elapsedSec = 0;
      _lastRewardSec = 0;
      _lastLineSec = 0;
      _lineCursor = 0;
    }
    state = PetTimerState.running;
    _rollLineGap();
  }

  void pause() {
    if (state == PetTimerState.running) state = PetTimerState.paused;
  }

  void resume() {
    if (state == PetTimerState.paused) state = PetTimerState.running;
  }

  void reset() {
    elapsedSec = 0;
    _lastRewardSec = 0;
    _lastLineSec = 0;
    _lineCursor = 0;
    state = PetTimerState.idle;
    _rollLineGap();
  }

  /// UI 每秒调一次；返回本秒发生的事件（奖励/话术/完成）
  List<PetTimerEvent> tick() {
    if (state != PetTimerState.running) return const [];
    elapsedSec++;
    final events = <PetTimerEvent>[];

    if (mode == PetTimerMode.countdown && elapsedSec >= durationSec) {
      elapsedSec = durationSec;
      state = PetTimerState.done;
      events.add(const PetTimerEvent(PetTimerEventType.completed));
      return events;
    }

    // 奖励：每 rewardIntervalSec 秒一次（间隔>0 才发）
    if (rewardIntervalSec > 0 &&
        elapsedSec - _lastRewardSec >= rewardIntervalSec) {
      _lastRewardSec = elapsedSec;
      events.add(PetTimerEvent(
        PetTimerEventType.reward,
        amount: rewardAmount,
      ));
    }

    // 话术：随机间隔（第一版 120~300 秒；轮询不重复）
    if (_nextLineGapSec > 0 && elapsedSec - _lastLineSec >= _nextLineGapSec) {
      _lastLineSec = elapsedSec;
      _rollLineGap();
      final line = _nextLine();
      if (line != null) {
        events.add(PetTimerEvent(PetTimerEventType.line, text: line));
      }
    }

    return events;
  }

  void _rollLineGap() {
    _nextLineGapSec = 120 + Random().nextInt(181); // 2~5 分钟
  }

  String? _nextLine() {
    final pool = lines.isNotEmpty ? lines : defaultLines;
    if (pool.isEmpty) return null;
    final line = pool[_lineCursor % pool.length];
    _lineCursor++;
    return line;
  }
}

enum PetTimerEventType { reward, line, completed }

class PetTimerEvent {
  final PetTimerEventType type;
  final int amount;
  final String? text;

  const PetTimerEvent(this.type, {this.amount = 0, this.text});
}
