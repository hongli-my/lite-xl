-- mod-version:4
-- Floating "Format" button for documents having a registered formatter.
--
-- A small button is drawn in the top right corner of the editor whenever the
-- active document's syntax is one of the registered ones, and it runs the
-- corresponding command when clicked. Adding a new language only requires a
-- new entry in the `formatters` table below.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local DocView = require "core.docview"
local ContextMenu = require "core.contextmenu"

---@class formatters.entry
---@field command string Command run when the button is clicked
---@field label string Label used in the context menu

---Formatters per syntax name. Add an entry to support a new syntax.
---@type table<string, formatters.entry>
local formatters = {
  SQL  = { command = "sql:format",  label = "Format SQL" },
  JSON = { command = "json:format", label = "Format JSON" },
}

local button_text = "格式化"
local button_alpha = 230
local border_width = 1 * SCALE

local function get_formatter(dv)
  local syntax = dv.doc and dv.doc.syntax
  local name = syntax and syntax.name
  return name and formatters[name] or nil
end

local function get_button_rect(dv)
  local font = style.font
  local w = font:get_width(button_text) + style.padding.x * 2
  local h = font:get_height() + style.padding.y
  local scrollbar = style.expanded_scrollbar_size or style.scrollbar_size or 0
  local x = dv.position.x + dv.size.x - w - style.padding.x - scrollbar
  local y = dv.position.y + style.padding.y
  return x, y, w, h
end

local function is_inside(dv, x, y)
  local bx, by, bw, bh = get_button_rect(dv)
  return x >= bx and x <= bx + bw and y >= by and y <= by + bh
end

---Linear blend of two {r,g,b,a} colours, t=0 -> a, t=1 -> b.
local function blend_color(a, b, t)
  return {
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
    a[3] + (b[3] - a[3]) * t,
    a[4] + (b[4] - a[4]) * t,
  }
end


function DocView:draw_format_button()
  if not get_formatter(self) then return end
  local font = style.font
  local x, y, w, h = get_button_rect(self)

  local background
  local text_color
  if self.format_button_hovered then
    -- accent chip with the editor background for the label: unmistakable
    -- feedback on both light and dark themes
    background = { table.unpack(style.accent) }
    background[4] = 255
    text_color = style.background
  else
    -- a chip blended towards the text colour becomes dark on a light theme
    -- and light on a dark one, so the floating button never melts into the
    -- editor background the way a theme-fixed colour would
    background = blend_color(style.background, style.text, 0.8)
    background[4] = button_alpha
    text_color = blend_color(style.background, style.text, 0.1)
  end

  renderer.draw_rect(x - border_width, y - border_width,
    w + border_width * 2, h + border_width * 2, style.divider)
  renderer.draw_rect(x, y, w, h, background)
  common.draw_text(font, text_color, button_text, "center", x, y, w, h)
end


-- Hover-reveal: hidden until the mouse approaches the top-right corner, so
-- no width has to be reserved from the wrapped text.
local function is_near(dv, x, y)
  local bx, by, bw, bh = get_button_rect(dv)
  local hx, hy = style.padding.x * 6, style.padding.y * 4
  return x >= bx - hx and x <= bx + bw + hx and y >= by - hy and y <= by + bh + hy
end

local old_draw = DocView.draw
function DocView:draw(...)
  old_draw(self, ...)
  if self.format_btn_reveal then
    self:draw_format_button()
  end
end


local old_on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  old_on_mouse_moved(self, x, y, ...)
  local formatter = get_formatter(self) ~= nil
  local reveal = formatter and is_near(self, x, y)
  if reveal ~= self.format_btn_reveal then
    self.format_btn_reveal = reveal
    core.redraw = true
  end
  local hovered = formatter and reveal and is_inside(self, x, y)
  if hovered ~= self.format_button_hovered then
    self.format_button_hovered = hovered
    core.redraw = true
  end
  if hovered then self.cursor = "arrow" end
end


local old_on_mouse_left = DocView.on_mouse_left
function DocView:on_mouse_left(...)
  old_on_mouse_left(self, ...)
  self.format_button_hovered = false
  self.format_btn_reveal = false
end


local old_on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  local formatter = get_formatter(self)
  if formatter and self.format_btn_reveal and button == "left" and is_inside(self, x, y) then
    -- the format commands act on the active view
    core.set_active_view(self)
    command.perform(formatter.command)
    return true
  end
  return old_on_mouse_pressed(self, button, x, y, clicks)
end


-- Add the "Format ..." entry to the context menu of the formatted files
local old_ContextMenu_show = ContextMenu.show
function ContextMenu:show(x, y, items, ...)
  local dv = core.active_view
  local formatter = dv and dv:is(DocView) and get_formatter(dv) or nil
  if formatter then
    local has_format = false
    for _, item in ipairs(items) do
      if item ~= ContextMenu.DIVIDER and item.command == formatter.command then
        has_format = true
        break
      end
    end
    if not has_format then
      table.insert(items, ContextMenu.DIVIDER)
      table.insert(items, { text = formatter.label, command = formatter.command })
    end
  end
  return old_ContextMenu_show(self, x, y, items, ...)
end


return formatters
