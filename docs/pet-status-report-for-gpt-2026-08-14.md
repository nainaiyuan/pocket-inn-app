# 桌宠动作系统 · 给 GPT 的完整现状报告 v2（2026-08-14 19:30）

> 用途：请 GPT 基于这份事实报告分析"下一步怎么修/怎么设计"。
> 项目：Flutter Android 应用（荣耀平板 ARM64，本地无法跑模拟器，只能编译 APK 到真机测）。
> 模块：桌宠 = 聊天页里的电子宠物（多个小人角色，可配置动作、互动组）。
> v2 相对 v1 新增：②第二个真根因（copyWith 丢归属）③用户实测验证进展 ④表结构全景实勘 ⑤设计缺口与待决策问题。

---

## 一、系统架构（数据流全景）

```
[配置页 pet_profile_page]
  _ActionEditDialog._save()
    → PetActionDef(profileId: 当前角色id, moveDir, moveDist, moveSec, moveRef, startX, startY, trajectory, ...)
    → PetStore.saveAction(def)          // SQLite 表 pet_actions（INSERT，ButlerStore 封装内置 ConflictAlgorithm.replace）
    → PetSettingsNotifier.instance.notifyChanged()   // 全局单例 ChangeNotifier

[聊天页 PetChatOverlay / 陪伴页 CompanionPage]（两个页面各自独立实例）
  initState → PetWorld(store, frames)
    → world.restore()      // 清空内存 → 从 SQLite 读 组合动作/单动作/移动组 → scene._actionDefs/_activities/_moveGroups
    → world.preloadAll()   // 遍历 _actionDefs → preloadFrames(id) → 扫文件系统 pet/animations/<id>/ 帧图目录 → _frameCache[actionId]
    → world.syncVisible()  // 创建/同步小人（位置、头像、可见性）
    → _loadGroupRuntimes() // 互动组运行时（读 pet_groups + slotActions）
  设置变更：notifyChanged() → _onSettingsChanged（800ms 防抖）→ 同一套 restore→preloadAll→syncVisible→_loadGroupRuntimes→setState

[播放] 三条路径
  A. 自主行动：PetScene._tickAutoAct 每帧 → pool = _actionDefs 里 profileId==pet.id 且非内置 且 (inPlace||moveTo) → playAction
  B. 测试点播：长按小人 → _showTestActionSheet → PetStore.allActions()（直查 SQLite）过滤 profileId==pet.id → playAction
  C. 互动组：_loadGroupRuntimes → store.slotActions(slotId)（按 slot_id 查）→ startGroup 编排
```

## 二、数据分层

| 数据 | 层 |
|---|---|
| 动作定义元数据（单人+坑动作） | SQLite `pet_actions`（profile_id 归属角色 / slot_id 归属互动组坑，普通动作 slot_id=NULL） |
| 组合动作 / 互动组 / 移动组 / 角色档案 | SQLite `pet_activities` / `pet_groups` / `pet_move_groups` / `pet_profiles` |
| 帧图文件 / 头像文件 | 文件系统 `pet/animations/<actionId>/`、`pet/avatars/` |
| _actionDefs / _activities / _moveGroups | 内存（restore 填充） |
| _frameCache | 内存缓存（preloadAll 填充：actionId → 帧路径列表） |
| groupRuntimes（slotActions/slotFrames） | 内存（_loadGroupRuntimes 填充） |

## 三、两个真根因（都已修复）

### 根因①（18:45 b6d363a）：saveAction 漏写归属字段
`PetStore.saveAction()` 写入 SQLite 时漏写 `profile_id`（和 `slot_id`），读取端 `_actionFromRow()` 读 `profile_id`、过滤端（测试列表/自主行动/idle 帧归属）全按 `profileId == pet.id` 匹配 → 库里所有单人动作归属 NULL → 全部被过滤（测试列表空、自主行动不播、idle 帧归属失效→中页显示头像兜底）。
修复（最小必要，仅 pet_store.dart 两处）：saveAction row 补 `'slot_id': def.slotId, 'profile_id': def.profileId`；_actionFromRow 补读 slotId。
对比 saveSlotAction()（互动组坑动作）一直写全 → 互动组始终正常。

### 根因②（19:25 41a62fa）：copyWith 内存重建时丢归属字段
`PetActionDef.copyWith({int? frameCount, PetSpeedTier? speedTier})`（pet_models.dart L413）**漏传 profileId/slotId**。
`preloadFrames` 扫到帧后执行 `registerAction(def.copyWith(frameCount: list.length))`（pet_scene.dart L1175 唯一调用点）→ _actionDefs 里的动作被替换成 profileId==null 的版本 → `_resolveIdleFrames`（idle 待机）和 `_tickAutoAct`（自主行动 pool）按 profileId==pet.id 匹配全部失败 → 待机显示头像兜底。测试播放不受影响（playAction 直接按 actionId，不走归属过滤）——所以用户实测"测试列表能看到、点播能播、但播完恢复 3:4 图（头像）"。
修复：copyWith 补 `profileId: profileId, slotId: slotId`（pet_models.dart 一处）。

