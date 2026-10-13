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

local function json_encode_value(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then return string.format("%.14g", v)
  elseif t == "string" then return json_str(v)
  elseif t == "table" then
    if #v > 0 or (next(v) == nil) then
      local parts = {}
      for _, item in ipairs(v) do parts[#parts + 1] = json_encode_value(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = json_str(k) .. ":" .. json_encode_value(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

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

---------------------------------------------------------------------
-- 驾驶舱 canvas: 增量合并生成
--   * 卡片键 = file + heading (章节唯一)
--   * 已存在的卡片(含手写便签/箭头/frame)原样保留, 位置不动
--   * 新章节追加到画布右侧空白区; 消失的章节不删卡(由人手动删)
--   => 你摆好的驾驶舱布局永远不会被重新生成冲掉
---------------------------------------------------------------------

-- minimal JSON decoder for reading back our own sidecar output
-- (our encoder escapes non-ASCII and control chars to \uXXXX / \" so plain
-- string capture is safe; handles compact and multiline layouts)
local function json_decode(s)
  local pos = 1
  local function skip()
    while true do
      local c = s:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" or c == "," then pos = pos + 1
      else break end
    end
  end
  local parse
  parse = function()
    skip()
    local ch = s:sub(pos, pos)
    if ch == "{" then
      pos = pos + 1
      local obj = {}
      while true do
        skip()
        if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
        local key = s:match('^"([^"]*)"', pos)
        pos = s:find('"', pos + 1) + 1  -- past closing quote of key
        skip()
        pos = pos + 1                   -- past colon
        obj[key] = parse()
      end
    elseif ch == "[" then
      pos = pos + 1
      local arr = {}
      while true do
        skip()
        if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
        arr[#arr + 1] = parse()
      end
    elseif ch == '"' then
      local str = s:match('^"([^"]*)"', pos)
      pos = s:find('"', pos + 1) + 1
      return str
    else
      local num = s:match("^%-?%d+%.?%d*", pos)
      if num then pos = pos + #num return tonumber(num) end
      if s:find("^true", pos) then pos = pos + 4 return true end
      if s:find("^false", pos) then pos = pos + 5 return false end
      if s:find("^null", pos) then pos = pos + 4 return nil end
      pos = pos + 1
      return nil
    end
  end
  return parse()
end

local function gen_canvas(root, path)
  -- read existing sidecar if present
  local existing_cards, arrows, frames = {}, {}, {}
  local by_section = {}
  local fp = io.open(path, "r")
  if fp then
    local ok, data = pcall(json_decode, fp:read("*a"))
    fp:close()
    if ok and type(data) == "table" then
      for _, c in ipairs(data.cards or {}) do
        existing_cards[#existing_cards + 1] = c
        if c.type == "md" then
          by_section[(c.file or "?") .. "\t" .. (c.heading or "?")] = c
        end
      end
      arrows = data.arrows or {}
      frames = data.frames or {}
    end
  end

  -- keep every user card (stickies, images, deleted-section md cards) as-is
  local cards = {}
  for _, c in ipairs(existing_cards) do
    cards[#cards + 1] = c
  end

  -- append NEW sections only, in a fresh column right of everything
  local max_x = 0
  for _, c in ipairs(cards) do max_x = math.max(max_x, c.x or 0) end
  local col_w = 300
  local cx = max_x + col_w + 80
  local next_id = #cards
  for _, dir in ipairs(config.plugins.kbgen.dirs) do
    local lines = read_lines(root .. "/" .. dir .. "/README.md")
    if lines then
      local y = 40
      local n_in_col = 0
      for _, l in ipairs(lines) do
        local hashes, title = l:match("^(#+)%s+(.-)%s*$")
        if hashes and #hashes >= 2 then
          local file = dir .. "/README.md"
          local heading = string.rep("#", #hashes) .. " " .. title
          if not by_section[file .. "\t" .. heading] then
            next_id = next_id + 1
            cards[#cards + 1] = {
              id = "k" .. tostring(next_id),
              type = "md", file = file, heading = heading,
              x = cx, y = y,
            }
            y = y + 200
            n_in_col = n_in_col + 1
          end
        end
      end
      if n_in_col > 0 then cx = cx + col_w + 60 end
    end
  end
  local parts = {
    "{",
    '  "cards": ' .. json_encode_value(cards) .. ",",
    '  "arrows": ' .. json_encode_value(arrows) .. ",",
    '  "frames": ' .. json_encode_value(frames),
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
      gen_canvas(root, root .. "/" .. config.plugins.kbgen.canvas_file))
    if mf and cf then
      core.log("kbgen: 已生成 %s / %s (改各目录 README.md 后可重新生成)",
        config.plugins.kbgen.mind_file, config.plugins.kbgen.canvas_file)
    else
      core.log("kbgen: 写入失败 (项目目录只读?)")
    end
  end,
})

keymap.add { ["ctrl+shift+k"] = "kbgen:generate" }
