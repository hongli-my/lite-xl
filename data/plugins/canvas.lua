-- mod-version:4
-- canvas: infinite whiteboard for brainstorms, mindmaps and moodboards.
--
-- A canvas is a sidecar file `<name>.canvas` (JSON) stored next to your
-- markdown files.  Cards come in three flavours:
--   * md card    - { type="md", file="tasks.md", heading="## M2" } renders
--                  the outline under that heading; double-click opens the file
--   * sticky     - { type="sticky", text="...", color="..." } quick note
--   * image      - { type="image", path="./ref.png", caption="..." }
-- plus arrows ({from=id, to=id}) and frames ({x,y,w,h,label}) that group
-- cards and later become slides (presentation mode).
--
-- Layout lives ONLY in the sidecar - dragging a card never touches your
-- markdown, so git diffs stay clean.  Open with "canvas:open" on a .canvas
-- file or from the treeview; pan with drag, zoom with the wheel, move a card
-- by dragging it, double-click empty space to add a sticky.
--
-- mindmap view: "mindmap:open" on a markdown file renders its outline
-- (nested "-" lists) as a tree; click a node to jump to that line.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Doc = require "core.doc"
local RootView = require "core.rootview"

config.plugins.canvas = common.merge({
  -- grid spacing of the background dots
  grid_size = 24,
  -- zoom limits
  min_zoom = 0.25,
  max_zoom = 2.5,
  -- default sticky colour (lerped from background)
  sticky_tint = 0.30,
}, config.plugins.canvas)

---------------------------------------------------------------------
-- JSON (minimal encoder/decoder - sidecars are flat data)
---------------------------------------------------------------------

local json = {}

local function json_escape(s)
  return (s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
      ['\r'] = '\\r', ['\t'] = '\\t' }
    return map[c] or string.format("\\u%04x", c:byte())
  end))
end

function json.encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    return string.format("%.14g", v)
  elseif t == "string" then return '"' .. json_escape(v) .. '"'
  elseif t == "table" then
    -- array?
    local n = #v
    if n > 0 or next(v) == nil then
      local parts = {}
      for i = 1, n do parts[i] = json.encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json.encode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot encode " .. t)
end

