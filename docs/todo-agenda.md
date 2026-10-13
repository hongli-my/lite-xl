# Todo Agenda(阶段 1:三视图)

AFFiNE 式任务工作台的第一阶段落地:同一个 markdown 真相源,三种投影。

## 任务语法

```markdown
- [ ] 写季度报告 @due(2026-10-16) #工作
- [x] 回复客户邮件 @due(2026-10-12) #工作
- [ ] 无标签无日期任务
```

- `@due(YYYY-MM-DD)`:截止日期,日历视图按它落格,逾期(未完成且 < 今天)红色高亮
- `#tag`:看板列。第一个 tag 决定卡片所在列;可多标签
- 都是可选的;纯 `- [ ] 文本` 照旧工作

## 三个视图

| 视图 | 交互 | 写回 |
|---|---|---|
| **列表**(原功能) | 点 ☑ 勾选;点文字跳到源文件行 | `doc:insert/remove`(文件打开时)或改盘 |
| **看板** | 列 = `#tag`;拖卡到别的列改写源文件里的 tag;点卡上 ☑ 勾选 | 同上,拖卡 = 一行文本编辑,进 undo 栈 |
| **日历** | `@due` 落格;点格内任务勾选;◀▶ 切月 | 同上 |

头部右侧「列表 / 看板 / 日历」按钮切换,或 `todo-agenda:switch-view` 命令循环切换。

## 写回语义(与编辑器融合的核心)

所有视图交互最终都是对 markdown 一行的编辑,经 `edit_task_line`:
- 文件在编辑器中打开 → `doc:remove + doc:insert`,进 undo 栈,不覆盖脏缓冲
- 文件未打开 → 直接改磁盘,dirwatch 触发重扫

所以:看板拖卡后切到文件 tab,那行 markdown 已经变了;`cmd+Z` 可撤销拖卡;`git diff` 只有一行变更。

## 配置

```lua
config.plugins.todo_agenda = {
  extensions = { "md", "markdown" },
  kanban_columns = { "工作", "生活" },  -- 列顺序(空列也显示)
  kanban_default_column = "其他",                      -- 无 tag 任务的列
  week_starts_monday = true,
}
```

## 快捷键

- `ctrl+shift+t`:开/关待办视图
- `todo-agenda:switch-view`:循环切换 列表→看板→日历

## 无头测试

不启动 GUI 即可验证行为:

```bash
lua tests/headless/test_todo_agenda.lua
```

覆盖:解析(@due/#tag/多标签/display)、勾选写回 Doc 模型、拖卡改 tag 写回、日历落格与月份导航、视图切换。

## UI 行为细节(review 后)

- 看板列内滚轮 = 该列垂直滚动(每列独立);`shift+滚轮` = 整板水平平移
- 长任务文本在卡片/日历格/列表行内自动截断加 `…`,不再溢出边界
- 卡片视觉:填充背景 + 左侧 2px 强调条(hover 变 accent),完成态 dim + `✓` 前缀;完成勾选框带 ✓ 刻痕
- 月份标题本地化 `2026年10月`;列头 hover 手型光标
- `style.error` 缺失的主题(fall/summer/textadept)回退 `style.dim`,不再崩溃
