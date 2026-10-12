local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"

local icon_colors = {
  bg = { common.color "#2e2e32ff" },
  color6 = { common.color "#e1e1e6ff" },
  color7 = { common.color "#ffa94dff" },
  color8 = { common.color "#93ddfaff" },
  color9 = { common.color "#f7c95cff" }
};

local restore_command = {
  symbol = "w", action = function() system.set_window_mode(core.window, "normal") end
}

local maximize_command = {
  symbol = "W", action = function() system.set_window_mode(core.window, "maximized") end
}

local title_commands = {
  {symbol = "_", action = function() system.set_window_mode(core.window, "minimized") end},
  maximize_command,
  {symbol = "X", action = function() core.quit() end},
}

---@class core.titleview : core.view
---@field super core.view
local TitleView = View:extend()

function TitleView:__tostring() return "TitleView" end

local function title_view_height()
  return style.font:get_height() + style.padding.y * 2
end

function TitleView:new()
  TitleView.super.new(self)
  self.visible = true
end

function TitleView:configure_hit_test(borderless)
  if borderless then
    local title_height = title_view_height()
    local icon_w = style.icon_font:get_width("_")
    local icon_spacing = icon_w
    local controls_width = (icon_w + icon_spacing) * #title_commands + icon_spacing
    system.set_window_hit_test(core.window, title_height, controls_width, icon_spacing)
    -- core.hit_test_title_height = title_height
  else
    system.set_window_hit_test(core.window)
  end
end

function TitleView:on_scale_change()
  self:configure_hit_test(self.visible)
end

function TitleView:update()
  -- While in fullscreen the title bar is hidden; temporarily reveal it when
  -- the mouse hovers the top edge so the window controls (close, unfullscreen
  -- via the restore button) stay reachable, and hide it again once the mouse
  -- moves back into the editor.
  if core.window_mode == "fullscreen" then
    local h = title_view_height()
    local mouse_y = core.root_view and core.root_view.mouse.y or -1
    if not self.visible and mouse_y >= 0 and mouse_y <= h then
      self.visible = true
      self:configure_hit_test(true)
    elseif self.visible and mouse_y > h * 2 then
      self.visible = false
      self:configure_hit_test(false)
    end
  end
  self.size.y = self.visible and title_view_height() or 0
  title_commands[2] = core.window_mode == "maximized" and restore_command or maximize_command
  TitleView.super.update(self)
end


function TitleView:draw_window_title()
  local h = style.font:get_height()
  local ox, oy = self:get_content_offset()
  local color = style.chrome_text or style.text
  local x, y = ox + style.padding.x, oy + style.padding.y
  common.draw_text(style.icon_font, icon_colors.bg, "5", nil, x, y, 0, h)
  common.draw_text(style.icon_font, icon_colors.color6, "6", nil, x, y, 0, h)
  common.draw_text(style.icon_font, icon_colors.color7, "7", nil, x, y, 0, h)
  common.draw_text(style.icon_font, icon_colors.color8, "8", nil, x, y, 0, h)
  x = common.draw_text(style.icon_font, icon_colors.color9, "9 ", nil, x, y, 0, h)
  local title = core.compose_window_title(core.window_title)
  common.draw_text(style.font, color, title, nil, x, y, 0, h)
end

function TitleView:each_control_item()
  local icon_h, icon_w = style.icon_font:get_height(), style.icon_font:get_width("_")
  local icon_spacing = icon_w
  local ox, oy = self:get_content_offset()
  ox = ox + self.size.x
  local i, n = 0, #title_commands
  local iter = function()
    i = i + 1
    if i <= n then
      local dx = - (icon_w + icon_spacing) * (n - i + 1)
      local dy = style.padding.y
      return title_commands[i], ox + dx, oy + dy, icon_w, icon_h
    end
  end
  return iter
end


function TitleView:draw_window_controls()
  for item, x, y, w, h in self:each_control_item() do
    local color = item == self.hovered_item and (style.chrome_text or style.text) or style.dim
    common.draw_text(style.icon_font, color, item.symbol, nil, x, y, 0, h)
  end
end


function TitleView:on_mouse_pressed(button, x, y, clicks)
  local caught = TitleView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return end
  core.set_active_view(core.last_active_view)
  if self.hovered_item then
    self.hovered_item.action()
  end
end


function TitleView:on_mouse_left()
  TitleView.super.on_mouse_left(self)
  self.hovered_item = nil
end


function TitleView:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  local x_min, x_max, y_min, y_max = self.size.x, 0, self.size.y, 0
  for item, x, y, w, h in self:each_control_item() do
    x_min, x_max = math.min(x, x_min), math.max(x + w, x_max)
    y_min, y_max = y, y + h
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      return
    end
  end
end


function TitleView:draw()
  self:draw_background(style.background2)
  self:draw_window_title()
  self:draw_window_controls()
end

return TitleView
