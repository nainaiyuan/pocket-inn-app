# 立绘体验重构：桌宠实现全盘点 + 立绘现状 + 用户问题（问 GPT 用）

> 日期：2026-08-16 ｜ 用途：给 GPT 出方案前的完整材料
> 背景：用户实测立绘功能后反馈 6 个问题，要求"把桌宠怎么做的 + UI 全部整理去问 GPT"。
> 本文 = 桌宠底层实现 + 配置中心 UI + 立绘现状 + 用户原话问题 + 待 GPT 解答。

---

## 一、桌宠是怎么做的（完整盘点）

### 1. 底层引擎（纯 Dart，全部配置驱动）

**文件：`lib/butler/pet/pet_engine.dart`（帧动画引擎）**
- `PetAnimPlayer`：帧序列播放器
  - `frames: List<String>` 图片路径列表（按播放顺序）
  - `fps` 播放帧率；`loop` 枚举 `PetAnimLoop.loop / once / pingpong`
  - `maxLoops`（0 = 无限循环）；`update(dt)` 按时间推进；`currentFrame` 当前帧路径
  - 桌宠/立绘都靠它播动画——**用户上传多张连拍图 = 一个动作，播放时帧切换 = 会动**
- `PetFrameSource`：帧图来源抽象（Flutter 实现扫目录，测试用内存实现）

**文件：`lib/butler/character_config/character_config_models.dart`（配置模型）**
- `CharacterConfig`：id / name / **actions**（动作）/ **behaviors**（行为）/ **triggers**（触发）/ **hotspots**（热点）/ **isPortrait**（立绘标记）/ **portraitBg**（背景图资源ID）/ **leadId**（绑定聊天角色ID）
- `CcAction`：id / name / category / **frames**（连拍图路径列表）/ fps / loop（once|loop）/ moveDir（8方向）/ moveDist（位移距离）
- `CcBehavior`：行为（触发条件 + 动作）
- `CcTrigger`：触发器（区域/对象/点击等条件 + 动作）
- `CcHotspot`：id / name / **x,y（0-1 归一化，相对立绘本体的显示矩形）** / radius（判定范围，默认0.08）/ actionId（触发动作）/ lines（单击台词池）/ longLines（长按台词池）/ expression
- 全部 JSON 短键序列化，旧数据缺字段 = 默认值，零迁移

**文件：`lib/butler/character_config/character_config_runtime_core.dart`（运行时）**
- `CcFrameSource`：cc_ 前缀动作 → CcAction.frames，否则回退桌宠
- `CcRuntimeBridge`：toActionDefs / toActivityDef 转换
- `CcBehaviorRuntime.update(dt)`：触发 6s 冷却 > interact+tapped > idle 加权随机
- `ccHotspotHitTest` / `ccHotspotPickLine`：热点命中判定 / 台词随机

**文件：`lib/butler/character_config/character_config_store.dart`（存储）**
- CharacterConfigStore：配置表存取（listSummaries / load / save）
- StorageRegistry：注册各 store（含 BgAssetStore 背景图资源库）

### 2. 桌宠配置中心 UI（管家页 → 配置中心）

**入口：`lib/pages/character_config/character_config_list_page.dart`**
- 角色配置列表 + 右下角双 FAB：「新建角色」/「新建立绘」（用户问题点：新建立绘走的是和新建角色一样的通用流程，看不到立绘在哪）
- 列表项区分：角色配置 / 立绘配置（立绘带"立绘"标签）

**配置向导：`lib/pages/character_config/character_config_edit_page.dart`（角色）/ `portrait_config_edit_page.dart`（立绘）**
- 统一卡片式 + 顶部步骤条 + 左 1/3 浅紫底预览（0xFFF7F0F4）+ 右边框（0xFFE4D4DE）+ 右滚动表单
- 步骤间跳转：`_openModule(page)` push 子编辑页，onChanged 回传（防丢数据铁律）

**子编辑页（桌宠与立绘共用）**
- `action_editor_page.dart`：动作编辑（连拍图上传 + 预览 + 速度）
- `behavior_editor_page.dart`：行为编辑
- `trigger_editor_page.dart`：触发编辑

### 3. 桌宠运行页（`lib/pages/home/companion_page.dart`）
- `CcFrameSource` 提供帧图 → PetAnimPlayer 播放
- `_ccConfigs` / `_ccRuntimes` / `_loadCcCharacters(world)` 加载配置角色
- `_onTick` 中 `rt.update(dt.clamp(0, 0.1))` 驱动行为运行时

