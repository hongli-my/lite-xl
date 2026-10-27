local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"


---@class core.commandview.input : core.doc
---@field super core.doc
local SingleLineDoc = Doc:extend()

function SingleLineDoc:__tostring() return "SingleLineDoc" end

function SingleLineDoc:insert(line, col, text)
  SingleLineDoc.super.insert(self, line, col, text:gsub("\n", ""))
end

---@class core.commandview : core.docview
---@field super core.docview
local CommandView = DocView:extend()

function CommandView:__tostring() return "CommandView" end

CommandView.context = "application"

local noop = function() end

---@class core.commandview.state
---@field submit function
---@field suggest function
---@field cancel function
---@field validate function
---@field text string
---@field select_text boolean
---@field show_suggestions boolean
---@field typeahead boolean
---@field wrap boolean
local default_state = {
  submit = noop,
  suggest = noop,
  cancel = noop,
  validate = function() return true end,
  text = "",
  select_text = false,
  show_suggestions = true,
  typeahead = true,
  wrap = true,
}


function CommandView:new()
  CommandView.super.new(self, SingleLineDoc())
  self.suggestion_idx = 1
  self.suggestions_offset = 1
  self.suggestions = {}
  self.suggestions_height = 0
  self.last_change_id = 0
  self.last_text = ""
  self.user_supplied_text = ""
  self.last_change = "text"
  self.gutter_width = 0
  self.gutter_text_brightness = 0
  self.selection_offset = 0
  self.state = default_state
  self.font = "font"
  self.size.y = 0
  self.label = ""
end


---@deprecated
function CommandView:set_hidden_suggestions()
  core.warn("Using deprecated function CommandView:set_hidden_suggestions")
  self.state.show_suggestions = false
end


function CommandView:get_name()
  return View.get_name(self)
end


function CommandView:get_line_screen_position(line, col)
  local x = CommandView.super.get_line_screen_position(self, 1, col)
  local _, y = self:get_content_offset()
  local lh = self:get_line_height()
  return x, y + (self.size.y - lh) / 2
end


function CommandView:supports_text_input()
  return true
end


function CommandView:get_scrollable_size()
  return 0
end

function CommandView:get_h_scrollable_size()
  return 0
end


function CommandView:scroll_to_make_visible()
  -- no-op function to disable this functionality
end


function CommandView:get_text()
  return self.doc:get_text(1, 1, 1, math.huge)
end


function CommandView:set_text(text, select)
  self.last_text = text
  self.doc:remove(1, 1, math.huge, math.huge)
  self.doc:text_input(text)
  if select then
    self.doc:set_selection(math.huge, math.huge, 1, 1)
  end
end


