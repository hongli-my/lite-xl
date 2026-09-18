-- mod-version:4
-- Highlights every occurrence of the selected word (or of the word under the
-- caret) in the current document.
--
-- Occurrences are only searched in a window of lines around the viewport:
-- lite-xl keeps no index of the document words, so scanning the whole document
-- on every change would be too slow on large files.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

config.plugins.highlight_occurrences = common.merge({
  -- highlight occurrences at all
  enabled = true,
  -- highlight the word under the caret when there is no selection
  word_at_caret = true,
  -- selections shorter/longer than this are ignored
  min_length = 2,
  max_length = 100,
  -- match case
  case_sensitive = true,
  -- lines scanned before/after the visible ones
  scan_margin = 400,
  -- give up after this many occurrences
  max_occurrences = 2000,
  -- opacity (0-255) of the highlight
  fill_alpha = 70,
  border_alpha = 200,
}, config.plugins.highlight_occurrences)


local function is_word_char(char)
  return char ~= "" and char:match("[%w_]") ~= nil
end


---Returns the word (identifier) around `col` on `line`, or nil.
---@param doc core.doc
---@param line integer
---@param col integer
---@return string? word
---@return integer? col1
---@return integer? col2
local function word_at(doc, line, col)
  local text = doc.lines[line]
  if not text then return end
  local n = #text
  -- the caret can sit right after the word: then look at the char before it
  local from = math.min(col, n)
  if not is_word_char(text:sub(from, from)) then from = col - 1 end
  if from < 1 or not is_word_char(text:sub(from, from)) then return end
  local col1, col2 = from, from
  while col1 > 1 and is_word_char(text:sub(col1 - 1, col1 - 1)) do col1 = col1 - 1 end
  while col2 < n and is_word_char(text:sub(col2 + 1, col2 + 1)) do col2 = col2 + 1 end
  -- col2 is returned exclusive, like a selection
  return text:sub(col1, col2), col1, col2 + 1
end


---Returns the content of the quoted string the caret is inside, or nil.
---@param doc core.doc
---@param line integer
---@param col integer
---@return string? text
---@return integer? col1 First column of the content
---@return integer? col2 Column after the content
local function quoted_at(doc, line, col)
  local text = doc.lines[line]
  if not text then return end
  local n = #text
  local quote_pos
  local i = math.min(col, n)
  while i >= 1 do
    local char = text:sub(i, i)
    if char == '"' or char == "'" or char == "`" then
      local backslashes, j = 0, i - 1
      while j >= 1 and text:sub(j, j) == "\\" do
        backslashes = backslashes + 1
        j = j - 1
      end
      if backslashes % 2 == 0 then
        quote_pos = i
        break
      end
    end
    i = i - 1
  end
  if not quote_pos then return end
  local quote = text:sub(quote_pos, quote_pos)
  local close_pos
  i = quote_pos + 1
  while i <= n do
    local char = text:sub(i, i)
    if char == quote then
      close_pos = i
      break
    elseif char == "\\" then
      i = i + 1
    end
    i = i + 1
  end
  if not close_pos or col < quote_pos or col > close_pos then return end
  local content = text:sub(quote_pos + 1, close_pos - 1)
  if content == "" then return end
  return content, quote_pos + 1, close_pos
end


---Returns the text to look for, or nil when nothing should be highlighted.
---@param dv core.docview
---@return string? needle
---@return integer? selection_line
---@return integer? selection_col1
---@return integer? selection_col2
local function get_needle(dv)
  local cfg = config.plugins.highlight_occurrences
  local doc = dv.doc
  local line1, col1, line2, col2 = doc:get_selection(true)
  if line1 ~= line2 then return nil end

  if col2 > col1 then
    local text = doc:get_text(line1, col1, line2, col2)
    if #text < cfg.min_length or #text > cfg.max_length then return nil end
    if text:find("[\r\n]") then return nil end
    return text, line1, col1, col2
  end

  if not cfg.word_at_caret then return nil end
  local word, wcol1, wcol2 = word_at(doc, line1, col1)
  if not word then
    -- inside a quoted string (a JSON key for example): use its content
    word, wcol1, wcol2 = quoted_at(doc, line1, col1)
  end
  if not word or #word < cfg.min_length or #word > cfg.max_length then return nil end
  return word, line1, wcol1, wcol2
