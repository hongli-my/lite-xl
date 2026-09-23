-- mod-version:4 --priority:120
-- findbar: a Sublime-style find bar docked above the status bar.
--
-- The stock find (`core/commands/findreplace.lua`) reuses the single
-- CommandView prompt for everything: it closes on Enter, can only walk matches
-- with F3, shows no match count, and leaves every match but the current one
-- invisible.  This plugin replaces it with a real bar:
--
--   * the find field is an ordinary DocView holding a single-line Doc, so the
--     caret, selection, click/drag, cmd+A/C/V/X, undo and the system IME all
--     come from the core instead of being re-implemented;
--   * every match in the document is highlighted, the current one emphasised;
--   * a "3/27" counter that updates while you type (the scan runs inline for
--     normal files, or in a coroutine for huge ones so no frame stalls);
--   * Enter / Shift+Enter walk matches without closing the bar, Esc closes and
--     returns to editing (selection collapsed, highlights dropped);
--   * a second row for the replacement: Replace / Replace All, one at a time
--     with Enter, whole file with cmd+alt+Enter;
--   * case / regex / whole-word toggles that are clickable, have shortcuts and
--     survive a restart (core.storage).
--
-- Bindings (cmd on macOS, ctrl elsewhere); see the keymap section at the end:
--   cmd+f            open the bar / focus the find field, prefilled with the
--                    selection when there is one
--   cmd+r / cmd+alt+f   open the replace row, focus the replace field
--   Enter            next match          shift+Enter      previous match
--   Tab / shift+Tab  switch between the find and the replace field
--   cmd+return       in the bar: replace this match and go to the next one
--   cmd+alt+return   Replace All (whole file, one undo step)
--   cmd+g            next match          cmd+shift+g      previous match
--   cmd+alt+c/r/w    case / regex / whole word
--   option+up/down   walk the search history of the focused field
--   Esc              close the bar and go back to editing
--   F3 / shift+F3    aliases of cmd+g / cmd+shift+g

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local storage = require "core.storage"

local is_macos = PLATFORM == "macOS" or PLATFORM == "Mac OS X"
local MOD = is_macos and "cmd" or "ctrl"

-- Forward declarations: the view classes below need the engine, and the engine
-- needs the classes.  Locals, so nothing leaks into the global namespace.
local state = {}
local tick, recompile, jump, open_bar, close_bar, toggle, insert_unique, retarget
local legacy -- the stock find commands, kept as a fallback

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------