-- decoder: position-based recursive descent
local function json_decode(s)
  local pos = 1
  local function skip()
    while pos <= #s and s:find("^[%s]", pos) do pos = pos + 1 end
  end
  local function parse_value()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skip()
        local k = parse_value()
        skip()
        assert(s:sub(pos, pos) == ":", "expected ':' in object")
        pos = pos + 1
        obj[k] = parse_value()
        skip()
        local d = s:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "}" then pos = pos + 1 return obj
        else error("expected ',' or '}' in object") end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = parse_value()
        skip()
        local d = s:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "]" then pos = pos + 1 return arr
        else error("expected ',' or ']' in array") end
      end
    elseif c == '"' then
      pos = pos + 1
      local buf = {}
      while true do
        local ch = s:sub(pos, pos)
        if ch == '"' then pos = pos + 1 break end
        if ch == "\\" then
          local e = s:sub(pos + 1, pos + 1)
          local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", b = "\b", f = "\f" }
          if map[e] then buf[#buf + 1] = map[e]; pos = pos + 2
          elseif e == "u" then
            local hex = s:sub(pos + 2, pos + 5)
            local cp = tonumber(hex, 16)
            pos = pos + 6
            if cp < 0x80 then buf[#buf + 1] = string.char(cp)
            elseif cp < 0x800 then
              buf[#buf + 1] = string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
            else
              buf[#buf + 1] = string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
            end
          else buf[#buf + 1] = e; pos = pos + 2 end
        else
          buf[#buf + 1] = ch; pos = pos + 1
        end
      end
      return table.concat(buf)
    elseif s:find("^%-?%d", pos) or c == "-" then
      local num = s:match("^%-?%d+%.?%d*[eE]?%d*", pos)
      pos = pos + #num
      return tonumber(num)
    elseif s:find("^true", pos) then pos = pos + 4 return true
    elseif s:find("^false", pos) then pos = pos + 5 return false
    elseif s:find("^null", pos) then pos = pos + 4 return nil
    else error("unexpected json char at " .. pos .. ": " .. (c or "eof"))
    end
  end
  return parse_value()
end

json.decode = json_decode

---------------------------------------------------------------------
-- Sidecar model: <path>.canvas JSON
--   { cards = { {id,x,y,w?,h?,type,...} }, arrows = { {from,to} },
--     frames = { {id,x,y,w,h,label} } }
---------------------------------------------------------------------

local CanvasView = View:extend()
CanvasView.context = "session"

function CanvasView:__tostring() return "CanvasView" end

local next_id = 0
local function new_id()
  next_id = next_id + 1
  return "c" .. tostring(next_id)
end

-- colour helpers (kept consistent with todo_agenda's theme-safe approach)
local function surface_color()
  return common.lerp(style.background, style.text, 0.06)
end
local function raised_color()
  return common.lerp(style.background, style.text, 0.13)
end

local STICKY_TINTS = { 0.85, 0.55, 0.25 }  -- warm-ish steps from text colour
local function sticky_color(id)
  -- deterministic tint per card id hash: same card keeps its colour
  local h = 0
  for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000 end
  local base = STICKY_TINTS[(h % #STICKY_TINTS) + 1]
  return common.lerp(style.background, style.good or style.text, base * config.plugins.canvas.sticky_tint + 0.15)
end

function CanvasView:new(path)
  CanvasView.super.new(self)
  self.path = path            -- sidecar .canvas filename
  self.cards = {}             -- id -> card table
  self.card_order = {}        -- array of ids (z-order, last on top)
  self.arrows = {}
  self.frames = {}
  self.cam = { x = 0, y = 0, z = 1.0 }
  self.drag = nil             -- { kind="card"/"pan", ... }
  self.hover = nil            -- card id under cursor
  self._mouse_x, self._mouse_y = 0, 0
  self._fitted = false
  self:load()
end

-- Centre the card cloud in the viewport (first real draw, when sized).
function CanvasView:center_content()
  if #self.card_order == 0 or self.size.x <= 0 then return end
  local min_x, min_y = math.huge, math.huge
  local max_x, max_y = -math.huge, -math.huge
  for _, id in ipairs(self.card_order) do
    local card = self.cards[id]
    local w, h = self:card_geometry(card)
    min_x = math.min(min_x, card.x)
    min_y = math.min(min_y, card.y)
    max_x = math.max(max_x, card.x + w)
    max_y = math.max(max_y, card.y + h)
  end
  local tw, th = max_x - min_x, max_y - min_y
  local vw, vh = self.size.x, self.size.y
  local ox, oy = self.position.x, self.position.y
  local pad = 32 * SCALE
  local z = math.min(1.0, (vw - pad * 2) / tw, (vh - pad * 2) / th)
  z = math.max(z, 0.25)
  self.cam.z = z
  self.cam.x = ox + (vw - tw * z) / 2 - min_x * z
  self.cam.y = oy + (vh - th * z) / 2 - min_y * z
  self._fitted = true
end

function CanvasView:get_name()
  local name = self.path:match("([^/\\]+)%.[cC][aA][nN][vV][aA][sS]$") or self.path
  return "🎨 " .. name
end

function CanvasView:try_close(do_close)
  do_close()
end

-- Load sidecar; missing file = empty canvas (created on first save).
function CanvasView:load()
  local fp = io.open(self.path, "r")
  if not fp then return end
  local content = fp:read("*a")
  fp:close()
  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= "table" then
    core.log("canvas: 无法解析 %s(%s)", self.path, tostring(data))
    return
  end
  self.cards, self.card_order, self.arrows, self.frames = {}, {}, {}, {}
  for _, c in ipairs(data.cards or {}) do
    c.id = c.id or new_id()
    self.cards[c.id] = c
    self.card_order[#self.card_order + 1] = c.id
  end
  self.arrows = data.arrows or {}
  self.frames = data.frames or {}
end
function CanvasView:save()
  local data = { cards = {}, arrows = self.arrows, frames = self.frames }
  for _, id in ipairs(self.card_order) do
    local card = self.cards[id]
    -- strip runtime-only fields; never let cache entries hit disk
    local clean = {}
    for k, v in pairs(card) do
      if k ~= "_img" and k ~= "_aspect" and k ~= "_abs" and k ~= "_md_lines"
        and type(v) ~= "function" then
        clean[k] = v
      end
    end
    data.cards[#data.cards + 1] = clean
  end
  local fp = io.open(self.path, "w")
  if not fp then
    core.log("canvas: 无法写入 %s", self.path)
    return
  end
  fp:write(json.encode(data), "\n")
  fp:close()
end

---------------------------------------------------------------------
-- Coordinate transforms
---------------------------------------------------------------------

function CanvasView:screen_to_world(sx, sy)
  local c = self.cam
  return (sx - c.x) / c.z, (sy - c.y) / c.z
end

---------------------------------------------------------------------
-- Card geometry
---------------------------------------------------------------------

local function wrap_text(font, text, w)
  local lines = {}
  for para in (text .. "\n"):gmatch("([^\n]*)\n") do
    if para == "" then lines[#lines + 1] = "" end
    local cur = ""
    for word in para:gmatch("%S+") do
      if cur == "" then cur = word
      elseif font:get_width(cur .. " " .. word) <= w then cur = cur .. " " .. word
      else lines[#lines + 1] = cur; cur = word end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
  end
  if #lines == 0 then lines[1] = "" end
  return lines
end

-- Measure a card at its natural size (world units).
-- Returns w, h, lines (text lines to draw), title.
function CanvasView:card_geometry(card)
  local fh = style.font:get_height()
  local pad = style.padding.x
  if card.type == "file" then
    -- compact pill: label text on one line
    local w = card.w or (style.font:get_width(card.text or "?") + pad * 2)
    local h = card.h or (fh + 8)
    return w, h, { card.text }
  elseif card.type == "sticky" then
    local w = card.w or 170
    local lines = wrap_text(style.font, card.text or "", w - pad * 2)
    local h = card.h or (#lines * fh + pad * 2 + 8)
    return w, h, lines
  elseif card.type == "image" then
    local w = card.w or 180
    local h = card.h or 120
    if not card._img and card.path and renderer.image and renderer.image.load then
      local ok, img = pcall(renderer.image.load, card.path)
      if ok and img then
        card._img = img
        local iw, ih = img:get_size()
        card._aspect = ih / iw
        -- resolve relative to the sidecar's directory
        if not card.path:find("^/") then
          local dir = self.path:match("^(.*)[/\\]") or "."
          card._abs = dir .. "/" .. card.path
          local ok2, img2 = pcall(renderer.image.load, card._abs)
          if ok2 and img2 then card._img = img2 end
        end
      end
    end
    if card._img and card._aspect then
      h = w * card._aspect
    end
    return w, h + fh + 6, nil
  else -- md card
    local w = card.w or 220
    local lines = card._md_lines or {}
    -- collapsed cards show only the heading strip
    local n = card.collapsed and 1 or #lines
    local want = fh + n * (fh + 2) + pad * 2 + 6
    -- stored h is a floor (min height), content can always grow past it
    local h = math.max(card.h or 0, want)
    return w, h, lines
  end
end

-- Load the outline under a heading from the card's markdown file.
-- Only re-reads when the doc is not already open in the editor (open docs
-- are read from their live buffers each draw).
function CanvasView:refresh_md_card(card)
  if card.type ~= "md" then return end
  card._md_lines = {}
  card._links = {}
  local lines = card._md_lines
  local links = card._links
  lines[1] = card.heading or (card.file and card.file:match("[^/\\]+$")) or "md"
  local doc
  for _, d in ipairs(core.docs) do
    if d.abs_filename == card.file then doc = d break end
  end
  local in_section = false
  local depth = nil
  local count = 0
  local function feed(text)
    local level = text:match("^(#+)%s")
    if level then
      local lv = #level
      if not in_section then
        if text:find(card.heading, 1, true) then in_section = true; depth = lv end
      else
        if lv <= depth then in_section = false end
      end
    elseif in_section and count < 12 then
      local t = text:match("^%s*-%s+(.+)$") or text
      if t ~= "" then
        count = count + 1
        -- markdown link bullets: [label](target) with optional trailing note
        local label, target, note = t:match("^%[(.-)%]%((.-)%)%s*(.*)$")
        lines[#lines + 1] = label and ("▸ " .. label) or t
        -- keyed by line index so hit-testing maps row -> target directly
        links[#lines] = label and target or nil
      end
    end
  end
  if doc then
    for i = 1, #doc.lines do feed(doc.lines[i]:gsub("\n$", "")) end
  else
    -- resolve relative paths against the sidecar's directory (the project)
    local path = card.file
    if path and not path:find("^/") then
      local dir = self.path and self.path:match("^(.*)[/\\]")
      if dir then path = dir .. "/" .. path end
    end
    local fp = io.open(path, "r")
    if not fp then return end
    for text in fp:lines() do feed(text) end
    fp:close()
  end
end

-- link target from a md card line, or nil. line index matches _md_lines.
function CanvasView:card_link_at(card, line_idx)
  if card.type ~= "md" or not card._links then return nil end
  return card._links[line_idx]
end

---------------------------------------------------------------------
-- Interaction
---------------------------------------------------------------------

function CanvasView:on_mouse_moved(mx, my, ...)
  CanvasView.super.on_mouse_moved(self, mx, my, ...)
  self._mouse_x, self._mouse_y = mx, my
  if self.drag then
    if self.drag.kind == "pan" then
      self.cam.x = self.drag.cam_x + (mx - self.drag.sx)
      self.cam.y = self.drag.cam_y + (my - self.drag.sy)
    elseif self.drag.kind == "card" then
      if math.abs(mx - self.drag.sx) + math.abs(my - self.drag.sy) > 4 then
        self.drag.moved = true
        -- user-dragged cards are pinned: kbgen keeps their position on regen
        self.drag.card.pinned = true
      end
      local c = self.drag.card
      c.x = self.drag.ox + (mx - self.drag.sx) / self.cam.z
      c.y = self.drag.oy + (my - self.drag.sy) / self.cam.z
    elseif self.drag.kind == "arrow" then
      self.drag.ex, self.drag.ey = mx, my
    end
    core.redraw = true
    return
  end
  -- hover detection (top of z-order first)
  self.hover = nil
  self._hover_link = nil
  local wx, wy = self:screen_to_world(mx, my)
  for i = #self.card_order, 1, -1 do
    local card = self.cards[self.card_order[i]]
    local w, h = self:card_geometry(card)
    if wx >= card.x and wx < card.x + w and wy >= card.y and wy < card.y + h then
      self.hover = card.id
      -- md card: which row (heading strip = 1, body rows 2+) is under cursor?
      if card.type == "md" and card._md_lines then
        local fh = style.font:get_height()
        local pad = style.padding.x
        local ry = wy - card.y
        if ry < (fh + pad) then
          self._hover_link = 1  -- heading strip: collapse toggle
        elseif not card.collapsed then
          local row = math.floor((ry - pad - fh) / (fh + 2)) + 2
          if card._md_lines[row] then self._hover_link = row end
        end
      end
      break
    end
  end
  self.cursor = self.hover and "hand" or "arrow"
  core.redraw = true
end

function CanvasView:on_mouse_pressed(button, mx, my, clicks)
  if button ~= "left" then
    return CanvasView.super.on_mouse_pressed(self, button, mx, my, clicks)
  end
  local wx, wy = self:screen_to_world(mx, my)
  -- topmost card?
  for i = #self.card_order, 1, -1 do
    local card = self.cards[self.card_order[i]]
    local w, h = self:card_geometry(card)
    if wx >= card.x and wx < card.x + w and wy >= card.y and wy < card.y + h then
      if clicks == 2 then
        self:card_double_click(card)
        return true
      end
      -- alt+drag from a card: start an arrow instead of moving it
      local mod = keymap.modkeys or {}
      if mod["alt"] then
        self.drag = { kind = "arrow", from = card.id, sx = mx, sy = my }
        core.redraw = true
        return true
      end
      -- raise to top of z-order
      table.remove(self.card_order, i)
      self.card_order[#self.card_order + 1] = card.id
      self.drag = { kind = "card", card = card, sx = mx, sy = my,
        ox = card.x, oy = card.y, moved = false,
        click_row = card.type == "md" and self._hover_link or nil }
      core.redraw = true
      return true
    end
  end
  -- double-click empty space: new sticky
  if clicks == 2 then
    local card = { id = new_id(), type = "sticky", x = wx - 80, y = wy - 40,
      text = "新便签" }
    self.cards[card.id] = card
    self.card_order[#self.card_order + 1] = card.id
    self:save()
    core.redraw = true
    return true
  end
  -- otherwise: pan
  self.drag = { kind = "pan", sx = mx, sy = my, cam_x = self.cam.x, cam_y = self.cam.y }
  return true
end

function CanvasView:on_mouse_released(button, mx, my)
  if self.drag then
    if self.drag.kind == "card" then
      -- a press-release without movement is a CLICK, not a drag
      if not self.drag.moved and self.drag.click_row then
        self:card_click(self.drag.card, self.drag.click_row)
      else
        self:save()  -- layout changes persist to the sidecar only
      end
    elseif self.drag.kind == "arrow" then
      -- dropped on another card? commit the arrow
      local wx, wy = self:screen_to_world(mx, my)
      for i = #self.card_order, 1, -1 do
        local card = self.cards[self.card_order[i]]
        local w, h = self:card_geometry(card)
        if card.id ~= self.drag.from
          and wx >= card.x and wx < card.x + w and wy >= card.y and wy < card.y + h then
          self.arrows[#self.arrows + 1] = { from = self.drag.from, to = card.id }
          self:save()
          break
        end
      end
    end
    self.drag = nil
    core.redraw = true
    return
  end
  CanvasView.super.on_mouse_released(self, button, mx, my)
end

-- single click on a md card row: heading strip toggles collapse, a link
-- row opens the target document (jumping to it in the editor)
function CanvasView:card_click(card, row)
  -- file pill (kbgen): open the file it points at
  if card.type == "file" and card.file then
    local doc = core.open_doc(card.file)
    local dv = core.root_view:open_doc(doc)
    if dv and dv.scroll_to_line then dv:scroll_to_line(1, false, true) end
    return
  end
  -- directory entry card (kbgen sticky with .dir): jump to that README
  if card.type == "sticky" and card.dir then
    local doc = core.open_doc(card.dir .. "/README.md")
    core.root_view:open_doc(doc)
    return
  end
  if row == 1 then
    card.collapsed = not card.collapsed
    self:save()
    return
  end
  local target = card._links and card._links[row]
  if target then
    -- resolve relative to the card's file directory
    local dir = card.file and card.file:match("^(.*)[/\\]") or ""
    local path = target:find("^/") and target or (dir ~= "" and dir .. "/" .. target or target)
    local doc = core.open_doc(path)
    local dv = core.root_view:open_doc(doc)
    if dv and dv.scroll_to_line then dv:scroll_to_line(1, false, true) end
    core.log("canvas: 打开 %s", path)
  end
end

function CanvasView:on_mouse_wheel(dy, dx)
  local conf = config.plugins.canvas
  local mx, my = self._mouse_x, self._mouse_y
  local k = dy > 0 and 1.12 or 1 / 1.12
  local nz = math.max(conf.min_zoom, math.min(conf.max_zoom, self.cam.z * k))
  -- zoom toward the cursor
  local c = self.cam
  local ax = (mx - c.x) / c.z  -- world coords under cursor
  local ay = (my - c.y) / c.z
  c.z = nz
  c.x = mx - ax * nz
  c.y = my - ay * nz
  core.redraw = true
  return true
end

-- Card double-click (dispatched from on_mouse_pressed with clicks == 2):
-- md cards open their file at the heading; stickies edit via the command line.
function CanvasView:card_double_click(card)
  if card.type == "file" and card.file then
    local doc = core.open_doc(card.file)
    core.root_view:open_doc(doc)
    return
  end
  if card.type == "md" and card.file then
    local doc = core.open_doc(card.file)
    local dv = core.root_view:open_doc(doc)
    for li, line in ipairs(doc.lines) do
      if line:find(card.heading or "", 1, true) then
        doc:set_selection(li, 1)
        dv:scroll_to_line(li, false, true)
        break
      end
    end
  elseif card.type == "sticky" then
    core.command:enter("编辑便签", function(text)
      if text ~= "" then
        card.text = text
        self:save()
        core.redraw = true
      end
    end, nil, card.text or "")
  end
end

---------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------

function CanvasView:draw_background(...)
  -- full background (theme) - View:draw_background draws style.background
  CanvasView.super.draw_background(self, ...)
end

function CanvasView:draw()
  if not self._fitted then self:center_content() end
  self:draw_background(style.background)
  local c = self.cam

  -- dotted grid (world-anchored)
  local gs = config.plugins.canvas.grid_size * c.z
  if gs > 8 then
    local ox = c.x % gs
    local oy = c.y % gs
    local dot = 1 * SCALE
    for x = ox, self.position.x + self.size.x, gs do
      for y = oy, self.position.y + self.size.y, gs do
        renderer.draw_rect(x, y, dot, dot,
          common.lerp(style.background, style.text, 0.07))
      end
    end
  end

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  -- frames (world -> screen)
  for _, f in ipairs(self.frames) do
    local fx, fy = f.x * c.z + c.x, f.y * c.z + c.y
    local fw, fh = f.w * c.z, f.h * c.z
    renderer.draw_rounded_rect(fx, fy, fw, fh, 8 * SCALE * c.z,
      common.lerp(style.background, style.accent or style.text, 0.05))
    renderer.draw_rounded_rect(fx, fy, fw, fh, 8 * SCALE * c.z,
      common.lerp(style.background, style.accent or style.text, 0.05))
    -- dashed border: draw thin rects along the edges with gaps
    local bc = common.lerp(style.background, style.accent or style.text, 0.45)
    local seg, gap = 12 * SCALE, 6 * SCALE
    local t = 1.5 * SCALE
    local x2, y2 = fx + fw, fy + fh
    local x = fx
    while x < x2 do
      local w1 = math.min(seg, x2 - x)
      renderer.draw_rect(x, fy, w1, t, bc)
      renderer.draw_rect(x, y2 - t, w1, t, bc)
      x = x + seg + gap
    end
    local y = fy
    while y < y2 do
      local h1 = math.min(seg, y2 - y)
      renderer.draw_rect(fx, y, t, h1, bc)
      renderer.draw_rect(x2 - t, y, t, h1, bc)
      y = y + seg + gap
    end
    if f.label then
      common.draw_text(style.font, style.accent or style.text, f.label, "left",
        fx + 4, fy - style.font:get_height() - 4, fw, style.font:get_height())
    end
  end

  -- arrows between cards
  local function draw_arrow(x1, y1, x2, y2, col)
    local t = 1.5 * SCALE
    -- horizontal then vertical elbow
    local mx_ = (x1 + x2) / 2
    renderer.draw_rect(x1, y1 - t / 2, math.max(mx_ - x1, t), t, col)
    renderer.draw_rect(mx_ - t / 2, math.min(y1, y2), t, math.abs(y2 - y1) + t, col)
    -- arrowhead at (x2, y2)
    local dir = y2 >= y1 and 1 or -1
    local ah = 6 * SCALE
    renderer.draw_rect(x2 - ah, y2 - dir * ah, ah * 2, t, col)
    renderer.draw_rect(x2 - ah / 2, y2 - dir * ah, ah, t, col)
    renderer.draw_rect(x2 - ah / 2, y2 - dir * ah / 2, ah / 2 + t / 2, t, col)
  end
  -- organic mindmap curve for structural links (same L-coverage raster as
  -- MindView links). Direction-aware: curves leave the parent's right edge
  -- for right-side children and its LEFT edge for left-side children, so the
  -- balanced horizontal layout reads like a classic mindmap.
  local function draw_struct_curve(from, to, col)
    local fw, fh = self:card_geometry(from)
    local tw, th = self:card_geometry(to)
    local left_side = to.x + tw / 2 < from.x + fw / 2
    local x1, x2
    if left_side then
      x1 = from.x * c.z + c.x
      x2 = (to.x + tw) * c.z + c.x
    else
      x1 = (from.x + fw) * c.z + c.x
      x2 = to.x * c.z + c.x
    end
    local y1 = (from.y + fh / 2) * c.z + c.y
    local y2 = (to.y + th / 2) * c.z + c.y
    local z = c.z
    local t = math.max(2, 2.5 * SCALE * z)
    local half = t / 2
    local dx = x2 - x1
    local c1x = x1 + dx * 0.45
    local c2x = x2 - dx * 0.45
    local steps = 24
    local px, py = x1, y1
    for i = 1, steps do
      local s = i / steps
      local u = 1 - s
      local bx = u*u*u*x1 + 3*u*u*s*c1x + 3*u*s*s*c2x + s*s*s*x2
      local by = u*u*u*y1 + 3*u*u*s*y1 + 3*u*s*s*y2 + s*s*s*y2
      renderer.draw_rect(math.min(px, bx) - half, math.min(py, by) - half,
        math.abs(bx - px) + t, math.abs(by - py) + t, col)
      px, py = bx, by
    end
  end
  for _, a in ipairs(self.arrows) do
    local from, to = self.cards[a.from], self.cards[a.to]
    if from and to then
      if a.kind == "struct" then
        -- structural links (kbgen dir->section) as organic mindmap curves
        draw_struct_curve(from, to,
          common.lerp(style.background, style.text, 0.28))
      else
        local fw, fh = self:card_geometry(from)
        local tw, th = self:card_geometry(to)
        draw_arrow((from.x + fw / 2) * c.z + c.x, (from.y + fh / 2) * c.z + c.y,
          (to.x + tw / 2) * c.z + c.x, (to.y + th / 2) * c.z + c.y,
          common.lerp(style.background, style.accent or style.text, 0.55))
      end
    end
  end
  -- in-progress arrow drag preview
  if self.drag and self.drag.kind == "arrow" and self.drag.ex then
    local from = self.cards[self.drag.from]
    if from then
      local fw, fh = self:card_geometry(from)
      draw_arrow((from.x + fw / 2) * c.z + c.x, (from.y + fh / 2) * c.z + c.y,
        self.drag.ex, self.drag.ey,
        common.lerp(style.background, style.accent or style.text, 0.35))
    end
  end

  -- cards (bottom to top of z-order)
  for _, id in ipairs(self.card_order) do
    local card = self.cards[id]
    if card.type == "md" then self:refresh_md_card(card) end
    self:draw_card(card)
  end

  core.pop_clip_rect()

  -- zoom indicator
  local zlbl = string.format("%d%%", math.floor(self.cam.z * 100 + 0.5))
  common.draw_text(style.code_font, style.dim, zlbl, "left",
    self.position.x + style.padding.x,
    self.position.y + self.size.y - style.code_font:get_height() - style.padding.y,
    60, style.code_font:get_height())
end

local function draw_text_clipped_canvas(font, color, text, x, y, w, h)
  local label = text
  if font:get_width(label) > w and w > 4 then
    while #label > 1 and font:get_width(label .. "…") > w do
      label = label:sub(1, -2)
    end
    label = label .. "…"
  end
  return common.draw_text(font, color, label, "left", x, y, w, h)
end

function CanvasView:draw_card(card)
  local c = self.cam
  local fh = style.font:get_height()
  local pad = style.padding.x
  local w, h, lines = self:card_geometry(card)
  local x, y = card.x * c.z + c.x, card.y * c.z + c.y
  local sw, sh = w * c.z, h * c.z
  local hovered = (self.hover == card.id)
  local r = 6 * SCALE

  -- soft drop shadow under every card (offset copy, theme-safe)
  local sh_col = common.lerp(style.background, style.text, 0.06)
  renderer.draw_rounded_rect(x + 2 * SCALE, y + 3 * SCALE, sw, sh, r, sh_col)

  if card.type == "file" then
    -- compact pill with an accent dot; click opens the file
    renderer.draw_rounded_rect(x, y, sw, sh, sh / 2,
      hovered and raised_color() or surface_color())
    renderer.draw_rect(x + 5 * SCALE, y + sh / 2 - 2 * SCALE, 4 * SCALE,
      4 * SCALE,
      hovered and style.accent
        or common.lerp(style.background, style.accent or style.text, 0.6))
    draw_text_clipped_canvas(style.font, style.text, card.text or "?",
      x + 12 * SCALE, y + (sh - fh * c.z) / 2, sw - 14 * SCALE, fh * c.z)
    return
  end

  if card.type == "sticky" then
    local bg = sticky_color(card.id)
    if hovered then bg = common.lerp(bg, style.text, 0.10) end
    renderer.draw_rounded_rect(x, y, sw, sh, r, bg)
    -- left accent bar
    renderer.draw_rounded_rect(x, y + 2 * SCALE, 3 * SCALE, sh - 4 * SCALE,
      1.5 * SCALE, common.lerp(bg, style.text, 0.28))
    local fs = fh * c.z
    for li, l in ipairs(lines) do
      draw_text_clipped_canvas(style.font, style.text, l,
        x + (pad + 4) * c.z, y + (pad + (li - 1) * fh) * c.z,
        sw - (pad + 6) * c.z, fs)
    end
  elseif card.type == "image" then
    renderer.draw_rounded_rect(x, y, sw, sh, r,
      hovered and raised_color() or surface_color())
    if card._img then
      renderer.draw_image(card._img, x + 2 * SCALE, y + 2 * SCALE,
        sw - 4 * SCALE, (sh - fh - 6) * c.z - 4 * SCALE)
    else
      -- placeholder
      renderer.draw_rect(x + 2 * SCALE, y + 2 * SCALE, sw - 4 * SCALE,
        (sh - fh - 6) * c.z - 4 * SCALE, surface_color())
      common.draw_text(style.font, style.dim, "🖼 " .. (card.path or "?"),
        "center", x, y, sw, sh - fh * c.z)
    end
    if card.caption then
      draw_text_clipped_canvas(style.font, style.dim, card.caption,
        x + pad * c.z, y + sh - (fh + 2) * c.z, sw - pad * 2 * c.z, fh * c.z)
    end
  else -- md card
    renderer.draw_rounded_rect(x, y, sw, sh, r,
      hovered and raised_color() or surface_color())
    -- heading strip
    renderer.draw_rounded_rect(x, y, sw, (fh + pad) * c.z, r,
      common.lerp(style.background, style.accent or style.text, 0.20))
    -- collapse toggle in the heading strip
    local toggle = card.collapsed and "▸" or "▾"
    draw_text_clipped_canvas(style.font, style.text, toggle,
      x + pad * c.z * 0.4, y + pad * c.z * 0.5, fh * c.z, fh * c.z)
    draw_text_clipped_canvas(style.font, style.text, lines and lines[1] or "md",
      x + (pad + fh * 0.8) * c.z, y + pad * c.z * 0.5,
      sw - (pad + fh) * c.z, fh * c.z)
    if not card.collapsed then
      for li = 2, #(lines or {}) do
        local is_link = card._links and card._links[li]
        local row_y = y + (pad + fh + (li - 2) * (fh + 2)) * c.z
        -- hover feedback on clickable rows
        if is_link and self.hover == card.id
          and self._hover_link == li then
          renderer.draw_rect(x + pad * c.z, row_y - 1 * SCALE,
            sw - pad * 2 * c.z, fh * c.z + 2 * SCALE,
            common.lerp(style.background, style.accent or style.text, 0.10))
        end
        draw_text_clipped_canvas(style.font,
          is_link and style.text or style.dim, lines[li],
          x + pad * c.z * 1.5, row_y, sw - pad * 2.5 * c.z, fh * c.z)
      end
    end
  end
end


---------------------------------------------------------------------
-- mindmap view (separate View over a markdown outline)
---------------------------------------------------------------------

local MindView = View:extend()
MindView.context = "session"
function MindView:__tostring() return "MindView" end

function MindView:new(path)
  MindView.super.new(self)
  self.path = path
  self.cam = { x = 0, y = 0, z = 1.0 }
  self.drag = nil
  self._fitted = false
  self._mouse_x, self._mouse_y = 0, 0
  self:parse()
end

function MindView:get_name()
  local name = self.path:match("([^/\\]+)%.%a+$") or self.path
  return "🧠 " .. name
end

function MindView:try_close(do_close) do_close() end

-- Parse markdown outline ("- item" nesting = tree) into nodes with layout.
function MindView:parse()
  -- read from the open doc when possible (live edits show up)
  local doc
  for _, d in ipairs(core.docs) do
    if d.abs_filename == self.path then doc = d break end
  end
  local all = {}
  if doc then
    for i = 1, #doc.lines do
      all[#all + 1] = doc.lines[i]:gsub("\n$", "")
    end
  else
    local fp = io.open(self.path, "r")
    if not fp then self.nodes = {} return end
    for l in fp:lines() do all[#all + 1] = l end
    fp:close()
  end

  local root = { text = self.path:match("([^/\\]+)%.%a+$") or "导图", children = {} }
  local stack = { { node = root, depth = -1, line = 1 } }
  for lineno, line in ipairs(all) do
    local indent, text = line:match("^(%s*)-%s+(.+)$")
    if text then
      local depth = math.floor(#indent / 2)
      local node = { text = text, children = {}, line = lineno }
      while #stack > 1 and stack[#stack].depth >= depth do table.remove(stack) end
      table.insert(stack[#stack].node.children, node)
      table.insert(stack, { node = node, depth = depth, line = lineno })
    end
  end
  -- tidy tree layout: leaves left-to-right, parents centred
  local fh = style.font:get_height()
  local ygap = fh + 16
  local row = 0
  local nodes = {}
  local function layout(n, depth)
    n.depth = depth
    if #n.children == 0 then
      n.y = row * ygap
      row = row + 1
    else
      for _, ch in ipairs(n.children) do layout(ch, depth + 1) end
      n.y = (n.children[1].y + n.children[#n.children].y) / 2
    end
    n.w = style.font:get_width(n.text) + style.padding.x * 2.5
    nodes[#nodes + 1] = n
  end
  layout(root, 0)
  self.root = root
  self.nodes = nodes
  -- column layout: cumulative x per depth, breathing room after the root
  local xgap = 72
  local col_x = { 0 }
  local max_row_w = {}
  for _, n in ipairs(nodes) do
    max_row_w[n.depth] = math.max(max_row_w[n.depth] or 0, n.w)
  end
  local acc = 0
  local max_depth = 0
  for _, n in ipairs(nodes) do if n.depth > max_depth then max_depth = n.depth end end
  for d = 0, max_depth do
    col_x[d] = acc
    -- extra gap between root and first level so curves can unfold
    acc = acc + (max_row_w[d] or 0) + (d == 0 and xgap * 1.3 or xgap)
  end
  for _, n in ipairs(nodes) do n.x = col_x[n.depth] or 0 end
  -- branch colour index: first-level children get distinct colours
  for i, ch in ipairs(root.children) do
    local function tag(n) n.branch = i for _, cc in ipairs(n.children) do tag(cc) end end
    tag(ch)
  end
  -- pill half-heights extend past the leaf row extent; pad both ends
  self._tree_w = acc - xgap
  self._tree_h = math.max(row - 1, 0) * ygap + fh + 16
end

-- Centre the tree in the viewport and pick a zoom that fits it.
function MindView:center_and_fit()
  if not self._tree_w or self.size.x <= 0 then return end
  local tw, th = self._tree_w, self._tree_h
  local vw, vh = self.size.x, self.size.y
  -- drawable origin is self.position (TreeView on the left shifts us)
  local ox, oy = self.position.x, self.position.y
  local pad = 24 * SCALE
  local z = math.min(1.0, (vw - pad * 2) / tw, (vh - pad * 2) / th)
  z = math.max(z, 0.25)
  self.cam.z = z
  -- node coordinates run 0..tw / 0..th; centre that box in the drawable area
  self.cam.x = ox + (vw - tw * z) / 2
  self.cam.y = oy + (vh - th * z) / 2
  self._fitted = true
end

function MindView:on_mouse_moved(mx, my, ...)
  MindView.super.on_mouse_moved(self, mx, my, ...)
  self._mouse_x, self._mouse_y = mx, my
  if self.drag then
    if self.drag.kind == "pan" then
      self.cam.x = self.drag.cam_x + (mx - self.drag.sx)
      self.cam.y = self.drag.cam_y + (my - self.drag.sy)
    end
    core.redraw = true
    return
  end
  self.hover_node = nil
  local c = self.cam
  local fh = style.font:get_height()
  local hit_h = (fh + 12) / 2  -- half-height of the pill around its centre line
  for _, n in ipairs(self.nodes) do
    -- screen coords: same transform as draw (scale THEN offset)
    local sx, sy = n.x * c.z + c.x, n.y * c.z + c.y
    local sw, sh = n.w * c.z, (fh + 10) * c.z
    if mx >= sx and mx < sx + sw and my >= sy - hit_h and my < sy + hit_h then
      self.hover_node = n
      break
    end
  end
  self.cursor = self.hover_node and "hand" or "arrow"
  core.redraw = true
end

function MindView:on_mouse_pressed(button, mx, my, clicks)
  if button ~= "left" then
    return MindView.super.on_mouse_pressed(self, button, mx, my, clicks)
  end
  if self.hover_node then
    -- jump to the source line in the editor
    local doc
    for _, d in ipairs(core.docs) do
      if d.abs_filename == self.path then doc = d break end
    end
    if not doc then doc = core.open_doc(self.path) end
    local dv = core.root_view:open_doc(doc)
    core.root_view.root_node:update_layout()
    doc:set_selection(self.hover_node.line, 1)
    dv:scroll_to_line(self.hover_node.line, false, true)
    return true
  end
  self.drag = { kind = "pan", sx = mx, sy = my, cam_x = self.cam.x, cam_y = self.cam.y }
  return true
end

function MindView:on_mouse_released(button, mx, my)
  self.drag = nil
  MindView.super.on_mouse_released(self, button, mx, my)
end

function MindView:on_mouse_wheel(dy, dx)
  local c = self.cam
  local mx, my = self._mouse_x, self._mouse_y
  local k = dy > 0 and 1.12 or 1 / 1.12
  local nz = math.max(0.25, math.min(2.5, c.z * k))
  local ax = (mx - c.x) / c.z
  local ay = (my - c.y) / c.z
  c.z = nz
  c.x = mx - ax * nz
  c.y = my - ay * nz
  core.redraw = true
  return true
end

-- Branch palette: distinct theme hues per first-level branch.
local MIND_PALETTE = {
  "accent", "good", "warn", "modified", "error", "syntax_normal",
}
local function branch_color(n)
  local key = MIND_PALETTE[((n.branch or 1) - 1) % #MIND_PALETTE + 1]
  local col = style[key]
  if type(col) ~= "table" and style.syntax then
    col = style.syntax[key == "syntax_normal" and "normal" or "keyword"] or style.accent
  end
  return col or style.accent or style.text
end

-- Smooth organic link between parent edge and child edge.
-- Rasterised as an L-coverage rect per sample pair (covers both the x run
-- and the y run of each step): continuous at any slope, 24 rects per link.
local function draw_mind_link(x1, y1, x2, y2, color, z)
  local t = math.max(2, 2.5 * SCALE * z)
  local half = t / 2
  local dx = x2 - x1
  -- control points pull horizontally out of both ends (natural mindmap look)
  local c1x = x1 + dx * 0.45
  local c2x = x2 - dx * 0.45
  local steps = 24
  local px, py = x1, y1
  for i = 1, steps do
    local s = i / steps
    local u = 1 - s
    local bx = u*u*u*x1 + 3*u*u*s*c1x + 3*u*s*s*c2x + s*s*s*x2
    local by = u*u*u*y1 + 3*u*u*s*y1 + 3*u*s*s*y2 + s*s*s*y2
    renderer.draw_rect(math.min(px, bx) - half, math.min(py, by) - half,
      math.abs(bx - px) + t, math.abs(by - py) + t, color)
    px, py = bx, by
  end
end

function MindView:draw()
  -- first real draw: the view has its final size now, fit once
  if not self._fitted then self:center_and_fit() end
  self:draw_background(style.background)
  local c = self.cam
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local fh = style.font:get_height()

  -- links (drawn under the nodes)
  local function link(n)
    for _, ch in ipairs(n.children) do
      -- inset endpoints so the line tucks under the pill edges
      local inset = 2 * SCALE
      local x1 = (n.x + n.w) * c.z + c.x - inset
      local y1 = n.y * c.z + c.y
      local x2 = ch.x * c.z + c.x + inset
      local y2 = ch.y * c.z + c.y
      local bc = common.lerp(style.background, branch_color(ch), 0.62)
      draw_mind_link(x1, y1, x2, y2, bc, c.z)
      link(ch)
    end
  end
  link(self.root)

  -- nodes
  for _, n in ipairs(self.nodes) do
    local x, y = n.x * c.z + c.x, n.y * c.z + c.y
    local is_root = (n == self.root)
    local h = (fh + (is_root and 14 or 9)) * c.z
    local w = n.w * c.z
    local hovered = (n == self.hover_node)
    local bc = branch_color(n)
    local bg
    if is_root then
      bg = bc
    elseif hovered then
      bg = common.lerp(style.background, bc, 0.32)
    else
      bg = common.lerp(style.background, bc, 0.14)
    end
    renderer.draw_rounded_rect(x, y - h / 2, w, h, h / 2, bg)
    -- branch accent bar on the left of each node
    if not is_root then
      renderer.draw_rounded_rect(x, y - h / 2 + 2 * SCALE, 3 * SCALE, h - 4 * SCALE,
        1.5 * SCALE, common.lerp(style.background, bc, 0.75))
    end
    draw_text_clipped_canvas(style.font,
      is_root and style.background or style.text, n.text,
      x + style.padding.x * 1.25 * c.z, y - fh * c.z / 2,
      w - style.padding.x * 2.5 * c.z, fh * c.z)
  end

  core.pop_clip_rect()
  local zlbl = string.format("%d%%", math.floor(self.cam.z * 100 + 0.5))
  common.draw_text(style.code_font, style.dim, zlbl, "left",
    self.position.x + style.padding.x,
    self.position.y + self.size.y - style.code_font:get_height() - style.padding.y,
    60, style.code_font:get_height())
end

-- refresh open mindmaps when the underlying doc changes
local orig_doc_on_text_change = Doc.on_text_change
function Doc:on_text_change(type)
  if orig_doc_on_text_change then orig_doc_on_text_change(self, type) end
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if tostring(view) == "MindView" and view.path == self.abs_filename then
      view:parse()
      core.redraw = true
    end
  end
end

---------------------------------------------------------------------
-- commands
---------------------------------------------------------------------

command.add(nil, {
  ["canvas:open"] = function()
    local doc = core.active_view and core.active_view.doc
    local path
    if doc and doc.filename then
      path = doc.filename:match("^(.*)%.[mM][dD]$") .. ".canvas"
    else
      path = core.root_view.project_directory
      if not path then core.log("canvas: 需要一个打开的 md 文件或项目") return end
      path = path .. "/untitled.canvas"
    end
    local node = core.root_view:get_active_node_default()
    node:add_view(CanvasView(path))
    core.redraw = true
  end,
  -- open an existing .canvas file directly (as a view, not a JSON text doc)
  ["canvas:open-file"] = function()
    local doc = core.active_view and core.active_view.doc
    local path = doc and (doc.abs_filename or doc.filename)
    if not path or not path:match("%.canvas$") then
      core.log("canvas: 请先打开/选中一个 .canvas 文件")
      return
    end
    local node = core.root_view:get_active_node_default()
    node:add_view(CanvasView(path))
    core.redraw = true
  end,
  ["mindmap:open"] = function(path)
    -- explicit path (treeview right-click) or the active doc; the context
    -- menu may forward a non-string argument — ignore those
    if type(path) ~= "string" then path = nil end
    if not path then
      local doc = core.active_view and core.active_view.doc
      path = doc and (doc.abs_filename or doc.filename)
    end
    if not path or not path:match("%.[mM][dD]$") then
      core.log("mindmap: 请先打开一个 markdown 大纲文件")
      return
    end
    local node = core.root_view:get_active_node_default()
    node:add_view(MindView(path))
    core.redraw = true
  end,
})

-- delete the hovered/selected card (and its arrows) from the active canvas
command.add(function()
  return core.active_view and core.active_view:is(CanvasView)
end, {
  ["canvas:delete-card"] = function()
    local view = core.active_view
    if not view or not view.hover then return end
    local id = view.hover
    view.cards[id] = nil
    for i = #view.card_order, 1, -1 do
      if view.card_order[i] == id then table.remove(view.card_order, i) end
    end
    for i = #view.arrows, 1, -1 do
      local a = view.arrows[i]
      if a.from == id or a.to == id then table.remove(view.arrows, i) end
    end
    view:save()
    core.log("canvas: 已删除卡片")
    core.redraw = true
  end,
})
keymap.add({ ["cmd+backspace"] = "canvas:delete-card" })

---------------------------------------------------------------------
-- treeview right-click: open files as their views
---------------------------------------------------------------------
local TreeView = require "plugins.treeview"

local old_treeview_menu_cv = TreeView.on_context_menu
function TreeView:on_context_menu()
  local args = { old_treeview_menu_cv(self) }
  local cmds = args[1]
  if cmds then
    local item = self.hovered_item or self.selected_item
    local items = cmds.items
    if item and items then
      local entry
      if item.type == "dir" then
        -- directory: generate a scoped dashboard from its README
        entry = { text = "生成驾驶舱", icon = "\u{f0e8}",
          command = "kbgen:generate-dir" }
      elseif item.type == "file" then
        local filename = item.abs_filename or ""
        self._cv_target = filename
        if filename:match("%.canvas$") then
          entry = { text = "打开画布", icon = "\u{f009}", command = "canvas:open-treeview" }
        elseif filename:match("%.[mM][dD]$") then
          entry = { text = "思维导图", icon = "\u{f0e8}", command = "mindmap:open-treeview" }
        end
      end
      if entry then
        table.move(items, 2, #items, 3)
        items[2] = entry
      end
    end
  end
  return table.unpack(args)
end

command.add(nil, {
  ["canvas:open-treeview"] = function()
    local tv = package.loaded["plugins.treeview"]
    local path = tv and tv._cv_target
    if path then
      local node = core.root_view:get_active_node_default()
      node:add_view(CanvasView(path))
      core.redraw = true
    end
  end,
  ["mindmap:open-treeview"] = function()
    local tv = package.loaded["plugins.treeview"]
    local path = tv and tv._cv_target
    if path then command.perform("mindmap:open", path) end
  end,
})

-- opening a .canvas file from treeview / palette routes to CanvasView
-- (same pattern as imageview), so the sidecar never shows raw JSON
---------------------------------------------------------------------
local rootview_open_doc = RootView.open_doc
function RootView:open_doc(doc)
  local filename = doc and (doc.abs_filename or doc.filename) or ""
  if filename:match("%.canvas$") then
    local node = self:get_active_node_default()
    node:add_view(CanvasView(filename))
    self.root_node:update_layout()
    return
  end
  return rootview_open_doc(self, doc)
end

return { CanvasView = CanvasView, MindView = MindView, json = json }
