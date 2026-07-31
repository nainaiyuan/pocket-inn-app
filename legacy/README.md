# legacy/ — 旧版代码备份

2026-08-01 整理。曾把整条旧聊天链挪出 lib/，后发现
**旧 chat_page 仍在用**（设置 → 角色内容 → 新建聊天 = ChatPage.draft，
世界书聊天流），已全部恢复。只有旧版 API 配置页留在备份区。

## 内容

| 文件 | 原路径 | 说明 |
|------|--------|------|
| api_config_page.dart | lib/pages/api_config_page.dart | 旧版 API 配置页（老 api_configs 系统），现无入口 |

## 为什么挪出

- 新 AI 系统（`lib/ai_provider/` + AIProviderManager）已接管所有聊天路由
- 旧配置页编辑的是老系统（`data/api_configs.dart`），新系统只读它做一次性迁移
- 旧 chat_page 的「管理配置」按钮已改指向新 `AiConfigPage`（lib/pages/ai_config_page.dart）
- 设置页的「API 配置」入口同样指向新页面

## 以后要用

copy 回 `lib/pages/api_config_page.dart` 即可（依赖的
`data/api_configs.dart`、`models/api_config.dart` 都还在）。
注意：恢复后它编辑的是旧系统配置，不会影响新 AIProviderManager。

---

## 世界书 UI（2026-08-01 深夜追加）

用户确认不要世界书功能，UI 层已整体移除：

| 文件 | 原路径 | 说明 |
|------|--------|------|
| world_book_page.dart | lib/pages/world_book_page.dart | 世界书管理页（用户确认不要） |
| world_book_edit_page.dart | lib/pages/world_book_edit_page.dart | 世界书编辑页（用户确认不要） |

**⚠️ 教训：character_world_page.dart 曾被误当世界书挪出，实为「秘密基地/小世界」页面
（男主日记/约定/故事彩蛋），已恢复原位 lib/pages/chat/widgets/，聊天页入口已还原。**

**同步删除的世界书 UI 入口（用户确认不要）：**
- 设置→角色内容 的「世界书管理」卡片
- 角色编辑页的「选择世界书/不关联世界书」+ 编辑按钮
- 旧聊天页输入栏的世界书按钮 + 菜单项（chat_input_area 的 onWorldBookPressed 参数、chat_selector_menus 的 showWorldBookMenu 函数）

**保留未动（逻辑层）：** models/world_book.dart、world_book_service.dart、数据库表、
chat_service/prompt_assembly/chat_view_model 里的世界书拼装逻辑——旧聊天流（ChatPage.draft）
若还加载角色的世界书条目仍能正常工作，只是没有编辑入口了。

**恢复方法：** 文件 copy 回原路径 + 恢复对应入口（见 git 历史 diff）。
