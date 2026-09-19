-- mod-version:4
-- Centered modal dialog, used instead of the bottom nag bar.
--
-- Usage:
--   core.dialog_view:show(title, message, options, on_selected)
--
-- `options` is a list of entries like `{ text = "...", default_yes = true }`
-- (`default_no` marks the entry selected by `escape`, `font` overrides the
-- button font). The selected entry is passed to `on_selected`, then the dialog
-- is closed (queued dialogs are shown next).
--
-- The dialog is a modal overlay: it draws above everything, takes the
-- keyboard focus and swallows the mouse events that don't hit its buttons.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"
local RootView = require "core.rootview"

local noop = function() end

---Mix two colors: `t = 0` returns `a`, `t = 1` returns `b`.
---@param a number[]
---@param b number[]
---@param t number
---@return number[]
local function srgb_channel(c)
  c = (c or 0) / 255
  return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

---Relative luminance of a color (WCAG).
---@param color number[]
---@return number
local function relative_luminance(color)
  return 0.2126 * srgb_channel(color[1])
       + 0.7152 * srgb_channel(color[2])
       + 0.0722 * srgb_channel(color[3])
end

---Contrast ratio between two colors (WCAG): 1 is invisible, 21 is max.
---@param a number[]
---@param b number[]
---@return number
local function contrast_ratio(a, b)
  local la, lb = relative_luminance(a), relative_luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end


local function mix(a, b, t)
  return {
    math.floor((a[1] or 0) + ((b[1] or 0) - (a[1] or 0)) * t),
    math.floor((a[2] or 0) + ((b[2] or 0) - (a[2] or 0)) * t),
    math.floor((a[3] or 0) + ((b[3] or 0) - (a[3] or 0)) * t),
    math.floor((a[4] or 255) + ((b[4] or 255) - (a[4] or 255)) * t),
  }
end


---Wraps `text` so that each line fits in `max_width` pixels.
---@param font renderer.font
---@param text string
---@param max_width number
---@return string[]
local function wrap_text(font, text, max_width)
  local result = {}
  for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = ""
    local function push()
      table.insert(result, line)
      line = ""
    end
    local function add_word(word)
      local candidate = line == "" and word or (line .. " " .. word)
      if font:get_width(candidate) <= max_width then
        line = candidate
        return
      end
      if line ~= "" then push() end
      -- the word alone doesn't fit: break it character by character
      for char in common.utf8_chars(word) do
        local extended = line .. char
        if line ~= "" and font:get_width(extended) > max_width then
          push()
        end
        line = line .. char
      end
    end
    for word in paragraph:gmatch("%S+") do add_word(word) end
    if line ~= "" or paragraph == "" then push() end
  end
  return result
end


---@class core.dialogview.option
---@field text string
---@field font renderer.font?
---@field default_yes boolean?
---@field default_no boolean?

---@class core.dialogview : core.view
---@field super core.view
local DialogView = View:extend()

function DialogView:__tostring() return "DialogView" end

function DialogView:new()
  DialogView.super.new(self)
  self.visible = false
  self.queue = {}
  self.force_focus = false
  self.hovered_item = nil
  self.buttons = {}
  self.message_lines = {}
  self.message_line_height = 0
  self.box = { x = 0, y = 0, w = 0, h = 0 }
end


function DialogView:update_layout()
  local font = style.font
  local padding_x, padding_y = style.padding.x, style.padding.y
  local root_w, root_h = core.root_view.size.x, core.root_view.size.y
  local max_width = math.max(math.min(root_w - padding_x * 8, 700 * SCALE), 200 * SCALE)

  local buttons, buttons_width = {}, 0
  for i, option in ipairs(self.options or {}) do
    local button_font = option.font or font
    local w = button_font:get_width(option.text) + padding_x * 2
    local h = button_font:get_height() + padding_y
    table.insert(buttons, { index = i, option = option, font = button_font, w = w, h = h })
    buttons_width = buttons_width + w + padding_x
  end
  if #buttons > 0 then buttons_width = buttons_width - padding_x end

  local title_width = font:get_width(self.title or "")
  local message_width = 0
  for line in ((self.message or "") .. "\n"):gmatch("([^\n]*)\n") do
    message_width = math.max(message_width, font:get_width(line))
  end

  local content_width = math.max(title_width, buttons_width)
  content_width = math.max(math.min(content_width, max_width), math.min(message_width, max_width))
  self.message_lines = wrap_text(font, self.message or "", content_width)
  self.message_line_height = math.floor(font:get_height() * config.line_height)

  local box_w = math.min(content_width + padding_x * 2, max_width + padding_x * 2)
  local box_h = padding_y * 2 + font:get_height()
  if #self.message_lines > 0 then
    box_h = box_h + padding_y + #self.message_lines * self.message_line_height
  end
  if #buttons > 0 then
    box_h = box_h + padding_y * 2 + buttons[1].h
  end
  local max_height = math.max(root_h - padding_y * 4, 120 * SCALE)
  self.clipped = box_h > max_height
  box_h = math.min(box_h, max_height)

  self.box.x = math.floor((root_w - box_w) / 2)
  self.box.y = math.floor((root_h - box_h) / 2)
  self.box.w, self.box.h = box_w, box_h

  -- buttons are laid out in the bottom right corner of the dialog
  local bx = self.box.x + box_w - padding_x
  local by = self.box.y + box_h - padding_y - (buttons[1] and buttons[1].h or 0)
  for i = #buttons, 1, -1 do
    local button = buttons[i]
    bx = bx - button.w
    button.x, button.y = bx, by
    bx = bx - padding_x
  end
  self.buttons = buttons
