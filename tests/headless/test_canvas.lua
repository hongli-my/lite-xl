-- Headless behaviour test for canvas.lua (CanvasView + MindView + json)
-- Run: lua tests/headless/test_canvas.lua

local ROOT = arg and arg[0]:match("^(.*)tests/headless") or "."
if ROOT == "" then ROOT = "." end
local PLUGIN = ROOT .. "/data/plugins/canvas.lua"

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

-- ---------------- lite-xl stubs (same shape as test_todo_agenda) ----------
local core_stubs = {}
local core
core = {
  docs = {}, projects = {}, threads = {}, redraw = false,
  add_thread = function(fn) core_stubs[#core_stubs + 1] = fn return fn end,
  try = function(fn) local ok_, err = pcall(fn) if not ok_ then print("core.try: " .. tostring(err)) end end,
  log = function(...) print("[log] " .. string.format(...)) end,
  log_quiet = function() end,
  set_active_view = function() end,
  open_doc = function(filename)
    local Doc = require "core.doc"
    local doc = Doc(filename)
    core.docs[#core.docs + 1] = doc
    return doc
  end,
  root_view = {
    root_node = { get_node_for_view = function() return nil end,
      update_layout = function() end,
      get_children = function() return {} end },
    get_active_node_default = function() return { add_view = function() end } end,
    open_doc = function(doc) return { doc = doc, scroll_to_line = function() end } end,
    project_directory = "/tmp",
  },
  active_view = nil,
  push_clip_rect = function() end,
  pop_clip_rect = function() end,
  command = { enter = function() end },
}

system = { get_time = function() return os.clock() end }

local draw_calls = {}
renderer = {
  draw_rect = function(x, y, w, h, color)
    draw_calls[#draw_calls + 1] = { x = x, y = y, w = w, h = h }
  end,
  draw_rounded_rect = function(x, y, w, h, r, color)
    draw_calls[#draw_calls + 1] = { x = x, y = y, w = w, h = h, r = r }
  end,
  draw_image = function(img, x, y, w, h)
    draw_calls[#draw_calls + 1] = { x = x, y = y, w = w, h = h, img = true }
  end,
  image = {
    load = function(path) return { get_size = function() return 400, 300 end, path = path } end,
  },
}

SCALE = 1.0

style = {
  font = { get_height = function() return 15 end,
           get_width = function(s) return #tostring(s) * 7 end },
  code_font = { get_height = function() return 14 end,
                get_width = function(s) return #tostring(s) * 7 end },
  padding = { x = 8, y = 4 },
  background = { 30, 31, 34, 255 },
  background2 = { 40, 41, 45, 255 },
  background3 = { 45, 46, 50, 255 },
  text = { 212, 212, 212, 255 },
  dim = { 128, 128, 128, 255 },
  accent = { 150, 200, 255, 255 },
  good = { 140, 220, 130, 255 },
  divider = { 64, 64, 64, 255 },
  line_highlight = { 40, 40, 48, 255 },
  error = { 255, 100, 100, 255 },
}

local common = {
  merge = function(a, b)
    local t = {}
    for k, v in pairs(a or {}) do t[k] = v end
    for k, v in pairs(b or {}) do t[k] = v end
    return t
  end,
  lerp = function(a, b, t)
    if type(a) == "table" then
      local res = {}
      for k, v in pairs(b) do
        if type(v) == "number" and type(a[k]) == "number" then
          res[k] = a[k] + (v - a[k]) * t
        end
      end
      return res
    end
    return a + (b - a) * t
  end,
  color = function(s)
    local r, g, b, a = s:match("^#(%x%x)(%x%x)(%x%x)(%x?%x?)$")
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16),
           a and tonumber(a, 16) or 255
  end,
  relative_path = function(base, target) return target end,
  draw_text = function(font, color, text, align, x, y, w, h)
    return x + (font.get_width and font:get_width(text) or #tostring(text) * 7)
  end,
}

local commands = {}
local command = {
  add = function(pred, map) for name, fn in pairs(map) do commands[name] = fn end end,
  perform = function(name, ...) if commands[name] then return commands[name](...) end end,
}
local keymaps = {}
local keymap = { add = function(map) for k, v in pairs(map) do keymaps[k] = v end end }

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
  return setmetatable(cls, { __index = self, __call = Object.__call })
end
function Object:new() end

local View = Object:extend()
function View:new()
  self.position = { x = 0, y = 0 }
  self.size = { x = 800, y = 600 }
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
  self.cursor = "arrow"
end
function View:draw_background() end
function View:on_mouse_moved() end
function View:on_mouse_pressed() end
function View:on_mouse_released() end
function View:on_mouse_wheel() end
function View:try_close(do_close) if do_close then do_close() end end

local Doc = {}
Doc.__index = Doc
setmetatable(Doc, { __call = function(cls, filename)
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
end })
function Doc.new(cls, filename) return Doc(filename) end
function Doc:on_text_change() end
function Doc:insert(l, c, t) self.lines[l] = t end
function Doc:remove() end
function Doc:set_selection() end

package.preload["core"] = function() return core end
package.preload["core.common"] = function() return common end
package.preload["core.command"] = function() return command end
package.preload["core.config"] = function() return { plugins = {} } end
package.preload["core.keymap"] = function() return keymap end
package.preload["core.style"] = function() return style end
package.preload["core.view"] = function() return View end
package.preload["core.doc"] = function() return Doc end
package.preload["core.rootview"] = function()
  return { open_doc = function() end }
end
package.preload["core.dirwatch"] = function() return { new = function() return {} end } end
package.preload["plugins.treeview"] = function()
  return { on_context_menu = function() end }
end

-- ---------------- load plugin ------------------------------------------------
local plugin = assert(dofile(PLUGIN))
local CanvasView, MindView, json = plugin.CanvasView, plugin.MindView, plugin.json
ok(CanvasView and MindView and json, "plugin exports CanvasView/MindView/json")
ok(commands["canvas:open"], "canvas:open registered")
ok(commands["mindmap:open"], "mindmap:open registered")
ok(keymaps["ctrl+shift+e"] == nil,
  "mindmap has NO global hotkey (treeview menu only)")

-- ---------------- json round-trip --------------------------------------------
local doc1 = {
  cards = {
    { id = "c1", type = "sticky", x = 10, y = 20, text = "想法\n第二行" },
    { id = "c2", type = "md", file = "notes.md", heading = "## M2", x = 300, y = 40 },
    { id = "c3", type = "image", path = "./a b.png", caption = "参考", x = 600, y = 400 },
  },
  arrows = { { from = "c1", to = "c2" } },
  frames = { { id = "f1", x = 0, y = 0, w = 400, h = 300, label = "Frame 1" } },
}
local enc = json.encode(doc1)
local dec = json.decode(enc)
eq(#dec.cards, 3, "json round-trip: 3 cards")
eq(dec.cards[1].text, "想法\n第二行", "json round-trip: multiline text")
eq(dec.cards[3].path, "./a b.png", "json round-trip: space in path")
eq(dec.frames[1].label, "Frame 1", "json round-trip: frame label")
eq(dec.arrows[1].to, "c2", "json round-trip: arrow")
eq(dec.cards[2].heading, "## M2", "json round-trip: heading")
-- CJK + escapes
local cjk = json.decode(json.encode({ s = "复习导图 \"引号\" 反斜杠\\" }))
eq(cjk.s, "复习导图 \"引号\" 反斜杠\\", "json round-trip: CJK + quotes + backslash")

-- ---------------- sidecar load/save ------------------------------------------
local sidecar = "/tmp/test_canvas.canvas"
do
  local fp = assert(io.open(sidecar, "w"))
  fp:write(enc, "\n")
  fp:close()
end
local cv = CanvasView(sidecar)
eq(#cv.card_order, 3, "sidecar loads 3 cards")
ok(cv.cards["c1"] ~= nil, "cards indexed by id")
eq(#cv.arrows, 1, "arrows loaded")
eq(#cv.frames, 1, "frames loaded")

-- drag a card: press at its screen pos, move, release -> sidecar updated
local c1 = cv.cards["c1"]
local w1, h1 = cv:card_geometry(c1)
local sx = c1.x * cv.cam.z + cv.cam.x + 5
local sy = c1.y * cv.cam.z + cv.cam.y + 5
cv:on_mouse_pressed("left", sx, sy, 1)
ok(cv.drag and cv.drag.kind == "card", "card drag started")
cv:on_mouse_moved(sx + 60, sy + 30)
cv:on_mouse_released("left", sx + 60, sy + 30)
eq(c1.x, 10 + 60 / cv.cam.z, 10 + 60 / cv.cam.z, "drag moved card (dummy eq)")
ok(math.abs(c1.x - (10 + 60 / cv.cam.z)) < 1e-9, "drag moved card by 60/z px")
-- sidecar persisted?
local fp = io.open(sidecar, "r")
local persisted = fp and fp:read("*a") or ""
fp:close()
local pdec = json.decode(persisted)
local p_c1 = nil
for _, c in ipairs(pdec.cards) do if c.id == "c1" then p_c1 = c break end end
ok(p_c1 and math.abs(p_c1.x - c1.x) < 1e-9, "drag persisted to sidecar")

-- pan: press empty space, move
local cam_x0 = cv.cam.x
cv:on_mouse_pressed("left", 100, 550, 1)
ok(cv.drag and cv.drag.kind == "pan", "empty press starts pan")
cv:on_mouse_moved(60, 520)
cv:on_mouse_released("left", 60, 520)
eq(cv.cam.x, cam_x0 - 40, "pan moved camera")

-- zoom toward cursor
local z0 = cv.cam.z
cv._mouse_x, cv._mouse_y = 400, 300
cv:on_mouse_wheel(1, 0)
eq(cv.cam.z, z0 * 1.12, "wheel zooms in")

-- double-click empty space creates a sticky and persists it
local n_cards = #cv.card_order
cv:on_mouse_pressed("left", 500, 350, 2)
eq(#cv.card_order, n_cards + 1, "double-click adds a sticky")
fp = io.open(sidecar, "r")
local after_new = json.decode(fp:read("*a"))
fp:close()
eq(#after_new.cards, n_cards + 1, "new sticky persisted")

-- md card refresh reads the outline under its heading
local mdfile = "/tmp/test_canvas_md.md"
do
  local fp2 = assert(io.open(mdfile, "w"))
  fp2:write([[
# 项目

## M2 进度

- [卡片拖拽](docs/drag.md)
- 箭头连接
- Frame 放映

## M3 协作

- Yjs 接入
]])
  fp2:close()
end
local cv2 = CanvasView("/tmp/unused.canvas")
local card = { id = "m1", type = "md", file = mdfile, heading = "## M2 进度", x = 0, y = 0 }
cv2.cards["m1"] = card
cv2.card_order[1] = "m1"
cv2:refresh_md_card(card)
eq(card._md_lines[1], "## M2 进度", "md card heading kept")
eq(card._md_lines[2], "▸ 卡片拖拽", "md link bullet shown with marker")
eq(card._links[2], "docs/drag.md", "md link target extracted")
eq(card._links[3], nil, "plain bullet has no link")
eq(card._md_lines[3], "箭头连接", "md card second bullet")
eq(card._md_lines[4], "Frame 放映", "md card third bullet")
-- heading scope ends at M3
local found_m3 = false
for _, l in ipairs(card._md_lines) do
  if l:find("Yjs", 1, true) then found_m3 = true end
end
ok(not found_m3, "md card stops at next heading of same level")
-- collapse: geometry shrinks to the heading strip only
local w_open, h_open = cv2:card_geometry(card)
card.collapsed = true
local w_col, h_col = cv2:card_geometry(card)
ok(h_col < h_open, "collapsed card is shorter")
card.collapsed = false

-- ---------------- mindmap ----------------------------------------------------
local mindfile = "/tmp/test_mind.md"
do
  local fp3 = assert(io.open(mindfile, "w"))
  fp3:write([[
# 复习导图

- 特征值
  - 定义 Av = λv
  - 求法
- 对角化
  - 条件
]])
  fp3:close()
end
local mv = MindView(mindfile)
local leaves = 0
for _, n in ipairs(mv.nodes) do
  if #n.children == 0 then leaves = leaves + 1 end
end
eq(leaves, 3, "mindmap parsed 3 leaves")
-- centering runs on first draw (view is unsized at construction time)
ok(not mv._fitted, "not fitted before any draw")
mv:draw()
ok(mv._fitted, "fitted on first draw")
local tw_, th_ = mv._tree_w, mv._tree_h
local z_ = math.min(1.0, (mv.size.x - 48) / tw_, (mv.size.y - 48) / th_)
z_ = math.max(z_, 0.25)
ok(math.abs(mv.cam.z - z_) < 1e-9, "fit zoom matches tree size")
ok(math.abs(mv.cam.x - (mv.size.x - tw_ * z_) / 2) < 1e-9, "tree centred horizontally")
ok(math.abs(mv.cam.y - (mv.size.y - th_ * z_) / 2) < 1e-9, "tree centred vertically")
-- leaf x positions grow with depth; parents centred over children
local av = mv.root.children[1]
local c1_, c2_ = av.children[1], av.children[2]
ok(math.abs(av.y - (c1_.y + c2_.y) / 2) < 1e-9, "parent centred between children")
ok(c1_.x > av.x, "child placed to the right of parent")
-- node line numbers map to the source file
local def = nil
for _, n in ipairs(mv.nodes) do
  if n.text == "定义 Av = λv" then def = n break end
end
ok(def ~= nil, "leaf node found")
eq(def.line, 4, "node carries source line number")

-- click a node: jumps (open_doc called, selection set)
local jumped = {}
local orig_open = core.root_view.open_doc
core.root_view.open_doc = function(_, doc)
  jumped.doc = doc
  jumped.sel = {}
  doc.set_selection = function(_, l, c) jumped.sel = { l, c } end
  return { doc = doc, scroll_to_line = function() end }
end
mv.cam = { x = 0, y = 0, z = 1 }
-- hover then press on the node centre
mv:on_mouse_moved(def.x + 5, def.y + 1)
ok(mv.hover_node == def, "hover detects node")
mv:on_mouse_pressed("left", def.x + 5, def.y + 1, 1)
eq(jumped.sel[1], 4, "node click jumps to source line")
core.root_view.open_doc = orig_open

mv.hover_node = nil
-- pan + zoom in mindmap
mv:on_mouse_pressed("left", 600, 500, 1)
ok(mv.drag and mv.drag.kind == "pan", "mindmap pan started")
mv:on_mouse_moved(580, 490)
mv:on_mouse_released("left", 580, 490)
mv._mouse_x, mv._mouse_y = 400, 300
local mz0 = mv.cam.z
mv:on_mouse_wheel(-1, 0)

-- double-click a card: sticky opens the edit prompt, md card opens the file
local prompted = {}
core.command.enter = function(_, label, submit, suggest, initial)
  prompted.label = label
  prompted.initial = initial
  if label == "编辑便签" then submit("改后的便签文本") end
end
-- sticky s1 is the newly added one from the earlier double-click-on-space test
local sticky_id = cv.card_order[#cv.card_order]
local sticky = cv.cards[sticky_id]
ok(sticky.type == "sticky", "last added card is a sticky")
local ssx = sticky.x * cv.cam.z + cv.cam.x + 4
local ssy = sticky.y * cv.cam.z + cv.cam.y + 4
cv:on_mouse_pressed("left", ssx, ssy, 2)
eq(prompted.label, "编辑便签", "sticky double-click opens edit prompt")
eq(sticky.text, "改后的便签文本", "sticky text updated through prompt")
fp = io.open(sidecar, "r")
local saved_sticky = nil
for _, c in ipairs(json.decode(fp:read("*a")).cards) do
  if c.id == sticky_id then saved_sticky = c break end
end
fp:close()
eq(saved_sticky.text, "改后的便签文本", "edited sticky persisted")
-- md card double-click jumps to the heading line
local md_jump = {}
core.root_view.open_doc = function(_, doc)
  md_jump.doc = doc
  doc.set_selection = function(_, l, c) md_jump.sel = { l, c } end
  return { doc = doc, scroll_to_line = function() end }
end
local c2card = cv.cards["c2"]
local c2sx = c2card.x * cv.cam.z + cv.cam.x + 4
local c2sy = c2card.y * cv.cam.z + cv.cam.y + 4
cv:on_mouse_pressed("left", c2sx, c2sy, 2)
-- alt+drag from a card to another card creates an arrow
local n_arrows = #cv.arrows
keymap.modkeys = { alt = true }
local a_sx = sticky.x * cv.cam.z + cv.cam.x + 4
local a_sy = sticky.y * cv.cam.z + cv.cam.y + 4
cv:on_mouse_pressed("left", a_sx, a_sy, 1)
ok(cv.drag and cv.drag.kind == "arrow", "alt+drag starts arrow")
cv:on_mouse_moved(c2sx, c2sy)
cv:on_mouse_released("left", c2sx, c2sy)
eq(#cv.arrows, n_arrows + 1, "arrow committed on drop over card")
eq(cv.arrows[#cv.arrows].to, "c2", "arrow targets the dropped card")
keymap.modkeys = {}

-- draw both views without errors
cv:draw()
mv:draw()
ok(true, "views draw without errors")

os.remove(sidecar)
os.remove(mdfile)
os.remove(mindfile)
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
