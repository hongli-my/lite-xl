# Git 状态(`plugins/git_status.lua`)

左树 + 编辑器行号区的只读 Git 状态显示,Sublime Text 风格。**侧栏只显示未提交的改动**:已 commit 的文件不染色、不带徽标。行标记对比 `HEAD` 与当前 buffer,所以未保存的编辑也会显示;提交后(且 buffer 与 HEAD 一致)自动消失。

## 左树

| 状态 | 徽标 | 颜色(浅色侧栏) |
|---|---|---|
| 新增 / 未跟踪 | `A` | 绿 `#1a7f37` |
| 修改 | `M` | 琥珀 `#9a6700` |
| 删除 | `D` | 红 `#cf222e` |
| 重命名 | `R` | 蓝 `#0969da` |
| 冲突 | `C` | 紫 `#8250df` |

- 文件名按状态染色,右侧显示一个字母徽标;目录显示子项的聚合状态(优先级 `C > D > R > A > M`)。
- 有未保存 buffer 的文件额外显示一个小圆点(和 tab 上的脏点一致)。
- 涵盖 `git status` 的 staged、unstaged、untracked 三类改动。
- 长文件名会被裁剪,不会盖住徽标。

## 编辑器行号区

- 新增行:左侧绿色竖条。
- 修改行:琥珀色竖条。
- 删除:边界处红色小横条(文件末尾的删除画在最后一行底部)。

行标记是**当前 buffer 对比 `HEAD`** 实时算出来的,输入时防抖更新;保存、切 tab 会立即刷新。超过 `max_live_diff_lines` 行的大文件只显示侧栏状态,不画行标记。

行标记对比的是 `HEAD` 与**当前 buffer**,所以未保存的编辑也会实时显示(Sublime 行为)。侧栏徽标只反映 `git status`:已 commit、仅有未保存编辑的文件只显示脏点,保存后徽标才出现。

## 刷新

| 触发 | 间隔 |
|---|---|
| 本地仓库轮询 | 4s(命令慢时自动退避) |
| 远端仓库轮询 | 15s |
| 保存文件 | 0.3s 后强制刷新 |
| 手动 | `ctrl+shift+g` / `git-status:refresh` |

## 远端目录

远端项目由 `plugins/remote_projects.lua` 落成本地 cache 目录。`git_status` 复用它的 SSH 通道(`ssh_command` / `run_with_password`),不重复处理密码/askpass:

- 在远端执行 `git rev-parse` / `git status` / `git show`;
- 把远端路径映射回本地 cache 路径,所以侧栏和行标记与本地项目一致;
- 未 pull 的占位文件**仍显示侧栏徽标**(远端 `git status` 不依赖是否 pull),文件名用**降低透明度的状态色**(保留“未拉取”的弱化感,但能看出状态),且不画行标记(避免把 0 字节占位文件误判成整文件删除);右键“拉取 (Pull)”后自动出现行标记;
- 远端连接后**新出现且未提交**的文件,会在下一次状态轮询(15s)时自动补一个 0 字节占位并出现在树里(灰色偏状态色 + `A` 徽标),可直接拉取;
- 远端目录不是 git 仓库、或远端没有 git 时静默跳过,不影响编辑。

### 远端文件列表同步

文件列表本身由 `plugins/remote_projects.lua` 同步,不依赖 git 状态:

| 触发 | 说明 |
|---|---|
| 连接远端时 | `ssh find` 全量列一次,生成占位文件 |
| 每 `tree_refresh_interval` 秒 | 默认 **60s**;设为 `0` 关闭自动刷新 |
| `ctrl+shift+alt+t` / 右键“刷新远端目录” | 立即重新列一次 |

刷新时:

- 远端新增的文件/目录 → 自动补 0 字节占位,树里出现(未拉取状态);
- 远端已删除、且**从未 pull** 的占位文件和空目录 → 自动清理;
- 已 pull 的文件、以及本地有内容的文件 → **不会删**(避免丢本地修改);
- 只同步**文件列表/占位**,不会自动重新下载已 pull 文件的内容;远端内容更新后需要右键“拉取 (Pull)”。

配置:

```lua
config.plugins.remote_projects = {
  tree_refresh_interval = 60, -- 0 = 只手动刷新
}
```

## 配置

```lua
config.plugins.git_status = {
  enabled = true,
  poll_interval = 4,
  remote_poll_interval = 15,
  save_refresh_delay = 0.3,
  materialize_remote_new_files = true, -- 远端新文件自动补占位

  live_diff_interval = 0.3,     -- 输入时两次行 diff 的最小间隔
  live_diff_clean_files = true, -- 已 commit 的文件也按 buffer 显示未保存编辑
  max_live_diff_lines = 20000,  -- 超过则只显示侧栏状态
  max_head_bytes = 4 * 1024 * 1024,
  max_status_bytes = 16 * 1024 * 1024,

  sidebar_colors = true,        -- 文件名染色
  sidebar_badges = true,        -- 右侧字母徽标
  sidebar_dirty_dot = true,     -- 未保存圆点
  gutter_markers = true,        -- 行号区标记

  git_binary = "git",           -- git 不在 PATH 时指定完整路径
}
```

颜色可在主题里覆盖:

```lua
style.git_added / git_modified / git_deleted / git_renamed / git_conflict
style.sidebar_git_added / ...   -- 浅色侧栏专用,缺省回退到上面的颜色
```

## 已知边界

- 行标记对比 `HEAD`,不是只对比 index;因此 staged + unstaged 改动都会显示。
- 子模块内部的文件暂不单独识别(父仓库的 `git status` 只报告子模块目录本身)。
- 远端每 15s 一次 `git status` 走 SSH;没有复用 SSH 连接,目录很大时可以调大 `remote_poll_interval`。
