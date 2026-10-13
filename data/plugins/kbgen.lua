-- mod-version:4
-- kbgen: 知识库派生文件生成器
--
-- 知识库里三个"汇总文件"不应手写, 它们是项目真实内容的投影:
--   * 星图-<项目>.md    ← 各目录 README.md 的标题结构 (导图场景: ctrl+shift+e)
--   * 驾驶舱.canvas     ← 项目目录结构 (画布场景: canvas:open)
-- 看板不需要生成: todo_agenda 本身就是全项目 checkbox 的动态投影。
--
-- 用法: 项目里任意位置执行命令 kbgen:generate (或 ctrl+shift+k)。
-- 生成物 = 派生物: 想改结构就改各目录的 README.md, 再重新生成。

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"

config.plugins.kbgen = common.merge({
  -- 星图: 只扫描这些目录的 README.md
  dirs = { "starrocks", "agent", "plantuml", "nginx-lua", "containerd" },
  -- 星图根标题
  mind_title = "知识导图",
  -- 生成文件名
  mind_file = "星图-知识库.md",
  canvas_file = "驾驶舱.canvas",
}, config.plugins.kbgen)

---------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------

local function read_lines(path)
  local fp = io.open(path, "r")
  if not fp then return nil end
  local lines = {}
  for l in fp:lines() do lines[#lines + 1] = l end
  fp:close()
  return lines
end

local function write_file(path, content)
  local fp = io.open(path, "w")
  if not fp then return false end
  fp:write(content)
  fp:close()
  return true
end

-- Minimal JSON escape/encode (same scheme as canvas.lua sidecar)
local function json_escape(s)
  local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
  return (s:gsub('[%c"\\]', function(c)
    return map[c] or string.format("\\u%04x", c.byte and c:byte() or 0)
  end))
end

local function json_str(s) return '"' .. json_escape(s) .. '"' end

---------------------------------------------------------------------
-- 星图: 各目录 README.md 的标题层级 → markdown 大纲
--   README 的 "# X"   → 导图一级分支
--   README 的 "## X"  → 导图二级
--   README 的 "### X" → 导图三级
-- 目录名作为一级分支前缀(目录可能没有 README, 保留目录占位)。
---------------------------------------------------------------------

local function gen_mindmap(root)
  local out = {}
  out[#out + 1] = "# " .. config.plugins.kbgen.mind_title
  out[#out + 1] = ""
  out[#out + 1] = "> 由 kbgen 生成 — 改各目录 README.md 后重新生成"
  out[#out + 1] = ""
  for _, dir in ipairs(config.plugins.kbgen.dirs) do
    out[#out + 1] = "- " .. dir
    local lines = read_lines(root .. "/" .. dir .. "/README.md")
    if lines then
      for _, l in ipairs(lines) do
        local hashes, title = l:match("^(#+)%s+(.-)%s*$")
        if hashes then
          -- h1 is the dir itself (already emitted); h2+ become outline nodes
          local depth = #hashes - 1
          if depth >= 1 and depth <= 3 then
            out[#out + 1] = string.rep("  ", depth) .. "- " .. title
          end
        end
      end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

---------------------------------------------------------------------
-- 驾驶舱 canvas: 一个目录 = 一列卡片
--   每个一级/二级标题(各目录 README) = 一张 md 卡, 双击跳源
--   sidecar 布局可以随手拖, 重新生成会覆盖
---------------------------------------------------------------------

local function gen_canvas(root)
  local cards, arrows = {}, {}
  local col_w, gap = 340, 60
  local cx = 40
  for _, dir in ipairs(config.plugins.kbgen.dirs) do
    local ccol = 0
    local lines = read_lines(root .. "/" .. dir .. "/README.md")
    if lines then
      local y = 40
      -- one sticky per dir as the column header
      cards[#cards + 1] = string.format(
        '    { "id": "h%s", "type": "sticky", "text": %s, "x": %d, "y": %d }',
        dir, json_str(dir), cx, y)
      y = y + 80
      for _, l in ipairs(lines) do
        local hashes, title = l:match("^(#+)%s+(.-)%s*$")
        if hashes and #hashes >= 2 then
          cards[#cards + 1] = string.format(
            '    { "id": "c%s%d", "type": "md", "file": %s, "heading": %s, "x": %d, "y": %d }',
            dir, ccol, json_str(dir .. "/README.md"),
            json_str(string.rep("#", #hashes) .. " " .. title), cx, y)
          ccol = ccol + 1
          y = y + 230
        end
      end
    end
    cx = cx + col_w + gap
  end
  local parts = {
    "{",
    '  "cards": [',
    table.concat(cards, ",\n"),
    "  ],",
    '  "arrows": [],',
    '  "frames": []',
    "}",
  }
  return table.concat(parts, "\n")
end

---------------------------------------------------------------------
-- command
---------------------------------------------------------------------

command.add(nil, {
  ["kbgen:generate"] = function()
    local root = core.root_project() and core.root_project().path
    if not root then
      core.log("kbgen: 没有打开的项目")
      return
    end
    local mf = write_file(root .. "/" .. config.plugins.kbgen.mind_file,
      gen_mindmap(root))
    local cf = write_file(root .. "/" .. config.plugins.kbgen.canvas_file,
      gen_canvas(root))
    if mf and cf then
      core.log("kbgen: 已生成 %s / %s (改各目录 README.md 后可重新生成)",
        config.plugins.kbgen.mind_file, config.plugins.kbgen.canvas_file)
    else
      core.log("kbgen: 写入失败 (项目目录只读?)")
    end
  end,
})

keymap.add { ["ctrl+shift+k"] = "kbgen:generate" }