end


local function escape_pattern(text)
  return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end


---Searches `needle` between `from` and `to` (1-based lines).
---@return table[] occurrences List of `{ line, col, len }`
local function find_occurrences(doc, needle, from, to, cfg)
  local occurrences = {}
  local limit = cfg.max_occurrences
  -- an identifier is matched on word boundaries; anything else (quoted keys,
  -- operators, non-ASCII text) is searched as-is
  local whole_word = needle:match("^[%w_]+$") ~= nil
  local pattern = escape_pattern(cfg.case_sensitive and needle or needle:lower())
  if whole_word then
    pattern = "%f[%w_]" .. pattern .. "%f[%W]"
  end

  for line = from, to do
    local text = doc.lines[line]
    if text then
      local haystack = cfg.case_sensitive and text or text:lower()
      local init = 1
      while true do
        local col1, col2 = haystack:find(pattern, init)
        if not col1 then break end
        table.insert(occurrences, { line = line, col = col1, len = col2 - col1 + 1 })
        if #occurrences >= limit then return occurrences end
        init = col2 + 1
      end
    end
  end
  return occurrences
end


function DocView:update_occurrences()
  local cfg = config.plugins.highlight_occurrences
  if not cfg.enabled or core.active_view ~= self then
    self.highlight_occurrences = nil
    return
  end

  local doc = self.doc
  local needle, sline, scol1, scol2 = get_needle(self)
  if not needle then
    self.highlight_occurrences = nil
    return
  end

  local minline, maxline = self:get_visible_line_range()
  local from = math.max(1, minline - cfg.scan_margin)
  local to = math.min(#doc.lines, maxline + cfg.scan_margin)
  local key = table.concat({ doc:get_change_id(), needle, from, to,
    cfg.case_sensitive and 1 or 0 }, "\0")
  local data = self.highlight_occurrences
  if data and data.key == key then return end

  local by_line = {}
  for _, occ in ipairs(find_occurrences(doc, needle, from, to, cfg)) do
    -- the current selection is already highlighted by the editor
    if not (occ.line == sline and occ.col == scol1 and occ.col + occ.len == scol2) then
      if not by_line[occ.line] then by_line[occ.line] = {} end
      table.insert(by_line[occ.line], occ)
    end
  end

  self.highlight_occurrences = {
    key = key,
    needle = needle,
    by_line = by_line,
    fill = { table.unpack(style.selection) },
    border = { table.unpack(style.selection) },
  }
  self.highlight_occurrences.fill[4] = cfg.fill_alpha
  self.highlight_occurrences.border[4] = cfg.border_alpha
end


function DocView:draw_occurrence_highlights()
  local data = self.highlight_occurrences
  if not data then return end
  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()
  local border = math.max(1, common.round(1 * SCALE))
  for line = minline, maxline do
    local occurrences = data.by_line[line]
    if occurrences then
      for _, occ in ipairs(occurrences) do
        local x, y = self:get_line_screen_position(line, occ.col)
        local x2 = self:get_line_screen_position(line, occ.col + occ.len)
        local w = x2 - x
        if w > 0 then
          renderer.draw_rect(x, y, w, lh, data.fill)
          renderer.draw_rect(x, y, w, border, data.border)
          renderer.draw_rect(x, y + lh - border, w, border, data.border)
          renderer.draw_rect(x, y, border, lh, data.border)
          renderer.draw_rect(x + w - border, y, border, lh, data.border)
        end
      end
    end
  end
end


local old_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay(...)
  old_draw_overlay(self, ...)
  if core.active_view == self then
    self:draw_occurrence_highlights()
  end
end


local old_update = DocView.update
function DocView:update(...)
  old_update(self, ...)
  self:update_occurrences()
end


command.add(nil, {
  ["highlight-occurrences:toggle"] = function()
    config.plugins.highlight_occurrences.enabled = not config.plugins.highlight_occurrences.enabled
    core.log("Highlight occurrences %s",
      config.plugins.highlight_occurrences.enabled and "enabled" or "disabled")
  end,
})


return {
  find_occurrences = find_occurrences,
  word_at = word_at,
}