**教训（开发者被用户批评"你当时不是检查了吗"）**：检查归属字段只查了 INSERT/SELECT 两个方向，漏了内存字段变换（copyWith）。**归属字段必须覆盖 PetActionDef 全部创建/变换路径**：构造函数 / copyWith / _actionFromRow / JSON / 内置模板 / 配置页构造。已逐一核查：6 条路径中只有 copyWith 一处漏（已修）；内置模板和 duo 动作 profileId=null 是合理的（内置不属于任何角色；双人动作不属于单个角色，不该进单人列表/待机）。

## 四、用户实测验证进展（2026-08-14 19:19，装 b6d363a 后的包）

用户日志铁证（DebugLogger 桌宠标签）：
- `restore 加载：组合 0 / 单动作 1 / 移动组 0`（19:16 启动）→ `单动作 2`（19:18 保存第二个动作成功）→ **保存链路✅ 刷新链路✅**（保存→notifyChanged→restore→数量即时更新）
- 长按测试列表显示"动作111" ✅（归属过滤命中，SQLite profile_id 正确）
- 点击测试动作能播放（原地切图=帧动画在播）✅
- **播完恢复 3:4 图（头像兜底）❌ → 即根因②，已修（41a62fa），待装新包验证**

## 五、表结构全景（pet_store.dart createTables L40-107 + ALTER 迁移 L108-160）

**6 张表：**

| 表 | 字段 | 绑定关系 |
|---|---|---|
| `pet_profiles` | pet_id PK, name, affection, scale, visible, area, fixed_x/y, break_action_id, avatar_path, updated_at | 角色本身 |
| `pet_actions` | action_id PK, name, kind(inPlace/moveTo/turn/behavior/duo), fps, loop, frame_dir, frame_count, move_anim_id, target_spot, target_x/y, trajectory, move_duration, speed_tier, move_group_id, duration_seconds, move_dir, move_dist, move_sec, move_ref, **profile_id, slot_id** | 单人动作：profile_id→角色；互动组坑动作：slot_id→坑 |
| `pet_duo_configs` | pair_id PK, pet_a, pet_b, action_id | 双人动作：绑定 2 个角色（专门表） |
| `pet_activities` | activity_id PK, name, steps_json | **❌ 无归属字段——设计缺口（见第七节）** |
| `pet_groups` | group_id PK, name, trigger_dist, exit_mode, slots_json, steps_json, updated_at | 多人/互动组：slots_json 里 N 个坑各绑一个角色 |
| `pet_move_groups` | group_id PK, name, walk_action_id, run_action_id | 移动组：引用动作 id |

**绑定模型结论**：单人=profile_id 绑 1 角色；双人=pet_duo_configs 绑 2 角色；多人/互动=pet_groups 绑 N 坑。**模型本身能扩展，不是"只能绑一个"**。用户的核心担忧是"以后加双人/多人/复杂组合还会不会默默错"——这取决于归属判断是否收口（见第七节方案 ②）。

## 六、GPT 上一轮 8 疑点代码实勘结论（全部确认，无第二原因）

1. actionId 与帧图目录一致（保存时 frameDir:actionId，framesFor 同 id 扫目录）✅
2. 帧图目录不存在 → framesFor 返回空列表不崩溃，播放走占位帧 ✅
3. 扩展名过滤：pet_frame_source_impl.dart L20 `_imageExts={png,jpg,jpeg,webp,gif}`（用户帧图须这几种格式）✅
4. 帧数为 0 → 空帧→占位帧兜底 ✅
5. 帧排序：保存时文件名加序号前缀 `001_/002_` + 扫描后 `_naturalCompare` 自然排序，双保险 ✅
6. fps=帧数÷秒数（clamp 1-60）；loop 无限循环；once 播完 finished（pet_engine.dart PetAnimPlayer）✅
7. frameCache 更新：刷新链 restore→preloadAll→preloadFrames 每次设置变更都重扫 ✅
8. idle 筛选：frameDir≠null + slotId==null + profileId==pet.id（41a62fa 后全通过）✅

结论：**"中页显示 3:4 头像"的唯一真因 = 归属匹配失败**（根因①入库丢失 + 根因②内存重建丢失），两条都已修。

## 七、待 GPT 决策的问题（用户确认不了，请 GPT 给方案）

