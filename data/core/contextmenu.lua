local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

local border_width = math.max(1, common.round(1 * SCALE))
local divider_width = 1
local divider_padding = 5
local DIVIDER = {}

---Linear blend of two {r,g,b,a} colours, t=0 -> a, t=1 -> b.
local function blend(a, b, t)
  return {
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
    a[3] + (b[3] - a[3]) * t,
    a[4] + (b[4] - a[4]) * t,
  }
end

---An item in the context menu.
---
---If the command predicate fails, it won't be included in the menu.
---@see core.command.command
---@class core.contextmenu.item
---@field text string
---@field info string? Text displayed on the right side of the menu.
---@field command string|fun(...)

---Definition of the context menu properties.
---
---@class core.contextmenu.contextdetails
---@field items core.contextmenu.item[] Array of items to show
---@field x integer? Context menu origin x coordinate. Defaults to the mouse position.
---@field y integer? Context menu origin y coordinate. Defaults to the mouse position.

---A context menu.
---@class core.contextmenu : core.view
---@field visible boolean
---@field selected number
---@field position core.view.position
---@field current_scale number
local ContextMenu = View:extend()

function ContextMenu:__tostring() return "ContextMenu" end

---A unique value representing the divider in a context menu.
ContextMenu.DIVIDER = DIVIDER

---Creates a new context menu.
function ContextMenu:new()
  self.visible = false
  self.selected = -1
  self.height = 0
  self.position = { x = 0, y = 0 }
  self.current_scale = SCALE
end

local function get_item_size(item)
  local lw, lh
  if item == DIVIDER then
    lw = 0
    lh = divider_width + divider_padding * SCALE * 2
  else
    lw = style.font:get_width(item.text)
    -- optional leading icon (Nerd Font glyph), with a gap to the text
    if item.icon and style.nerd_font then
      lw = lw + style.nerd_font:get_width(item.icon) + style.padding.x
    end
    if item.info then
      lw = lw + style.padding.x + style.font:get_width(item.info)
    end
    -- a touch taller than font + padding so the rows breathe, like Sublime's
    lh = style.font:get_height() + style.padding.y + common.round(2 * SCALE)
  end
  return lw, lh
end

local function update_items_size(items, update_binding)
  local width, height = 0, 0
  for _, item in ipairs(items) do
    if update_binding and item ~= DIVIDER then
      item.info = keymap.get_binding(item.command)
    end
    local lw, lh = get_item_size(item)
    width = math.max(width, lw)
    height = height + lh
  end
  width = width + style.padding.x * 2
  items.width, items.height = width, height
end

