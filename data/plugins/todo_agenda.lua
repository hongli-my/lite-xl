-- mod-version:4
-- todo_agenda: aggregate Markdown task-list items across the project into a
-- single view with three projections over the same data:
--
--   * list     - the original grouped list (click checkbox to toggle,
--                click text to jump to the source line)
--   * kanban   - columns = #tags; drag a card between columns rewrites the
--                tag in the source file (through the Doc model when open)
--   * calendar - month grid; tasks with @due(YYYY-MM-DD) land on their day,
--                overdue open tasks are highlighted
--
-- Task syntax understood (all optional except the checkbox):
--   - [ ] buy milk @due(2026-10-16) #errands
-- Multiple #tags are allowed; the first one is the kanban column.  Dates use
-- YYYY-MM-DD.  Everything is written back through doc:insert/doc:remove so
-- the change lands on the undo stack and a dirty buffer is never clobbered;
-- files that are not open are patched on disk directly.
--
-- Toggle with "todo-agenda:toggle" (Ctrl+Shift+T).  The view is a normal tab;
-- a dirwatch thread keeps the list fresh while it is open.  Switch views
-- with the buttons in the header or todo-agenda:switch-view.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Dirwatch = require "core.dirwatch"

config.plugins.todo_agenda = common.merge({
  -- file extensions scanned for tasks (lowercase, no dot)
  extensions = { "md", "markdown" },
  -- re-scan at most this often (seconds) when a change is signalled
  rescan_cooldown = 0.5,
  -- show completed tasks below the open ones (list view)
  show_completed = true,
  -- kanban: column order for known tags; unknown tags are appended after
  kanban_columns = { "作业", "复习", "项目", "生活" },
  -- kanban: fallback column for tasks without a tag
  kanban_default_column = "其他",
  -- calendar: week starts on monday
  week_starts_monday = true,
}, config.plugins.todo_agenda)

