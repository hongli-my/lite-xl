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
  self.cam = { x = 40, y = 30, z = 0.9 }
  self.drag = nil             -- { kind="card"/"pan", ... }
  self.hover = nil            -- card id under cursor
  self._mouse_x, self._mouse_y = 0, 0
  self:load()
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
  if card.type == "sticky" then
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
    local h = card.h or (fh + #lines * (fh + 2) + pad * 2 + 6)
    return w, h, lines
  end
end

-- Load the outline under a heading from the card's markdown file.
-- Only re-reads when the doc is not already open in the editor (open docs
-- are read from their live buffers each draw).
function CanvasView:refresh_md_card(card)
  if card.type ~= "md" then return end
  card._md_lines = {}
  local lines = card._md_lines
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
        lines[#lines + 1] = t
      end
    end
  end
  if doc then
    for i = 1, #doc.lines do feed(doc.lines[i]:gsub("\n$", "")) end
  else
    local fp = io.open(card.file, "r")
    if not fp then return end
    for text in fp:lines() do feed(text) end
    fp:close()
  end
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
  local wx, wy = self:screen_to_world(mx, my)
  for i = #self.card_order, 1, -1 do
    local card = self.cards[self.card_order[i]]
    local w, h = self:card_geometry(card)
    if wx >= card.x and wx < card.x + w and wy >= card.y and wy < card.y + h then
      self.hover = card.id
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
        ox = card.x, oy = card.y }
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
      self:save()  -- layout changes persist to the sidecar only
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

  -- arrows between card centres
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
  for _, a in ipairs(self.arrows) do
    local from, to = self.cards[a.from], self.cards[a.to]
    if from and to then
      local fw, fh = self:card_geometry(from)
      local tw, th = self:card_geometry(to)
      draw_arrow((from.x + fw / 2) * c.z + c.x, (from.y + fh / 2) * c.z + c.y,
        (to.x + tw / 2) * c.z + c.x, (to.y + th / 2) * c.z + c.y,
        common.lerp(style.background, style.accent or style.text, 0.55))
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

function CanvasView:draw_card(card)
  local c = self.cam
  local fh = style.font:get_height()
  local pad = style.padding.x
  local w, h, lines = self:card_geometry(card)
  local x, y = card.x * c.z + c.x, card.y * c.z + c.y
  local sw, sh = w * c.z, h * c.z
  local hovered = (self.hover == card.id)

  if card.type == "sticky" then
    local bg = sticky_color(card.id)
    renderer.draw_rounded_rect(x, y, sw, sh, 4 * SCALE, bg)
    -- slight darker edge
    renderer.draw_rounded_rect(x, y + sh - 2 * SCALE, sw, 2 * SCALE, 1 * SCALE,
      common.lerp(bg, style.background, 0.3))
    if hovered then
      renderer.draw_rounded_rect(x, y, sw, sh, 4 * SCALE,
        common.lerp(bg, style.text, 0.15))
    end
    local fs = fh * c.z
    for li, l in ipairs(lines) do
      draw_text_clipped_canvas(style.font, style.text, l, x + pad * c.z,
        y + (pad + (li - 1) * fh) * c.z, sw - pad * 2 * c.z, fs)
    end
  elseif card.type == "image" then
    renderer.draw_rounded_rect(x, y, sw, sh, 4 * SCALE, raised_color())
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
    renderer.draw_rounded_rect(x, y, sw, sh, 4 * SCALE,
      hovered and raised_color() or surface_color())
    -- heading strip
    renderer.draw_rounded_rect(x, y, sw, fh * c.z + pad * c.z, 4 * SCALE,
      common.lerp(style.background, style.accent or style.text, 0.18))
    draw_text_clipped_canvas(style.font, style.text, lines and lines[1] or "md",
      x + pad * c.z, y + pad * c.z * 0.5, sw - pad * 2 * c.z, fh * c.z)
    for li = 2, #(lines or {}) do
      draw_text_clipped_canvas(style.font, style.dim, lines[li],
        x + pad * c.z * 1.5, y + (pad + fh + (li - 2) * (fh + 2)) * c.z,
        sw - pad * 2.5 * c.z, fh * c.z)
    end
  end
end

-- clipped text for the canvas (same truncation rule as todo_agenda)
function draw_text_clipped_canvas(font, color, text, x, y, w, h)
  local label = text
  if font:get_width(label) > w and w > 4 then
    while #label > 1 and font:get_width(label .. "…") > w do
      label = label:sub(1, -2)
    end
    label = label .. "…"
  end
  return common.draw_text(font, color, label, "left", x, y, w, h)
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
  self.cam = { x = 40, y = 40, z = 1.0 }
  self.drag = nil
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
  local ygap, xgap = fh + 14, 230
  local row = 0
  local nodes = {}
  local function layout(n, depth)
    if #n.children == 0 then
      n.y = row * ygap
      row = row + 1
    else
      for _, ch in ipairs(n.children) do layout(ch, depth + 1) end
      n.y = (n.children[1].y + n.children[#n.children].y) / 2
    end
    n.x = depth * xgap
    n.w = style.font:get_width(n.text) + style.padding.x * 2
    nodes[#nodes + 1] = n
  end
  layout(root, 0)
  self.root = root
  self.nodes = nodes
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
  for _, n in ipairs(self.nodes) do
    local sx, sy = n.x + c.x, n.y + c.y
    if mx >= sx and mx < sx + n.w and my >= sy - 10 and my < sy + 10 then
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

function MindView:draw()
  self:draw_background(style.background)
  local c = self.cam
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local fh = style.font:get_height()

  -- connectors first
  local function link(n)
    for _, ch in ipairs(n.children) do
      local x1 = (n.x + (n == self.root and 60 or n.w)) * c.z + c.x
      local y1 = n.y * c.z + c.y
      local x2 = ch.x * c.z + c.x
      local y2 = ch.y * c.z + c.y
      local mx_ = (x1 + x2) / 2
      local col = common.lerp(style.background, style.accent or style.text, 0.4)
      local t = 1.5 * SCALE
      renderer.draw_rect(x1, y1 - t / 2, mx_ - x1, t, col)
      renderer.draw_rect(mx_ - t / 2, math.min(y1, y2), t, math.abs(y2 - y1) + t, col)
      renderer.draw_rect(mx_ - t / 2, y2 - t / 2, x2 - mx_ + t, t, col)
      link(ch)
    end
  end
  link(self.root)

  -- nodes
  for _, n in ipairs(self.nodes) do
    local x, y = n.x * c.z + c.x, n.y * c.z + c.y
    local w, h = n.w * c.z, (fh + 8) * c.z
    local is_root = (n == self.root)
    local hovered = (n == self.hover_node)
    local bg = is_root and (style.accent or style.text)
      or (hovered and raised_color() or surface_color())
    renderer.draw_rounded_rect(x, y - h / 2, w, h, h / 2, bg)
    draw_text_clipped_canvas(style.font,
      is_root and style.background or style.text, n.text,
      x + style.padding.x * c.z, y - fh * c.z / 2, w - style.padding.x * 2 * c.z, fh * c.z)
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
  ["mindmap:open"] = function()
    local doc = core.active_view and core.active_view.doc
    local path
    if doc and doc.filename then
      path = doc.abs_filename or doc.filename
    else
      core.log("mindmap: 请先打开一个 markdown 大纲文件")
      return
    end
    local node = core.root_view:get_active_node_default()
    node:add_view(MindView(path))
    core.redraw = true
  end,
})

keymap.add({
  ["ctrl+shift+e"] = "mindmap:open",
})

return { CanvasView = CanvasView, MindView = MindView, json = json }
