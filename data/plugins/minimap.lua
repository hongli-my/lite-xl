-- mod-version:4
-- minimap: a Sublime-style code minimap docked on the right edge of code views.
--
-- The strip renders a scaled-down silhouette of the document (one thin rect
-- per line, indentation preserved).  A viewport indicator tracks the lines
-- currently visible in the editor, and clicking / dragging inside the strip
-- scrolls the editor, continuous while the button is held -- the Sublime
-- interaction.  Documents taller than the strip slide a window through the
-- document, centred on the viewport, exactly like Sublime's fixed-zoom map.
--
-- The strip reserves its width through DocView:get_right_inset, so lines wrap
-- before reaching it instead of drawing underneath.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local CommandView = require "core.commandview"
local DocView = require "core.docview"

config.plugins.minimap = common.merge({
  -- show the minimap strip on the right edge of code views
  visible = true,
  -- strip width in logical pixels
  width = 80,
}, config.plugins.minimap)

local PAD = math.max(2, math.floor(style.padding.x / 2))

---The minimap applies to plain code views: it needs a document, and it must
---not fight the findbar fields (which override get_right_inset themselves,
---but are CommandViews anyway).
local function active(dv)
  return config.plugins.minimap.visible and dv.doc ~= nil and not dv:is(CommandView)
end

---Geometry of the strip for this view, shared by drawing and hit testing.
---Line height inside the map is fixed (Sublime's map is fixed-zoom); the
---rendered window slides through long documents.
local function metrics(dv)
  local width = config.plugins.minimap.width
  local mm_lh = math.max(2, common.round(2 * SCALE))
  local col_w = math.max(1, common.round(1.1 * SCALE))
  local map_x = dv.position.x + dv.size.x - width - PAD
  return {
    w = width,
    lh = mm_lh,
    colw = col_w,
    x = map_x,
    y = dv.position.y,
    h = dv.size.y,
    max_cols = math.floor(width / col_w),
  }
end

---The first document line rendered at the top of the strip: the whole
---document when it fits, otherwise a window centred on the editor viewport.
local function window_start(dv, m)
  local total = #dv.doc.lines
  local window_lines = math.max(1, math.floor(m.h / m.lh))
  if total <= window_lines then return 1, total end
  local minline, maxline = dv:get_visible_line_range()
  local center = (minline + maxline) / 2
  local start = math.floor(common.clamp(center - window_lines / 2, 1, total - window_lines + 1))
  return start, math.min(total, start + window_lines - 1)
end

---Leading indent of a line, in columns (tabs count as indent_size).
local function indent_cols(text, indent_size)
  local cols, i, len = 0, 1, #text
  while i <= len do
    local c = text:byte(i)
    if c == 9 then cols = cols + indent_size
    elseif c == 32 then cols = cols + 1
    else break end
    i = i + 1
  end
  return cols, i
end

local function draw_minimap(dv)
  local doc = dv.doc
  local m = metrics(dv)
  local first_line, last_line = window_start(dv, m)
  local _, indent_size = doc:get_indent_info()
  -- a dimmed, theme-derived blob colour
  local blob = {
    style.background[1] + (style.text[1] - style.background[1]) * 0.45,
    style.background[2] + (style.text[2] - style.background[2]) * 0.45,
    style.background[3] + (style.text[3] - style.background[3]) * 0.45,
    255,
  }
  local gap = math.max(1, common.round(0.6 * SCALE))

  core.push_clip_rect(m.x, m.y, m.w, m.h)
  for line = first_line, last_line do
    local text = doc.lines[line]
    if text and #text > 1 then
      local cols, body_start = indent_cols(text, indent_size)
      local content_len = #text - body_start
      if text:byte(-1) == 10 then content_len = content_len - 1 end
      local content_cols = math.min(content_len, m.max_cols - cols)
      if content_cols > 0 then
        local y = m.y + (line - first_line) * m.lh
        renderer.draw_rect(m.x + cols * m.colw, y, content_cols * m.colw,
          m.lh - gap, blob)
      end
    end
  end

  -- viewport indicator: the lines currently visible in the editor
  local minline, maxline = dv:get_visible_line_range()
  local vy = m.y + (minline - first_line) * m.lh
  local vh = (maxline - minline + 1) * m.lh
  local vfill = { style.text[1], style.text[2], style.text[3], 16 }
  local vedge = { style.text[1], style.text[2], style.text[3], 60 }
  renderer.draw_rect(m.x, vy, m.w, vh, vfill)
  local b = math.max(1, common.round(1 * SCALE))
  renderer.draw_rect(m.x, vy, m.w, b, vedge)
  renderer.draw_rect(m.x, vy + vh - b, m.w, b, vedge)
  renderer.draw_rect(m.x, vy, b, vh, vedge)
  renderer.draw_rect(m.x + m.w - b, vy, b, vh, vedge)
  -- hairline separating the strip from the text
  renderer.draw_rect(m.x - PAD, m.y, 1, m.h,
    { style.text[1], style.text[2], style.text[3], 25 })
  core.pop_clip_rect()
end

-------------------------------------------------------------------------------
-- Interaction: click / drag inside the strip scrolls the editor
-------------------------------------------------------------------------------

local function hit(dv, x)
  if not active(dv) then return false end
  local m = metrics(dv)
  return x >= m.x - PAD and x <= dv.position.x + dv.size.x
end

local function scroll_to(dv, x, y)
  local m = metrics(dv)
  local first_line = window_start(dv, m)
  local line = math.floor(first_line + (y - m.y) / m.lh)
  local minline, maxline = dv:get_visible_line_range()
  local visible = maxline - minline + 1
  dv.scroll.to.y = (line - visible / 2) * dv:get_line_height()
end

local old_on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and hit(self, x) and y >= self.position.y
      and y <= self.position.y + self.size.y then
    self.__minimap_drag = true
    scroll_to(self, x, y)
    return true
  end
  return old_on_mouse_pressed(self, button, x, y, clicks)
end

local old_on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  if self.__minimap_drag then
    scroll_to(self, x, y)
    return true
  end
  return old_on_mouse_moved(self, x, y, ...)
end

local old_on_mouse_released = DocView.on_mouse_released
function DocView:on_mouse_released(button, x, y, ...)
  self.__minimap_drag = nil
  return old_on_mouse_released(self, button, x, y, ...)
end

-------------------------------------------------------------------------------
-- Layout + drawing hooks
-------------------------------------------------------------------------------

local old_get_right_inset = DocView.get_right_inset
function DocView:get_right_inset()
  if active(self) then
    return config.plugins.minimap.width + PAD
  end
  return old_get_right_inset(self)
end

local old_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay(...)
  old_draw_overlay(self, ...)
  if active(self) then
    draw_minimap(self)
  end
end

-------------------------------------------------------------------------------
-- Toggle from the command palette
-------------------------------------------------------------------------------

command.add(nil, {
  ["minimap:toggle"] = function()
    config.plugins.minimap.visible = not config.plugins.minimap.visible
    core.redraw = true
  end,
})