-- A single task item:
--   { file = abs path, rel = display path, line = 1-based,
--     checked = bool, text = task text, bullet = "-", indent = leading spaces,
--     tag = first #tag or nil, tags = { all tags }, due = "YYYY-MM-DD" or nil }

-- Module-level reference to the live TodoView instance.  Declared here (before
-- any method that reads it) so try_close can nil it out; without this the
-- name resolves to a global and strict.lua rejects it.
local todo_view = nil

local TodoView = View:extend()

function TodoView:__tostring() return "TodoView" end

TodoView.context = "session"

function TodoView:new()
  TodoView.super.new(self)
  self.scrollable = true
  self.items = {}          -- flat list of task items
  self.searching = false
  self.selected_idx = 0
  self.hover_idx = 0
  self._rescan_pending = false
  self._last_rescan = 0
  self.watches = {}
  -- view state: "list" | "kanban" | "calendar"
  self.view_mode = "list"
  -- kanban drag state
  self.drag = nil          -- { item = item, from_tag = tag, x = px, y = px }
  -- calendar state
  local now = os.date("*t")
  self.cal_year = now.year
  self.cal_month = now.month
  -- header hit areas (rebuilt on every draw): switch buttons
  self._switch_rects = {}
  self._cal_nav_rects = {}
  -- kick off the first scan
  self:rescan()
  -- start a watcher thread that keeps the list fresh while the view lives
  self:start_watch()
end

function TodoView:get_name()
  return "待办"
end

-- Stop the background watch thread when the view is closed, and drop the
-- module-level reference so a fresh toggle creates a new view instead of
-- reactivating a dead one.
function TodoView:try_close(do_close)
  self._watch_alive = false
  if todo_view == self then todo_view = nil end
  do_close()
end

-----------------------------------------------------------------------
-- Parsing: @due() dates and #tags
-----------------------------------------------------------------------

local function is_task_file(filename, exts)
  local ext = filename:match("%.([^.]+)$")
  return ext and exts[string.lower(ext)] == true
end

-- Parse one markdown line into a task item, or nil.
-- Matches:  <indent> <bullet> [ ] text   /   <indent> <bullet> [x] text
-- Bullet is -, * or +.  The checkbox may use X or a space.
-- NOTE: "-" must be LAST inside the character class, otherwise Lua reads
-- "[-*+]" as a range from "*" to "+".  And the bullet must be its own
-- capture group, or the three captures (indent, box, text) land in the
-- wrong variables.
local function parse_task_line(line)
  local indent, bullet, box, text =
    line:match("^(%s*)([*+-])%s+%[([ xX])%]%s+(%S.*)$")
  if not text then return nil end
  local item = {
    indent = #indent,
    bullet = bullet,
    checked = (box == "x" or box == "X"),
    text = text,
  }
  -- tags: all #word tokens (first becomes the kanban column)
  item.tags = {}
  for tag in text:gmatch("#(%S+)") do
    item.tags[#item.tags + 1] = tag
  end
  item.tag = item.tags[1]
  -- due date: @due(YYYY-MM-DD)
  item.due = text:match("@due%((%d%d%d%d%-%d%d%-%d%d)%)")
  -- display text strips tags and due so list/kanban show clean prose
  item.display = text:gsub("@due%(%d%d%d%d%-%d%d%-%d%d%)", "")
    :gsub("#%S+", "")
    :gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "")
  if item.display == "" then item.display = text end
  return item
end

-- Scan a single file, appending task items to `out`.
local function scan_file(out, filename, rel)
  local fp = io.open(filename, "r")
  if not fp then return end
  local n = 0
  for line in fp:lines() do
    n = n + 1
    local t = parse_task_line(line)
    if t then
      t.file = filename
      t.rel = rel
      t.line = n
      out[#out + 1] = t
    end
    -- yield periodically so the UI stays responsive on big vaults
    if n % 200 == 0 then coroutine.yield(0) end
  end
  fp:close()
end

function TodoView:rescan()
  self.searching = true
  self.items = {}
  local exts = {}
  for _, e in ipairs(config.plugins.todo_agenda.extensions) do
    exts[e] = true
  end
  core.add_thread(function()
    local out = {}
    for _, project in ipairs(core.projects) do
      for dir_name, file in project:files() do
        if file.type == "file" and is_task_file(file.filename, exts) then
          local rel = common.relative_path(project.path, file.filename)
          scan_file(out, file.filename, rel)
        end
      end
    end
    -- open tasks first, then completed; stable within each group by file/line
    table.sort(out, function(a, b)
      if a.checked ~= b.checked then return not a.checked end
      if a.rel ~= b.rel then return a.rel < b.rel end
      return a.line < b.line
    end)
    self.items = out
    self.searching = false
    self._last_rescan = system.get_time()
    core.redraw = true
  end)
end

-----------------------------------------------------------------------
-- File watching
-----------------------------------------------------------------------

-- Watch the project root for changes and trigger a rescan (debounced) when a
-- markdown file might have changed.  Runs for the lifetime of the view.
-- Uses an auto-increment thread key (no weak_ref) instead of `self`, because
-- core.add_thread asserts that the key is absent from core.threads — and a
-- view can be constructed, closed, and constructed again while the old watch
-- thread (keyed on the now-GC'd view) is still mid-yield, which would trip
-- the assert.  The thread stops itself once the view is gone (the `self`
-- reference becomes nil inside the closure once `todo_view` is reassigned
-- and the old view is collected, but we also guard with an explicit liveness
-- check so the loop exits deterministically).
function TodoView:start_watch()
  self._watch_alive = true
  core.add_thread(function()
    while self._watch_alive do
      for _, project in ipairs(core.projects) do
        local watch = self.watches[project]
        if not watch then
          watch = Dirwatch.new()
          watch:watch(project.path)
          self.watches[project] = watch
        end
        watch:check(function(path)
          if path:match("%.[mM][dD]$") or path:match("%.[mM][aA][rR][kK][dD][oO][wW][nN]$") then
            self._rescan_pending = true
          end
        end)
      end
      coroutine.yield(1)
    end
  end)
end

-----------------------------------------------------------------------
-- Writing back to the source (Doc model first, disk second)
-----------------------------------------------------------------------

-- Find the Doc for `filename` if it is already open, so writes go onto the
-- undo stack and a dirty buffer is not clobbered.
local function find_open_doc(abs_filename)
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename == abs_filename then return doc end
  end
end

-- Rewrite line `item.line` of the item's file by applying `fn` to the old
-- line text.  Goes through the live Doc when the file is open (undo stack,
-- unsaved changes preserved); otherwise patches the file on disk.
-- Returns the new line text, or nil when nothing changed / write failed.
local function edit_task_line(item, fn)
  local doc = find_open_doc(item.file)
  if doc then
    local text = doc.lines[item.line] or ""
    local new_text = fn(text)
    if not new_text or new_text == text then return nil end
    doc:remove(item.line, 1, item.line, #text + 1)
    doc:insert(item.line, 1, new_text)
    return new_text
  end
  -- file not open: edit on disk
  local fp = io.open(item.file, "r")
  if not fp then return nil end
  local lines = {}
  for line in fp:lines() do lines[#lines + 1] = line end
  fp:close()
  local old = lines[item.line]
  if not old then return nil end
  local new_text = fn(old)
  if not new_text or new_text == old then return nil end
  lines[item.line] = new_text
  fp = io.open(item.file, "w")
  if not fp then return nil end
  for _, line in ipairs(lines) do fp:write(line, "\n") end
  fp:close()
  return new_text
end

-- Toggle the checkbox of a task.
local function toggle_task_in_source(item)
  local new_text = edit_task_line(item, function(text)
    if item.checked then
      return text:gsub("%[([ xX])%]", "[ ]", 1)
    else
      return text:gsub("%[([ xX])%]", "[x]", 1)
    end
  end)
  if new_text then
    item.checked = not item.checked
    -- refresh derived fields from the new source line
    local reparsed = parse_task_line(new_text)
    if reparsed then
      item.tags, item.tag, item.due, item.display =
        reparsed.tags, reparsed.tag, reparsed.due, reparsed.display
    end
  end
  return new_text
end

-- Replace the first #tag of a task (kanban drag between columns).
-- Keeps every other part of the line byte-identical.
-- Tags are escaped for gsub patterns so "-" or "(" inside a tag can not
-- break the match (pattern and replacement sides both).
-- Escape a tag for use in a gsub PATTERN (magic chars lose their meaning).
local function gsub_escape(s)
  return (s:gsub("([^%w])", "%%%1"))
end

-- Escape a tag for use in a gsub REPLACEMENT (only % is magic there).
local function gsub_escape_repl(s)
  return (s:gsub("%%", "%%%%"))
end

local function retag_task_in_source(item, new_tag)
  local old_tag = item.tag
  local new_text = edit_task_line(item, function(text)
    if old_tag then
      local pat = "#" .. gsub_escape(old_tag) .. "([%s%)]?)"
      local repl = "#" .. gsub_escape_repl(new_tag) .. "%1"
      return (text:gsub(pat, repl, 1))
    end
    -- no tag yet: append one at the end of the line
    return text:gsub("%s*$", "") .. " #" .. new_tag
  end)
  if new_text then
    local reparsed = parse_task_line(new_text)
    if reparsed then
      item.tags, item.tag, item.due, item.display =
        reparsed.tags, reparsed.tag, reparsed.due, reparsed.display
    end
    -- keep other items with the same (file,line) in sync (duplicate views)
    for _, it in ipairs(todo_view and todo_view.items or {}) do
      if it.file == item.file and it.line == item.line and it ~= item then
        local rp = reparsed
        it.tags, it.tag, it.due, it.display = rp.tags, rp.tag, rp.due, rp.display
        it.checked = reparsed.checked
      end
    end
  end
  return new_text
end

-----------------------------------------------------------------------
-- Shared helpers
-----------------------------------------------------------------------

local function today_str()
  return os.date("%Y-%m-%d")
end

local function date_parts(d)
  local y, m, day = d:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil end
  return tonumber(y), tonumber(m), tonumber(day)
end

-- Compare two "YYYY-MM-DD" strings (lexicographic works for this format).
local function date_lt(a, b) return a < b end
-- Whether `tag` is one of the configured columns (always shown, even empty).
-- NOTE: must stay above kanban_columns_with_items — it is a local there, so
-- calling it before this line would silently hit a global (rejected by
-- strict.lua in real lite-xl).
local function seen_in_config(tag)
  if tag == config.plugins.todo_agenda.kanban_default_column then return true end
  for _, t in ipairs(config.plugins.todo_agenda.kanban_columns) do
    if t == tag then return true end
  end
  return false
end

-- The columns to show: configured order first, then unknown tags in
-- first-seen order, then the default column last.
local function kanban_columns(items)
  local cols, seen = {}, {}
  local function add(tag)
    if not seen[tag] then seen[tag] = true cols[#cols + 1] = tag end
  end
  for _, tag in ipairs(config.plugins.todo_agenda.kanban_columns) do add(tag) end
  for _, it in ipairs(items) do
    if it.tag and not seen[it.tag] then add(it.tag) end
  end
  add(config.plugins.todo_agenda.kanban_default_column)
  return cols
end

local function column_of(item)
  return item.tag or config.plugins.todo_agenda.kanban_default_column
end

-- Tasks grouped per column: { { tag = t, items = {...} }, ... }
-- Unknown-but-populated columns show; configured columns show even empty.
local function kanban_columns_with_items(items)
  local cols = kanban_columns(items)
  local by_tag = {}
  for _, tag in ipairs(cols) do by_tag[tag] = { tag = tag, items = {} } end
  for _, it in ipairs(items) do
    local col = by_tag[column_of(it)]
    if col then col.items[#col.items + 1] = it end
  end
  local out = {}
  for _, tag in ipairs(cols) do
    local c = by_tag[tag]
    if #c.items > 0 or seen_in_config(tag) then out[#out + 1] = c end
  end
  return out
end

-----------------------------------------------------------------------
-- Layout: header / switcher
-----------------------------------------------------------------------

function TodoView:get_line_height()
  return style.padding.y + style.font:get_height()
end

function TodoView:get_header_height()
  return style.font:get_height() + style.padding.y * 3
end

local VIEW_LABELS = { list = "列表", kanban = "看板", calendar = "日历" }

-- Draw the header: stats (left) + view switch buttons (right).
-- Records the button hit rects in self._switch_rects.
function TodoView:draw_header(x, y, w)
  self._switch_rects = {}
  local fh = style.font:get_height()
  local text
  if self.searching then
    text = string.format("正在扫描待办…（已找到 %d 项）", #self.items)
  else
    local open_n, done_n, over_n = 0, 0, 0
    local today = today_str()
    for _, it in ipairs(self.items) do
      if it.checked then done_n = done_n + 1 else
        open_n = open_n + 1
        if it.due and date_lt(it.due, today) then over_n = over_n + 1 end
      end
    end
    text = string.format("待办 %d · 已完成 %d", open_n, done_n)
    if over_n > 0 then text = text .. string.format(" · 逾期 %d", over_n) end
  end
  common.draw_text(style.font, style.accent or style.text, text, "left",
    x, y, w, fh)
  -- switch buttons on the right
  local bx = x + w
  for _, mode in ipairs({ "calendar", "kanban", "list" }) do
    local label = VIEW_LABELS[mode]
    local bw = style.font:get_width(label) + style.padding.x * 2
    bx = bx - bw
    local on = (self.view_mode == mode)
    renderer.draw_rect(bx, y, bw, fh,
      on and (style.line_highlight or style.background2) or style.background2)
    if on then
      renderer.draw_rect(bx, y + fh - 2 * SCALE, bw, 2 * SCALE, style.accent or style.text)
    end
    common.draw_text(style.font, on and (style.accent or style.text) or style.dim,
      label, "center", bx, y, bw, fh)
    self._switch_rects[#self._switch_rects + 1] =
      { mode = mode, x = bx, y = y, w = bw, h = fh }
    bx = bx - style.padding.x
  end
end

-----------------------------------------------------------------------
-- Layout: list view (original behaviour)
-----------------------------------------------------------------------

function TodoView:get_scrollable_size()
  if self.view_mode == "kanban" or self.view_mode == "calendar" then
    return math.huge  -- these views manage their own scrolling (horizontal)
  end
  return self:get_header_height() + #self.items * self:get_line_height()
end

function TodoView:get_visible_range()
  local lh = self:get_line_height()
  local oy = self:get_header_height()
  local min = self.scroll.y + oy - style.font:get_height()
  min = math.max(1, math.floor(min / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end

function TodoView:each_visible_item()
  return coroutine.wrap(function()
    local lh = self:get_line_height()
    local x, y = self:get_content_offset()
    local min, max = self:get_visible_range()
    y = y + self:get_header_height() + lh * (min - 1)
    local _, _, w = self:get_content_bounds()
    for i = min, max do
      local item = self.items[i]
      if not item then break end
      coroutine.yield(i, item, x, y, w, lh)
      y = y + lh
    end
  end)
end

-- The checkbox rect for an item row.  x is the row's left edge.
local function checkbox_rect(x, y, lh)
  local box = math.floor(lh * 0.55)
  local bx = x + style.padding.x
  local by = y + math.floor((lh - box) / 2)
  return bx, by, box, box
end

-----------------------------------------------------------------------
-- Layout: kanban view
-----------------------------------------------------------------------

local function kanban_geometry(self)
  local cols = kanban_columns_with_items(self.items)
  local lh = self:get_line_height()
  local card_h = lh + style.padding.y      -- one line + breathing room
  local col_w = math.max(160 * SCALE, math.min(240 * SCALE,
    (self.size.x - style.padding.x * 2) / math.max(1, #cols)))
  local gap = style.padding.x
  local x0 = self.position.x + style.padding.x
  local y0 = self.position.y + self:get_header_height() + style.padding.y
  return cols, lh, card_h, col_w, gap, x0, y0
end

-- Hit-test the kanban layout at view coords (mx, my).
-- Returns:
--   { kind = "card", item = item, col_idx = i, card_idx = j, x=, y=, w=, h= }
--   { kind = "column", tag = tag, col_idx = i, x=, y=, w=, h= }
--   nil
function TodoView:kanban_hit(mx, my)
  local cols, lh, card_h, col_w, gap, x0, y0 = kanban_geometry(self)
  for i, col in ipairs(cols) do
    local cx = x0 + (i - 1) * (col_w + gap)
    if mx >= cx and mx < cx + col_w then
      -- header zone of the column
      local head_h = lh + style.padding.y
      if my >= y0 and my < y0 + head_h then
        return { kind = "column", tag = col.tag, col_idx = i,
          x = cx, y = y0, w = col_w, h = head_h }
      end
      -- cards
      for j, item in ipairs(col.items) do
        local cy = y0 + head_h + style.padding.y + (j - 1) * (card_h + gap)
        if my >= cy and my < cy + card_h then
          return { kind = "card", item = item, col_idx = i, card_idx = j,
            x = cx, y = cy, w = col_w, h = card_h }
        end
      end
    end
  end
  return nil
end

-- Draw the kanban: a column per tag, cards inside.  When a drag is active,
-- the dragged card follows the cursor and the target column is highlighted.
function TodoView:draw_kanban()
  local cols, lh, card_h, col_w, gap, x0, y0 = kanban_geometry(self)
  local today = today_str()
  local head_h = lh + style.padding.y

  for i, col in ipairs(cols) do
    local cx = x0 + (i - 1) * (col_w + gap)
    -- column background
    renderer.draw_rect(cx, y0, col_w, self.size.y - (y0 - self.position.y),
      style.background2)
    -- column header: tag + count
    local open_n = 0
    for _, it in ipairs(col.items) do
      if not it.checked then open_n = open_n + 1 end
    end
    common.draw_text(style.font, style.text, "#" .. col.tag, "left",
      cx + style.padding.x, y0, col_w, lh)
    common.draw_text(style.code_font, style.dim, tostring(#col.items), "right",
      cx, y0, col_w - style.padding.x, lh)
    renderer.draw_rect(cx, y0 + head_h - style.divider_size,
      col_w, style.divider_size, style.divider)
    -- cards
    core.push_clip_rect(cx, y0 + head_h, col_w,
      self.position.y + self.size.y - y0 - head_h)
    for j, item in ipairs(col.items) do
      local cy = y0 + head_h + style.padding.y + (j - 1) * (card_h + gap)
      local hovered = self.hover_item == item
      local dragging = self.drag and self.drag.item == item
      if not dragging then
        self:draw_card(cx + 2 * SCALE, cy, col_w - 4 * SCALE, card_h, item,
          hovered, today)
      end
    end
    core.pop_clip_rect()
    -- drag target highlight
    if self.drag and self.drag.target_col == i then
      renderer.draw_rect(cx, y0, col_w,
        self.size.y - (y0 - self.position.y),
        style.dragging_highlight or style.line_highlight)
    end
  end

  -- dragged card on top, following the cursor
  if self.drag then
    local d = self.drag
    local w = col_w - 4 * SCALE
    self:draw_card(d.x - w / 2, d.y - card_h / 2, w, card_h, d.item, true, today)
  end
end

-- One kanban card: checkbox + display text (+ due chip + source hint).
function TodoView:draw_card(x, y, w, h, item, hovered, today)
  local bg = hovered and (style.line_highlight or style.background2)
    or style.background3 or style.background2
  renderer.draw_rect(x, y, w, h, bg)
  local border = hovered and (style.accent or style.text) or style.divider
  renderer.draw_rect(x, y, w, 1 * SCALE, border)
  renderer.draw_rect(x, y + h - 1 * SCALE, w, 1 * SCALE, border)
  renderer.draw_rect(x, y, 1 * SCALE, h, border)
  renderer.draw_rect(x + w - 1 * SCALE, y, 1 * SCALE, h, border)
  -- checkbox
  local box = math.floor(h * 0.4)
  local bx, by = x + style.padding.x, y + math.floor((h - box) / 2)
  renderer.draw_rect(bx, by, box, box, item.checked
    and (style.accent or style.text) or style.dim)
  if item.checked then
    renderer.draw_rect(bx + 1, by + 1, box - 2, box - 2, style.background2)
  end
  -- text
  local tx = bx + box + style.padding.x
  local tcolor = item.checked and style.dim or style.text
  local label = item.display
  if item.due then
    local overdue = (not item.checked) and date_lt(item.due, today)
    local chip = "⏰ " .. item.due
    local chip_w = style.code_font:get_width(chip) + style.padding.x
    local tw = style.font:get_width(label)
    if tw + chip_w < w - (tx - x) - style.padding.x then
      common.draw_text(style.code_font,
        overdue and style.error or style.dim, chip, "left",
        x + w - chip_w - style.padding.x, y, chip_w, h)
    end
  end
  common.draw_text(style.font, tcolor, label, "left", tx, y,
    w - (tx - x) - style.padding.x, h)
end

-----------------------------------------------------------------------
-- Layout: calendar view
-----------------------------------------------------------------------

-- os.time of the first visible day of the calendar grid (may be in the
-- previous month).  Weeks start on monday by default.
local function month_grid(year, month, week_starts_monday)
  local first = os.time({ year = year, month = month, day = 1 })
  local start_wday = os.date("*t", first).wday  -- 1=Sun .. 7=Sat
  local lead
  if week_starts_monday then
    lead = (start_wday == 1) and 6 or (start_wday - 2)  -- Mon=0 lead
  else
    lead = start_wday - 1
  end
  -- days in month: day 0 of next month
  local days = os.date("*t", os.time({ year = year, month = month + 1, day = 0 })).day
  return first, lead, days
end

-- Tasks grouped by due date: { ["2026-10-16"] = { item, ... }, ... }
local function tasks_by_due(items)
  local by = {}
  for _, it in ipairs(items) do
    if it.due then
      local list = by[it.due]
      if not list then list = {} by[it.due] = list end
      list[#list + 1] = it
    end
  end
  return by
end

function TodoView:draw_calendar()
  local conf = config.plugins.todo_agenda
  local first, lead, days = month_grid(self.cal_year, self.cal_month,
    conf.week_starts_monday)
  local by_due = tasks_by_due(self.items)
  local today = today_str()
  local _, tmonth, tyear = today:match("^(%d+)-(%d+)-(%d+)$")
  local x0 = self.position.x + style.padding.x
  local y0 = self.position.y + self:get_header_height() + style.padding.y
  local w = self.size.x - style.padding.x * 2
  local cw = w / 7
  local fh = style.font:get_height()
  local row_h = math.max(fh * 2, (self.size.y - (y0 - self.position.y) - fh * 2) / 6)
  local cw_i = math.floor(cw)

  -- month navigation header: ◀ 2026-10 ▶
  local title = string.format("%d-%02d", self.cal_year, self.cal_month)
  local tw = style.font:get_width(title)
  local nav_y = y0
  local prev_r = { x = x0, y = nav_y, w = fh, h = fh }
  local next_r = { x = x0 + w - fh, y = nav_y, w = fh, h = fh }
  self._cal_nav_rects = { prev = prev_r, next = next_r }
  common.draw_text(style.font, style.dim, "◀", "center", prev_r.x, prev_r.y, prev_r.w, prev_r.h)
  common.draw_text(style.font, style.dim, "▶", "center", next_r.x, next_r.y, next_r.w, next_r.h)
  common.draw_text(style.font, style.accent or style.text, title, "center",
    x0, nav_y, w, fh)
  local grid_y = nav_y + fh + style.padding.y

  -- weekday labels
  local wdays = conf.week_starts_monday
    and { "一", "二", "三", "四", "五", "六", "日" }
    or { "日", "一", "二", "三", "四", "五", "六" }
  for i = 1, 7 do
    common.draw_text(style.code_font, style.dim, wdays[i], "center",
      x0 + (i - 1) * cw, grid_y, cw, fh)
  end
  grid_y = grid_y + fh + style.padding.y / 2

  -- day cells
  self._cal_cells = {}
  local cell_h = math.max(fh * 2, (self.position.y + self.size.y - grid_y - style.padding.y) / 6)
  for row = 0, 5 do
    for col = 0, 6 do
      local idx = row * 7 + col          -- 0-based day slot
      local day = idx - lead + 1
      local cx, cy = x0 + col * cw, grid_y + row * cell_h
      local in_month = day >= 1 and day <= days
      local ds
      if in_month then
        ds = string.format("%04d-%02d-%02d", self.cal_year, self.cal_month, day)
      end
      -- cell background
      renderer.draw_rect(cx + 1, cy + 1, cw_i - 2, cell_h - 2,
        in_month and style.background2 or style.background)
      local is_today = ds == today
      if is_today then
        renderer.draw_rect(cx + 1, cy + 1, cw_i - 2, cell_h - 2,
          style.line_highlight or style.background2)
        renderer.draw_rect(cx + 1, cy + 1, cw_i - 2, 1 * SCALE, style.accent)
        renderer.draw_rect(cx + 1, cy + 1, 1 * SCALE, cell_h - 2, style.accent)
        renderer.draw_rect(cx + cw_i - 2 * SCALE, cy + 1, 1 * SCALE, cell_h - 2, style.accent)
        renderer.draw_rect(cx + 1, cy + cell_h - 2 * SCALE, cw_i - 2, 1 * SCALE, style.accent)
      end
      -- day number
      if in_month then
        common.draw_text(style.code_font, is_today and (style.accent or style.text)
          or style.dim, tostring(day), "right",
          cx, cy + 1, cw - style.padding.x, fh)
        -- due tasks
        local list = by_due[ds]
        if list then
          local ly = cy + fh + 1
          local lh = fh
          core.push_clip_rect(cx + 1, cy + 1, cw_i - 2, cell_h - 2)
          for k = 1, math.min(#list, math.floor((cell_h - fh - 2) / lh)) do
            local it = list[k]
            local overdue = (not it.checked) and date_lt(it.due, today)
            -- 2px accent bar on the left
            renderer.draw_rect(cx + 2, ly, 2 * SCALE, lh - 2 * SCALE,
              overdue and style.error or (style.accent or style.text))
            common.draw_text(style.font,
              it.checked and style.dim or style.text,
              (it.checked and "✓ " or "") .. it.display, "left",
              cx + 2 + 2 * SCALE + 2, ly - 1, cw - 8, lh)
            ly = ly + lh
          end
          if #list > math.floor((cell_h - fh - 2) / lh) then
            common.draw_text(style.code_font, style.dim,
              string.format("+%d", #list - math.floor((cell_h - fh - 2) / lh)),
              "left", cx + 4, ly, cw - 8, fh)
          end
          core.pop_clip_rect()
          self._cal_cells[#self._cal_cells + 1] =
            { ds = ds, x = cx, y = cy, w = cw_i, h = cell_h, items = list }
        end
      end
    end
  end
end

-----------------------------------------------------------------------
-- Mouse
-----------------------------------------------------------------------

function TodoView:on_mouse_moved(mx, my, ...)
  TodoView.super.on_mouse_moved(self, mx, my, ...)
  if self.view_mode == "kanban" then
    if self.drag then
      self.drag.x, self.drag.y = mx, my
      -- find target column under cursor
      local cols, lh, card_h, col_w, gap, x0 = kanban_geometry(self)
      local target = 0
      for i = 1, #cols do
        local cx = x0 + (i - 1) * (col_w + gap)
        if mx >= cx and mx < cx + col_w then target = i break end
      end
      self.drag.target_col = target
      core.redraw = true
      return
    end
    local hit = self:kanban_hit(mx, my)
    self.hover_item = hit and hit.kind == "card" and hit.item or nil
    self.hover_col = hit and hit.kind == "column" and hit.tag or nil
    self.cursor = self.hover_item and "hand" or "arrow"
    core.redraw = true
    return
  end
  -- list view hover
  self.hover_idx = 0
  for i, item, x, y, w, h in self:each_visible_item() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self.hover_idx = i
      break
    end
  end
  self.cursor = (self.hover_idx > 0) and "hand" or "arrow"
  core.redraw = true
end

function TodoView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then
    return TodoView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  -- view switch buttons (any mode)
  for _, r in ipairs(self._switch_rects or {}) do
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      self.view_mode = r.mode
      core.redraw = true
      return true
    end
  end
  -- calendar: month nav
  if self.view_mode == "calendar" then
    local nav = self._cal_nav_rects or {}
    for _, r in ipairs({ nav.prev, nav.next }) do
      if r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
        local m = self.cal_month + (r == nav.next and 1 or -1)
        if m < 1 then m, self.cal_year = 12, self.cal_year - 1
        elseif m > 12 then m, self.cal_year = 1, self.cal_year + 1 end
        self.cal_month = m
        core.redraw = true
        return true
      end
    end
    -- click a task in a day cell: toggle it
    for _, cell in ipairs(self._cal_cells or {}) do
      if x >= cell.x and x < cell.x + cell.w
         and y >= cell.y and y < cell.y + cell.h then
        -- find which task row was hit
        local fh = style.font:get_height()
        local row = math.floor((y - cell.y - fh) / fh) + 1
        local it = cell.items[row]
        if it then
          toggle_task_in_source(it)
          core.redraw = true
          return true
        end
      end
    end
  end
  -- kanban: press on a card starts a drag; click on checkbox toggles
  if self.view_mode == "kanban" then
    local hit = self:kanban_hit(x, y)
    if hit and hit.kind == "card" then
      local item = hit.item
      -- checkbox zone (left padding.x + box)
      local box = math.floor(hit.h * 0.4)
      if x < hit.x + style.padding.x + box + 4 then
        toggle_task_in_source(item)
        core.redraw = true
        return true
      end
      -- start drag
      self.drag = { item = item, x = x, y = y, target_col = hit.col_idx }
      core.redraw = true
      return true
    end
    return TodoView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  -- list view
  for i, item, ix, iy, w, h in self:each_visible_item() do
    if x >= ix and y >= iy and x < ix + w and y < iy + h then
      local bx, by, bw, bh = checkbox_rect(ix, iy, h)
      if x >= bx and x < bx + bw and y >= by and y < by + bh then
        -- toggle the checkbox
        toggle_task_in_source(item)
        -- re-sort so toggled items move to the other group
        table.sort(self.items, function(a, b)
          if a.checked ~= b.checked then return not a.checked end
          if a.rel ~= b.rel then return a.rel < b.rel end
          return a.line < b.line
        end)
        core.redraw = true
        return true
      end
      -- click on the text: jump to the source line
      core.try(function()
        local dv = core.root_view:open_doc(core.open_doc(item.file))
        core.root_view.root_node:update_layout()
        dv.doc:set_selection(item.line, 1)
        dv:scroll_to_line(item.line, false, true)
      end)
      return true
    end
  end
  return TodoView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function TodoView:on_mouse_released(button, x, y)
  if self.view_mode == "kanban" and self.drag then
    local d = self.drag
    self.drag = nil
    local cols, lh, card_h, col_w, gap, x0 = kanban_geometry(self)
    local target = d.target_col
    if target and target > 0 then
      local col = cols[target]
      local new_tag = col and col.tag
      local old_tag = d.item.tag or config.plugins.todo_agenda.kanban_default_column
      if new_tag and new_tag ~= old_tag then
        retag_task_in_source(d.item, new_tag)
        core.log("已移动到 #%s(%s:%d)", new_tag, d.item.rel, d.item.line)
      end
    end
    core.redraw = true
    return
  end
  TodoView.super.on_mouse_released(self, button, x, y)
end

function TodoView:update()
  -- debounce the dirwatch-triggered rescan
  if self._rescan_pending then
    local now = system.get_time()
    if now - self._last_rescan > config.plugins.todo_agenda.rescan_cooldown then
      self._rescan_pending = false
      self:rescan()
    end
  end
  TodoView.super.update(self)
end

function TodoView:draw_checkbox(x, y, lh, checked, hovered)
  local bx, by, bw, bh = checkbox_rect(x, y, lh)
  local border = hovered and style.accent or style.dim
  local fill = checked and (style.accent or style.text) or style.background
  -- 1px border
  renderer.draw_rect(bx, by, bw, bh, border)
  renderer.draw_rect(bx + 1, by + 1, bw - 2, bh - 2, fill)
  if checked then
    -- crude check mark: two short lines
    local cx, cy = bx + bw * 0.5, by + bh * 0.5
    local len = math.floor(bw * 0.25)
    renderer.draw_rect(cx - len, cy, len, 1 * SCALE, style.background)
    renderer.draw_rect(cx, cy, 1 * SCALE, len, style.background)
  end
end

function TodoView:draw()
  self:draw_background(style.background)

  local ox, oy = self.position.x, self.position.y
  local hy = self:get_header_height()

  -- header (stats + view switcher)
  renderer.draw_rect(ox, oy, self.size.x, hy, style.background)
  local x, y = ox + style.padding.x, oy + style.padding.y
  self:draw_header(x, y, self.size.x - style.padding.x * 2)
  -- divider under the header
  renderer.draw_rect(ox, oy + hy - style.divider_size, self.size.x, style.divider_size, style.divider)

  if self.view_mode == "kanban" then
    self:draw_kanban()
  elseif self.view_mode == "calendar" then
    self:draw_calendar()
  else
    -- list items
    local _, _, bw = self:get_content_bounds()
    core.push_clip_rect(ox, oy + hy, bw, self.size.y - hy)
    for i, item, ix, iy, w, h in self:each_visible_item() do
      local hovered = (i == self.hover_idx)
      if hovered then
        renderer.draw_rect(ix, iy, w, h, style.line_highlight)
      end
      -- checkbox
      self:draw_checkbox(ix, iy, h, item.checked, hovered)
      -- text: file:line prefix (dim) + task text
      local tx = ix + style.padding.x + math.floor(h * 0.55) + style.padding.x
      local prefix = string.format("%s:%d  ", item.rel, item.line)
      local tcolor = item.checked and style.dim or style.text
      tx = common.draw_text(style.code_font, style.dim, prefix, "left", tx, iy, w, h)
      local remaining = ix + w - tx
      local label = item.display
      if item.due then
        local chip = "@" .. item.due
        local chip_w = style.code_font:get_width(chip) + style.padding.x
        common.draw_text(style.code_font,
          (not item.checked) and date_lt(item.due, today_str()) and style.error or style.dim,
          chip, "right", ix + w - chip_w - style.padding.x, iy, chip_w, h)
        remaining = remaining - chip_w - style.padding.x
      end
      common.draw_text(style.font, tcolor, label, "left", tx, iy, remaining, h)
    end
    core.pop_clip_rect()
    self:draw_scrollbar()
  end
end

-----------------------------------------------------------------------
-- Command / mount
-----------------------------------------------------------------------

command.add(nil, {
  ["todo-agenda:toggle"] = function()
    -- If the todo view is currently active (visible + focused), close it.
    if core.active_view and core.active_view:is(TodoView) then
      local node = core.root_view.root_node:get_node_for_view(core.active_view)
      if node then
        node:close_view(core.root_view.root_node, core.active_view)
      else
        -- fallback: try_close directly
        core.active_view:try_close(function() end)
      end
      return
    end
    -- Otherwise open it: reuse an existing instance if still in the tree,
    -- else create a new one.
    if todo_view and todo_view:is(TodoView)
       and core.root_view.root_node:get_node_for_view(todo_view) then
      core.set_active_view(todo_view)
      return
    end
    todo_view = TodoView()
    local node = core.root_view:get_active_node_default()
    node:add_view(todo_view)
    core.set_active_view(todo_view)
  end,
  ["todo-agenda:rescan"] = function()
    if todo_view then todo_view:rescan() end
  end,
  ["todo-agenda:switch-view"] = function()
    if not todo_view then return end
    local order = { "list", "kanban", "calendar" }
    for i, m in ipairs(order) do
      if todo_view.view_mode == m then
        todo_view.view_mode = order[(i % #order) + 1]
        break
      end
    end
    core.redraw = true
  end,
})

command.add(TodoView, {
  ["todo-agenda:refresh"] = function() todo_view:rescan() end,
})

keymap.add({
  ["ctrl+shift+t"] = "todo-agenda:toggle",
})

return TodoView
