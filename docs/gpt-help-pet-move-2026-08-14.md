# GPT 求助：桌宠 moveTo 动作"走走停停/瞬移回起点"——第 3 轮仍未解决

> 用户 22:14 指令：同一问题错两遍就去问 GPT。这是移动链路第 5 次反馈，必须一次给对方案。
> 日期：2026-08-14 22:15 | 代码：`nainaiyuan/-APP`（私有，本报告发公开库）

## 一、用户需求（原文整理）

1. **单动作 = 边走边播**：帧动画和移动**同时开始**，不是先原地播几秒再走（21:33 明确："让他边走边动"）
2. **移动速度 = 距离 / 移动时长**（用户配 4 秒 → 4 秒到达目的地；配的"原地时长"与移动速度无关）
3. **"走到底"**：从当前位置沿配置方向走到屏幕边（撞墙才停）；**运动 = 屏幕相对距离（0~1 比例）**，换设备按比例换算
4. **自主行动循环**：走到底 → **待一小会儿** → 再走（不要 8~20 秒长停，像卡住）
5. 想"先原地再走" → 用户自己组组合动作，**不要自动两段式**

## 二、用户实测日志（22:12-22:13，ddcdd52 包）

```
[22:12:54] 移动播放 act_... | 方向=downLeft 距离=1.00 目标=(0.29,0.71) 当前位置=(1.00,0.00) 走距=1.00
[22:13:03] 移动播放 act_... | 方向=downLeft 距离=1.00 目标=(-0.41,1.41) 当前位置=(0.29,0.71) 走距=0.37   ← 目标出屏!
[22:13:06] restore 加载：组合 0 / 单动作 1 / 移动组 0
[22:13:09] 移动播放 act_... | 方向=downLeft 距离=1.00 目标=(0.29,0.71) 当前位置=(1.00,0.00) 走距=1.00   ← 瞬移回起点!
```

**日志揭示 3 个问题**：
- **A. 小人每次 restore/刷新瞬移回 preferredStart (1.00,0.00)**——第三次播放前 restore → 位置从 (0.29,0.71) 跳回 (1.00,0.00)
- **B. 第二次播放目标=(-0.41,1.41) 出屏** → clampToArea 后实际只走 0.37（从 (0.29,0.71) 往 downLeft 走 1.00 很快就撞边）——"走到底"语义下从边缘附近出发走距很短，用户觉得"走不动"
- **C. 自主行动间隔 8~20 秒**（ddcdd52）→ 走 2.86s 停 9s → 用户"走走停停像卡住"（c57ed75 已改 3~6s，未测）

## 三、当前实现（pet_scene.dart）

**L949 `playAction(petId, actionId)` moveTo 分支**（三分支统一逻辑）：
```dart
final PetPoint target;
if (def.target != null) {
  target = def.target!;
} else if (def.moveDir != null) {
  final (vx, vy) = def.moveDir!.vector;
  target = PetPoint(pet.position.x + vx * (def.moveDist ?? 0.3),
                    pet.position.y + vy * (def.moveDist ?? 0.3));
} else {
  target = pet.position;  // ← 无方向 → 原地
}
final clamped = pet.clampToArea(target);
final dist = pet.position.distanceTo(clamped);
pet.playAction(def, _resolveFramesSync(actionId));      // 边走边播（同步启动）
pet.autoActionLeft = (def.moveSec ?? dist / speed) + 0.3;  // 走完才停
pet.moveTo(clamped, duration: def.moveSec ?? dist / speed,
           ease: walk→linear, ...);
```

**L1148 preferredStart**：`moveRef/startX/startY` 只在刷新时用（preferredStart）——**syncVisible（pet.dart L141）每次 restore 用 preferredStart 重置小人位置** → 问题 A 根源

**L1097 `_tickAutoAct`**：每 3~6 秒（c57ed75 已改）随机挑一个自己角色的动作播一次

**PetMoveState（pet_engine.dart L141）**：from/to/duration/ease/jumpHeight，linear 匀速

## 四、请 GPT 给方案的问题

1. **问题 A（瞬移）**：restore/syncVisible 是否应该**保留小人当前位置**（只在首次出现/无位置记录时用 preferredStart）？还是用户配置的起点就该每次刷新都回？哪个符合"桌宠=连续存在"的语义？
2. **问题 B（出屏目标）**："走到底"语义下，从边缘附近出发走 1.00 只走 0.37 合理吗？是否应该**先走到屏幕边**（目标点 clamp 到边）就算"走到底"？还是"距离 1.00 = 走满一屏"应该从**屏幕中心/起点锚点**算而不是当前位置？
3. **问题 C（连贯性）**：用户要"走到底→待一小会儿→再走"——3~6 秒间隔是否合理？还是应该**动作播完立即接下一个动作**（无限连续走动）？用户说"待一会儿"但没说多久——给个推荐值。
4. **日志困惑**：用户每次看日志"方向=downLeft 距离=1.00 目标=(0.29,0.71)"一模一样，觉得"没变化"——日志应加什么（间隔倒计时/剩余秒数/连续第几次）让用户看到系统在动？

## 五、已走过的弯路（避免再犯）

- 21:27 用户说"先原地放一会儿才动" → 我误判"要两段式" → 加了 delay（414aed5）→ 用户 21:33 澄清"边走边播，原地+移动用组合自己拼" → revert（ddcdd52）
- autoActionLeft 从"帧播秒数"改"移动时长"（走完才停，不掐断）✓ 保留
- 间隔 8~20s → 3~6s（c57ed75，未测）
- copyWith 漏字段（moveDir/moveDist）已修（c994bb1）✓

## 六、请求

给一个**明确的修复方案**（文件+改动点+为什么），我直接执行。重点：A 瞬移、B 走到底语义、C 连贯循环，一次到位。