### A. 设计缺口：组合动作（pet_activities）无归属
用户（19:23）原话："以后我再多放几个角色，再多弄一点复杂的动作，把各种动作绑在一起，然后再绑定不同的角色，然后你又弄错了，找bug又找不到。"——**组合动作目前不属于任何角色**，多角色下必乱。
开发者方案（未动手，等 GPT 确认）：
1. `pet_activities` 加 `profile_id`（组合属于创建它的角色，与单动作角色隔离原则一致）
2. **归属判断收口成单入口函数**（`actionsForProfile(profileId)` / `activitiesForProfile(profileId)`），所有 UI/引擎走这一个入口——杜绝"这处漏那处丢"（本次两个根因都属于归属过滤分散导致的）
3. 需要 GPT 回答：**组合动作的归属语义**——属于创建角色（隔离）还是全局共用（所有角色可见）？双人/多人组合（涉及多角色）的归属该怎么表达？

### B. 双人动作的配置入口
现状：pet_widgets.dart L764 有独立 duo 创建入口（kind=duo，存 pet_actions profile_id=NULL + pet_duo_configs 配对）。同时 pet_groups（互动组）也支持 N 坑×剧本。
问题：双人互动应该走"互动组"配置（统一模型），还是保留独立双人入口？两种入口并存会不会造成概念重复、归属混乱？

### C. 上一轮未答问题（保留）
1. 自主行动"什么时候动"完整行为模型（行为权重表 + 定时/聊天触发）设计
2. 旧数据迁移：历史 profile_id=NULL 动作无法追溯归属（表无时间戳），当前方案=忽略+用户删掉重配，是否有更好方案（动作认领 UI / 按帧图目录推断）
3. 日志体系：是否加"动作加载/播放/过滤命中/未命中"级跟踪日志
4. **CI 自动化测试**（开发者无法跑模拟器：ARM64 objective_c build-hook 失败）：是否可在 GitHub Actions（x64）用 sqflite_common_ffi 内存库跑 PetStore 往返/归属过滤测试——把"归属"写进测试，以后改代码跑测试就知道有没有破坏绑定（用户 19:23 的痛点"找bug又找不到"的正解）

### D. 用户最痛的三个点（请优先回应）
1. "动作保存了但中页显示 3:4 头像不是动画" → 两个根因已修，41a62fa（19:40 出包）待真机验证
2. "单个都左错右错，未来双人多人怎么办" → 见 A/B，请给归属模型定案
3. "找bug又找不到" → 见 C-4 CI 测试 + 归属收口

## 八、回归清单进度（GPT 12 项，用户真机实测）

| # | 项 | 状态 |
|---|---|---|
| 1 | 新角色创建动作并保存 | ✅ 通过（单动作 1→2 日志） |
| 2 | 配置页重开仍存在 | ⏳ 待测 |
| 3 | 聊天页测试列表出现 | ✅ 通过（"动作111"可见） |
| 4 | 点测试动作能播放 | ✅ 通过（原地切图） |
| 5 | 自主行动能播放 | ⏳ 待测（根因②修复后） |
| 6 | 完全退出 App 重开仍能播放 | ⏳ 待测 |
| 7 | 角色 A/B 动作互不串 | ⏳ 待测 |
| 8 | 第二个动作保存后第一个仍在 | ✅ 通过（单动作 2） |
| 9 | 互动组继续正常 | ⏳ 待测 |
| 10 | 内置动作符合当前设计（默认小人兜底） | ⏳ 待测 |
| 11 | UI 与修复前一致 | ⏳ 待测 |
| 12 | 日志显示 restore 加载单动作 N | ✅ 通过（1→2） |

## 九、当前代码事实（HEAD 41a62fa，供 GPT 核对）

- PetStore.saveAction（pet_store.dart ~L301）：已写 profile_id/slot_id；_actionFromRow（~L351）读 profile_id+slotId
- PetActionDef.copyWith（pet_models.dart L413）：**已补 profileId/slotId**（41a62fa）
- PetScene._resolveIdleFrames（pet_scene.dart ~L1152）：frameDir≠null + slotId==null + profileId==pet.id → 帧列表 → 头像 → 静态占位
- PetScene._tickAutoAct：pool = profileId==pet.id + 排除内置 + (inPlace||moveTo)
- PetScene.preloadFrames（~L1171）：framesFor 扫目录 → _frameCache[actionId] → registerAction(copyWith(frameCount))
- PetScene._resolveFramesSync（L1077）：def.hasFrames→_frameCache→占位帧兜底
- PetScene.playAction（L949）：moveTo 相对目标（当前位置+方向×距离，无瞬移）；duo→startDuo；turn/behavior 分支
- PetWorld.restore（pet.dart ~L48）：clearActions → 全量重载 + 日志"restore 加载：组合 X / 单动作 Y / 移动组 Z"
- 测试列表 _showTestActionSheet（pet_chat_overlay.dart ~L224）：只显示自己的动作（无内置）
- FilePetFrameSource（pet_frame_source_impl.dart）：rootRelative='pet/animations'；framesFor 按 actionId 扫目录 + 扩展名过滤 + 自然排序

---

**请 GPT 给出：① 第七节 A/B 的归属模型定案；② C 系列问题（重点 CI 测试可行性）；③ 实施优先级；④ 任何开发者还没发现的隐患。**
