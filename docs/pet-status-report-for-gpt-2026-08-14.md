# 桌宠动作系统 · 给 GPT 的完整现状报告（2026-08-14 18:50）

> 用途：请 GPT 基于这份事实报告分析"下一步怎么修/怎么设计"，不要再让开发者在黑暗中反复试错。
> 项目：Flutter Android 应用（荣耀平板 ARM64，本地无法跑模拟器，只能编译 APK 到真机测）。
> 模块：桌宠 = 聊天页里的电子宠物（多个小人角色，可配置动作、互动组）。

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
    → world.preloadAll()   // 遍历 _actionDefs → 扫文件系统 pet/animations/<id>/ 帧图目录 → _frameCache[actionId]
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
| _frameCache | 内存缓存（preloadAll 填充） |
| groupRuntimes（slotActions/slotFrames） | 内存（_loadGroupRuntimes 填充） |

## 三、统一根因（已修复，2026-08-14 18:45 b6d363a）

**`PetStore.saveAction()` 写入 SQLite 时漏写 `profile_id`（和 `slot_id`）**，而读取端 `_actionFromRow()` 读 `profile_id`、过滤端（测试列表/自主行动/idle 帧归属）全按 `profileId == pet.id` 匹配。

→ 库里所有单人动作归属 NULL → 全部被过滤 → 测试列表看不到、自主行动不播、idle 帧归属失效（中页显示头像兜底）。
→ 对比 `saveSlotAction()`（互动组坑动作）一直写全 profile_id+slot_id → 互动组始终正常。
→ **一个 bug 解释了用户今天 17:15–18:44 反馈的所有"互不相关"的现象。**

修复（最小必要，仅 pet_store.dart 两处，UI 零改动）：
1. `saveAction()` row 补 `'slot_id': def.slotId, 'profile_id': def.profileId`
2. `_actionFromRow()` 补读 `slotId`（存读对称）
3. insert 无需改（ButlerStore.insert 已内置 ConflictAlgorithm.replace，编辑覆盖正常）

验证：纯 Dart 脚本（绕过 ARM64 build-hook，复制 pet_models.dart 单独跑）——
model↔row 全字段往返一致 ✅ 角色隔离（A 看到 A1、B 看不到）✅ 旧 NULL 不归属任何人 ✅ JSON 往返 ✅

## 四、修复提交链（今天 14:10 → 18:55，全部已 push + 编译出包）

| commit | 内容 |
|---|---|
| d3361c9 | 移动动作完整链路四连修（编辑器补传 moveRef/startX/startY/moveSec；playAction moveTo 分支重写；_tickAutoAct pool 加 moveTo；preferredStart） |
| f9724ba | 长按菜单"测试动作"入口 |
| 1ba6982 | 自主行动死代码修复（PetAnimPlayer loop 模式 finished 永远 false → 触发条件改 state==idle + autoActionLeft 超时回 idle） |
| 664d26e | 动作相对衔接（存 moveDir+moveDist，删瞬移回起点，起点只用于 preferredStart） |
| 09e36da | 角色彻底隔离（取消 profileId==null 共享兜底——串图真根因；pool 只自己的+排除内置；测试列表只自己的） |
| 7524cf9 | 不撞脸（Pet.avatarPath 头像兜底；多小人横向排开防重叠） |
| d8e616e | 全局联动审查（组合动作步骤 moveDir 相对化；syncVisible 防重叠） |
| 299c151 | UI 刷新链路（restore 先 clearActions 再全量重载；聊天页+陪伴页完整刷新链 800ms 防抖） |
| 97ce761 | 测试动作列表删掉内置（用户明确不要内置） |
| **b6d363a** | **根因修复：saveAction 补写 profile_id/slot_id（见第三节）** |
| ef15fd4 | restore 加单动作加载日志（组合 X / 单动作 Y / 移动组 Z） |

**当前 HEAD = ef15fd4（19:10 左右出包）**。b6d363a（根因修复）已出包可下载。

## 五、用户历史反馈全景（按时间，帮助 GPT 看模式）

- 14:10–16:45：拖拽锁、切页拦截、自主行动不动（死代码）、idle 不播
- 16:53：不要内置动作，自己上传的单动作要能自主播放
- 16:58：动作必须相对衔接（不瞬移回起点）
- 17:15：①默认角色覆盖用户角色 ②底层表建好 ③新小人没从初始地方开始 ④一闪一闪原地不动 ⑤不要内置
- 17:37：①默认小人绑定新角色初始位置 ②长按测试只看到内置 ③默认小人是复制的一模一样
- 17:38：批评"你每次修bug都修一个地方吗"（要求全局联动审查）
- 17:41：怀疑"没同步到刷新那里，UI又有错"（→299c151 刷新链路）
- 17:58：测试列表内置没用、保存的动作不在列表（当时包=7524cf9，根因未修）
- 18:00：质疑"我的明明是新包"（时间线误会：17:45 提交 18:00 出包，用户装的就是最新）
- 18:18：转 GPT 要求——先答 12 个问题再修（→ 架构梳理文档 + 根因实勘）
- 18:28：内置不该出现在新男主小人那边（→97ce761 已删测试列表内置，全入口确认无内置）
- 18:44：①动作又保存不了 ②3:4框图片（头像兜底）出现在中页 ③日志只看到"互动组运行时加载：0组"，质疑单动作不播放（当时包=97ce761，根因未修；b6d363a 18:45 才提交）
- 18:46：要求把所有东西整理好交给 GPT 分析

