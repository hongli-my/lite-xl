-- mod-version:4
-- Code folding for Lite XL.
--
-- Foldable ranges are found with two strategies, and the longest one wins:
--  * indentation: a line whose next non-blank line is more indented
--  * brackets: a line opening a bracket that is closed on a later line
--
-- Only the *closed* folds are remembered (`doc.folds[start] = stop`), so the
-- line <-> screen row mapping and the scrollbar only depend on them: no
-- document-wide scan is needed while drawing. The stored ranges are adjusted
-- when lines are inserted or removed, and forgotten when the document is
-- reloaded.
--
-- Folding is disabled while line wrapping is on: both remap the rows of a
-- document and cannot be combined reliably.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local Doc = require "core.doc"

config.plugins.folding = common.merge({
  enabled = true,
  -- fold ranges coming from the indentation of the next lines
  indent_folding = true,
  -- fold ranges coming from brackets closed on a later line
  bracket_folding = true,
  -- how far a bracket is searched when deciding whether a line is foldable
  -- (the real range is searched without limit when the fold is created)
  bracket_scan_limit = 200,
  -- unfold when the cursor ends up inside a folded region
  auto_unfold = true,
}, config.plugins.folding)


local function is_blank(text)
  return text == nil or text:find("[^ \t\r\n]") == nil
end


