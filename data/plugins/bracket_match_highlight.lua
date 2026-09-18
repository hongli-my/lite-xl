-- mod-version:4
-- Bracket pair highlighting.
--
-- When the caret is next to a bracket, both that bracket and its matching
-- partner are highlighted. Brackets inside strings and comments are ignored,
-- and the matching scan is grammar-aware so brackets in comments/strings
-- never count toward the nesting depth. Works together with code folding
-- (line<->row remapping) and highlight_occurrences.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

config.plugins.bracket_match_highlight = common.merge({
  enabled = true,
  -- opacity (0-255) of the highlight fill and border
  fill_alpha = 70,
  border_alpha = 230,
  -- how far to look for the matching bracket, in each direction
  max_scan_lines = 5000,
}, config.plugins.bracket_match_highlight)

local OPEN  = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local CLOSE = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
local ANY_BRACKET = "[%(%)%[%]{}]"


---A token whose brackets count as code (not strings or comments).
local function is_code_token(t)
  return t ~= "string" and t ~= "comment" and t ~= "longstring"
end


local EMPTY = {}


---Type of the token covering byte column `col` on `line`, or "normal".
local function token_type_at(doc, line, col)
  if not doc.highlighter then return "normal" end
  local pos = 1
  for _, t, text in doc.highlighter:each_token(line) do
    local len = #text
    if col >= pos and col < pos + len then return t end
    pos = pos + len
  end
  return "normal"
end


---List of code brackets `{ col, char }` on a line. Brackets inside strings or
---comments are skipped; lines without any bracket are detected cheaply so a
---large scan over bracket-free lines stays fast.
local function brackets_of_line(doc, line)
  local text = doc.lines[line]
  if not text or not text:find(ANY_BRACKET) then return EMPTY end
  local list = {}
  if doc.highlighter then
    local pos = 1
    for _, t, tok in doc.highlighter:each_token(line) do
      if is_code_token(t) then
        for i = 1, #tok do
          local c = tok:sub(i, i)
          if OPEN[c] or CLOSE[c] then
            list[#list + 1] = { col = pos + i - 1, char = c }
          end
        end
      end
      pos = pos + #tok
    end
  else
    for i = 1, #text do
      local c = text:sub(i, i)
      if OPEN[c] or CLOSE[c] then list[#list + 1] = { col = i, char = c } end
    end
  end
  return list
end


---Finds the bracket matching the one at `(line, col)`, or nil.
---@return integer? line
---@return integer? col
local function find_match(doc, line, col)
  local ch = (doc.lines[line] or ""):sub(col, col)
  local target = OPEN[ch] or CLOSE[ch]
  if not target then return nil end
  local limit = config.plugins.bracket_match_highlight.max_scan_lines
  local depth = 1
  if OPEN[ch] then
    -- scan forward for the closer
    local last = math.min(#doc.lines, line + limit)
    for l = line, last do
      local brackets = brackets_of_line(doc, l)
      for _, b in ipairs(brackets) do
        if l > line or b.col > col then
          if b.char == ch then depth = depth + 1
          elseif b.char == target then
            depth = depth - 1
            if depth == 0 then return l, b.col end
          end
        end
      end
    end
  else
    -- scan backward for the opener
    local first = math.max(1, line - limit)
    for l = line, first, -1 do
      local brackets = brackets_of_line(doc, l)
      for i = #brackets, 1, -1 do
        local b = brackets[i]
        if l < line or b.col < col then
          if b.char == ch then depth = depth + 1
          elseif b.char == target then
            depth = depth - 1
            if depth == 0 then return l, b.col end
          end
        end
      end
    end
  end
  return nil
end


local function base_color()
  return style.caret or style.accent or style.text or { 255, 255, 255, 255 }
end


function DocView:update_bracket_match()
  local cfg = config.plugins.bracket_match_highlight
  if not cfg.enabled or core.active_view ~= self then
    self.bracket_match = nil
    return
  end
  local doc = self.doc
  -- the caret is the active end of the selection
  local _, _, line, col = doc:get_selection()
  local key = string.format("%d\0%d\0%d", doc:get_change_id(), line, col)
  if self.bracket_match and self.bracket_match.key == key then return end

  local oline, ocol, mline, mcol
  -- the caret sits between two columns: try the char to its right, then left
  for _, c in ipairs({ col, col - 1 }) do
    if c >= 1 then
      local ch = (doc.lines[line] or ""):sub(c, c)
      if (OPEN[ch] or CLOSE[ch]) and is_code_token(token_type_at(doc, line, c)) then
        local ml, mc = find_match(doc, line, c)
        if ml then oline, ocol, mline, mcol = line, c, ml, mc end
        break
      end
    end
  end

  local fill = { table.unpack(base_color()) }
  fill[4] = cfg.fill_alpha
  local border = { table.unpack(base_color()) }
  border[4] = cfg.border_alpha
  self.bracket_match = {
    key = key, oline = oline, ocol = ocol, mline = mline, mcol = mcol,
    fill = fill, border = border,
  }
end


function DocView:draw_bracket_match_highlights()
  local m = self.bracket_match
  if not m or not m.mline then return end
  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()
  local b = math.max(1, common.round(SCALE))
  for _, p in ipairs({ { m.oline, m.ocol }, { m.mline, m.mcol } }) do
    local l, c = p[1], p[2]
    if l >= minline and l <= maxline then
      local x, y = self:get_line_screen_position(l, c)
      local x2 = self:get_line_screen_position(l, c + 1)
      local w = x2 - x
      if w > 0 then
        renderer.draw_rect(x, y, w, lh, m.fill)
        renderer.draw_rect(x, y, w, b, m.border)
        renderer.draw_rect(x, y + lh - b, w, b, m.border)
        renderer.draw_rect(x, y, b, lh, m.border)
        renderer.draw_rect(x + w - b, y, b, lh, m.border)
      end
    end
  end
end


local old_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay(...)
  old_draw_overlay(self, ...)
  if core.active_view == self then
    self:draw_bracket_match_highlights()
  end
end


local old_update = DocView.update
function DocView:update(...)
  old_update(self, ...)
  self:update_bracket_match()
end


command.add(nil, {
  ["bracket-match-highlight:toggle"] = function()
    local cfg = config.plugins.bracket_match_highlight
    cfg.enabled = not cfg.enabled
    core.log("Bracket match highlighting %s", cfg.enabled and "enabled" or "disabled")
  end,
})


return {
  find_match = find_match,
  token_type_at = token_type_at,
  brackets_of_line = brackets_of_line,
}