**模式总结**：用户每次反馈时测的包都比最新修复晚 1 个版本（编译 15 分钟延迟 + 用户下载时机），导致"修好的功能用户测不到、测到的还是上一版 bug"。18:44 反馈的三点全部是 b6d363a（18:45）刚修完的根因。

## 六、当前代码事实（HEAD ef15fd4，供 GPT 核对）

- `PetStore.saveAction()`（lib/butler/pet/pet_store.dart ~L301）：已补 profile_id/slot_id 写入
- `PetStore._actionFromRow()`（~L345）：读 profile_id + slot_id
- `PetScene._resolveIdleFrames()`（lib/butler/pet/pet_scene.dart ~L1152）：只认 profileId==pet.id 的帧 → 头像兜底 → 静态占位
- `PetScene._tickAutoAct()`：pool 过滤 profileId==pet.id + 排除内置 + (inPlace||moveTo)
- `PetWorld.restore()`（lib/butler/pet/pet.dart ~L48）：clearActions → 全量重载 + 新日志
- 测试列表 `_showTestActionSheet`（lib/pages/chat/widgets/pet_chat_overlay.dart ~L224）：只显示自己的动作（无内置）
- 配置页动作列表：`store.allActions()`（SQLite），不含内置
- 互动组：slotActions(slotId) 按 slot_id 查（一直正常）

## 七、待 GPT 决策/分析的问题

1. **帧图上传 UI 与播放衔接**：用户在配置对话框里上传帧图（显示在 3:4 预览框），保存后中页应播放帧动画。请核对：帧图目录扫描（FilePetFrameSource）、帧排序（文件名序）、fps、循环模式（loop/once）这套链路有没有隐患？用户对"中页显示静态图/头像"的抱怨是否还有别的可能路径（如帧图目录名与 actionId 不一致、文件扩展名过滤、帧数=0 时不播放）？
2. **自主行动策略**：用户诉求"单个动作能自发播放"（已满足：state==idle 触发 + autoActionLeft 超时回 idle）。下一步用户要"什么时候动"的完整行为模型（行为权重表 + 定时/聊天触发）——请给设计方案（触发条件、权重、冷却、与拖拽/互动组的优先级冲突处理）。
3. **存读对称性全面复查**：pet_actions 全表读写我已查（INSERT：saveAction/saveSlotAction；SELECT：allActions/slotActions；DELETE：removeAction；无 UPDATE）。请再确认有没有其他表（pet_activities steps_json、pet_groups slots_json/steps_json、pet_move_groups）存在类似"写入字段 ≠ 读取字段"的不对称。
4. **旧数据迁移**：历史单人动作 profile_id=NULL 无法追溯归属（表无时间戳）。当前方案：不删数据、新逻辑忽略（不显示不播放不串图），用户删掉重配。是否有更好的方案（如按帧图目录名/创建时间推断归属、或提供"动作认领"UI）？
5. **互动组与单动作共存**：互动组运行时（_groupRun）和单动作自主行动（_tickAutoAct）的优先级/互斥是否完备？（目前：_groupRun 非空时跳过自主行动 tick；小人被互动组接管时 _pair/_activity 非空不 stop）
6. **日志体系**：当前 DebugLogger 按"桌宠"标签过滤。是否有必要加"动作加载/播放/过滤命中/过滤未命中"级别的跟踪日志，方便用户在真机上自助定位？
7. **测试策略**：开发者无法跑模拟器（ARM64 build-hook objective_c 失败）。当前验证 = dart analyze + 纯 Dart 脚本复制 model 层跑往返。是否有办法在 CI（GitHub Actions，x64）里加 dart test 或 widget test 覆盖 PetStore 往返/过滤逻辑（sqflite 可用 sqflite_common_ffi 在测试里跑内存库）？

## 八、用户当前最痛的三个点（请优先回应）

1. "动作又没办法保存" → 根因已修（b6d363a），等用户装新包验证
2. "中页显示 3:4 图片（头像）而不是动作动画" → 根因已修（idle 帧归属匹配），等验证
3. "单动作不允许播放吗（日志只有互动组 0 组）" → 单动作走 restore（已加日志 ef15fd4）；互动组 0 组 = 没建互动组，正常

**请 GPT 给出：① 对第七节 7 个问题的分析；② 下一步实施优先级；③ 任何我还没发现的隐患。**