end


function DialogView:change_hovered(index)
  if self.hovered_item ~= index then
    self.hovered_item = index
    core.redraw = true
  end
end


function DialogView:get_default_index()
  return common.find_index(self.options or {}, "default_yes")
      or common.find_index(self.options or {}, "default_no")
      or 1
end


---Runs the callback of the hovered entry and moves to the next dialog.
function DialogView:select()
  local option = self.hovered_item and self.options and self.options[self.hovered_item]
  local on_selected = self.on_selected
  if not option then return end
  -- close the dialog first: the callback may open another view
  self:next()
  if on_selected then on_selected(option) end
end


---Shows the next queued dialog, if any.
function DialogView:next()
  local entry = table.remove(self.queue, 1)
  if entry then
    self.title = entry.title
    self.message = entry.message
    self.options = entry.options
    self.on_selected = entry.on_selected or noop
    self.visible = true
    self.force_focus = true
    self:update_layout()
    self:change_hovered(self:get_default_index())
    core.set_active_view(self)
  else
    self.visible = false
    self.force_focus = false
    self.title, self.message, self.options, self.on_selected = nil, nil, nil, nil
    self.hovered_item = nil
    core.set_active_view(core.next_active_view or core.last_active_view
      or core.root_view:get_primary_node().active_view)
  end
  core.redraw = true
end


---Queues a dialog and shows it when the previous ones are closed.
---@param title string
---@param message string
---@param options core.dialogview.option[]
---@param on_selected fun(option: core.dialogview.option)?
function DialogView:show(title, message, options, on_selected)
  assert(title, "No title")
  assert(message, "No message")
  assert(options, "No options")
  table.insert(self.queue, {
    title = title,
    message = message,
    options = options,
    on_selected = on_selected,
  })
  if not self.visible then self:next() end
end


function DialogView:hide()
  self.queue = {}
  self:next()
end


local function overlaps_button(self, x, y)
  for _, button in ipairs(self.buttons) do
    if x >= button.x and x <= button.x + button.w
    and y >= button.y and y <= button.y + button.h then
      return button
    end
  end
end


function DialogView:on_mouse_moved(x, y)
  core.request_cursor("arrow")
  local button = overlaps_button(self, x, y)
  self:change_hovered(button and button.index or nil)
end


function DialogView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local hit = overlaps_button(self, x, y)
    if hit then
      self:change_hovered(hit.index)
      self:select()
    end
  end
  -- the dialog is modal: nothing else can be interacted with
  return true
end


---Colors of the dialog, derived from the current theme.
---`style.background` and `style.text` are used as the base because they are
---by definition a readable pair. `background3`/`background2` cannot be
---trusted (a theme may use a light panel background together with the dark
---editor text color, giving light-on-light text) and neither can `divider`
---(it is darker than the panels in several themes, so it cannot be used for
---borders).
function DialogView:get_colors()
  local background = style.background or style.background3
  local text = style.text
  local backdrop = { table.unpack(style.nagbar_dim or { 0, 0, 0, 150 }) }
  backdrop[4] = math.max(backdrop[4] or 0, 150)
  return {
    backdrop = backdrop,
    -- what the backdrop leaves behind, used to check the contrast
    dimmed_background = mix(background, backdrop, (backdrop[4] or 0) / 255),
    -- kept close to the editor background so the text keeps the contrast it
    -- has in the editor itself
    card = mix(background, text, 0.06),
    card_border = mix(background, text, 0.38),
    separator = mix(background, text, 0.18),
    -- buttons are flat (bordered) so that their label keeps the same contrast
    -- as the rest of the card; only the selected one gets the accent color
    button = mix(background, text, 0.06),
    accent = style.accent,
    text = text,
  }
