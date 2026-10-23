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
  width = 100,
  -- zoom of the map: rendered line height in logical pixels
  line_height = 5,
  -- "text" renders scaled-down real glyphs (Sublime's look); "blocks" draws
  -- the cheaper per-token colour bars
  render = "text",
  -- column width for the "blocks" renderer, logical pixels
  column_width = 1.6,
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
  local cfg = config.plugins.minimap
  local width = cfg.width
  local mm_lh = math.max(2, common.round(cfg.line_height * SCALE))
  local col_w = math.max(1, common.round(cfg.column_width * SCALE))
  local map_x = dv.position.x + dv.size.x - width - PAD
  return {
    w = width,
    lh = mm_lh,
    colw = col_w,
    x = map_x,
    y = dv.position.y,
    h = dv.size.y,
    max_cols = math.floor(width / col_w),
    -- cap tokens drawn per line: a minified line is one huge token and
    -- would otherwise be rasterised in full every frame (see draw loop)
    char_budget = math.floor(width / math.max(1, col_w)) * 4,
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

---Syntax-coloured blob palette, derived from the theme (token colours dimmed
---toward the background).  Rebuilt whenever the background changes, which
---covers theme switches.
local blob_cache = {}
local function blob_color(type_)
  local c = blob_cache[type_]
  if not c then
    local src = style.syntax[type_] or style.text
    c = {
      style.background[1] + (src[1] - style.background[1]) * 0.55,
      style.background[2] + (src[2] - style.background[2]) * 0.55,
      style.background[3] + (src[3] - style.background[3]) * 0.55,
      255,
    }
    blob_cache[type_] = c
  end
  return c
end

---A tiny copy of the code font used to render the map as scaled-down real
---text (Sublime's look).  Rebuilt when the zoom or the code font changes.
local tiny_font, tiny_font_key
local function get_tiny_font()
  local key = string.format("%s:%.2f:%d", tostring(style.code_font),
    config.plugins.minimap.line_height, SCALE)
  if tiny_font_key ~= key then
    local size = math.max(2, config.plugins.minimap.line_height * SCALE * 0.95)
    local ok, f = pcall(style.code_font.copy, style.code_font, size)
    tiny_font = ok and f or false
    tiny_font_key = key
  end
  return tiny_font or nil
end

-- Cached strip segments per document line. Rebuilding walks the tokenizer
-- and measures every token; replaying the segs only issues draw calls, so
-- scrolling and editing elsewhere no longer retokenize the whole strip.
-- An entry is keyed by the highlighter's line table, which is replaced
-- wholesale whenever the line is retokenized -- any edit invalidates
-- exactly the edited lines.
local strip_cache = setmetatable({}, { __mode = "k" })

local function strip_cache_for(doc, tiny, m)
  local budget = m.char_budget or 512
  local cache = strip_cache[doc]
  if not cache or cache.tiny ~= tiny or cache.palette ~= blob_cache
    or cache.width ~= m.w or cache.max_cols ~= m.max_cols
    or cache.budget ~= budget then
    cache = { tiny = tiny, palette = blob_cache, width = m.w,
              max_cols = m.max_cols, budget = budget, lines = {}, count = 0 }
    strip_cache[doc] = cache
  end
  return cache
end

local function strip_segs(doc, line, tiny, m, cache)
  local hl = doc.highlighter
  local lt = hl:get_line(line)
  local entry = cache.lines[line]
  if entry and entry.src == lt then return entry.segs end
  local segs = { }
  if tiny then
    -- scaled-down real glyphs: {colour, text, width} triplets, cut to the
    -- strip budget (a minified line is one giant token; measuring it whole
    -- every frame is what this cache exists to avoid)
    local tx = 0
    for _, type_, tok in hl:each_token(line) do
      if tok:byte(-1) == 10 then tok = tok:sub(1, -2) end
      if tok ~= "" then
        if tx >= cache.width then break end
        if #tok > cache.budget then tok = tok:sub(1, cache.budget) end
        local w = tiny:get_width(tok)
        segs[#segs+1] = blob_color(type_)
        segs[#segs+1] = tok
        segs[#segs+1] = w
        tx = tx + w
      end
    end
  else
    -- word runs as {colour, col_x, col_count} triplets; spaces advance
    -- without drawing
    local cx = 0
    for _, type_, tok in hl:each_token(line) do
      if cx >= cache.max_cols then break end
      if tok:byte(-1) == 10 then tok = tok:sub(1, -2) end
      if #tok > cache.budget then tok = tok:sub(1, cache.budget) end
      local ws = select(2, tok:find("^%s*")) or 0
      cx = cx + ws
      local body = tok:sub(ws + 1)
      local color = blob_color(type_)
      local p = 1
      while p <= #body and cx < cache.max_cols do
        local s, e = body:find("%S+", p)
        if not s then break end
        cx = cx + (s - p)
        local seg_cols = math.min(e - s + 1, cache.max_cols - cx)
        if seg_cols > 0 then
          segs[#segs+1] = color
          segs[#segs+1] = cx
          segs[#segs+1] = seg_cols
          cx = cx + seg_cols
        end
        p = e + 1
      end
    end
  end
  cache.lines[line] = { src = lt, segs = segs }
  cache.count = cache.count + 1
  -- scrolling through a huge file must not accumulate one entry per line
  -- forever; dropping the table only costs one rebuild of the visible strip
  if cache.count > 32768 then cache.lines = { }; cache.count = 0 end
  return segs
end

local function draw_minimap(dv)
  local doc = dv.doc
  local m = metrics(dv)
  local first_line, last_line = window_start(dv, m)
  if blob_cache.bg ~= style.background[1] then
    blob_cache = { bg = style.background[1] }
  end
  local gap = math.max(1, common.round(0.6 * SCALE))
  local tiny = config.plugins.minimap.render ~= "blocks" and get_tiny_font() or nil

  -- Panel: tint the whole reserved strip (out to the view's right edge, so
  -- the scrollbar zone reads as part of it) and separate it from the text
  -- with a divider line right on the strip's left edge.  The old hairline sat
  -- PAD pixels inside the text area, where it read as a stray line and gave
  -- the impression the strip overlapped the code.
  local blend = function(a, b, t)
    return {
      a[1] + (b[1] - a[1]) * t,
      a[2] + (b[2] - a[2]) * t,
      a[3] + (b[3] - a[3]) * t,
      255,
    }
  end
  local strip_w = dv.position.x + dv.size.x - m.x
  renderer.draw_rect(m.x, m.y, strip_w, m.h, blend(style.background, style.text, 0.035))
  renderer.draw_rect(m.x - 1, m.y, 1, m.h, blend(style.background, style.text, 0.30))

  core.push_clip_rect(m.x, m.y, m.w, m.h)
  local cache = strip_cache_for(doc, tiny, m)
  -- vertical centering exactly as common.draw_text does it, rounded per
  -- line: common.round is asymmetric at negative half-integers, so
  -- precomputing round((lh - th) / 2) once would shift glyphs by 1px
  local tq = tiny and (m.lh - tiny:get_height()) / 2 or 0
  for line = first_line, last_line do
    local text = doc.lines[line]
    if text and #text > 1 then
      local y = m.y + (line - first_line) * m.lh
      local segs = strip_segs(doc, line, tiny, m, cache)
      if tiny then
        local ty = common.round(y + tq)
        local tx = m.x
        for i = 1, #segs, 3 do
          renderer.draw_text(tiny, segs[i+1], tx, ty, segs[i])
          tx = tx + segs[i+2]
        end
      else
        for i = 1, #segs, 3 do
          renderer.draw_rect(m.x + segs[i+1] * m.colw, y, segs[i+2] * m.colw,
            m.lh - gap, segs[i])
        end
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

---Floating buttons (the preview / format chips) live inside the strip's x
---range; when one is hovered the click belongs to it, not to the map.
local function on_floating_button(dv)
  return dv.md_preview_btn_hover or dv.format_button_hovered
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
  if button == "left" and not on_floating_button(self)
      and hit(self, x) and y >= self.position.y
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
  -- additive: other widgets (the preview / format buttons) may reserve width
  -- through the same hook, and whoever loads last must not discard it
  local inset = old_get_right_inset(self)
  if active(self) then
    return inset + config.plugins.minimap.width + PAD
  end
  return inset
end

-- Drawn from the draw_scrollbar hook, which runs *after* the text clip is
-- popped: the text clip excludes the reserved right inset, so a minimap drawn
-- in draw_overlay (inside that clip) would be invisible.
local old_draw_scrollbar = DocView.draw_scrollbar
function DocView:draw_scrollbar(...)
  if active(self) then
    draw_minimap(self)
  end
  old_draw_scrollbar(self, ...)
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