config.plugins.findbar = common.merge({
  -- the toggles, persisted between runs (see save_state)
  case_sensitive = false,
  regex = false,
  whole_word = false,
  -- wrap around the end of the file
  wrap = true,
  -- paint every match, not only the current one
  highlight_all = true,
  -- stop counting after this many matches (the counter then shows "20000+")
  max_matches = 20000,
  -- documents with fewer lines than this are counted synchronously, so the
  -- count and the "3/27" index are correct on the very first frame; bigger
  -- ones are counted in a coroutine, yielding once per chunk
  sync_scan_lines = 5000,
  scan_chunk = 4000,
  -- seconds of quiet before a (re)count is started
  count_delay = 0.08,
  -- how long the "Wrapped" hint stays on screen
  wrapped_hint_time = 1.5,
  -- Esc: leave the caret on the current match (Sublime's behaviour) or collapse
  -- the selection and drop the highlights, so that typing does not overwrite
  -- the match.  The latter is the default: closing the bar means "back to
  -- editing".
  keep_selection_on_close = false,
  -- highlight colours are derived from style.selection so that they follow the
  -- colour scheme; these are the alpha components
  fill_alpha = 55,
  border_alpha = 150,
  current_fill_alpha = 110,
}, config.plugins.findbar)

local STATE_KEY = "state"

---Restores the persisted toggles and search history.
local function load_state()
  local saved = storage.load("findbar", STATE_KEY)
  if type(saved) ~= "table" then return end
  local cfg = config.plugins.findbar
  for _, key in ipairs { "case_sensitive", "regex", "whole_word", "wrap" } do
    if type(saved[key]) == "boolean" then cfg[key] = saved[key] end
  end
  local function restore(list, name)
    local saved_list = saved[name]
    if type(saved_list) ~= "table" then return end
    for i = #list, 1, -1 do table.remove(list, i) end
    for _, v in ipairs(saved_list) do
      if type(v) == "string" and v ~= "" and #list < 30 then table.insert(list, v) end
    end
  end
  restore(core.previous_find, "find_history")
  restore(core.previous_replace, "replace_history")
end

---Writes the toggles and the search history to USERDIR/storage/findbar/state.
local function save_state()
  local cfg = config.plugins.findbar
  storage.save("findbar", STATE_KEY, {
    case_sensitive = cfg.case_sensitive,
    regex = cfg.regex,
    whole_word = cfg.whole_word,
    wrap = cfg.wrap,
    find_history = core.previous_find,
    replace_history = core.previous_replace,
  })
end

-------------------------------------------------------------------------------
-- Matching
--
-- Matches never span lines: lite-xl keeps the trailing newline inside
-- `doc.lines[i]`, so the matcher works on the line without it.  Columns are
-- the usual editor columns, where `#line` is the position of the newline, that
-- is "right after the last visible character".
-------------------------------------------------------------------------------

local matcher = {}

local function is_word_char(c)
  return c ~= "" and c:find("[%w_]") ~= nil
end

---The matchable part of `doc.lines[line]`.
local function line_content(text)
  if text:byte(-1) == 10 then text = text:sub(1, -2) end
  if text:byte(-1) == 13 then text = text:sub(1, -2) end
  return text
end

---Compiles a query.
---@return table|nil m
---@return string|nil err
function matcher.compile(query, case_sensitive, regex_mode, whole_word)
  if query == "" then return nil end
  local m = {
    query = query,
    case_sensitive = case_sensitive,
    regex = regex_mode,
    whole_word = whole_word,
  }
  if regex_mode then
    local ok, re, err = pcall(regex.compile, query, case_sensitive and "" or "i")
    if not ok then return nil, tostring(re) end
    if not re then return nil, tostring(err or "invalid pattern") end
    m.re = re
  else
    m.needle = case_sensitive and query or query:lower()
  end
  return m
end

---The string to search in (the regex engine handles case itself).
local function haystack(m, content)
  if m.regex or m.case_sensitive then return content end
  return content:lower()
end

---First match of `m` in `content` at or after `col`.
---@return integer? s first byte
---@return integer? e last byte
local function find_in_line(m, content, hay, col)
  if m.regex then
    local s, e = m.re:cmatch(content, col, regex.NOTEMPTY)
    if not s then return end
    e = e - 1
    while m.whole_word and (is_word_char(content:sub(s - 1, s - 1))
        or is_word_char(content:sub(e + 1, e + 1))) do
      s, e = m.re:cmatch(content, s + 1, regex.NOTEMPTY)
      if not s then return end
      e = e - 1
    end
    return s, e
  end
  while true do
    local s, e = hay:find(m.needle, col, true)
    if not s then return end
    if not m.whole_word
        or (not is_word_char(content:sub(s - 1, s - 1))
          and not is_word_char(content:sub(e + 1, e + 1))) then
      return s, e
    end
    col = s + 1
  end
end

---First match at or after (line, col); never wraps.
---@return integer? line1
---@return integer? col1
---@return integer? col2 exclusive
local function find_forward(m, doc, line, col)
  for l = math.max(line, 1), #doc.lines do
    local text = doc.lines[l]
    if text then
      local content = line_content(text)
      local s, e = find_in_line(m, content, haystack(m, content), l == line and col or 1)
      if s then return l, s, e + 1 end
    end
  end
end

---Last match that starts before (line, col); never wraps.
local function find_backward(m, doc, line, col)
  for l = math.min(line, #doc.lines), 1, -1 do
    local text = doc.lines[l]
    if text then
      local content = line_content(text)
      local hay = haystack(m, content)
      local limit = l == line and col or math.huge
      local last_s, last_e
      local init = 1
      while true do
        local s, e = find_in_line(m, content, hay, init)
        if not s or s >= limit then break end
        last_s, last_e = s, e
        init = s + 1
      end
      if last_s then return l, last_s, last_e + 1 end
    end
  end
end

---Counts the matches of `m` in the document, and how many of them start before
---`anchor_line, anchor_col`.
---@param yield_fn fun(): boolean? called between chunks; false aborts the scan
---@return table|nil { total, before, truncated }
local function scan_document(doc, m, anchor_line, anchor_col, yield_fn)
  local cfg = config.plugins.findbar
  local total, before, truncated = 0, 0, false
  local line, last = 1, #doc.lines
  while line <= last do
    local stop = math.min(last, line + cfg.scan_chunk - 1)
    for l = line, stop do
      local text = doc.lines[l]
      if text then
        local content = line_content(text)
        local hay = haystack(m, content)
        local col = 1
        while true do
          local s, e = find_in_line(m, content, hay, col)
          if not s then break end
          total = total + 1
          if l < anchor_line or (l == anchor_line and s < anchor_col) then
            before = before + 1
          end
          if total >= cfg.max_matches then
            truncated = true
            break
          end
          col = e + 1
        end
      end
      if truncated then break end
    end
    if truncated then break end
    line = stop + 1
    if yield_fn and line <= last and not yield_fn() then return end
  end
  return { total = total, before = before, truncated = truncated }
end

-------------------------------------------------------------------------------
-- The field
-------------------------------------------------------------------------------

---One row of the bar.  It derives from CommandView, not DocView: the core
---already treats a CommandView as "a UI text field, not a document", which is
---exactly what this is.  That single fact keeps the status bar from showing a
---file name and a caret position for the query, and makes the stock find/replace
---code treat the field as a prompt instead of as the document to search.
---
---Everything that makes a text field (caret, selection, mouse, IME,
---clipboard, undo) comes from DocView; only the gutter is ours.
---@class plugins.findbar.view : core.commandview
local FindField = CommandView:extend()
-- "application": the field must survive `close_all_docviews` (project switch).
FindField.context = "application"

function FindField:__tostring() return "FindField" end

---@param kind "find"|"replace"
function FindField:new(kind)
  -- CommandView:new() gives us a SingleLineDoc, so pasted newlines are dropped
  CommandView.new(self)
  self.kind = kind
  self.visible = false
  self.size.y = 0
  -- width of the empty space in front of the query: the row is lined up with
  -- the document's text column (see get_gutter_width)
  self.left_inset = 0
  self.controls = {}
  self.controls_width = 0
  self.hovered_control = nil
  -- no scrollbars: the row is one line high and scrolls horizontally only
  self.scrollable = false
end

function FindField:get_name()
  return self.kind == "find" and "Find" or "Replace"
end

function FindField:supports_text_input()
  return true
end

function FindField:get_scrollable_size()
  return 0
end

---`math.huge` keeps the core in charge of bounding the horizontal scroll (see
---DocView:clamp_scroll_position); the scrollbar itself is never drawn.
function FindField:get_h_scrollable_size()
  return math.huge
end

function FindField:draw_scrollbar()
end

function FindField:get_text()
  return self.doc:get_text(1, 1, 1, math.huge)
end

function FindField:set_text(text, select)
  if self:get_text() == text then
    if select then self.doc:set_selection(math.huge, math.huge, 1, 1) end
    return
  end
  self.doc:remove(1, 1, math.huge, math.huge)
  self.doc:text_input(text)
  if select then self.doc:set_selection(math.huge, math.huge, 1, 1) end
end

---The height of one row; the locked node holding this view reads `size.y`.
function FindField:row_height()
  return self:get_line_height() + style.padding.y * 2
end

---Keeps the caret inside the field.  Same maths as DocView, minus the
---scrollbar; the row never scrolls vertically.
function FindField:scroll_to_make_visible(line, col)
  local xoffset = self:get_col_x_offset(line, col)
  local gw = self:get_gutter_width()
  local margin = 3 * self:get_font():get_width(" ")
  local xsup, xinf = xoffset + gw + margin, xoffset - margin
  if xsup > self.scroll.x + self.size.x then
    self.scroll.to.x = xsup - self.size.x
  elseif xinf < self.scroll.x then
    self.scroll.to.x = math.max(0, xinf)
  end
  self.scroll.to.y = 0
end

function FindField:update()
  self:move_towards(self.size, "y", self.visible and self:row_height() or 0, 0.35)
  if not self.visible and self.size.y < 1 then
    self.scroll.x, self.scroll.to.x = 0, 0
  end
  -- Never leave the field doc dirty: an unnamed dirty document would make the
  -- core ask "Save changes?" when the project is switched or the editor quits.
  if self.doc:is_dirty() then self.doc:clean() end
  DocView.update(self)
  if state.open and self == state.field then tick() end
end

---The field cannot be closed: cmd+w on the bar collapses it instead.
function FindField:try_close()
  close_bar()
end

function FindField:draw()
  if self.size.y < 1 then return end
  DocView.draw(self)
  -- hairline on top of the row, like the status bar has
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, style.divider_size, style.divider)
end

-------------------------------------------------------------------------------
-- Controls (the clickable strip in the gutter)
-------------------------------------------------------------------------------

local function control_width(font, text)
  return font:get_width(text) + style.padding.x * 2
end

---Rebuilds `self.controls`, the strip of clickable parts of the row.
---
---It is laid out from the right edge (where Sublime puts the find panel's
---buttons) and drawn by `draw_overlay`; `get_right_inset` keeps the text from
---running underneath it.  Called from `get_right_inset`, so the drawing and the
---hit testing always agree.
function FindField:layout_controls()
  local cfg = config.plugins.findbar
  local font = self:get_font()
  local controls = {}
  local x = 0
  local function push(text, color, command_name, tooltip, min_width)
    local w = control_width(font, text)
    controls[#controls + 1] = {
      text = text, color = color, command = command_name,
      tooltip = tooltip, offset = x, w = math.max(w, min_width or 0),
    }
    x = x + controls[#controls].w
  end

  if self.kind == "find" then
    push("<", style.dim, "findbar:previous", "Previous match")
    push(">", style.dim, "findbar:next", "Next match")
    push("Aa", cfg.case_sensitive and style.accent or style.dim,
      "findbar:toggle-case", "Case sensitive")
    push(".*", cfg.regex and style.accent or style.dim,
      "findbar:toggle-regex", "Regular expression")
    push("\\b", cfg.whole_word and style.accent or style.dim,
      "findbar:toggle-word", "Whole word")
    -- The counter owns a fixed width slot at the right edge, so that neither a
    -- growing match count nor the "Wrapped" hint moves the buttons around.
    -- "Wrapped" borrows the slot for a moment (Sublime shows it there too) and
    -- the count stays visible in the tooltip.
    local text, color, tip = state.count_text(), style.dim, "Matches in this file"
    if state.err then
      text, color, tip = "!", style.error, state.err
    elseif state.wrapped_at
        and system.get_time() - state.wrapped_at < cfg.wrapped_hint_time then
      tip = (text == "" and "" or (text .. " matches"))
      text, color = "Wrapped", style.warn
      if tip ~= "" then tip = tip .. ", search wrapped" end
    elseif state.query ~= "" and state.count == 0 and not state.counting then
      color = style.error
    end
    push(text, color, nil, tip, control_width(font, "00/000"))
    -- right aligned inside its slot, so that the count growing a digit does not
    -- push the buttons around
    controls[#controls].align = "right"
  else
    push("Replace", style.text, "findbar:replace-current", "Replace this match")
    push("All", style.text, "findbar:replace-all", "Replace every match in the file")
  end

  self.controls = controls
  self.controls_width = x
  local offset = self.size.x - x
  for _, c in ipairs(controls) do c.x = offset + c.offset end
end

---The buttons live on the right of the row; the text is clipped just before
---them (see the fork's DocView:get_right_inset).
function FindField:get_right_inset()
  if self.size.y < 1 then return 0 end
  self:layout_controls()
  return self.controls_width + style.padding.x
end

---No visible gutter, but the row reserves the same width as the line number
---area of the document it belongs to, so that the query starts exactly where
---the code does.  `left_inset` is kept up to date by the engine.
function FindField:get_gutter_width()
  return self.left_inset or 0, 0
end

---The inherited CommandView implementation draws a label in the gutter; the bar
---draws its own controls instead.
function FindField:draw_line_gutter(line, x, y, width)
  return self:get_line_height()
end

---Draws the controls.  Note that `DocView.draw_overlay` here is the plugin's
---own wrapper around the core one: it draws the caret and, for a document view,
---the match highlights.  For a field it stops after the caret.
function FindField:draw_overlay()
  DocView.draw_overlay(self)
  if self.size.y < 1 then return end
  local font = self:get_font()
  local lh = self:get_line_height()
  local ty = self.position.y + style.padding.y + self:get_line_text_y_offset()
  for _, c in ipairs(self.controls) do
    local cx = self.position.x + c.x
    if c.command and self.hovered_control == c then
      renderer.draw_rect(cx, self.position.y, c.w, self.size.y, style.line_highlight)
    end
    common.draw_text(font, c.color, c.text, c.align or "center", cx, ty, c.w, lh)
  end
end

function FindField:control_at(x, y)
  if y < self.position.y or y > self.position.y + self.size.y then return end
  for _, c in ipairs(self.controls) do
    local cx = self.position.x + c.x
    if x >= cx and x <= cx + c.w then return c end
  end
end

function FindField:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local c = self:control_at(x, y)
    if c then
      if c.command then command.perform(c.command) end
      -- swallow the click: no caret move, no line selection
      return true
    end
  end
end

function FindField:on_mouse_moved(x, y, ...)
  self.hovered_control = self:control_at(x, y)
  if self.hovered_control and self.hovered_control.tooltip then
    core.status_view:show_tooltip(self.hovered_control.tooltip)
  end
  -- one frame of lag between a tooltip and the hover flag never bothered
  -- anyone, but the caret/drag/word-snap handling below is core code we want
  DocView.on_mouse_moved(self, x, y, ...)
end

function FindField:on_mouse_left()
  self.hovered_control = nil
  DocView.on_mouse_left(self)
end

-------------------------------------------------------------------------------
-- Engine
-------------------------------------------------------------------------------

state.open = false
state.field = nil          -- the find field
state.target = nil         -- the DocView being searched
state.doc = nil            -- target.doc
state.query = ""
state.compiled = nil       -- matcher for `query`
state.err = nil            -- regex compile error
state.current = nil        -- { line, col, len } of the selected match
state.anchor_line = 1      -- where the next search starts from
state.anchor_col = 1
state.count = 0
state.index = 0
state.counting = false
state.truncated = false
state.wrapped_at = nil
state.replace_open = false    -- is the replace row on screen?
state.field_replace = nil     -- the replace field
state.replaced = 0            -- replacements done by the last Replace All
state.dirty_at = nil       -- set while the count has to be redone
state.scanned_change_id = nil
state.show_highlights = false
state.highlight_change_id = nil
state.scan_token = 0

---The "3/27" counter, as drawn in the gutter.
function state.count_text()
  if state.err then return "!" end
  if state.query == "" then return "" end
  if state.count == 0 then return state.counting and "..." or "0" end
  local total = state.truncated and (tostring(config.plugins.findbar.max_matches) .. "+") or tostring(state.count)
  if state.index > 0 then return state.index .. "/" .. total end
  return total
end

---Drops the cached count: the query, the toggles or the document changed.
local function invalidate_count()
  state.scan_token = state.scan_token + 1
  state.count, state.index, state.counting, state.truncated = 0, 0, false, false
  state.scanned_change_id = nil
  state.dirty_at = nil
end

---Reads the field text and the toggles back into the engine.
function recompile()
  local cfg = config.plugins.findbar
  state.query = state.field and state.field:get_text() or ""
  state.err, state.compiled = nil, nil
  if state.query ~= "" then
    state.compiled, state.err = matcher.compile(state.query, cfg.case_sensitive, cfg.regex, cfg.whole_word)
  end
  invalidate_count()
  state.show_highlights = state.compiled ~= nil
  state.highlight_change_id = state.doc and state.doc:get_change_id() or nil
end

---Selects `col1..col2` of `line` in the target document.
local function select_match(line, col1, col2)
  local doc = state.doc
  if not doc then return end
  doc:set_selection(line, col1, line, col2)
  if state.target then state.target:scroll_to_line(line, true) end
  state.current = { line = line, col = col1, len = col2 - col1 }
  state.anchor_line, state.anchor_col = line, col1
end

---Moves to the next (dir > 0) or previous (dir < 0) match.
---@param from_anchor? boolean search from the anchor instead of after the current match
function jump(dir, from_anchor)
  local doc, m = state.doc, state.compiled
  if not doc or not m then return false end
  local line, col
  if from_anchor or not state.current then
    line, col = doc:get_selection(true)
  elseif dir > 0 then
    line, col = state.current.line, state.current.col + state.current.len
  else
    line, col = state.current.line, state.current.col
  end

  local l1, c1, c2, wrapped
  if dir > 0 then
    l1, c1, c2 = find_forward(m, doc, line, col)
    if not l1 and config.plugins.findbar.wrap then
      l1, c1, c2 = find_forward(m, doc, 1, 1)
      wrapped = l1 ~= nil
    end
  else
    l1, c1, c2 = find_backward(m, doc, line, col)
    if not l1 and config.plugins.findbar.wrap then
      l1, c1, c2 = find_backward(m, doc, #doc.lines, math.huge)
      wrapped = l1 ~= nil
    end
  end
  if not l1 then
    state.current = nil
    return false
  end

  -- keep the counter in step when the total is already known
  if state.count > 0 and state.index > 0 then
    if wrapped then
      state.index = dir > 0 and 1 or state.count
    else
      state.index = ((state.index - 1 + dir) % state.count) + 1
    end
  else
    state.dirty_at = system.get_time()
  end
  select_match(l1, c1, c2)
  state.wrapped_at = wrapped and system.get_time() or nil
  return true
end

---Counts the matches: inline for normal documents, in a coroutine for huge
---ones so that typing never blocks on a 100k line file.
local function start_scan()
  local cfg = config.plugins.findbar
  local doc, m = state.doc, state.compiled
  if not doc or not m then return end
  state.dirty_at = nil
  local change_id = doc:get_change_id()
  state.scanned_change_id = change_id
  local anchor_line = state.current and state.current.line or state.anchor_line
  local anchor_col = state.current and state.current.col or state.anchor_col

  local function apply(res)
    state.count, state.truncated = res.total, res.truncated
    state.index = res.total > 0 and math.min(res.before + 1, res.total) or 0
    state.counting = false
  end

  if #doc.lines <= cfg.sync_scan_lines then
    local res = scan_document(doc, m, anchor_line, anchor_col)
    if res and doc:get_change_id() == change_id then apply(res) end
    state.counting = false
    return
  end

  state.scan_token = state.scan_token + 1
  local token = state.scan_token
  state.counting = true
  core.add_thread(function()
    local res = scan_document(doc, m, anchor_line, anchor_col, function()
      core.redraw = true
      if token ~= state.scan_token then return false end
      if doc:get_change_id() ~= change_id then
        -- the document changed under us: recount once the edits settle
        state.dirty_at = system.get_time()
        return false
      end
      return true
    end)
    if token ~= state.scan_token then return end
    state.counting = false
    if res then apply(res) end
    core.redraw = true
  end)
end

---Collects every match of `m`, as { line, col, len }.  Used by Replace All.
---@return table[] matches
---@return boolean truncated
local function collect_matches(doc, m, cap)
  local matches, truncated = {}, false
  for line = 1, #doc.lines do
    local text = doc.lines[line]
    if text then
      local content = line_content(text)
      local hay = haystack(m, content)
      local col = 1
      while true do
        local s, e = find_in_line(m, content, hay, col)
        if not s then break end
        matches[#matches + 1] = { line = line, col = s, len = e - s + 1 }
        if #matches >= cap then
          truncated = true
          break
        end
        col = e + 1
      end
    end
    if truncated then break end
  end
  return matches, truncated
end

---Expands the backslash escapes Sublime understands in a replacement.
local function expand_escapes(text)
  return (text:gsub("\\(.)", function(c)
    if c == "n" then return "\n" end
    if c == "t" then return "\t" end
    if c == "r" then return "\r" end
    if c == "\\" then return "\\" end
    return c
  end))
end

---The text that replaces the match at `line, col1, col2`.
---
---Regex mode substitutes `$0`..`$9` from the match's capture offsets (the API
---reports groups by offset, not by name, so `${name}` is not supported) and then
---expands the backslash escapes; plain mode is literal plus the escapes.
local function replacement_text(m, line, col1, col2)
  local repl = state.field_replace and state.field_replace:get_text() or ""
  if m.regex and m.re then
    local offsets = { m.re:cmatch(line, col1, regex.NOTEMPTY) }
    local function group(i)
      local s, e = offsets[i * 2 + 1], offsets[i * 2 + 2]
      if not s or not e then return "" end
      return line:sub(s, e - 1)
    end
    repl = repl:gsub("%$%{?(%d+)%}?", function(n) return group(tonumber(n)) end)
    repl = repl:gsub("%$%$", "$")   -- "$$" is an escaped dollar sign
  end
  return expand_escapes(repl)
end

---Replaces the current match and moves on to the next one.
local function replace_current()
  local doc, m = state.doc, state.compiled
  if not doc or not m then return false end
  if not state.current then
    -- nothing selected yet: take the first match, so that a single press still
    -- does something useful
    if not jump(1) then return false end
  end
  local cur = state.current
  local old_text = doc:get_text(cur.line, cur.col, cur.line, cur.col + cur.len)
  local new_text = replacement_text(m, doc.lines[cur.line], cur.col, cur.col + cur.len)
  if new_text ~= old_text then
    doc:remove(cur.line, cur.col, cur.line, cur.col + cur.len)
    doc:insert(cur.line, cur.col, new_text)
  end
  -- the replacement may itself contain the query, so the count has to be redone
  invalidate_count()
  state.current = nil
  local l, c = doc:position_offset(cur.line, cur.col, #new_text)
  doc:set_selection(l, c, l, c)
  if state.target then state.target:scroll_to_line(l, true) end
  jump(1)
  state.dirty_at = system.get_time()
  return true
end

---Replaces every match in the document.  Works backwards so that the positions
---collected before the edit stay valid, and lands in one undo step (all the
---edits share the same timestamp, which the undo stack merges).
local function replace_all()
  local doc, m = state.doc, state.compiled
  if not doc or not m then return false end
  local matches, truncated = collect_matches(doc, m, config.plugins.findbar.max_matches)
  if #matches == 0 then
    core.error("Replace: no match for %q", state.query)
    return false
  end
  local n = 0
  for i = #matches, 1, -1 do
    local mt = matches[i]
    local text = doc.lines[mt.line]
    if text then
      local old_text = doc:get_text(mt.line, mt.col, mt.line, mt.col + mt.len)
      local new_text = replacement_text(m, text, mt.col, mt.col + mt.len)
      if new_text ~= old_text then
        doc:remove(mt.line, mt.col, mt.line, mt.col + mt.len)
        doc:insert(mt.line, mt.col, new_text)
        n = n + 1
      end
    end
  end
  state.replaced = n
  doc:set_selection(matches[1].line, matches[1].col)
  if state.target then state.target:scroll_to_line(matches[1].line, true) end
  invalidate_count()
  state.current = nil
  recompile()
  state.dirty_at = system.get_time()
  core.log("Replaced %d occurrence(s) of %q%s", n, state.query, truncated and " (truncated)" or "")
  return n > 0
end

---Points the engine at the document of the focused view.  Does nothing when a
---view that is not a document has the focus (the treeview, the AI panel, one of
---our own fields), so the previous target survives a detour through the UI.
---@return boolean have_target
function retarget()
  local av = core.active_view
  if av and av:is(DocView) and not av:is(FindField) and not av:is(CommandView) then
    if state.doc ~= av.doc then
      invalidate_count()
      state.target, state.doc = av, av.doc
      state.current = nil
      state.anchor_line, state.anchor_col = av.doc:get_selection(true)
      if state.query ~= "" then recompile() end
    end
  end
  if not state.doc or not core.root_view.root_node:get_node_for_view(state.target) then
    state.target, state.doc = nil, nil
    return false
  end
  return true
end

---Shows the bar and focuses a field.
---@param want_replace? boolean also show the replace row
---@return boolean ok
function open_bar(want_replace)
  if not retarget() then return false end
  state.open = true
  state.field.visible = true
  if want_replace ~= nil then state.replace_open = want_replace end
  state.field_replace.visible = state.replace_open
  local focus = (state.replace_open and want_replace and state.field_replace) or state.field
  core.set_active_view(focus)
  return true
end

function close_bar()
  if state.query ~= "" then insert_unique(core.previous_find, state.query) end
  local replace_text = state.field_replace and state.field_replace:get_text() or ""
  if replace_text ~= "" then insert_unique(core.previous_replace, replace_text) end
  state.open = false
  state.replace_open = false
  state.field.visible = false
  state.field_replace.visible = false
  if not config.plugins.findbar.keep_selection_on_close then
    -- Collapse the selection and drop the highlights: leaving the match
    -- selected means the next keystroke replaces it, which is not what
    -- "close the search" should do.
    local cur = state.current
    if state.doc and cur then
      state.doc:set_selection(cur.line, cur.col, cur.line, cur.col)
    end
    state.current = nil
    state.show_highlights = false
  end
  if state.target and core.root_view.root_node:get_node_for_view(state.target) then
    core.set_active_view(state.target)
  end
  save_state()
end

function toggle(which)
  local cfg = config.plugins.findbar
  cfg[which] = not cfg[which]
  save_state()
  if state.open then
    recompile()
    if state.compiled then jump(1, true) end
    state.dirty_at = system.get_time()
  end
end

---The selection of the searched document, when it can seed the query.
local function selection_text()
  local doc = state.doc
  if not doc or not doc:has_selection() then return nil end
  local l1, c1, l2, c2 = doc:get_selection(true)
  if l1 ~= l2 then return nil end
  local text = doc:get_text(l1, c1, l2, c2)
  if text == "" or text:find("[\r\n]") or #text > 200 then return nil end
  return text
end

---Runs once per frame, from the focused field.
function tick()
  local field = state.field
  if not field or not state.doc then return end

  -- keep the two rows aligned with the document's text column
  local inset = state.target:get_gutter_width()
  field.left_inset = inset
  state.field_replace.left_inset = inset

  -- the tab we were searching is gone
  if not core.root_view.root_node:get_node_for_view(state.target) then
    close_bar()
    return
  end

  if field:get_text() ~= state.query then
    recompile()
    if state.compiled then
      jump(1, true)
    else
      state.current = nil
    end
    state.dirty_at = system.get_time()
  end

  -- somebody else moved the selection (a click in the document, an edit):
  -- follow the caret and recount from there
  local l1, c1 = state.doc:get_selection(true)
  local known = state.current
  if not known or known.line ~= l1 or known.col ~= c1 then
    state.current = nil
    state.anchor_line, state.anchor_col = l1, c1
    state.index = 0
    state.dirty_at = state.dirty_at or system.get_time()
  end

  if state.doc:get_change_id() ~= state.scanned_change_id and not state.dirty_at then
    invalidate_count()
    state.dirty_at = system.get_time()
  end
  if state.dirty_at and system.get_time() - state.dirty_at >= config.plugins.findbar.count_delay then
    start_scan()
  end
  if state.counting
      or (state.wrapped_at and system.get_time() - state.wrapped_at < config.plugins.findbar.wrapped_hint_time) then
    core.redraw = true
  end
end

-------------------------------------------------------------------------------
-- Highlighting (drawn on top of the document)
-------------------------------------------------------------------------------

local function draw_highlights(dv)
  local cfg = config.plugins.findbar
  local m = state.compiled
  if not m or not state.show_highlights or dv.doc ~= state.doc then return end
  if not state.open and state.highlight_change_id ~= dv.doc:get_change_id() then
    -- the document was edited after the bar was closed: the matches we know
    -- about are stale, stop advertising them
    state.show_highlights = false
    return
  end

  local minline, maxline = dv:get_visible_line_range()
  local lh = dv:get_line_height()
  local border = math.max(1, common.round(1 * SCALE))
  local current = state.current
  local fill, edge, current_fill = {}, {}, {}
  for i = 1, 4 do
    fill[i], edge[i], current_fill[i] = style.selection[i], style.selection[i], style.selection[i]
  end
  fill[4] = cfg.fill_alpha
  edge[4] = cfg.border_alpha
  current_fill[4] = cfg.current_fill_alpha

  for line = minline, maxline do
    local text = dv.doc.lines[line]
    if text then
      local content = line_content(text)
      local hay = haystack(m, content)
      local col = 1
      while true do
        local s, e = find_in_line(m, content, hay, col)
        if not s then break end
        if cfg.highlight_all or (current and current.line == line and current.col == s) then
          local x, y = dv:get_line_screen_position(line, s)
          local x2 = dv:get_line_screen_position(line, e + 1)
          local w = x2 - x
          if w > 0 then
            local is_current = current and current.line == line and current.col == s
            renderer.draw_rect(x, y, w, lh, is_current and current_fill or fill)
            renderer.draw_rect(x, y, w, border, edge)
            renderer.draw_rect(x, y + lh - border, w, border, edge)
            renderer.draw_rect(x, y, border, lh, edge)
            renderer.draw_rect(x + w - border, y, border, lh, edge)
          end
        end
        col = e + 1
      end
    end
  end
end

local old_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay(...)
  old_draw_overlay(self, ...)
  if not self:is(FindField) then draw_highlights(self) end
end

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

command.add(function()
  local av = core.active_view
  return av ~= nil and av:is(FindField), av
end, {
  -- While a field has the focus.  Every one of these must return true: the
  -- keymap performs the first command whose predicate matched and *then* keeps
  -- walking the list when it returns a falsy value, so a `nil` here would let
  -- doc:newline / doc:indent run on the field as well.
  ["findbar:submit"] = function(field)
    if field.kind == "find" then
      jump(1)
    else
      -- Enter in the replace field: replace this match, move to the next one
      replace_current()
    end
    return true
  end,
  ["findbar:submit-previous"] = function(field)
    jump(-1)
    return true
  end,
  ["findbar:tab"] = function(field)
    -- Tab walks between the two rows, like Sublime's find/replace panel
    local other = field.kind == "find" and state.field_replace or state.field
    if other and other.visible then
      core.set_active_view(other)
      other.doc:set_selection(math.huge, math.huge, 1, 1)
    end
    return true
  end,
  ["findbar:tab-previous"] = function(field)
    local other = field.kind == "find" and state.field_replace or state.field
    if other and other.visible then
      core.set_active_view(other)
      other.doc:set_selection(math.huge, math.huge, 1, 1)
    end
    return true
  end,
  ["findbar:history-previous"] = function(field)
    field:history_walk(-1)
    return true
  end,
  ["findbar:history-next"] = function(field)
    field:history_walk(1)
    return true
  end,
})

-- These two also work when the focus is in the document but the bar is open
-- (cmd+alt+return, the Replace All shortcut), so they are gated on the bar.
local function bar_open()
  return state.open and state.compiled ~= nil
end

command.add(function() return bar_open() end, {
  ["findbar:replace-current"] = function()
    replace_current()
    return true
  end,
  ["findbar:replace-all"] = function()
    replace_all()
    return true
  end,
})

-- Esc must close the bar whenever it is open, not only when a field has the
-- focus: clicking into the document (or switching tabs) moves the focus away
-- from the field, but the bar stays on screen and Esc should still dismiss it.
-- Gated on state.open alone (not bar_open, which also needs a compiled query)
-- so an empty bar can be dismissed too.  Overrides the FindField registration
-- above (command.add replaces existing entries).
command.add(function() return state.open end, {
  ["findbar:escape"] = function()
    close_bar()
    return true
  end,
})

command.add(nil, {
  ["findbar:find"] = function()
    local was_open = state.open
    if not open_bar() then
      -- No document to search: nothing to do.  We must not call the legacy
      -- find prompt here: its .perform() runs the handler unconditionally
      -- (no predicate check) and the handler dereferences
      -- core.active_view.doc, which is nil when no DocView exists, so it
      -- would crash with "attempt to index a nil value".
      return true
    end
    -- Seed the query from the selection, but only when the bar was closed: once
    -- it is open the document's selection *is* the current match, and seeding
    -- from it would overwrite a regex query with whatever it matched.
    if not was_open then
      local selected = selection_text()
      if selected then state.field:set_text(selected, true) end
    end
    if state.field:get_text() ~= "" then
      -- keep the query, but select it so that typing replaces it
      state.field.doc:set_selection(math.huge, math.huge, 1, 1)
    end
    recompile()
    if state.compiled then jump(1, true) end
    state.dirty_at = system.get_time()
    return true
  end,

  -- cmd+g / F3 with the bar closed: walk the last search without popping the
  -- bar open (Sublime does the same).  With nothing to search for, cmd+g keeps
  -- doing what it did before this plugin existed: go to line.
  ["findbar:next"] = function()
    if not retarget() then return true end
    if state.query == "" and not state.compiled then
      command.perform("doc:go-to-line")
      return true
    end
    if not state.compiled then recompile() end
    if jump(1) then state.dirty_at = state.dirty_at or system.get_time() end
    return true
  end,

  ["findbar:previous"] = function()
    if not retarget() then return true end
    if state.query == "" and not state.compiled then return true end
    if not state.compiled then recompile() end
    if jump(-1) then state.dirty_at = state.dirty_at or system.get_time() end
    return true
  end,

  ["findbar:toggle-case"] = function() toggle("case_sensitive"); return true end,
  ["findbar:toggle-regex"] = function() toggle("regex"); return true end,
  ["findbar:toggle-word"] = function() toggle("whole_word"); return true end,

  -- the replace row: same seed-the-query logic as cmd+f, but it opens the
  -- second row and puts the focus in it when there is already a query
  ["findbar:find-replace"] = function()
    local was_open = state.open
    if not open_bar(true) then
      return true
    end
    if not was_open then
      local selected = selection_text()
      if selected then state.field:set_text(selected, true) end
    end
    recompile()
    if state.compiled then jump(1, true) end
    state.dirty_at = system.get_time()
    if state.field:get_text() == "" then core.set_active_view(state.field) end
    return true
  end,
})

---Walks the search history inside a field.
function FindField:history_walk(dir)
  local list = self.kind == "find" and core.previous_find or core.previous_replace
  if #list == 0 then return end
  self.history_idx = (self.history_idx or 0) + dir
  if self.history_idx < 1 then self.history_idx = #list end
  if self.history_idx > #list then self.history_idx = 1 end
  local value = list[self.history_idx]
  if type(value) ~= "string" then return end
  self:set_text(value, true)
  if self.kind == "find" then
    recompile()
    if state.compiled then jump(1, true) end
    state.dirty_at = system.get_time()
  end
end

function insert_unique(list, value)
  if value == nil or value == "" then return end
  for i = #list, 1, -1 do
    if list[i] == value then table.remove(list, i) end
  end
  table.insert(list, 1, value)
  while #list > 30 do table.remove(list) end
end

-------------------------------------------------------------------------------
-- Keymap
--
-- `keymap.add` without overwrite *prepends* to the command list of a stroke,
-- and the keymap performs the first command whose predicate is valid.  That is
-- what we need for Enter/Tab/Esc, which the core also binds (doc:newline,
-- doc:indent, doc:select-none): our command refuses to run unless one of the
-- fields has the focus, so everything else keeps working.
-------------------------------------------------------------------------------

keymap.add({
  ["return"] = "findbar:submit",
  ["shift+return"] = "findbar:submit-previous",
  ["tab"] = "findbar:tab",
  ["shift+tab"] = "findbar:tab-previous",
  ["escape"] = "findbar:escape",
  ["f3"] = "findbar:next",
  ["shift+f3"] = "findbar:previous",
  ["alt+up"] = "findbar:history-previous",
  ["alt+down"] = "findbar:history-next",
  ["option+up"] = "findbar:history-previous",
  ["option+down"] = "findbar:history-next",
  -- replace the current match: prepended, so it only wins inside a field and
  -- cmd+return keeps inserting a line below everywhere else
  [MOD .. "+return"] = "findbar:replace-current",
})

-- These strokes are the bar's now.  `ctrl+g` stays on "go to line", matching
-- Sublime; `find-replace:find` is kept as a command name (see below) so the
-- palette and the muscle memory still work.
keymap.add({
  [MOD .. "+f"] = "findbar:find",
  [MOD .. "+r"] = "findbar:find-replace",
  [MOD .. "+alt+f"] = "findbar:find-replace",
  [MOD .. "+alt+return"] = "findbar:replace-all",
  [MOD .. "+g"] = "findbar:next",
  [MOD .. "+shift+g"] = "findbar:previous",
  [MOD .. "+alt+c"] = "findbar:toggle-case",
  [MOD .. "+alt+r"] = "findbar:toggle-regex",
  [MOD .. "+alt+w"] = "findbar:toggle-word",
}, true)

-------------------------------------------------------------------------------
-- Mount
-------------------------------------------------------------------------------

local find_field = FindField("find")
local replace_field = FindField("replace")
state.field = find_field
state.field_replace = replace_field

-- Locked nodes take their size from their view's `size.y`, which
-- `FindField:update` animates between 0 and one row.
--
-- Docking: the bar belongs to the *editing area*, not to the window.  The
-- sidebar and the AI panel dock into the document leaf themselves and they load
-- before us (see the plugin priority), so the primary node is exactly the area
-- the code lives in: docking there lines the query up with the code, gives the
-- sidebar its full height back, and keeps the bar off the parts of the window
-- that are not the editor.  Docking into the root chain instead spans the whole
-- window, i.e. the input starts underneath the sidebar.
--
-- The rows go at the *bottom* of that area (above the status bar), like
-- Sublime's find panel: the document keeps the top of the screen, the panel
-- grows from the bottom edge of the editor.
do
  -- Reuse the nodes of a previous load (core:reload-module while hacking on
  -- this file): docking a second time would leave the old rows behind.
  local function take_over(field)
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if v ~= field and v.kind == field.kind and v.__tostring and v:__tostring() == "FindField" then
        local node = core.root_view.root_node:get_node_for_view(v)
        if node and #node.views == 1 then
          node.views[1] = field
          node.active_view = field
          field.node = node
          return true
        end
      end
    end
    return false
  end

  local node = core.root_view:get_primary_node()
  if not take_over(replace_field) and node and node.type == "leaf" then
    -- the replace row goes directly under the document...
    replace_field.node = node:split("down", replace_field, { y = true })
  end
  if not take_over(find_field) and replace_field.node then
    -- ...and the find row right above it: the bar sits at the bottom of the
    -- editing area, just above the status bar, with Find over Replace -- the
    -- order Sublime's panel uses
    find_field.node = replace_field.node:split("up", find_field, { y = true })
  end
end

-- Re-register the stock find commands so that F3, the command palette and the
-- old tooltips keep working, but now driving the bar.  The legacy
-- implementations stay in core/commands/findreplace.lua and are used when the
-- bar has no query yet (their `last_fn`/`last_text` still work).
legacy = {
  repeat_find = command.map["find-replace:repeat-find"],
  previous_find = command.map["find-replace:previous-find"],
}

command.add("core.docview!", {
  ["find-replace:find"] = function()
    command.perform("findbar:find")
  end,
  ["find-replace:replace"] = function()
    command.perform("findbar:find-replace")
  end,
  ["find-replace:repeat-find"] = function()
    if state.compiled then command.perform("findbar:next")
    elseif legacy.repeat_find then legacy.repeat_find.perform() end
  end,
  ["find-replace:previous-find"] = function()
    if state.compiled then command.perform("findbar:previous")
    elseif legacy.previous_find then legacy.previous_find.perform() end
  end,
})

load_state()

return {
  state = state,
  matcher = matcher,
  -- exposed so that the matcher can be exercised without a running editor
  -- (the stubbed harness lives outside the repo)
  scan = scan_document,
  collect = collect_matches,
  find_forward = find_forward,
  find_backward = find_backward,
  find_in_line = find_in_line,
  line_content = line_content,
  replacement_text = replacement_text,
}