---Shows the context menu.
---@param x number
---@param y number
---@param items table
---@return boolean # If true, the context menu is shown.
function ContextMenu:show(x, y, items, ...)
  local items_list = { width = 0, height = 0, arguments = { ... } }
  for _, item in ipairs(items) do
    if item and (not item.command or command.is_valid(item.command, ...)) then
      table.insert(items_list, item)
    end
  end

  -- Drop orphaned dividers and bail out when no real item survived the
  -- filter above. Otherwise a right click on the treeview's empty area
  -- (where every entry's predicate needs a hovered item) leaves a lone
  -- DIVIDER, which renders a ~28x11 dark blob at the cursor.
  local cleaned = {}
  for _, item in ipairs(items_list) do
    if item ~= DIVIDER then
      table.insert(cleaned, item)
    elseif #cleaned > 0 and cleaned[#cleaned] ~= DIVIDER then
      table.insert(cleaned, item)
    end
  end
  while cleaned[#cleaned] == DIVIDER do table.remove(cleaned) end
  for i = 1, #cleaned do items_list[i] = cleaned[i] end
  for i = #items_list, #cleaned + 1, -1 do items_list[i] = nil end

  if #items_list > 0 then
    self.items = items_list
    update_items_size(self.items, true)
    local w, h = self.items.width, self.items.height

    -- by default the box is opened on the right and below
    x = common.clamp(x, 0, core.root_view.size.x - w - style.padding.x)
    y = common.clamp(y, 0, core.root_view.size.y - h)

    self.position.x, self.position.y = x, y
    self.visible = true
    core.set_active_view(self)
    core.request_cursor("arrow")
    return true
  end
  return false
end

---Hides the context menu.
function ContextMenu:hide()
  self.visible = false
  self.items = nil
  self.selected = -1
  self.height = 0
  if core.active_view == self then
    core.set_active_view(core.last_active_view)
  end
  core.request_cursor(core.active_view.cursor)
end

---Returns an iterator that iterates over each context menu item and their dimensions.
---@return fun(): number, core.contextmenu.item, number, number, number, number
function ContextMenu:each_item()
  local x, y, w = self.position.x, self.position.y, self.items.width
  local oy = y
  return coroutine.wrap(function()
    for i, item in ipairs(self.items) do
      local _, lh = get_item_size(item)
      if y - oy > self.height then break end
      coroutine.yield(i, item, x, y, w, lh)
      y = y + lh
    end
  end)
end

function ContextMenu:on_mouse_pressed(button, x, y)
  if not self.visible then return false end
  if button =='left' and x >= self.position.x and y >= self.position.y and x < self.position.x + self.items.width and y < self.position.y + self.height then
    local item = self:get_item_selected()
    if not item or not item.command then return true end
    if core.active_view == self then
      core.set_active_view(core.last_active_view)
    end
    self:on_selected(item)
  end
  self:hide()
  return true
end

function ContextMenu:on_mouse_released(button, x, y)
  if not self.visible then return false end
  return true
end

---Event handler for mouse movements.
---@param px any
---@param py any
---@return boolean # true if the event is caught.
function ContextMenu:on_mouse_moved(px, py)
  if not self.visible then return false end

  self.selected = -1
  for i, _, x, y, w, h in self:each_item() do
    if px > x and px <= x + w and py > y and py <= y + h then
      self.selected = i
      core.request_cursor("arrow")
      break
    end
  end
  return true
end

---Event handler for when the selection is confirmed.
---@param item core.contextmenu.item
function ContextMenu:on_selected(item)
  if type(item.command) == "string" then
    command.perform(item.command, table.unpack(self.items.arguments))
  else
    item.command(table.unpack(self.items.arguments))
  end
end

local function change_value(value, change)
  return value + change
end

---Selects the the previous item.
function ContextMenu:focus_previous()
  self.selected = (self.selected == -1 or self.selected == 1) and #self.items or change_value(self.selected, -1)
  if self:get_item_selected() == DIVIDER then
    self.selected = change_value(self.selected, -1)
  end
end

---Selects the next item.
function ContextMenu:focus_next()
  self.selected = (self.selected == -1 or self.selected == #self.items) and 1 or change_value(self.selected, 1)
  if self:get_item_selected() == DIVIDER then
    self.selected = change_value(self.selected, 1)
  end
end

---Gets the currently selected item.
---@return core.contextmenu.item|nil
function ContextMenu:get_item_selected()
  return (self.items or {})[self.selected]
end

---@type fun(self: table, k: string, dest: number, rate?: number, name?: string)
ContextMenu.move_towards = View.move_towards

---Event handler for content update.
function ContextMenu:update()
  if self.visible then
    self:move_towards("height", self.items.height, nil, "contextmenu")
  end
end

---Draws the context menu.
---
---This wraps `ContextMenu:draw_context_menu()`.
---@see core.contextmenu.draw_context_menu
function ContextMenu:draw()
  if not self.visible then return end
  if self.current_scale ~= SCALE then
    update_items_size(self.items)
    self.current_scale = SCALE
  end
  if not self.items then return end
  local bx, by, bw, bh = self.position.x, self.position.y, self.items.width, self.height

  -- Sublime-style skin: rounded panel with a layered frame (a faint outer
  -- ring reads as depth where a real shadow is not available), rows hover as
  -- inset rounded chips and dividers are short and quiet instead of being
  -- full-width light lines.
  local bg = style.contextmenu_background or style.background3
  local radius = math.max(3, common.round(6 * SCALE))
  local item_radius = math.max(2, radius - 3)
  local item_inset = common.round(4 * SCALE)
  local ring = blend(bg, style.text, 0.30)
  local shadow = blend(bg, style.text, 0.12)
  local hover = blend(bg, style.text, 0.16)
  local divider = blend(bg, style.text, 0.18)

  renderer.draw_rounded_rect(
    bx - border_width * 2, by - border_width * 2,
    bw + border_width * 4, bh + border_width * 4,
    radius + 2, shadow)
  renderer.draw_rounded_rect(
    bx - border_width, by - border_width,
    bw + border_width * 2, bh + border_width * 2,
    radius + 1, ring)
  renderer.draw_rounded_rect(bx, by, bw, bh, radius, bg)

  for i, item, x, y, w, h in self:each_item() do
    if item == DIVIDER then
      renderer.draw_rect(
        x + style.padding.x, y + divider_padding * SCALE,
        w - style.padding.x * 2, divider_width, divider)
    else
      if i == self.selected then
        renderer.draw_rounded_rect(
          x + item_inset, y + SCALE,
          w - item_inset * 2, h - SCALE * 2,
          item_radius, hover)
      end

      local text_x = x + style.padding.x
      if item.icon and style.nerd_font then
        local iw = style.nerd_font:get_width(item.icon)
        common.draw_text(style.nerd_font, item.icon_color or style.dim,
          item.icon, nil, text_x, y, 0, h)
        text_x = text_x + iw + style.padding.x
      end
      common.draw_text(style.font, style.text, item.text, "left", text_x, y, w, h)
      if item.info then
        common.draw_text(style.font, style.dim, item.info, "right", x, y, w - style.padding.x, h)
      end
    end
  end
end


return ContextMenu