function CommandView:move_suggestion_idx(dir)
  local function overflow_suggestion_idx(n, count)
    if count == 0 then return 0 end
    if self.state.wrap then
      return (n - 1) % count + 1
    else
      return common.clamp(n, 1, count)
    end
  end

  local function get_suggestions_offset()
    local max_visible = math.min(config.max_visible_commands, #self.suggestions)
    if dir > 0 then
      if self.suggestions_offset + max_visible < self.suggestion_idx + 1 then
        return self.suggestion_idx - max_visible + 1
      elseif self.suggestions_offset > self.suggestion_idx then
        return self.suggestion_idx
      end
    else
      if self.suggestions_offset > self.suggestion_idx then
        return self.suggestion_idx
      elseif self.suggestions_offset + max_visible < self.suggestion_idx + 1 then
        return self.suggestion_idx - max_visible + 1
      end
    end
    return self.suggestions_offset
  end

  self.last_change = "suggestion"
  if self.state.show_suggestions then
    local n = self.suggestion_idx + dir
    self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
    self:complete()
    self.last_change_id = self.doc:get_change_id()
  else
    local current_suggestion = #self.suggestions > 0 and self.suggestions[self.suggestion_idx].text
    local text = self:get_text()
    if text == current_suggestion then
      local n = self.suggestion_idx + dir
      if n == 0 and self.save_suggestion then
        self:set_text(self.save_suggestion)
      else
        self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
        self:complete()
      end
    else
      self.save_suggestion = text
      self:complete()
    end
    self.last_change_id = self.doc:get_change_id()
    self.state.suggest(self:get_text())
  end

  self.suggestions_offset = get_suggestions_offset()
end


function CommandView:complete()
  if #self.suggestions > 0 then
    self:set_text(self.suggestions[self.suggestion_idx].text)
  end
end


function CommandView:submit()
  local suggestion = self.suggestions[self.suggestion_idx]
  local text = self:get_text()
  if self.state.validate(text, suggestion) then
    local submit = self.state.submit
    self:exit(true)
    submit(text, suggestion)
  end
end

---@param label string
---@varargs any
---@overload fun(label:string, options: core.commandview.state)
function CommandView:enter(label, ...)
  if self.state ~= default_state then
    return
  end
  local options = select(1, ...)

  if type(options) ~= "table" then
    core.warn("Using CommandView:enter in a deprecated way")
    local submit, suggest, cancel, validate = ...
    options = {
      submit = submit,
      suggest = suggest,
      cancel = cancel,
      validate = validate,
    }
  end

  -- Support deprecated CommandView:set_hidden_suggestions
  -- Remove this when set_hidden_suggestions is not supported anymore
  if options.show_suggestions == nil then
    options.show_suggestions = self.state.show_suggestions
  end

  self.state = common.merge(default_state, options)

  -- We need to keep the text entered with CommandView:set_text to
  -- maintain compatibility with deprecated usage, but still allow
  -- overwriting with options.text
  local old_text = self:get_text()
  if old_text ~= "" then
    core.warn("Using deprecated function CommandView:set_text")
  end
  if options.text or options.select_text then
    local text = options.text or old_text
    self:set_text(text, self.state.select_text)
  end
  -- Replace with a simple
  -- self:set_text(self.state.text, self.state.select_text)
  -- once old usage is removed

  core.set_active_view(self)
  self:update_suggestions()
  self.gutter_text_brightness = 100
  self.label = label .. ": "
end


function CommandView:exit(submitted, inexplicit)
  if core.active_view == self then
    core.set_active_view(core.last_active_view)
  end
  local cancel = self.state.cancel
  self.state = default_state
  self.doc:reset()
  self.suggestions = {}
  if not submitted then cancel(not inexplicit) end
  self.save_suggestion = nil
  self.last_text = ""
end


function CommandView:get_line_height()
  return math.floor(self:get_font():get_height() * 1.2)
end


function CommandView:get_gutter_width()
  return self.gutter_width
end


function CommandView:get_suggestion_line_height()
  return self:get_font():get_height() + style.padding.y
end


function CommandView:update_suggestions()
  local text = self:get_text()
  local t = self.state.suggest(self.last_change == "suggestion" and self.user_supplied_text or text) or {}
  local res = {}
  for i, item in ipairs(t) do
    if type(item) == "string" then
      item = { text = item }
    end
    res[i] = item
  end
  if self.suggestions and self.last_change == "suggestion" then
    local new_suggestion_idx
    for i, v in ipairs(res) do
      if v.text == self.suggestions[self.suggestion_idx].text then
        new_suggestion_idx = i
        break
      end
    end
    self.suggestion_idx = new_suggestion_idx
    -- This preserves the suggestion_offset and realigns it with the new table.
    self:move_suggestion_idx(0)
  else
    self.suggestion_idx = 1
    self.suggestions_offset = 1
  end
  self.suggestions = res
end


function CommandView:update()
  CommandView.super.update(self)

  if core.active_view ~= self and self.state ~= default_state then
    self:exit(false, true)
  end

  -- update suggestions if text has changed
  if self.last_change_id ~= self.doc:get_change_id() then
    self.last_change = "text"
    self.user_supplied_text = self:get_text()
    self:update_suggestions()
    if self.state.typeahead and self.suggestions[self.suggestion_idx] then
      local current_text = self:get_text()
      local suggested_text = self.suggestions[self.suggestion_idx].text or ""
      if #self.last_text < #current_text and
         string.find(suggested_text, current_text, 1, true) == 1 then
        self:set_text(suggested_text)
        self.doc:set_selection(1, #current_text + 1, 1, math.huge)
      end
      self.last_text = current_text
    end
    self.last_change_id = self.doc:get_change_id()
  end

  -- update gutter text color brightness
  self:move_towards("gutter_text_brightness", 0, 0.1, "commandview")

  -- update gutter width
  local dest = self:get_font():get_width(self.label) + style.padding.x
  if self.size.y <= 0 then
    self.gutter_width = dest
  else
    self:move_towards("gutter_width", dest, nil, "commandview")
  end

  -- update suggestions box height
  local lh = self:get_suggestion_line_height()
  local dest = self.state.show_suggestions and math.min(#self.suggestions, config.max_visible_commands) * lh or 0
  self:move_towards("suggestions_height", dest, nil, "commandview")

  -- update suggestion cursor offset
  local dest = (self.suggestion_idx - self.suggestions_offset + 1) * self:get_suggestion_line_height()
  self:move_towards("selection_offset", dest, nil, "commandview")

  -- update size based on whether this is the active_view
  local dest = 0
  if self == core.active_view then
    dest = style.font:get_height() + style.padding.y * 2
  end
  self:move_towards(self.size, "y", dest, nil, "commandview")
end


function CommandView:draw_line_highlight()
  -- no-op function to disable this functionality
end


function CommandView:draw_line_gutter(idx, x, y)
  local yoffset = self:get_line_text_y_offset()
  local pos = self.position
  local color = common.lerp(style.chrome_text or style.text, style.accent, self.gutter_text_brightness / 100)
  core.push_clip_rect(pos.x, pos.y, self:get_gutter_width(), self.size.y)
  x = x + style.padding.x
  renderer.draw_text(self:get_font(), self.label, x, y + yoffset, color)
  core.pop_clip_rect()
  return self:get_line_height()
end


---UTF-8 char length at byte `pos`.
local function utf8_char_len(text, pos)
  local c = text:byte(pos)
  if not c then return 0 end
  if c >= 0xF0 then return 4 elseif c >= 0xE0 then return 3 elseif c >= 0xC0 then return 2 end
  return 1
end

---Draws `text` with the bytes marked in `hits` bright and the rest dim,
---sublime-style match highlighting.  Groups consecutive same-style runs so a
---filename costs a handful of draw calls.
local function draw_text_with_hits(font, text, hits, x, y, base_color, hit_color)
  local run_start, run_hit, cx = 1, nil, x
  local pos, len = 1, #text
  while pos <= len do
    local n = utf8_char_len(text, pos)
    local char_hit = false
    for i = pos, math.min(pos + n - 1, len) do
      if hits[i] then char_hit = true break end
    end
    if run_hit == nil then run_hit = char_hit end
    if char_hit ~= run_hit then
      local run = text:sub(run_start, pos - 1)
      common.draw_text(font, run_hit and hit_color or base_color, run, nil, cx, y, 0, 0)
      cx = cx + font:get_width(run)
      run_start, run_hit = pos, char_hit
    end
    pos = pos + n
  end
  if run_start <= len then
    common.draw_text(font, run_hit and hit_color or base_color, text:sub(run_start), nil, cx, y, 0, 0)
  end
end


---Linear blend of two {r,g,b,a} colours, t=0 -> a, t=1 -> b.
local function blend(a, b, t)
  return {
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
    a[3] + (b[3] - a[3]) * t,
    a[4] + (b[4] - a[4]) * t,
  }
end

---Relative luminance of an {r,g,b,a} colour (0-255), for WCAG contrast math.
local function rel_luminance(color)
  local function channel(v)
    v = v / 255
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * channel(color[1]) + 0.7152 * channel(color[2]) + 0.0722 * channel(color[3])
end

---WCAG contrast ratio between two colours.
local function contrast_ratio(a, b)
  local la, lb = rel_luminance(a), rel_luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

---Returns `color` shifted toward white/black until it reaches at least
---`target`:1 contrast on `bg` (best effort if the surface itself is extreme).
---Theme roles like style.text and style.dim are tuned against the editor
---background, not the command palette surface, so borrowed roles can land
---below readable contrast on the palette (style.dim on background3 is ~2:1 in
---the default theme); this keeps the palette legible in every theme.
local function ensure_contrast(color, bg, target)
  if contrast_ratio(color, bg) >= target then
    return color
  end
  local white, black = { 255, 255, 255, 255 }, { 0, 0, 0, 255 }
  -- shift away from the surface luminance first; on mid-grey surfaces only
  -- one direction can reach the target (white and black cap out at ~2.6:1
  -- there), so fall back to the other direction when the first one fails
  local function clamp_toward(goal)
    for i = 1, 32 do
      local clamped = blend(color, goal, i / 32)
      if contrast_ratio(clamped, bg) >= target then return clamped end
    end
  end
  local goal = rel_luminance(color) >= rel_luminance(bg) and white or black
  return clamp_toward(goal) or clamp_toward(goal == white and black or white) or color
end

---An elevated "floating card" surface derived from a theme's panel background
---(style.background3).  Dark chrome is lifted toward white (a raised panel
---catching light) and light chrome toward white (a bright sheet above the grey
---chrome), so the suggestion list never merges with the sidebar/status bar it
---sits above.  This is what makes the palette read as a distinct layer rather
---than flat editor chrome.
local function elevated_surface(bg)
  local lift = rel_luminance(bg) < 0.5 and 0.12 or 0.80
  return blend(bg, { 255, 255, 255, 255 }, lift)
end

---Selected-row band: the theme accent laid over the panel, auto-adapted for
---clear visibility.  Dark panels get a higher contrast target (band clearly
---lighter, >= 2.6:1) and a higher minimum strength so the accent hue reads;
---light panels get a lower target (>= 1.8:1, band clearly darker but not
---jarringly dark).  When the accent itself can't reach the target by blending
---alone — e.g. slate's high-luminance lime on a white panel — the band is
---forced toward the opposite luminance pole (darkened on light surfaces),
---preserving accent hue while guaranteeing the separation.
local function selection_band(panel, accent)
  local panel_lum = rel_luminance(panel)
  local target = panel_lum < 0.5 and 2.6 or 1.8
  local lo = panel_lum < 0.5 and 0.42 or 0.30
  -- Phase 1: increase accent strength until the band separates from the panel.
  local band = blend(panel, accent, lo)
  for i = 0, 40 do
    local s = lo + (0.85 - lo) * (i / 40)
    band = blend(panel, accent, s)
    if contrast_ratio(band, panel) >= target then return band end
  end
  -- Phase 2: accent alone can't reach the target (luminance too close to the
  -- panel).  Force luminance away from the panel: lighten on dark, darken on
  -- light, keeping as much accent hue as possible.
  local pole = panel_lum < 0.5 and { 255, 255, 255, 255 } or { 0, 0, 0, 255 }
  for i = 1, 32 do
    local c = blend(band, pole, i / 32)
    if contrast_ratio(c, panel) >= target then return c end
  end
  return blend(band, pole, 1.0)
end

---Left accent-bar colour for the selected row: the theme accent, luminance-
---adjusted (>= 3:1, WCAG 1.4.11 for non-text UI components) against the band
---so the bar is always visible even when the accent hue is close to the band.
local function accent_bar_color(accent, band)
  return ensure_contrast(accent, band, 3.0)
end

local function draw_suggestions_box(self)
  local lh = self:get_suggestion_line_height()
  local dh = style.divider_size
  local x, _ = self:get_line_screen_position()
  local h = math.ceil(self.suggestions_height)
  local rx, ry, rw, rh = self.position.x, self.position.y - h - dh, self.size.x, h

  -- The suggestion list reads as a floating card layered above the editor:
  -- an elevated surface (distinct from the surrounding chrome so it does not
  -- merge with the sidebar/status bar) framed by a hairline top edge, using
  -- the codebase's blend-toward-foreground depth idiom (same as the context
  -- menu's frame).  Themes may override either role via style.lua; the
  -- computed defaults degrade gracefully for any theme.
  local fg    = style.chrome_text or style.text
  local panel = style.command_view_background or elevated_surface(style.background3)
  local edge  = blend(panel, fg, 0.30)
  local band  = style.command_view_selection or selection_band(panel, style.accent)

  -- Palette text colours, clamped to WCAG AA (>= 4.5:1) on the surface they
  -- actually sit on.  Roles like style.text/style.dim are tuned against the
  -- editor background, not this elevated surface, so borrowed roles can land
  -- below readable contrast; ensure_contrast keeps every state legible.  The
  -- selected row sits on the accent band, so its colours are re-clamped
  -- against the band.
  local content       = ensure_contrast(fg, panel, 4.5)
  local secondary     = ensure_contrast(style.dim, panel, 4.5)
  local sel_content   = ensure_contrast(content, band, 4.5)
  local sel_secondary = ensure_contrast(secondary, band, 4.5)

  -- Extend the clip up by one divider row so the panel's top edge -- drawn in
  -- that gap, just above the list -- is actually visible.  push_clip_rect
  -- intersects with the parent clip, so clipping only to the panel area would
  -- hide the edge (the previous divider line was clipped out entirely).
  core.push_clip_rect(rx, ry - dh, rw, rh + dh)

  -- draw suggestions background
  if #self.suggestions > 0 then
    renderer.draw_rect(rx, ry - dh, rw, dh, edge)   -- top edge (card frame)
    renderer.draw_rect(rx, ry, rw, rh, panel)       -- panel surface
    -- selected-row band (accent-tinted, auto-adapted for clear visibility)
    local y = self.position.y - self.selection_offset - dh
    renderer.draw_rect(rx, y, rw, lh, band)
    -- left accent bar: a solid strip at the left edge of the selected row,
    -- like the active-tab accent line.  Provides a second, hue-based
    -- selection cue that is unmistakable even when the band's luminance
    -- shift is subtle (e.g. grey-on-grey in the default theme).
    local bar_w = math.max(2, common.round(3 * SCALE))
    renderer.draw_rect(rx, y, bar_w, lh, accent_bar_color(style.accent, band))
  end

  -- draw suggestion text
  local first = math.max(self.suggestions_offset, 1)
  local last = math.min(self.suggestions_offset + config.max_visible_commands, #self.suggestions)
  for i = first, last do
    local item = self.suggestions[i]
    local selected = i == self.suggestion_idx
    local text_color = selected and sel_content or content
    local dim_color = selected and sel_secondary or secondary
    local y = self.position.y - (i - first + 1) * lh - dh
    -- optional leading file-type icon (Nerd Font glyph supplied by the
    -- suggestion source, e.g. the quick-open palette)
    local text_x = x
    if item.icon and style.nerd_font then
      local iw = style.nerd_font:get_width(item.icon)
      common.draw_text(style.nerd_font, item.icon_color or dim_color,
        item.icon, nil, text_x, y, 0, lh)
      text_x = text_x + iw + style.padding.x / 2
    end
    if item.hits and next(item.hits) then
      draw_text_with_hits(self:get_font(), item.text, item.hits, text_x, y,
        dim_color, text_color)
    else
      common.draw_text(self:get_font(), text_color, item.text, nil, text_x, y, 0, lh)
    end

    if item.info then
      local w = self.size.x - x - style.padding.x
      common.draw_text(self:get_font(), dim_color, item.info, "right", x, y, w, lh)
    end
  end
  core.pop_clip_rect()
end


function CommandView:draw()
  CommandView.super.draw(self)
  if self.state.show_suggestions then
    core.root_view:defer_draw(draw_suggestions_box, self)
  end
end

return CommandView