### 4. 立绘页（`lib/pages/chat/portrait_mode_page.dart`，👤 入口）
- 立绘本体 = 第一个有图动作的帧动画（PetAnimPlayer 循环播，空闲时头会动）
- 触发热点 = 播一次热点绑定的动作（once，播完回空闲）
- 热点相对立绘本体的 contain 显示矩形（帧切换时随当前帧宽高比更新）
- 三种触发：单击（台词+动作）/ 长按（长按台词池）/ 拖❤ 触发物拖到热点上松手
- 编辑模式（暂停动画）→ 热点 chips + 选中热点编辑（名称/位置滑块/判定范围滑块/台词/删除）
- 背景 = BgAsset 资源库（唯一 ID，可复用，图库弹层管理）

---

## 二、立绘配置向导现状（`portrait_config_edit_page.dart`）

**6 步：①立绘 ②动作 ③热点 ④行为 ⑤触发 ⑥完成**

| 步骤 | 内容 | 现状 |
|------|------|------|
| ①立绘 | 名称/绑定聊天角色/背景图 | 卡片式，可选绑定 |
| ②动作 | 上传连拍图 = 动作 | 动作列表 + 上传 |
| ③热点 | 预览立绘图 + 热点点/圈 + 右侧编辑 | 热点相对立绘本体；**没有调整立绘图本身位置的能力**（用户问题1） |
| ④行为 | 跳转 CharacterConfigBehaviorsPage | **一点就跳进去直接改，没有选择机会**（用户问题2） |
| ⑤触发 | 跳转 CharacterConfigTriggersPage | 同上 |
| ⑥完成 | 汇总 | 纯文字 |

---

## 三、用户实测反馈的问题（2026-08-16 15:14 原话整理）

1. **热点步骤不能调立绘图位置**："你都没有给我机会调整立绘图的上下左右的位置"
   —— 热点步骤只有热点位置滑块，立绘图本身固定居中，用户想挪立绘位置再绑点，没得调。

2. **行为步骤一点就跳进去改**："第四步行为，跳转到行为那里，又不给我选择的机会，一点就进去修改行为了"
   —— 行为步骤应该先展示/选择（有哪些行为、要不要新建），而不是直接跳编辑页。

3. **没有最终效果预览**："我根本分不清最终效果是什么，满不满意，你根本没有给我预览"
   —— 配置过程中看不到"配出来最终是什么样"（立绘+热点+行为+触发 整体效果）。

4. **新建立绘 = 新建角色，看不到立绘在哪**："你新建立绘按钮，建了，就是新建角色一样，我根本没有看到立绘在哪里"
   —— 新建入口流程和角色一样，没有立绘可视化。

5. **立绘应该塞进角色里**："你要么把立绘塞进角色里面，和那些动作行为放在一起，要设的时候按步骤跳转"
   —— 用户期望：立绘是角色的一个模块（和动作/行为/触发放一起），设置时按步骤跳转，
     而不是独立于角色的另一个"新建"流程。

6. **步骤里不能设的没得选**："你步骤里面还有好多 不能设就是不能设，也没得选"
   —— 禁用状态没有引导/替代方案（例如没素材时「添加热点」置灰，用户不知道怎么办）。

---

## 四、给 GPT 的问题

1. **立绘与角色的关系怎么组织**？用户明确说"把立绘塞进角色里面，和动作行为放在一起"——
   应该把立绘做成 CharacterConfig 的一个模块（角色 = 动作 + 行为 + 触发 + 立绘 + 热点），
   还是保持独立立绘配置但入口整合进角色？两种的信息架构/数据模型/迁移成本怎么评估？
2. **配置向导怎么给"最终效果预览"**？预览什么（立绘动画 + 热点圈 + 行为/触发可试触发？），
   预览组件怎么复用桌宠运行时（PetWorld/PetGroupRuntime 直接当预览运行时，临时数据不落库）？
3. **行为/触发步骤应该"先选择再编辑"**：进入步骤先看到已有列表 + 选择/新建，而不是直接跳编辑页？
   交互怎么设计（列表卡片 + 预览 + 跳转）？
4. **热点步骤要不要支持调整立绘图本身的位置/缩放**？还是立绘位置固定、只调热点？
   如果支持，立绘图位置存哪（x/y 偏移 + scale，相对舞台）？热点归一化坐标是否受影响？
5. **新建入口怎么区分**：新建立绘应该看到什么（立绘可视化 + 步骤引导），
   而不是和新建角色一样的通用表单？入口层级怎么设计最清楚？
6. **禁用状态引导**：步骤里"不能设"的项怎么给替代路径（跳转提示卡 + 可点击直达），
   而不是单纯置灰？
7. **整体信息架构**：桌宠/立绘/文游/小屋都是同一套底层（CcAction/CcBehavior/CcTrigger），
   管家页怎么聚合入口让用户"看得见配出来是什么"？

---

*关联文档：`管家配置中心_现状与规划_问GPT.md`、`单角色配置中心_设计规格_v1.0_GPT.md`、`互动组编辑器v2_可视化配置_设计文档.md`*
