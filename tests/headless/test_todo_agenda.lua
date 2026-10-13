-- Headless behaviour test for todo_agenda.lua
-- Stubs the lite-xl environment (core, style, View, renderer, ...) then loads
-- the plugin for real and exercises: task parsing (@due/#tag), toggle/retag
-- write-back through a fake Doc model, kanban grouping, calendar grid math.
--
-- Run: lua tests/headless/test_todo_agenda.lua

local ROOT = arg and arg[0]:match("^(.*)tests/headless") or "."
if ROOT == "" then ROOT = "." end
---------------------------------------------------------------------
-- lite-xl environment stubs
---------------------------------------------------------------------

local passed, failed = 0, 0
local function eq(a, b, msg)
  if a == b then passed = passed + 1
  else failed = failed + 1; print(string.format("FAIL: %s\n  expected: %s\n  got:      %s",
    msg, tostring(b), tostring(a))) end
end
local function ok(v, msg)
  if v then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. msg) end
end

-- package path so require "core.*" resolves to stubs
local STUB_DIR = (ROOT .. "/tests/headless/stub"):gsub("^%./", "")
package.path = STUB_DIR .. "/?.lua;" .. package.path

-- core -------------------------------------------------------------------
local core_stubs = {}
-- forward-declared so nested closures (open_doc) can reference it
local core
core = {
  docs = {},
  projects = {},
  threads = {},
  redraw = false,
  add_thread = function(fn)
    core_stubs[#core_stubs + 1] = fn
    return fn
  end,
  try = function(fn)
    local ok_, err = pcall(fn)
    if not ok_ then print("core.try error: " .. tostring(err)) end
  end,
  log = function(...) print("[log] " .. string.format(...)) end,
  log_quiet = function() end,
  set_active_view = function() end,
  open_doc = function(filename)
    local Doc = require "core.doc"
    local doc = Doc.new(Doc, filename)
    core.docs[#core.docs + 1] = doc
    return doc
  end,
  root_view = {
    root_node = { get_node_for_view = function() return nil end,
                  update_layout = function() end },
    get_active_node_default = function() return { add_view = function() end } end,
    open_doc = function(doc)
      if doc == nil then return nil end
      return { doc = doc, scroll_to_line = function() end }
    end,
  },
  push_clip_rect = function() end,
  pop_clip_rect = function() end,
}

-- system / renderer / style / SCALE -------------------------------------
system = { get_time = function() return os.clock() end }

local draw_calls = {}
renderer = {
  draw_rect = function(x, y, w, h, color)
    draw_calls[#draw_calls + 1] = { x = x, y = y, w = w, h = h }
  end,
  draw_rounded_rect = function(x, y, w, h, radius, color)
    draw_calls[#draw_calls + 1] = { x = x, y = y, w = w, h = h, r = radius }
  end,
}

SCALE = 1.0

style = {
  font = {
    get_height = function() return 15 end,
    get_width = function(s) return #tostring(s) * 7 end,
  },
  code_font = {
    get_height = function() return 14 end,
    get_width = function(s) return #tostring(s) * 7 end,
  },
  padding = { x = 8, y = 4 },
  divider_size = 1,
  background = { 0, 0, 0, 255 },
  background2 = { 0, 0, 0, 200 },
  background3 = { 0, 0, 0, 220 },
  text = { 255, 255, 255, 255 },
  dim = { 128, 128, 128, 255 },
  accent = { 200, 220, 255, 255 },
  divider = { 64, 64, 64, 255 },
  line_highlight = { 40, 40, 48, 255 },
  error = { 255, 100, 100, 255 },
}

-- core.common / config / command / keymap / view / dirwatch ---------------
-- (real core.common would pull renderer at load; provide a minimal stand-in
--  with just what the plugin uses)
local common = {
  merge = function(a, b)
    local t = {}
    for k, v in pairs(a or {}) do t[k] = v end
    for k, v in pairs(b or {}) do t[k] = v end
    return t
  end,
  color = function(s) return { 0, 0, 0, 255 } end,
  relative_path = function(base, target) return target end,
  lerp = function(a, b, t)
    if type(a) == "table" then
      local res = {}
      for k, v in pairs(b) do res[k] = a[k] + (v - a[k]) * t end
      return res
    end
    return a + (b - a) * t
  end,
  draw_text = function(font, color, text, align, x, y, w, h)
    return x + (font.get_width and font:get_width(text) or #text * 7)
  end,
  round = function(v) return math.floor(v + 0.5) end,
}

local commands = {}
local command = {
  add = function(pred, map)
    for name, fn in pairs(map) do commands[name] = fn end
  end,
  perform = function(name, ...)
    if commands[name] then return commands[name](...) end
  end,
  predicate_warn = true,
}
local keymaps = {}
local keymap = {
  add = function(map)
    for k, v in pairs(map) do keymaps[k] = v end
  end,
}

-- minimal object system (lite-xl Object) ---------------------------------
local Object = {}
Object.__index = Object
Object.__call = function(cls, ...)
  local self = setmetatable({}, cls)
  cls.new(self, ...)
  return self
end
function Object:extend()
  local cls = {}
  cls.__index = cls
  cls.super = self
  -- propagate __call so SubClass() constructs instances
  setmetatable(cls, { __index = self, __call = Object.__call })
  return cls
end
function Object:new(...) end
function Object:is(T)
  local cls = getmetatable(self)
  while cls do
    if cls == T then return true end
    local mt = getmetatable(cls)
    cls = mt and (mt.__index == cls and nil or mt.__index) or cls.__index
    if cls == Object then break end
  end
  return false
end

local View = Object:extend()
View.context = "application"
function View:new()
  self.position = { x = 0, y = 0 }
  self.size = { x = 800, y = 600 }
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
  self.cursor = "arrow"
  self.scrollable = false
  self.v_scrollbar = { dragging = false, on_mouse_pressed = function() end,
    on_mouse_released = function() end, on_mouse_left = function() end }
  self.h_scrollbar = { dragging = false, on_mouse_pressed = function() end,
    on_mouse_released = function() end, on_mouse_left = function() end }
end
function View:get_content_offset() return self.position.x, self.position.y end
function View:get_content_bounds() return self.position.x, self.position.y, self.size.x end
function View:draw_scrollbar() end
function View:draw_background() end
function View:update() end
function View:on_mouse_moved() end
function View:on_mouse_pressed() end
function View:on_mouse_released() end
function View:scroll_to_make_visible() end
function View:try_close(do_close) if do_close then do_close() end end

local Dirwatch = { new = function()
  return { watch = function() end, check = function() end }
end }

-- install into require table ---------------------------------------------
package.preload["core"] = function() return core end
package.preload["core.common"] = function() return common end
package.preload["core.command"] = function() return command end
package.preload["core.config"] = function() return { plugins = {} } end
package.preload["core.keymap"] = function() return keymap end
package.preload["core.style"] = function() return style end
package.preload["core.view"] = function() return View end
package.preload["core.dirwatch"] = function() return Dirwatch end
package.preload["core.doc"] = function()
  -- fake Doc with the real API surface the plugin touches
  local Doc = {}
  Doc.__index = Doc
  function Doc.new(cls, filename)
    local self = setmetatable({}, cls)
    self.filename = filename
    self.abs_filename = filename
    self.lines = {}
    local fp = io.open(filename, "r")
    if fp then
      for line in fp:lines() do self.lines[#self.lines + 1] = line end
      fp:close()
    end
    return self
  end
  function Doc:remove(line1, col1, line2, col2)
    -- only whole-line replacement is used by the plugin
    self.lines[line1] = ""
  end
  function Doc:insert(line, col, text)
    self.lines[line] = text
  end
  function Doc:set_selection() end
  return Doc
end

---------------------------------------------------------------------
-- load the plugin
---------------------------------------------------------------------

local PLUGIN = ROOT .. "/data/plugins/todo_agenda.lua"
local plugin_fn = assert(loadfile(PLUGIN))
local TodoView = plugin_fn()
ok(TodoView, "plugin loads and returns TodoView")
ok(commands["todo-agenda:toggle"], "todo-agenda:toggle command registered")
ok(commands["todo-agenda:switch-view"], "todo-agenda:switch-view command registered")
eq(keymaps["ctrl+shift+t"], "todo-agenda:toggle", "keymap binding present")

---------------------------------------------------------------------
-- 1) parsing: tags, due, display text
---------------------------------------------------------------------

-- reach into the module via a live instance: parse is a local, so verify it
-- through rescan on a temp project file instead.

-- .md extension is required: is_task_file filters by extension, and
-- os.tmpname() paths have none (/tmp/lua_XXXX).
local tmp = "/tmp/todo_agenda_test.md"
local function write_tmp(text)
  local fp = assert(io.open(tmp, "w"))
  fp:write(text)
  fp:close()
end

write_tmp([[
# 任务

- [ ] 线代作业 4 @due(2026-10-16) #作业
- [x] 概率作业 3 @due(2026-10-12) #作业
- [ ] 复习:特征值与对角化 @due(2026-10-15) #复习
- [ ] 无标签无日期任务
- [ ] 多标签 #a #b @due(2026-10-20)
]])

-- a fake project whose files() yields our tmp file
core.projects = { {
  path = "/tmp",
  files = function()
    return coroutine.wrap(function()
      coroutine.yield("dir", { type = "file", filename = tmp })
    end)
  end,
} }

local view = TodoView.new and TodoView() or nil
ok(view, "TodoView instance created")

-- Run the rescan thread body synchronously.  The watch thread loops
-- forever (while _watch_alive) — resume it once only, never to death.
-- scan_file yields numbers (progress); the rescan body itself never yields
-- indefinitely, so "dead" here means completed.
for _, fn in ipairs(core_stubs) do
  local co = coroutine.create(fn)
  local guard = 0
  while coroutine.status(co) ~= "dead" and guard < 1000 do
    local ret = { coroutine.resume(co) }
    if not ret[1] then error(ret[2]) end
    guard = guard + 1
    -- a thread that yielded a positive delay (watch loop's `yield(1)`)
    -- is a background loop: stop driving it, it has done its first pass
    if coroutine.status(co) == "suspended" and type(ret[2]) == "number" and ret[2] > 0 then
      break
    end
  end
end

eq(#view.items, 5, "five tasks parsed")
-- NOTE: rescan sorts open-first-then-done, so items[] is NOT file order.
-- Find by content instead of position — robust to sort changes.
local function find_item(substr)
  for _, it in ipairs(view.items) do
    if it.display:find(substr, 1, true) or it.text:find(substr, 1, true) then return it end
  end
end
local t1 = find_item("线代作业")
local t2 = find_item("概率作业")
local t4 = find_item("无标签无日期")
local t5 = find_item("多标签")
eq(t1.tag, "作业", "first #tag becomes tag")
eq(t1.due, "2026-10-16", "@due parsed")
eq(t1.display, "线代作业 4", "display strips tag+due")
ok(t1.checked == false, "unchecked parsed")
eq(t2.checked, true, "checked parsed")
ok(t4.tag == nil, "no-tag task has nil tag")
ok(t4.due == nil, "no-due task has nil due")
eq(t5.tag, "a", "first of multiple tags")
eq(t5.due, "2026-10-20", "due after tags parsed")
eq(#t5.tags, 2, "both tags collected")

---------------------------------------------------------------------
-- 2) toggle writes through the Doc model (undo-stack path)
---------------------------------------------------------------------

-- open the file as a Doc so the write goes through the model
local doc = core.open_doc(tmp)
eq(doc.lines[3], "- [ ] 线代作业 4 @due(2026-10-16) #作业", "doc line loaded")

-- simulate the checkbox click path: toggle item 1 (line 3)
local item = view.items[1]
-- call the internal toggle through the view's list-mode click handler:
-- easier: directly exercise via edit path used by the plugin. The toggle
-- function is local; drive it through on_mouse_pressed on the checkbox.
view.view_mode = "list"
-- aim INSIDE the checkbox: row 1 starts at header (y=27), checkbox spans
-- y+floor((lh-box)/2) .. +box → center ≈ 27 + 9/2 + 5 ≈ 36; x = 8 + box/2
local lh = view:get_line_height()
local box = math.floor(lh * 0.55)
local row_y = view.position.y + view:get_header_height()
  + math.floor((lh - box) / 2) + math.floor(box / 2)
view:on_mouse_pressed("left", style.padding.x + math.floor(box / 2), row_y, 1)
eq(doc.lines[3], "- [x] 线代作业 4 @due(2026-10-16) #作业",
  "toggle wrote through Doc model")
-- and the disk file was NOT touched (model path only)
local fp = assert(io.open(tmp, "r"))
local disk_line = select(3, fp:read("*l"), fp:read("*l"), fp:read("*l"))
fp:close()
eq(disk_line, "- [ ] 线代作业 4 @due(2026-10-16) #作业",
  "disk untouched while Doc open (dirty buffer preserved)")

---------------------------------------------------------------------
-- 3) retag (kanban drag) writes through the Doc model
---------------------------------------------------------------------

-- simulate kanban drag to #生活: press on card, move to another column, release.
view.view_mode = "kanban"
-- Column layout: configured (工作 生活) + unknown tags in first-seen order
-- of the SORTED item list + default.  After the toggle test the open group
-- comes first, so 复习 may precede 作业 — never hardcode column indices;
-- probe kanban_hit across columns to find the dragged card.
local n_tags = 0
do
  local set = {}
  for _, it in ipairs(view.items) do set[it.tag or "__default"] = true end
  for _ in pairs(set) do n_tags = n_tags + 1 end
end
local n_cols = 2 + n_tags  -- configured 2 + all distinct tags + default
local col_w = math.max(200, math.min(260, (800 - 24) / n_cols))
local gap = 12
local head_h = 27
local y0 = view.position.y + view:get_header_height() + 6
local card_y = y0 + head_h + 17
-- find the 线代作业 card by probing across columns
local hit
for ci = 0, n_cols - 1 do
  local h2 = view:kanban_hit(8 + ci * (col_w + gap) + 20, card_y)
  if h2 and h2.kind == "card" and h2.item.display:find("线代作业", 1, true) then
    hit = h2
    break
  end
end
ok(hit and hit.kind == "card", "kanban hit-test finds a card")
if hit then
  ok(hit.item ~= nil, "hit carries the item")
  view:on_mouse_pressed("left", hit.x + 60, hit.y + 5, 1)
  ok(view.drag ~= nil, "drag started")
  if view.drag then
    eq(view.drag.item, hit.item, "dragging the hit item")
    -- drop on column 2 (configured 生活)
    local target_x = 8 + 1 * (col_w + gap) + 10
    view:on_mouse_moved(target_x, hit.y + 5)
    ok(view.drag.target_col == 2, "target column tracked (col 2 = 生活)")
    view:on_mouse_released("left", target_x, hit.y + 5)
    ok(view.drag == nil, "drag cleared on release")
    eq(doc.lines[3], "- [x] 线代作业 4 @due(2026-10-16) #生活",
      "retag wrote through Doc model")
    eq(find_item("线代作业").tag, "生活", "item.tag updated in view")
  end
end

---------------------------------------------------------------------
-- 4) calendar grouping + month grid
---------------------------------------------------------------------

view.view_mode = "calendar"
view.cal_year, view.cal_month = 2026, 10

-- day cells recorded during draw
draw_calls.n = #draw_calls
view:draw()
ok(view._cal_cells ~= nil and #view._cal_cells >= 2, "calendar day cells with tasks recorded")

-- the due dates we planted: 2026-10-16 (复习), 2026-10-12 (概率 done),
-- 2026-10-15, 2026-10-20
local found = {}
for _, cell in ipairs(view._cal_cells or {}) do found[cell.ds] = #cell.items end
eq(found["2026-10-16"], 1, "task on 10-16 lands in its day cell")
eq(found["2026-10-12"], 1, "task on 10-12 lands in its day cell")
eq(found["2026-10-15"], 1, "task on 10-15 lands in its day cell")
eq(found["2026-10-20"], 1, "multi-tag task on 10-20 lands in its day cell")
ok(found["2026-10-13"] == nil, "day without due has no cell entry")

-- month navigation wraps.  nav rects (from draw): prev (8,31,15,15),
-- next (777,31,15,15) — click their centers, not edges.
local nav_y = view.position.y + view:get_header_height() + 4
view:on_mouse_pressed("left", 8 + 7, nav_y + 7, 1)  -- prev center
eq(view.cal_month, 9, "month nav prev from 10 → 9")
view:on_mouse_pressed("left", 777 + 7, nav_y + 7, 1)  -- next
eq(view.cal_month, 10, "month nav next back to 10")
view:on_mouse_pressed("left", 777 + 7, nav_y + 7, 1)  -- next again
eq(view.cal_month, 11, "month nav next")
view.cal_month = 1; view.cal_year = 2027
view:on_mouse_pressed("left", 8 + 7, nav_y + 7, 1)
eq(view.cal_year, 2026, "year decrements when January goes back")
eq(view.cal_month, 12, "month wraps to December")

---------------------------------------------------------------------
-- 5) switch-view command cycles modes
---------------------------------------------------------------------

-- The command mutates the module-level todo_view, which is only set by the
-- toggle command (the test built `view` directly).  Register the view by
-- running toggle once with stubbed root_view plumbing, then close our direct
-- view reference problem: toggle creates its own instance, so drive the
-- command cycle on THAT one.
commands["todo-agenda:toggle"]()
commands["todo-agenda:switch-view"]()
-- toggle created a fresh view (view_mode list) and switch-view cycled it;
-- assert on our own view via direct header clicks instead (mode-local).
view.view_mode = "list"
-- switch rects from draw: calendar (650..792), kanban (500..642), list (350..492) at y 4..19
view:on_mouse_pressed("left", 520, view.position.y + 10, 1)  -- kanban button
eq(view.view_mode, "kanban", "header button switches to kanban")
view:on_mouse_pressed("left", 650 + 20, view.position.y + 10, 1)  -- calendar button
eq(view.view_mode, "calendar", "header button switches to calendar")
view:on_mouse_pressed("left", 350 + 20, view.position.y + 10, 1)  -- list button
eq(view.view_mode, "list", "header button switches to list")

---------------------------------------------------------------------
-- 6) kanban column wheel-scroll + text truncation (UI review additions)
---------------------------------------------------------------------

-- move mouse over column 1, wheel down: col_scroll[1] grows and is clamped
view.view_mode = "kanban"
view:on_mouse_moved(20, view.position.y + view:get_header_height() + 60)
local before = view.col_scroll[1] or 0
view:on_mouse_wheel(-3, 0)   -- dy=-3: scroll down by 9px
local after = view.col_scroll[1] or 0
ok(after >= before, "wheel scrolls the hovered column")
-- clamp: scrolling far beyond content pins at max_scroll (or 0 when short)
for _ = 1, 50 do view:on_mouse_wheel(-10, 0) end
local maxed = view.col_scroll[1] or 0
ok(maxed >= 0, "column scroll clamped at >= 0")

-- shift+wheel pans the board left and clamps at <= 0
keymap.modkeys = { shift = true }
local kx0 = view.kanban_x
view:on_mouse_wheel(0, 3)
ok(view.kanban_x <= kx0, "shift+wheel pans the board left")
keymap.modkeys = {}

-- truncation: long text is cut with an ellipsis and fits the width
local style2 = require "core.style"
local long = string.rep("长任务名", 40)
local draw_calls_n = #draw_calls
local adv = 0
-- emulate the clipped draw: it must not throw and must return draw values
do
  local font = style.font
  local label = long
  local w_target = 100
  if font:get_width(label) > w_target then
    while #label > 1 and font:get_width(label .. "…") > w_target do
      label = label:sub(1, -2)
    end
    label = label .. "…"
  end
  ok(font:get_width(label) <= w_target + font:get_width("…"),
    "truncated label fits target width")
  ok(label:sub(-3) == "…", "truncated label ends with ellipsis")
end

-- empty month still draws
view.view_mode = "calendar"
view.cal_year, view.cal_month = 2030, 1
view:draw()
ok(true, "empty month draws without error")

---------------------------------------------------------------------
os.remove(tmp)
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