end


function DialogView:draw()
  if not self.visible then return end
  local font = style.font
  local padding_x, padding_y = style.padding.x, style.padding.y
  local border = math.max(1, common.round(1 * SCALE)) * 2
  local box = self.box
  local colors = self:get_colors()
  local backdrop, card = colors.backdrop, colors.card
  local card_border, separator, button = colors.card_border, colors.separator, colors.button
  local accent = colors.accent

  -- dim everything behind the dialog
  renderer.draw_rect(0, 0, core.root_view.size.x, core.root_view.size.y, backdrop)

  -- card
  renderer.draw_rect(box.x - border, box.y - border,
    box.w + border * 2, box.h + border * 2, card_border)
  renderer.draw_rect(box.x, box.y, box.w, box.h, card)

  core.push_clip_rect(box.x, box.y, box.w, box.h)
  local x = box.x + padding_x
  local y = box.y + padding_y
  local w = box.w - padding_x * 2
  local h = font:get_height()
  common.draw_text(font, style.text, self.title or "", "left", x, y, w, h)

  -- separator under the title
  y = y + h + math.floor(padding_y / 2)
  renderer.draw_rect(x, y, w, math.max(1, common.round(1 * SCALE)), separator)

  y = y + math.floor(padding_y / 2) + padding_y
  local lh = self.message_line_height
  for i, line in ipairs(self.message_lines) do
    local ly = y + (i - 1) * lh
    if ly + lh > box.y + box.h - padding_y then break end
    common.draw_text(font, style.text, line, "left", x, ly, w, lh)
  end
  core.pop_clip_rect()

  -- Label of the selected button: the most readable of the card/text colors
  -- and plain black/white. Accents sit halfway between black and white in many
  -- themes, so the theme colors are not always the best choice.
  local selected_foreground = card
  for _, candidate in ipairs({ style.text, { 0, 0, 0 }, { 255, 255, 255 } }) do
    if contrast_ratio(candidate, accent) > contrast_ratio(selected_foreground, accent) then
      selected_foreground = candidate
    end
  end
  for _, b in ipairs(self.buttons) do
    local hovered = b.index == self.hovered_item
    local background = hovered and accent or button
    local foreground = hovered and selected_foreground or style.text
    local outline = hovered and accent or card_border
    renderer.draw_rect(b.x - border, b.y - border,
      b.w + border * 2, b.h + border * 2, outline)
    renderer.draw_rect(b.x, b.y, b.w, b.h, background)
    common.draw_text(b.font, foreground, b.option.text, "center",
      b.x, b.y, b.w, b.h)
  end
end


-- The dialog is not part of the node tree: it draws itself above everything
-- and intercepts the events while it is visible.
local old_root_draw = RootView.draw
function RootView:draw(...)
  old_root_draw(self, ...)
  local dialog = core.dialog_view
  if dialog and dialog.visible then dialog:draw() end
end


local old_root_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(...)
  local dialog = core.dialog_view
  if dialog and dialog.visible then
    old_root_mouse_moved(self, ...)
    dialog:on_mouse_moved(...)
    return true
  end
  return old_root_mouse_moved(self, ...)
end


local old_root_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(...)
  local dialog = core.dialog_view
  if dialog and dialog.visible then
    return dialog:on_mouse_pressed(...)
  end
  return old_root_mouse_pressed(self, ...)
end


local old_root_mouse_wheel = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(...)
  local dialog = core.dialog_view
  if dialog and dialog.visible then return true end
  return old_root_mouse_wheel(self, ...)
end


-- The dialog is modal for the keyboard too. The old nag bar was a locked node
-- in the tree, so `root:close`'s predicate (which checks the active node's
-- locked size) failed while it was shown, naturally swallowing key repeat.
-- The dialog is not in the node tree, so without this a held cmd+w would
-- close one tab per key-repeat, because every stroke still reaches
-- `root:close`. Only the navigation keys (bound to dialog:* commands) are
-- forwarded; everything else is swallowed.
local old_on_key_pressed = keymap.on_key_pressed
keymap.on_key_pressed = function(key, ...)
  local dialog = core.dialog_view
  if dialog and dialog.visible then
    local nav = key == "escape" or key == "return" or key == "keypad enter"
             or key == "left" or key == "right"
    if not nav then
      return true
    end
  end
  return old_on_key_pressed(key, ...)
end


return DialogView
