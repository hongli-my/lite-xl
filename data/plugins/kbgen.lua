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
local common = require "core.common"
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

---------------------------------------------------------------------
-- 驾驶舱 canvas: 思维导图式树形布局 + 增量合并
--   * 结构: 中心根卡 → 目录卡 → 章节卡 (struct 箭头, 导图曲线渲染)
--   * 卡片键 = file+heading / dir; 已有卡位置保留
--   * 新章节沿其父目录的分支追加; 手绘箭头/便签/frame 永不丢
---------------------------------------------------------------------

local function gen_canvas(root, path, dir_override, root_text)
  -- read existing sidecar if present
  local existing_cards, arrows, frames = {}, {}, {}
  local by_section, by_dir = {}, {}
  local root_card
  local fp = io.open(path, "r")
  if fp then
    local ok, data = pcall(json_decode, fp:read("*a"))
    fp:close()
    if ok and type(data) == "table" then
      for _, c in ipairs(data.cards or {}) do
        existing_cards[#existing_cards + 1] = c
        if c.type == "md" then
          by_section[(c.file or "?") .. "\t" .. (c.heading or "?")] = c
        elseif c.type == "sticky" and c.dir then
          by_dir[c.dir] = c
        elseif c.type == "sticky" and c.is_root then
          root_card = c
        end
      end
      arrows = data.arrows or {}
      frames = data.frames or {}
    end
  end

  -- keep every user card as-is
  local cards = {}
  for _, c in ipairs(existing_cards) do
    cards[#cards + 1] = c
  end

  -- measure: char-width estimate is fine for layout (CJK ~ 1em, latin ~ 0.55em)
  local EM = 16
  local function est_w(text) return #text * EM * 0.62 + 48 end
  local function est_h(n_lines) return n_lines * EM + 26 end

  -- 1) collect the section tree from dir READMEs (dir_override scopes it:
  --    {} = the project root README; nil = the configured dir list)
  local dirs = {}
  local scan = dir_override or config.plugins.kbgen.dirs
  for _, dir in ipairs(scan) do
    local lines = read_lines(root .. "/" .. dir .. "/README.md")
    if lines then
      local sections = {}
      for _, l in ipairs(lines) do
        local hashes, title = l:match("^(#+)%s+(.-)%s*$")
        if hashes and #hashes >= 2 then
          sections[#sections + 1] = {
            file = dir .. "/README.md",
            heading = string.rep("#", #hashes) .. " " .. title,
            title = title,
            links = {},
          }
        elseif #sections > 0 and l:match("^%s*-%s+") then
          local s = sections[#sections]
          -- file links become their own cards: [label](target)
          local label, target = l:match("^%s*-%s+%[(.-)%]%((.-)%)")
          if label and target then
            s.links[#s.links + 1] = { label = label, target = target }
          end
        end
      end
      if #sections > 0 then dirs[#dirs + 1] = { dir = dir, sections = sections } end
    end
  end
  -- project-root README mode: one pseudo-dir named "" (root README itself)
  if dir_override and #dir_override == 0 then
    local lines = read_lines(root .. "/README.md")
    if lines then
      local sections = {}
      for _, l in ipairs(lines) do
        local hashes, title = l:match("^(#+)%s+(.-)%s*$")
        if hashes and #hashes >= 2 then
          sections[#sections + 1] = {
            file = "README.md",
            heading = string.rep("#", #hashes) .. " " .. title,
            title = title,
            links = {},
          }
        elseif #sections > 0 and l:match("^%s*-%s+") then
          local s = sections[#sections]
          local label, target = l:match("^%s*-%s+%[(.-)%]%((.-)%)")
          if label and target then
            s.links[#s.links + 1] = { label = label, target = target }
          end
        end
      end
      if #sections > 0 then dirs[#dirs + 1] = { dir = "", sections = sections } end
    end
  end

  -- 2) assign / create cards for the tree nodes (positions from layout below)
  local next_id = #cards
  local function new_id(prefix)
    next_id = next_id + 1
    return prefix .. tostring(next_id)
  end
  -- the mindmap root card
  if not root_card then
    root_card = { id = new_id("r"), type = "sticky", is_root = true,
      text = root_text or "📦 知识库", x = 0, y = 0 }
    cards[#cards + 1] = root_card
  end
  local struct_arrows = {}
  -- scoped mode (dir_override): no dir layer, sections hang off the root
  local scoped = dir_override ~= nil
  for _, d in ipairs(dirs) do
    local dcard
    if not scoped then
      dcard = by_dir[d.dir]
      if not dcard then
        dcard = { id = new_id("d"), type = "sticky", dir = d.dir,
          text = "📂 " .. d.dir, x = 0, y = 0 }
        cards[#cards + 1] = dcard
      end
      d.card = dcard
      struct_arrows[#struct_arrows + 1] =
        { from = root_card.id, to = dcard.id, kind = "struct" }
    end
    -- parent for sections: the dir card, or the root in scoped mode
    local parent = dcard or root_card
    d.parent = parent
    for _, s in ipairs(d.sections) do
      local key = s.file .. "\t" .. s.heading
      local scard = by_section[key]
      if not scard then
        scard = { id = new_id("k"), type = "md", file = s.file,
          heading = s.heading, x = 0, y = 0 }
        cards[#cards + 1] = scard
        by_section[key] = scard
      end
      s.card = scard
      -- compact pill: section cards only show the title now (links are cards)
      s.w = est_w(s.title)
      s.h = est_h(1)
      struct_arrows[#struct_arrows + 1] =
        { from = d.parent.id, to = scard.id, kind = "struct" }
      -- file sub-cards, one per README link, laid out horizontally
      s.link_cards = {}
      for li, lk in ipairs(s.links) do
        local lkey = s.file .. "\t" .. s.heading .. "\t" .. lk.target
        local lcard = by_section[lkey]
        if not lcard then
          lcard = { id = new_id("f"), type = "file",
            file = s.file:match("^(.*)[/\\]") .. "/" .. lk.target,
            text = lk.label, x = 0, y = 0 }
          cards[#cards + 1] = lcard
          by_section[lkey] = lcard
        end
        lcard.w = est_w(lk.label) * 0.7 + 20
        lcard.h = est_h(1)
        s.link_cards[#s.link_cards + 1] = lcard
        struct_arrows[#struct_arrows + 1] =
          { from = scard.id, to = lcard.id, kind = "struct" }
      end
    end
  end

  -- 3) classic mindmap layout, recursive: every child gets its own vertical
  --    row (siblings stack along y), each parent is centred on the mid of its
  --    children's span. Branches alternate left/right of the root.
  --    Cards the user has dragged (pinned=true) keep their position.
  local X_GAP, Y_GAP = 70, 14
  root_card.w = est_w(root_card.text)
  local root_w = root_card.w
  local H_ROW = est_h(1)

  -- subtree vertical span (with pinned children measured at their card size)
  local function span_of(d)
    local h = 0
    for _, s in ipairs(d.sections) do
      local n = math.max(#s.link_cards, 1)
      h = h + n * (H_ROW + Y_GAP)
    end
    return math.max(h - Y_GAP, H_ROW)
  end

  -- split dirs left/right by cumulative span (balanced halves)
  local total = 0
  for _, d in ipairs(dirs) do total = total + span_of(d) + Y_GAP * 3 end
  local half, acc = total / 2, 0
  for _, d in ipairs(dirs) do
    d.side = acc < half and "right" or "left"
    acc = acc + span_of(d) + Y_GAP * 3
  end

  -- recursive placement per side
  local cursor = { right = 0, left = 0 }
  local extent = { right = 0, left = 0 }
  for _, d in ipairs(dirs) do
    local side = d.side
    local card = d.card
    if card then
      card.w = est_w(card.text)
    end
    local dir_w = card and card.w or 0
    local top = cursor[side]
    -- dir subtree: sections stack; dir card centers on the subtree mid
    local span = span_of(d)
    if card and not card.pinned then
      card.x = side == "right" and (root_w + X_GAP) or (-X_GAP - dir_w)
      card.y = top + span / 2 - H_ROW / 2
    end
    local parent_x = card and card.x or 0
    local sy = top
    for _, s in ipairs(d.sections) do
      s.card.w = math.max(est_w(s.title), 110)
      -- section subtree: its file cards stack vertically; section centers mid
      local n = math.max(#s.link_cards, 1)
      local s_span = n * (H_ROW + Y_GAP) - Y_GAP
      if not s.card.pinned then
        if side == "right" then
          s.card.x = parent_x + dir_w + X_GAP
        else
          s.card.x = parent_x - X_GAP - s.card.w
        end
        s.card.y = sy + s_span / 2 - H_ROW / 2
      end
      -- file cards: each on its own row (classic mindmap leaves)
      local fy = sy
      for _, lcard in ipairs(s.link_cards) do
        if not lcard.pinned then
          if side == "right" then
            lcard.x = s.card.x + s.card.w + X_GAP * 0.6
          else
            lcard.x = s.card.x - X_GAP * 0.6 - lcard.w
          end
          lcard.y = fy
        end
        fy = fy + H_ROW + Y_GAP
      end
      sy = sy + s_span + Y_GAP
    end
    cursor[side] = top + span + Y_GAP * 3
    extent[side] = cursor[side]
  end
  if not root_card.pinned then
    root_card.x = 0
    root_card.y = math.max(extent.right, extent.left) / 2 - H_ROW / 2
  end

  -- 4) user-drawn arrows (no kind) are preserved; struct rebuilt
  local final_arrows = {}
  for _, a in ipairs(arrows) do
    if not a.kind then final_arrows[#final_arrows + 1] = a end
  end
  for _, a in ipairs(struct_arrows) do
    final_arrows[#final_arrows + 1] = a
  end

  local parts = {
    "{",
    '  "cards": ' .. json_encode_value(cards) .. ",",
    '  "arrows": ' .. json_encode_value(final_arrows) .. ",",
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

  -- generate a dashboard scoped to one directory (treeview right-click):
  -- that dir's README becomes the whole tree
  ["kbgen:generate-dir"] = function(dir_path)
    -- called from the treeview menu: pick up the hovered dir
    if not dir_path then
      local tv = package.loaded["plugins.treeview"]
      dir_path = tv and tv.hovered_item and tv.hovered_item.abs_filename
    end
    local root = core.root_project() and core.root_project().path
    if not root or not dir_path then return end
    local rel = dir_path:sub(#root + 1):gsub("^" .. PATHSEP, "")
    if rel == "" then rel = "." end
    local name = rel == "." and (root:match("[^/\\]+$") or "root")
      or rel:match("[^/\\]+$")
    -- "." means the project root README itself
    local dir_list = rel == "." and {} or { rel }
    local out = (rel == "." and "" or rel .. "/") .. "驾驶舱-" .. name .. ".canvas"
    local ok = write_file(root .. "/" .. out,
      gen_canvas(root, root .. "/" .. out, dir_list, "📦 " .. name))
    if ok then
      core.log("kbgen: 已生成 %s", out)
    else
      core.log("kbgen: 写入失败")
    end
  end,
})

-- no global hotkey: generation lives in the treeview context menu
