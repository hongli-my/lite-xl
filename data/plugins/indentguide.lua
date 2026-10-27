-- mod-version:4
--
-- indentguide: vertical indent reference lines in the editor.
-- Draws one thin line per indentation level in front of each line, on both
-- the wrapped and the plain rendering paths.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"
local command = require "core.command"
local LineWrapping = require "plugins.linewrapping"

config.plugins.indentguide = common.merge(config.plugins.indentguide or {}, {
  enabled = true,
})

local M = { _internal = { draw_count = 0 } }

local FALLBACK_GUIDE = { common.color "#90909050" }

---Computes the indent level of a line and the column at which each level's
---guide should be drawn.  Returns nil for blank lines.
local function indent_info(doc, line)
  local text = doc.lines[line]
  if not text or not text:find("[^%s]") then return nil end
  local _, size = doc:get_indent_info()
  size = math.max(1, size)
  local level, spaces, col = 0, 0, 0
  local guides = {}
  local n = #text
  while col < n do
    col = col + 1
    local c = text:byte(col)
    if c == 32 then -- space
      spaces = spaces + 1
      if spaces >= size then
        spaces = spaces - size
        level = level + 1
        guides[level] = col + 1
      end
    elseif c == 9 then -- tab
      spaces = 0
      level = level + 1
      guides[level] = col + 1
    else
      break
    end
  end
  return level, guides
end

local docview_draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(line, x, y)
  if config.plugins.indentguide.enabled and self.doc then
    local level, guides = indent_info(self.doc, line)
    if level and level > 1 then
      local lh = self:get_line_height()
      local count = 1
      if LineWrapping.get_line_idx_col_count and self.wrapped_settings then
        local _, _, c = LineWrapping.get_line_idx_col_count(self, line)
        count = math.max(1, c or 1)
      end
      local color = style.guide or FALLBACK_GUIDE
      local w = math.max(1, common.round(SCALE))
      for u = 1, level - 1 do
        local gx = x + self:get_col_x_offset(line, guides[u])
        renderer.draw_rect(gx, y, w, lh * count, color)
        M._internal.draw_count = M._internal.draw_count + 1
      end
    end
  end
  return docview_draw_line_text(self, line, x, y)
end

command.add(nil, {
  ["indentguide:toggle"] = function()
    config.plugins.indentguide.enabled = not config.plugins.indentguide.enabled
    core.redraw = true
    core.log("缩进参考线: " .. (config.plugins.indentguide.enabled and "开启" or "关闭"))
  end,
})

return M
