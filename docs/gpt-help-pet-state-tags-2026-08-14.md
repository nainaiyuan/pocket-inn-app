# GPT 求助：桌宠"状态标签系统"设计方案 + 拖动打断 Bug（2026-08-14 22:50）

> 用户原话（22:47-22:50，未删改）：
> "好像好了？但是我长按再一半没松手，他好像还是会继续不听我的，就是划屏幕划到一半，然后他就继续动作，比如往左下运动，也没办法打断他，虽然我确定没有配把他提起来的图，感觉需要有个专门可以配置这个角色，被拎起来，或者收到屏幕边边的状态，还有待机，还有各种各样的，就是打一个标签，这样我把他扔到屏幕顶端，判定我扔的，就一个状态，用户自己设，或者小人自己运动到屏幕顶端，会怎么样，用户自己设，你能听得懂吗？不理解整理了去问gpt，还要有个是否自动判定状态，然后匹配单个动作，一组动作的开关，目前就是有几个单个动作就循环"
> "看不懂，主要是我没松手，那个小人就开始动了，状态越多越好，反正要让用户特别自由，都可以设置的那种，你问gpt怎样好吧，他有经验"

## 一、核心 Bug（优先级最高）

**拖动中（长按拎起、还没松手）小人继续自主行动**：比如用户正把小人往左下拖，小人自己也在播移动/动作，用户无法打断。

### 现状代码（Flutter，ARM64 平板）
- 拖动手势在 `lib/pages/chat/widgets/pet_chat_overlay.dart`：
  - `_onPetPanStart` (L385) / `_onPetPanUpdate` (L397) / `_onPetPanEnd` (L410)
  - `_onPetDrag` 只更新小人位置（`pet.position = ...`），**从不暂停自主行动/动作播放**
  - `_touchingPetId` (L385) 只锁其他小人的手势，不锁被拎小人的动作
- 自主行动在 `lib/butler/pet/pet_scene.dart` `_tickAutoAct` (L1129)：`pet.state == PetState.idle && !pet.moving` 时随机挑该角色自己的动作播放
- `PetScene.update` (L820) 每帧循环：idle → `_tickAutoAct` → 播动作；`autoActionLeft > 0` 递减 → 归零 stop

**期望行为**：手指按住小人期间 = 完全"冻结"自主行动（不播新动作、当前移动/动画暂停），松手后才恢复自主行动。拎起本身是一个可配置状态（见下）。

## 二、功能需求：状态标签系统（State Tag System）

用户要"状态越多越好、用户自由设置"，每个状态 = 触发条件 + 响应的动作（单动作或一组动作），带"是否自动判定"开关。

### 用户明确提到的状态
1. **被拎起**（拖动中，用户按住没松手）
2. **被扔**（用户松手时带速度/方向，或扔到特定区域）
3. **贴边**（自主移动撞到屏幕边）
4. **到顶**（被扔到屏幕顶端 / 自己走到屏幕顶端——两种情况用户想分别配置）
5. **待机**（无动作时的默认状态）
6. 其他"各种各样的"——用户要自由扩展

### 用户明确要的机制
- 每个状态：**自动判定开关**（开了 = 满足条件自动切状态播对应动作；关了 = 不参与）
- 状态响应：**单个动作 or 一组动作**（现在自主行动 = 单动作随机循环，没有状态概念）
- 用户自己配：从该角色**自己的动作池**里选（不能出现内置动作——之前已确立"内置=默认小人专属兜底，用户角色彻底隔离"）

### 需要你（GPT）设计的关键点
1. **状态集设计**：建议哪几个状态？如何做到"自由扩展"而不失控？（枚举 vs 用户自定义状态名？固定集+开关 vs 动态添加？）
2. **数据模型**：如何存"状态→动作绑定"？建议表结构（现有 6 张表：pet_profiles / pet_actions / pet_move_groups / pet_activities / pet_duo_configs / pet_activity_steps，都带 profile_id 归属）
3. **判定优先级**：多状态同时满足时（如拎起+贴边、扔到顶端+贴边）谁优先？
4. **拖动生命周期**：panStart → 拎起状态；panUpdate（拖动中）；panEnd（松手）→ 判定"扔"（速度/方向/落点）→ 落点状态（顶端/贴边/普通）。这些时机怎么挂进现有手势代码？
5. **与现有自主行动的关系**：有状态绑定时按状态播；没有/关掉开关时保持现在的随机循环？
6. **与互动组（双人/多人剧本）的关系**：状态系统会不会和互动组运行时冲突？（现在互动组运行时演员跳过自主行动）

## 三、相关代码位置（2026-08-14 22:47 状态，commit ac1b385）

- `lib/butler/pet/pet_models.dart`：PetActionDef（24 字段，含 moveMode: distance/toEdge）、PetBuiltinActions
- `lib/butler/pet/pet_scene.dart`：Pet（position setter + lastPositions 静态缓存）、PetScene（playAction L949 三分支、_targetFor/_edgeTargetFor、_tickAutoAct L1129 状态机 MOVE→DWELL 1.5~3s→MOVE、_wasMoving 检测、_dwellLeft）
- `lib/butler/pet/pet.dart`：PetWorld（restore/syncVisible/preferredStart）、PetStore
- `lib/butler/pet/pet_store.dart`：6 表建表 + ALTER 迁移模式（try/catch 幂等）
- `lib/pages/chat/widgets/pet_chat_overlay.dart`：手势（pan start/update/end、长按菜单、_touchingPetId）
- `lib/pages/butler/pet_profile_page.dart`：动作配置 UI（_ActionEditDialog、MoveTargetEditor）
- `lib/pages/butler/pet_group_page.dart`：互动组配置

## 四、请求

1. **拖动打断的最小修复**：按住期间如何可靠冻结自主行动（含正在播的移动/动画），松手恢复？
2. **状态标签系统完整设计**：状态集/数据模型/判定逻辑/优先级/UI 入口/与自主行动和互动组的关系，一次到位。
3. 按"先设计后动手"——你给方案，我们确认后再改代码。

## 五、已确认的设计铁律（前几轮确立，方案必须遵守）

- 相对移动：灰球锚点/目标球相对绑定/换设备可用/动作衔接/撞墙才停，绝不改绝对坐标
- 内置动作 = 默认小人专属兜底，用户角色任何界面不得出现
- 表结构一次建对：支撑单人/双人/多人/组合/互动组/状态绑定
- copyWith 全字段透传；存读对称；先设计后动手
- 日志说话：所有状态切换/动作播放打日志（用户靠日志反馈）