---Width of the leading indentation of a line.
local function indent_width(text, tab_size)
  local first = text:find("[^ \t]") or (#text + 1)
  local width = 0
  for i = 1, first - 1 do
    if text:sub(i, i) == "\t" then
      width = width + tab_size - (width % tab_size)
    else
      width = width + 1
    end
  end
  return width
end


local function get_tab_size(doc)
  local _, size = doc:get_indent_info()
  return size or config.indent_size
end


--------------------------------------------------------------------------------
-- Fold range detection
--------------------------------------------------------------------------------

local OPENERS = { ["{"] = true, ["("] = true, ["["] = true }
local CLOSERS = { ["}"] = true, [")"] = true, ["]"] = true }
-- Content of the character class matching the characters that need a closer
-- look while scanning a line. Both brackets must be escaped: a `[` inside the
-- class silently breaks the whole pattern. The surrounding `[...]` are added
-- by `scan_line`.
local INTERESTING = "(){}%[%]\"'`%-/"

---Scans a line, calling `on_bracket(char)` for every bracket outside of
---strings and comments. Keeps `state` across calls (`in_block_comment`).
local function scan_line(text, state, on_bracket)
  local i, n = 1, #text
  while i <= n do
    if state.in_block_comment then
      local close = text:find("*/", i, true)
      if not close then return end
      state.in_block_comment = false
      i = close + 2
    else
      -- the capture group is needed: `find` only returns the matched text
      -- when the pattern has captures
      local start, stop, char = text:find("([" .. INTERESTING .. "])", i)
      if not start then return end
      if char == '"' or char == "'" or char == "`" then
        local j, escaped = start + 1, false
        while j <= n do
          local c = text:sub(j, j)
          if escaped then escaped = false
          elseif c == "\\" then escaped = true
          elseif c == char then break end
          j = j + 1
        end
        i = j + 1
      elseif char == "-" and text:sub(start + 1, start + 1) == "-" then
        return -- line comment
      elseif char == "/" and text:sub(start + 1, start + 1) == "/" then
        return -- line comment
      elseif char == "/" and text:sub(start + 1, start + 1) == "*" then
        state.in_block_comment = true
        i = start + 2
      else
        on_bracket(char)
        i = stop + 1
      end
    end
  end
end


---Line closing a bracket opened on `line`, or nil. Brackets opened and closed
---on the same line are ignored: only a fold spanning several lines matters.
---@param doc core.doc
---@param line integer
---@param limit integer? Maximum number of lines scanned
local function bracket_end(doc, line, limit)
  if not doc.lines[line] then return nil end
  local last = limit and math.min(#doc.lines, line + limit) or #doc.lines
  local state = { in_block_comment = false }
  local depth, opened, found = 0, false, nil
  local current = line
  -- one closure for the whole scan: creating it per line is measurable on
  -- documents with hundreds of thousands of lines
  local function on_bracket(char)
    if current == line then
      -- only the brackets opened on this line start the fold
      if OPENERS[char] then
        depth = depth + 1
        opened = true
      elseif CLOSERS[char] and depth > 0 then
        depth = depth - 1
      end
    elseif opened and depth > 0 then
      if OPENERS[char] then
        depth = depth + 1
      elseif CLOSERS[char] then
        depth = depth - 1
        if depth == 0 and not found then found = current end
      end
    end
  end
  for i = line, last do
    current = i
    local text = doc.lines[i]
    -- a line without any bracket or comment character cannot change the
    -- depth: skipping it avoids scanning the whole line
    if text:find("[{}%(%)%[%]/]") then
      scan_line(text, state, on_bracket)
    end
    if i == line and depth == 0 then
      -- nothing left open on the opener line (or no bracket at all): the
      -- brackets of this line are closed on this line, so it cannot fold
      return nil
    end
    if found then return found end
  end
  return nil
end


---Last line of the indentation block starting at `line`, or nil.
local function indentation_end(doc, line)
  local text = doc.lines[line]
  if is_blank(text) then return nil end
  local tab = get_tab_size(doc)
  local base = indent_width(text, tab)
  local last
  for i = line + 1, #doc.lines do
    local other = doc.lines[i]
    if not is_blank(other) then
      if indent_width(other, tab) <= base then break end
      last = i
    end
  end
  return last
end


---True when the line can be folded (cheap check used for the gutter marker).
local function is_foldable(doc, line)
  local cfg = config.plugins.folding
  local text = doc.lines[line]
  if is_blank(text) then return false end
  if cfg.indent_folding then
    local tab = get_tab_size(doc)
    local base = indent_width(text, tab)
    for i = line + 1, #doc.lines do
      local other = doc.lines[i]
      if not is_blank(other) then
        if indent_width(other, tab) > base then return true end
        break
      end
    end
  end
  if cfg.bracket_folding and text:find("[%{%(%[]") then
    -- need at least one line to hide between the opener and the closer
    local bend = bracket_end(doc, line, cfg.bracket_scan_limit)
    if bend and bend > line + 1 then return true end
  end
  return false
end


---Range of the fold starting at `line` (its last hidden line), or nil.
local function fold_end(doc, line)
  local cfg = config.plugins.folding
  local last
  if cfg.indent_folding then
    last = indentation_end(doc, line)
  end
  if cfg.bracket_folding then
    local brackets = bracket_end(doc, line)
    if brackets then
      -- keep the line holding the closing bracket visible: only the lines
      -- strictly between the opener and the closer are hidden
      local bstop = brackets - 1
      if bstop > line and (not last or bstop > last) then
        last = bstop
      end
    end
  end
  return last and last > line and last or nil
end


--------------------------------------------------------------------------------
-- Fold state and line <-> row mapping
--------------------------------------------------------------------------------

local function bump_folds(doc)
  doc.folds_version = (doc.folds_version or 0) + 1
  doc.folding_cache = nil
end


local function get_folds(doc)
  return doc.folds
end


---True when `line` is the header of a closed fold.
local function is_folded(doc, line)
  return doc.folds ~= nil and doc.folds[line] ~= nil
end


local function set_fold(doc, start, stop)
  if not doc.folds then doc.folds = {} end
  doc.folds[start] = stop
  bump_folds(doc)
end


local function clear_fold(doc, start)
  if doc.folds and doc.folds[start] then
    doc.folds[start] = nil
    bump_folds(doc)
  end
end


---Merged, sorted hidden ranges (the fold header stays visible).
local function get_ranges(doc)
  local version = doc.folds_version or 0
  local cache = doc.folding_cache
  if cache and cache.version == version then return cache end
  local list = {}
  for start, stop in pairs(doc.folds or {}) do
    if stop > start then table.insert(list, { start + 1, stop }) end
  end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, range in ipairs(list) do
    local last = merged[#merged]
    if last and range[1] <= last[2] + 1 then
      if range[2] > last[2] then last[2] = range[2] end
    else
      table.insert(merged, range)
    end
  end
  local total = 0
  for _, range in ipairs(merged) do
    total = total + (range[2] - range[1] + 1)
  end
  cache = { version = version, ranges = merged, total = total }
  doc.folding_cache = cache
  return cache
end


local function is_hidden(doc, line)
  for _, range in ipairs(get_ranges(doc).ranges) do
    if line < range[1] then return false end
    if line <= range[2] then return true end
  end
  return false
end


---Number of hidden lines before `line`.
local function hidden_before(doc, line)
  local count = 0
  for _, range in ipairs(get_ranges(doc).ranges) do
    if line > range[2] then
      count = count + (range[2] - range[1] + 1)
    elseif line > range[1] then
      count = count + (line - range[1])
    else
      break
    end
  end
  return count
end


---Screen row of a line. Hidden lines share the row of their fold header.
local function row_of_line(doc, line)
  for _, range in ipairs(get_ranges(doc).ranges) do
    if line < range[1] then break end
    if line <= range[2] then
      line = range[1] - 1
      break
    end
  end
  return line - hidden_before(doc, line)
end


local function line_of_row(doc, row)
  local line = row
  for _, range in ipairs(get_ranges(doc).ranges) do
    if line >= range[1] then
      line = line + (range[2] - range[1] + 1)
    else
      break
    end
  end
  return line
end


---True when folding is available for this view: markers are drawn and folds
---can be created. Line wrapping remaps the rows as well, so both cannot be
---used at the same time.
---@param dv core.docview
local function folding_enabled(dv)
  return config.plugins.folding.enabled and not dv.wrapped_settings
end


---True when some fold is closed: only then the rows have to be remapped.
---@param dv core.docview
local function folding_active(dv)
  return folding_enabled(dv) and dv.doc.folds ~= nil and next(dv.doc.folds) ~= nil
end


--------------------------------------------------------------------------------
-- Row mapping hooks
--------------------------------------------------------------------------------

local old_get_scrollable_size = DocView.get_scrollable_size
function DocView:get_scrollable_size()
  local size = old_get_scrollable_size(self)
  if folding_active(self) then
    size = size - get_ranges(self.doc).total * self:get_line_height()
  end
  return size
end


local old_get_visible_line_range = DocView.get_visible_line_range
function DocView:get_visible_line_range()
  if not folding_active(self) then
    return old_get_visible_line_range(self)
  end
  local _, y, _, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local minrow = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
  local maxrow = math.max(minrow, math.floor((y2 - style.padding.y) / lh) + 1)
  local minline = math.min(line_of_row(self.doc, minrow), #self.doc.lines)
  local maxline = math.min(#self.doc.lines, line_of_row(self.doc, maxrow))
  return minline, math.max(minline, maxline)
end


local old_get_line_screen_position = DocView.get_line_screen_position
function DocView:get_line_screen_position(line, col)
  if not folding_active(self) then
    return old_get_line_screen_position(self, line, col)
  end
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  y = y + (row_of_line(self.doc, line) - 1) * lh + style.padding.y
  if col then
    return x + gw + self:get_col_x_offset(line, col), y
  end
  return x + gw, y
end


local old_resolve_screen_position = DocView.resolve_screen_position
function DocView:resolve_screen_position(x, y)
  if not folding_active(self) then
    return old_resolve_screen_position(self, x, y)
  end
  local ox, oy = self:get_line_screen_position(1)
  local rows = #self.doc.lines - get_ranges(self.doc).total
  local row = common.clamp(math.floor((y - oy) / self:get_line_height()) + 1, 1, math.max(rows, 1))
  local line = math.min(line_of_row(self.doc, row), #self.doc.lines)
  return line, self:get_x_offset_col(line, x - ox)
end


local old_draw = DocView.draw
function DocView:draw()
  if not folding_active(self) then
    return old_draw(self)
  end
  self:draw_background(style.background)
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local doc = self.doc
  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()
  local gw, gpad = self:get_gutter_width()

  local x, y = self:get_line_screen_position(minline)
  for i = minline, maxline do
    if not is_hidden(doc, i) then
      y = y + (self:draw_line_gutter(i, self.position.x, y, gpad and gw - gpad or gw) or lh)
    end
  end

  local pos = self.position
  x, y = self:get_line_screen_position(minline)
  core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
  for i = minline, maxline do
    if not is_hidden(doc, i) then
      y = y + (self:draw_line_body(i, x, y) or lh)
    end
  end
  self:draw_overlay()
  core.pop_clip_rect()

  self:draw_scrollbar()
end


--------------------------------------------------------------------------------
-- Gutter markers
--------------------------------------------------------------------------------

local old_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local lh = old_draw_line_gutter(self, line, x, y, width)
  if not folding_enabled(self) then return lh end
  if is_hidden(self.doc, line) then return lh end

  local folded = is_folded(self.doc, line)
  if not folded and not self:is_foldable_line(line) then return lh end

  -- a real chevron in the document font: the icon font (codicon) has no
  -- glyph for ASCII "+"/"-", so the markers were invisible
  local icon = folded and "\u{25b8}" or "\u{25be}"
  local color = self.hovered_fold == line and (style.accent or style.text) or style.line_number
  common.draw_text(self:get_font(), color, icon, "center",
    self.position.x, y, style.padding.x, lh)
  return lh
end


---Cached, cheap "can this line be folded" check for the visible lines.
function DocView:is_foldable_line(line)
  local doc = self.doc
  local minline, maxline = self:get_visible_line_range()
  local key = string.format("%d:%d:%d", doc:get_change_id(), minline, maxline)
  if not self.folding_foldable or self.folding_foldable.key ~= key then
    self.folding_foldable = { key = key }
  end
  local value = self.folding_foldable[line]
  if value == nil then
    value = is_foldable(doc, line) or false
    self.folding_foldable[line] = value
  end
  return value
end


--------------------------------------------------------------------------------
-- Folding / unfolding
--------------------------------------------------------------------------------

---Marker hit box of a line, in screen coordinates.
---Hit box of a line's fold marker: the empty strip on the left of the
---line numbers, in screen coordinates.
local function fold_marker_rect(dv, line)
  local y = select(2, dv:get_line_screen_position(line))
  return dv.position.x, y, style.padding.x, dv:get_line_height()
end


function DocView:fold_line(line)
  if not config.plugins.folding.enabled then return false end
  if self.wrapped_settings then
    core.log("Cannot fold while line wrapping is enabled")
    return false
  end
  local last = fold_end(self.doc, line)
  if not last then return false end
  set_fold(self.doc, line, last)
  self:clamp_scroll_position()
  core.redraw = true
  return true
end


function DocView:unfold_line(line)
  local doc = self.doc
  if is_folded(doc, line) then
    clear_fold(doc, line)
    core.redraw = true
    return true
  end
  -- the cursor may be inside a fold: unfold the one containing this line
  for start, stop in pairs(doc.folds or {}) do
    if line > start and line <= stop then
      clear_fold(doc, start)
      core.redraw = true
      return true
    end
  end
  return false
end


function DocView:toggle_fold(line)
  if is_folded(self.doc, line) then
    return self:unfold_line(line)
  end
  if self:unfold_line(line) then return true end
  return self:fold_line(line)
end


local old_on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if folding_enabled(self) and button == "left" then
    local mx, my, mw, mh = fold_marker_rect(self, 1)
    -- every marker shares the x of the line 1 marker
    if x >= mx and x < mx + mw then
      local line = self:resolve_screen_position(x, y)
      if line and not is_hidden(self.doc, line)
      and (is_folded(self.doc, line) or self:is_foldable_line(line)) then
        local _, ly, _, lh = fold_marker_rect(self, line)
        if y >= ly and y < ly + lh then
          self:toggle_fold(line)
          if is_folded(self.doc, line) then
            -- the caret may sit inside the region we just hid: move it onto
            -- the header, otherwise update() auto-unfolds it at once and the
            -- click looks like it did nothing
            local cl = select(1, self.doc:get_selection())
            if is_hidden(self.doc, cl) then
              self.doc:set_selection(line, 1)
            end
          end
          core.redraw = true
          return true
        end
      end
    end
  end
  return old_on_mouse_pressed(self, button, x, y, clicks)
end


local old_on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  old_on_mouse_moved(self, x, y, ...)
  if not folding_enabled(self) then
    self.hovered_fold = nil
    return
  end
  local mx, my, mw, mh = fold_marker_rect(self, 1)
  local hovered
  if x >= mx and x < mx + mw then
    local line = self:resolve_screen_position(x, y)
    if line and not is_hidden(self.doc, line)
    and (is_folded(self.doc, line) or self:is_foldable_line(line)) then
      local _, ly, _, lh = fold_marker_rect(self, line)
      if y >= ly and y < ly + lh then hovered = line end
    end
  end
  if hovered ~= self.hovered_fold then
    self.hovered_fold = hovered
    core.redraw = true
  end
end


--------------------------------------------------------------------------------
-- Cursor movement skips the folded lines
--------------------------------------------------------------------------------

local function move_to_line(dv, line, col, target)
  local offset = dv:get_col_x_offset(line, col)
  return target, dv:get_x_offset_col(target, offset)
end


local old_previous_line = DocView.translate.previous_line
DocView.translate.previous_line = function(doc, line, col, dv)
  if not dv or not folding_active(dv) then
    return old_previous_line(doc, line, col, dv)
  end
  local target = line - 1
  while target >= 1 and is_hidden(doc, target) do target = target - 1 end
  if target < 1 then return 1, 1 end
  return move_to_line(dv, line, col, target)
end


local old_next_line = DocView.translate.next_line
DocView.translate.next_line = function(doc, line, col, dv)
  if not dv or not folding_active(dv) then
    return old_next_line(doc, line, col, dv)
  end
  -- moving down from a fold header jumps over the whole fold
  local stop = doc.folds and doc.folds[line]
  local target = stop and (stop + 1) or (line + 1)
  while target <= #doc.lines and is_hidden(doc, target) do target = target + 1 end
  target = math.min(target, #doc.lines)
  if target == line then return line, col end
  return move_to_line(dv, line, col, target)
end


--------------------------------------------------------------------------------
-- Keeping the folds in sync with the document
--------------------------------------------------------------------------------

local function shift_folds_for_insert(doc, line, col, text)
  local folds = get_folds(doc)
  if not folds then return end
  local added = select(2, text:gsub("\n", ""))
  if added == 0 then return end
  -- when a line is split at its beginning, the content of that line moves down
  local from = col == 1 and line or (line + 1)
  local updated, changed = {}, false
  for start, stop in pairs(folds) do
    local new_start = start >= from and (start + added) or start
    local new_stop = stop >= from and (stop + added) or stop
    if new_start ~= start or new_stop ~= stop then changed = true end
    if new_stop > new_start then
      updated[new_start] = new_stop
    else
      changed = true
    end
  end
  if changed then
    doc.folds = updated
    bump_folds(doc)
  end
end


local function shift_folds_for_remove(doc, line1, line2)
  local folds = get_folds(doc)
  if not folds then return end
  local removed = line2 - line1
  if removed <= 0 then return end
  local updated, changed = {}, false
  for start, stop in pairs(folds) do
    if start > line1 and start <= line2 then
      changed = true -- the header is gone
    else
      local new_start = start > line2 and (start - removed) or start
      local new_stop = stop > line2 and (stop - removed) or stop
      if new_start ~= start or new_stop ~= stop then changed = true end
      if new_stop > new_start then
        updated[new_start] = new_stop
      else
        changed = true
      end
    end
  end
  if changed then
    doc.folds = updated
    bump_folds(doc)
  end
end


local old_raw_insert = Doc.raw_insert
function Doc.raw_insert(self, line, col, text, undo_stack, time)
  old_raw_insert(self, line, col, text, undo_stack, time)
  shift_folds_for_insert(self, line, col, text)
end


local old_raw_remove = Doc.raw_remove
function Doc.raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  old_raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  shift_folds_for_remove(self, line1, line2)
end


local old_doc_load = Doc.load
function Doc:load(...)
  old_doc_load(self, ...)
  self.folds = nil
  bump_folds(self)
end


local old_update = DocView.update
function DocView:update(...)
  old_update(self, ...)
  if not folding_active(self) then return end
  -- a cursor can end up inside a fold (find, undo, mouse wheel): unfold it
  if config.plugins.folding.auto_unfold then
    for _, line1, _, line2 in self.doc:get_selections() do
      for _, line in ipairs({ line1, line2 }) do
        if is_hidden(self.doc, line) then
          self:unfold_line(line)
        end
      end
    end
  end
end


--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

command.add(function()
  local dv = core.active_view
  return dv and dv:is(DocView), dv
end, {
  ["folding:toggle"] = function(dv)
    local line = select(1, dv.doc:get_selection())
    if dv:toggle_fold(line) then
      core.log("%s line %d", is_folded(dv.doc, line) and "Folded" or "Unfolded", line)
    end
  end,

  ["folding:fold"] = function(dv)
    local line = select(1, dv.doc:get_selection())
    if not dv:fold_line(line) then
      core.log("Nothing to fold on line %d", line)
    end
  end,

  ["folding:unfold"] = function(dv)
    local line = select(1, dv.doc:get_selection())
    if not dv:unfold_line(line) then
      core.log("Nothing to unfold on line %d", line)
    end
  end,

  -- folding every outermost block hides the whole document body, which is
  -- what "fold all" is expected to do, without folding every nested level
  ["folding:fold-all"] = function(dv)
    local doc = dv.doc
    local stack = {}
    for line = 1, #doc.lines do
      local text = doc.lines[line]
      if not is_blank(text) then
        local tab = get_tab_size(doc)
        local indent = indent_width(text, tab)
        while #stack > 0 and stack[#stack].indent >= indent do
          local entry = table.remove(stack)
          if entry.last and entry.last > entry.line then
            set_fold(doc, entry.line, entry.last)
          end
        end
        table.insert(stack, { indent = indent, line = line, last = nil })
      end
      for _, entry in ipairs(stack) do
        if not is_blank(text) then entry.last = line end
      end
    end
    for _, entry in ipairs(stack) do
      if entry.last and entry.last > entry.line then
        set_fold(doc, entry.line, entry.last)
      end
    end
    dv:clamp_scroll_position()
    core.redraw = true
  end,

  ["folding:unfold-all"] = function(dv)
    dv.doc.folds = nil
    bump_folds(dv.doc)
    dv:clamp_scroll_position()
    core.redraw = true
  end,
})


-- `PLATFORM` is "Mac OS X" with SDL2 and "macOS" with SDL3
local macos = PLATFORM == "Mac OS X" or PLATFORM == "macOS"
keymap.add {
  [macos and "cmd+alt+[" or "ctrl+shift+["] = "folding:toggle",
  [macos and "cmd+alt+]" or "ctrl+shift+]"] = "folding:unfold-all",
}


return {
  bracket_end = bracket_end,
  indentation_end = indentation_end,
  fold_end = fold_end,
  is_foldable = is_foldable,
  is_folded = is_folded,
  is_hidden = is_hidden,
  row_of_line = row_of_line,
  line_of_row = line_of_row,
}
