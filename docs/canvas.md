# Canvas 画布 & Mindmap 导图

阶段 2 视图:`canvas.lua` 提供无限画布(脑暴/moodboard/视觉草稿)和 markdown 大纲导图。
核心原则与 todo_agenda 一致:**markdown 是唯一数据源,布局只存 sidecar,永远不污染 md/git diff**。

## 快速开始

| 操作 | 命令/快捷键 |
|---|---|
| 当前 md 文件开画布 | `canvas:open`(侧栏命令面板) |
| 当前 md 文件开导图 | `mindmap:open` / `ctrl+shift+m` |

画布数据存 `<文件名>.canvas`(同目录 sidecar JSON),可直接放进 git 或忽略。

## Canvas 画布

### 三种卡片

| 类型 | sidecar 写法 | 说明 |
|---|---|---|
| 便签 sticky | `{ type="sticky", text="...", x, y }` | 快速想法;双击编辑 |
| md 卡片 | `{ type="md", file="notes.md", heading="## M2", x, y }` | 渲染该标题下的清单;双击跳转源文件 |
| 图片卡 | `{ type="image", path="./ref.png", caption="...", x, y }` | moodboard;路径相对 sidecar 所在目录 |

### 交互

- **拖空白处**平移;**滚轮**缩放(以光标为中心,25%–250%)
- **拖卡片**移动(z-order 置顶;松手写回 sidecar)
- **双击空白**新建便签(文本"新便签",双击卡片改内容)
- **双击 md 卡**打开源文件并定位标题行
- **alt + 从卡片拖出**画箭头到另一张卡
- `frames`(JSON 手写)= 虚线圈选分组,阶段 4 演示模式将按 frame 分页

### sidecar 结构

```json
{
  "cards":  [ { "id": "c1", "type": "sticky", "text": "想法", "x": 40, "y": 60 } ],
  "arrows": [ { "from": "c1", "to": "c2" } ],
  "frames": [ { "id": "f1", "x": 0, "y": 0, "w": 400, "h": 300, "label": "入选方案" } ]
}
```

布局(x/y/z-order)只进 sidecar;文本内容仍以 md 文件为准(md 卡每次绘制重新读取打开中的 buffer)。

## Mindmap 导图

打开任意 markdown 文件后 `ctrl+shift+m`:嵌套 `- 列表` 渲染为树(两层缩进 = 一层树),
`- 平级` = 兄弟节点。

```markdown
# 期末复习
- 特征值
  - 定义 Av = λv
  - 求法 det(A-λI)=0
- 相似对角化
  - 条件:n 个线性无关特征向量
```

- 点击节点 → 编辑器跳到源文件对应行
- 编辑 md 后导图实时刷新(读取打开中的 buffer)
- 拖空白平移、滚轮缩放,同画布

## 配置

```lua
config.plugins.canvas = {
  grid_size = 24,    -- 背景点阵间距
  min_zoom = 0.25,
  max_zoom = 2.5,
  sticky_tint = 0.30,
}
```

## 场景对照

| 场景(见 docs/examples/) | 用法 |
|---|---|
| 头脑风暴 | 便签卡 + 箭头聚类 + frame 圈"入选方案" |
| 视觉草稿/moodboard | 图片卡引用本地 png |
| 团队 wiki | md 卡引用 `work/项目-x.md` 的章节,画布即项目地图 |
| 复习思维导图 | `mindmap:open` 直接渲染 `05-导图与脑暴.md` 的大纲 |

## 已知边界

- 便签文本编辑走命令行输入(core.command:enter),非内联编辑器
- frame 暂无鼠标圈选交互,sidecar 手写(阶段 4 演示模式一起做)
- 箭头为肘形(水平-垂直),不支持曲线
