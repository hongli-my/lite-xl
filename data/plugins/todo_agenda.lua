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
  kanban_columns = { "工作", "生活" },
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

-- Truncate text to fit `w` pixels, appending an ellipsis when cut.
-- lite-xl's common.draw_text does not clip; without this, long task text
-- paints across kanban card borders and neighbouring columns.
local function draw_text_clipped(font, color, text, align, x, y, w, h)
  local label = text
  if font:get_width(label) > w then
    while #label > 1 and font:get_width(label .. "…") > w do
      label = label:sub(1, -2)
    end
    label = label .. "…"
  end
  return common.draw_text(font, color, label, align, x, y, w, h)
end

-- Some color themes (fall/summer/textadept) do not define style.error.
local function error_color()
  return style.error or style.dim
end

-- Theme-safe surface colours.  This fork's default theme (slate) uses LIGHT
-- chrome colours for background2/background3 (#efefef) while style.text is
-- tuned for the dark editor (#d4d4d4) — drawing text over background2 is
-- unreadable.  Instead of borrowing chrome colours, derive every surface
-- from the editor background blended toward the text colour, so contrast
-- between surface and text is guaranteed in any theme:
--   surface: bg lerped 6% toward text (one step above the editor bg)
--   raised : bg lerped 12% toward text (cards, hover, active buttons)
--   accent bar / checked box: style.accent (Monokai green here) pops on bg
local function surface_color()
  return common.lerp(style.background, style.text, 0.06)
end

local function raised_color()
  return common.lerp(style.background, style.text, 0.13)
end

-- Text on our surfaces: style.text when the theme defines a dark editor bg
-- with light text (the norm); fall back to chrome_text for light themes.
local function surface_text()
  return style.chrome_text or style.text
end

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
  -- kanban scroll state
  self.col_scroll = {}
  self.kanban_x = 0
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
  -- switch buttons on the right: inactive = dim text, active = accent on
  -- background3 with an accent underline; 2*padding.x gutter between them
  local bx = x + w
  for _, mode in ipairs({ "calendar", "kanban", "list" }) do
    local label = VIEW_LABELS[mode]
    local bw = style.font:get_width(label) + style.padding.x * 3
    bx = bx - bw
    local on = (self.view_mode == mode)
    renderer.draw_rect(bx, y, bw, fh,
      on and raised_color() or surface_color())
    if on then
      renderer.draw_rect(bx, y + fh - 2 * SCALE, bw, 2 * SCALE, style.accent or style.text)
    end
    common.draw_text(style.font, on and (style.accent or style.text) or style.dim,
      label, "center", bx, y, bw, fh)
    self._switch_rects[#self._switch_rects + 1] =
      { mode = mode, x = bx, y = y, w = bw, h = fh }
    bx = bx - style.padding.x * 2
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

-- Offset (px) a column's cards are scrolled by; each column scrolls
-- independently via the mouse wheel while the cursor is over it.
-- Stored on the view as self.col_scroll[col_idx]; reset when columns change.
local function col_scroll(self, col_idx, n_cols)
  local s = self.col_scroll
  if #s ~= n_cols then
    -- column set changed: drop stale offsets, keep size in sync
    for i = #s, n_cols + 1, -1 do s[i] = nil end
    for i = #s + 1, n_cols do s[i] = 0 end
  end
  return s[col_idx] or 0
end

-- Kanban geometry, Trello proportions: cards are 1.5 lines tall with real
-- padding, columns are rounded containers with a colored dot header.
local function kanban_geometry(self)
  local cols = kanban_columns_with_items(self.items)
  local lh = self:get_line_height()
  local fh = style.font:get_height()
  -- card: two lines of breathing room around one line of text
  local card_h = fh + style.padding.y * 5
  local col_w = math.max(200 * SCALE, math.min(260 * SCALE,
    (self.size.x - style.padding.x * 3) / math.max(1, #cols)))
  local gap = style.padding.x * 1.5
  -- column header: dot + tag + count, taller than a plain line
  local head_h = fh + style.padding.y * 3
  local x0 = self.position.x + style.padding.x + self.kanban_x
  local y0 = self.position.y + self:get_header_height() + style.padding.y * 1.5
  return cols, lh, card_h, col_w, gap, x0, y0, head_h
end

-- Hit-test the kanban layout at view coords (mx, my).
-- Returns:
--   { kind = "card", item = item, col_idx = i, card_idx = j, x=, y=, w=, h= }
--   { kind = "column", tag = tag, col_idx = i, x=, y=, w=, h= }
--   nil
function TodoView:kanban_hit(mx, my)
  local cols, lh, card_h, col_w, gap, x0, y0, head_h = kanban_geometry(self)
  for i, col in ipairs(cols) do
    local cx = x0 + (i - 1) * (col_w + gap)
    if mx >= cx and mx < cx + col_w then
      -- header zone of the column
      if my >= y0 and my < y0 + head_h then
        return { kind = "column", tag = col.tag, col_idx = i,
          x = cx, y = y0, w = col_w, h = head_h }
      end
      -- cards (offset by this column's scroll)
      local sy = col_scroll(self, i, #cols)
      for j, item in ipairs(col.items) do
        local cy = y0 + head_h + (j - 1) * (card_h + gap) - sy
        if my >= cy and my < cy + card_h then
          return { kind = "card", item = item, col_idx = i, card_idx = j,
            x = cx, y = cy, w = col_w, h = card_h }
        end
      end
    end
  end
  return nil
end

-- Wheel over the kanban: scroll the column under the cursor (vertical);
-- shift+wheel pans the whole board horizontally.
function TodoView:on_mouse_wheel(dy, dx)
  if self.view_mode == "kanban" then
    if keymap.modkeys and keymap.modkeys["shift"] then
      self.kanban_x = math.min(0, self.kanban_x - dx * 3 - dy * 3)
      core.redraw = true
      return true
    end
    local mx, my = self._mouse_x or 0, self._mouse_y or 0
    local cols, lh, card_h, col_w, gap, x0, y0 = kanban_geometry(self)
    for i, col in ipairs(cols) do
      local cx = x0 + (i - 1) * (col_w + gap)
      if mx >= cx and mx < cx + col_w then
        local sy = col_scroll(self, i, #cols)
        local head_h = lh + style.padding.y
        local body_h = self.position.y + self.size.y - (y0 + head_h) - style.padding.y
        local content_h = #col.items * (card_h + gap)
        local max_scroll = math.max(0, content_h - body_h)
        local ny = math.max(0, math.min(max_scroll, sy - dy * 3))
        self.col_scroll[i] = ny
        core.redraw = true
        return true
      end
    end
    return true
  end
  return TodoView.super.on_mouse_wheel(self, dy, dx)
end

-- Stable per-tag hue: hash the tag into a palette of theme colours so every
-- column gets its own dot colour — alive, but still theme-born.
-- Palette entries: theme status colours + syntax colours (via style.syntax).
local tag_color_cache = {}
local function tag_color(tag)
  local c = tag_color_cache[tag]
  if c ~= nil then return c end
  local n = 0
  for i = 1, #tag do n = (n * 31 + tag:byte(i)) % 1000003 end
  local syn = style.syntax or {}
  local palette = {
    style.accent, style.good, style.warn, style.modified,
    syn.keyword, syn.keyword2, syn.number, syn.string, syn["function"],
  }
  c = palette[(n % #palette) + 1] or style.accent or style.text
  -- blend toward the palette colour so near-black entries stay visible
  c = common.lerp(style.text, c, 0.85)
  tag_color_cache[tag] = c
  return c
end

-- Header dot radius helper (font-derived).
local function dot_radius()
  return math.max(3 * SCALE, math.floor(style.code_font:get_height() * 0.28))
end

-- Draw the kanban: rounded column containers with colored dot headers,
-- raised rounded cards.  The dragged card floats on top of everything.
function TodoView:draw_kanban()
  local cols, lh, card_h, col_w, gap, x0, y0, head_h = kanban_geometry(self)
  local today = today_str()
  local view_h = self.size.y - (y0 - self.position.y) - style.padding.y
  local radius = 4 * SCALE

  for i, col in ipairs(cols) do
    local cx = x0 + (i - 1) * (col_w + gap)
    local tcol = tag_color(col.tag)
    -- column container: rounded, one step above the view background
    renderer.draw_rounded_rect(cx, y0, col_w, view_h, radius + 2 * SCALE,
      surface_color())
    -- column header: colored dot + tag name + open-count chip
    local open_n = 0
    for _, it in ipairs(col.items) do
      if not it.checked then open_n = open_n + 1 end
    end
    local dr = dot_radius()
    local dot_y = y0 + style.padding.y
    renderer.draw_rounded_rect(cx + style.padding.x * 1.5, dot_y,
      dr * 2, dr * 2, dr, tcol)
    common.draw_text(style.font, style.text, col.tag, "left",
      cx + style.padding.x * 1.5 + dr * 2 + style.padding.x,
      y0, col_w, head_h)
    local cnt = tostring(open_n)
    local cnt_h = style.code_font:get_height() + style.padding.y
    local cnt_w = style.code_font:get_width(cnt) + style.padding.x * 1.5
    local cnt_y = y0 + (head_h - cnt_h) / 2
    renderer.draw_rounded_rect(cx + col_w - cnt_w - style.padding.x, cnt_y,
      cnt_w, cnt_h, radius, raised_color())
    common.draw_text(style.code_font, style.dim, cnt, "center",
      cx + col_w - cnt_w - style.padding.x, cnt_y, cnt_w, cnt_h)
    -- cards (scrolled per column, clipped to the column body)
    local sy = col_scroll(self, i, #cols)
    core.push_clip_rect(cx, y0 + head_h, col_w, view_h - head_h)
    for j, item in ipairs(col.items) do
      local cy = y0 + head_h + (j - 1) * (card_h + gap) - sy
      local hovered = self.hover_item == item
      local dragging = self.drag and self.drag.item == item
      if not dragging then
        self:draw_card(cx + style.padding.x, cy,
          col_w - style.padding.x * 2, card_h, item, hovered, today, tcol)
      end
    end
    core.pop_clip_rect()
    -- drag target highlight: tint the whole column toward its tag colour
    if self.drag and self.drag.target_col == i then
      renderer.draw_rounded_rect(cx, y0, col_w, view_h, radius + 2 * SCALE,
        common.lerp(style.background, tcol, 0.10))
    end
  end

  -- dragged card on top, following the cursor
  if self.drag then
    local d = self.drag
    local w = col_w - style.padding.x * 2
    local tcol = tag_color(d.item.tag
      or config.plugins.todo_agenda.kanban_default_column)
    self:draw_card(d.x - w / 2, d.y - card_h / 2, w, card_h, d.item,
      true, today, tcol)
  end
end

-- One kanban card, Trello style: raised rounded rectangle with a soft
-- shadow ring, colored left bar matching the column, checkbox, and a due
-- chip on a second visual layer (bottom-right) when it fits.
function TodoView:draw_card(x, y, w, h, item, hovered, today, tcol)
  local radius = 4 * SCALE
  -- soft shadow: slightly larger, darker rounded rect under the card
  renderer.draw_rounded_rect(x, y + 1.5 * SCALE, w, h, radius,
    common.lerp(style.background, style.text, 0.03))
  -- card body: clearly raised above the column surface
  local bg = common.lerp(style.background, style.text,
    hovered and 0.19 or 0.15)
  renderer.draw_rounded_rect(x, y, w, h, radius, bg)
  -- colored left bar (column hue; dimmed when the task is done)
  local bar = item.checked and common.lerp(style.background, style.text, 0.10)
    or tcol
  renderer.draw_rounded_rect(x, y, 3 * SCALE, h, 1.5 * SCALE, bar)
  -- checkbox (hollow square, filled with a check when done)
  local box = math.floor(h * 0.34)
  local bx, by = x + style.padding.x * 1.5 + 3 * SCALE,
    y + math.floor((h - box) / 2)
  renderer.draw_rounded_rect(bx, by, box, box, 1.5 * SCALE,
    item.checked and (style.accent or style.text) or style.dim)
  if item.checked then
    renderer.draw_rounded_rect(bx + 1.5 * SCALE, by + 1.5 * SCALE,
      box - 3 * SCALE, box - 3 * SCALE, 1 * SCALE, bg)
    local cx, cy = bx + box * 0.5, by + box * 0.5
    local len = math.floor(box * 0.25)
    renderer.draw_rect(cx - len, cy, len, 1 * SCALE, style.accent or style.text)
    renderer.draw_rect(cx, cy, 1 * SCALE, len, style.accent or style.text)
  end
  -- text
  local tx = bx + box + style.padding.x
  local tcolor = item.checked and style.dim or style.text
  local label = (item.checked and "✓ " or "") .. item.display
  local avail = w - (tx - x) - style.padding.x
  -- due chip at the bottom-right of the card when there is room
  if item.due then
    local overdue = (not item.checked) and date_lt(item.due, today)
    local chip = "⏰ " .. item.due:sub(6)
    local chip_h = style.code_font:get_height() + style.padding.y * 0.5
    local chip_w = style.code_font:get_width(chip) + style.padding.x * 1.5
    if chip_w < avail then
      local ch_y = y + h - chip_h - style.padding.y * 0.5
      renderer.draw_rounded_rect(x + w - chip_w - style.padding.x * 0.5,
        ch_y, chip_w, chip_h, 3 * SCALE,
        common.lerp(style.background, overdue and error_color() or style.dim,
          0.35))
      common.draw_text(style.code_font,
        overdue and error_color() or style.dim, chip, "center",
        x + w - chip_w - style.padding.x * 0.5, ch_y, chip_w, chip_h)
      -- text stays on the upper half when a chip is present
      local text_h = h - chip_h - style.padding.y
      draw_text_clipped(style.font, tcolor, label, "left", tx, y,
        avail, text_h)
      return
    end
  end
  draw_text_clipped(style.font, tcolor, label, "left", tx, y, avail, h)
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

-- Calendar redesign notes:
--   * pill hover state (self.hover_cal_item) highlights the exact pill
--   * pill hit rects are recorded per cell for precise click targets
--   * weekend columns get a slightly darker tint to structure the week
--   * today = small colored dot under the day number (no full-cell ring)
--   * month nav = ◀ ▶ pill buttons flanking the centered title
function TodoView:draw_calendar()
  local conf = config.plugins.todo_agenda
  local first, lead, days = month_grid(self.cal_year, self.cal_month,
    conf.week_starts_monday)
  local by_due = tasks_by_due(self.items)
  local today = today_str()
  local x0 = self.position.x + style.padding.x
  local y0 = self.position.y + self:get_header_height() + style.padding.y
  local w = self.size.x - style.padding.x * 2
  local cw = w / 7
  local fh = style.font:get_height()
  local cfh = style.code_font:get_height()
  local cw_i = math.floor(cw)

  -- month navigation: pill buttons flanking the centered title
  local title = string.format("%d年%d月", self.cal_year, self.cal_month)
  local nav_y = y0
  local btn_h = fh + style.padding.y
  local btn_w = btn_h
  local prev_r = { x = x0, y = nav_y, w = btn_w, h = btn_h }
  local next_r = { x = x0 + w - btn_w, y = nav_y, w = btn_w, h = btn_h }
  self._cal_nav_rects = { prev = prev_r, next = next_r }
  local nav_hover = self._cal_nav_hover
  for _, r in ipairs({ { r = prev_r, lbl = "◀" }, { r = next_r, lbl = "▶" } }) do
    renderer.draw_rounded_rect(r.r.x, r.r.y, r.r.w, r.r.h, 3 * SCALE,
      nav_hover == r.lbl and raised_color() or surface_color())
    common.draw_text(style.font, nav_hover == r.lbl and style.text or style.dim,
      r.lbl, "center", r.r.x, r.r.y, r.r.w, r.r.h)
  end
  common.draw_text(style.font, style.text, title, "center", x0, nav_y, w, btn_h)

  -- weekday labels (weekend in dim-er tint)
  local grid_y = nav_y + btn_h + style.padding.y
  local wdays = conf.week_starts_monday
    and { "一", "二", "三", "四", "五", "六", "日" }
    or { "日", "一", "二", "三", "四", "五", "六" }
  local weekend = conf.week_starts_monday and { 6, 7 } or { 1, 7 }
  for i = 1, 7 do
    common.draw_text(style.code_font,
      weekend[i] and style.dim or style.text, wdays[i], "left",
      x0 + (i - 1) * cw, grid_y, cw, cfh)
  end
  grid_y = grid_y + cfh + style.padding.y / 2

  -- day cells
  self._cal_cells = {}
  local cell_h = math.max(fh * 2,
    (self.position.y + self.size.y - grid_y - style.padding.y) / 6)
  local pill_h = fh + style.padding.y * 0.5
  for row = 0, 5 do
    for col = 0, 6 do
      local idx = row * 7 + col          -- 0-based day slot
      local day = idx - lead + 1
      local cx, cy = x0 + col * cw, grid_y + row * cell_h
      local in_month = day >= 1 and day <= days
      local is_weekend = col == 5 or col == 6
      if not conf.week_starts_monday then
        is_weekend = col == 0 or col == 6
      end
      local ds
      if in_month then
        ds = string.format("%04d-%02d-%02d", self.cal_year, self.cal_month, day)
      end
      local is_today = ds == today
      -- cell background: flat, weekends one step darker; out-of-month
      -- days keep the plain view background and draw nothing else
      local cell_bg
      if not in_month then
        cell_bg = style.background
      elseif is_weekend then
        cell_bg = common.lerp(style.background, style.text, 0.03)
      else
        cell_bg = surface_color()
      end
      renderer.draw_rect(cx, cy, cw_i, cell_h, cell_bg)
      -- hairline separators only between cells (not around the grid edge)
      if col > 0 then
        renderer.draw_rect(cx, cy, 1, cell_h, style.background)
      end
      if row > 0 then
        renderer.draw_rect(cx, cy, cw_i, 1, style.background)
      end
      if in_month then
        -- day number + today dot
        local dnum_color = is_today and (style.accent or style.text) or style.dim
        common.draw_text(style.code_font, dnum_color, tostring(day), "left",
          cx + style.padding.x, cy + 2, cw - style.padding.x, cfh)
        if is_today then
          local dot_r = 1.5 * SCALE
          local nw = style.code_font:get_width(tostring(day))
          renderer.draw_rounded_rect(cx + style.padding.x + nw + 4, cy + cfh - dot_r,
            dot_r * 2, dot_r * 2, dot_r, tag_color(today))
        end
        -- due tasks as pills; record hit rects for precise clicks
        local list = by_due[ds]
        if list then
          local cell = { ds = ds, x = cx, y = cy, w = cw_i, h = cell_h,
            items = list, pills = {} }
          self._cal_cells[#self._cal_cells + 1] = cell
          local max_rows = math.max(0, math.floor((cell_h - cfh - 4) / pill_h))
          for k = 1, math.min(#list, max_rows) do
            local it = list[k]
            local overdue = (not it.checked) and date_lt(it.due, today)
            local hovered = (self.hover_cal_item == it)
            local ly = cy + cfh + 3 + (k - 1) * pill_h
            local tcol = tag_color(it.tag
              or config.plugins.todo_agenda.kanban_default_column)
            local pill_bg = common.lerp(style.background,
              overdue and error_color() or tcol, hovered and 0.42 or 0.22)
            renderer.draw_rounded_rect(cx + 2, ly, cw_i - 4, pill_h - 2,
              3 * SCALE, pill_bg)
            renderer.draw_rect(cx + 2, ly, 2 * SCALE, pill_h - 2,
              overdue and error_color() or tcol)
            draw_text_clipped(style.font,
              it.checked and style.dim or style.text,
              (it.checked and "✓ " or "") .. it.display, "left",
              cx + 2 + 2 * SCALE + 4, ly, cw_i - 12, pill_h)
            cell.pills[#cell.pills + 1] = { item = it, x = cx + 2, y = ly,
              w = cw_i - 4, h = pill_h - 2 }
          end
          if #list > max_rows then
            common.draw_text(style.code_font, style.dim,
              string.format("+%d 项", #list - max_rows),
              "left", cx + style.padding.x, cy + cfh + 3 + max_rows * pill_h,
              cw - 8, cfh)
          end
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
  -- remember the last mouse position: on_mouse_wheel receives no
  -- coordinates; we need them to find the column under the cursor
  self._mouse_x, self._mouse_y = mx, my
  -- calendar hover: exact pill rects + nav buttons
  if self.view_mode == "calendar" then
    self.hover_cal_item = nil
    self._cal_nav_hover = nil
    local nav = self._cal_nav_rects or {}
    for lbl, r in pairs({ prev = nav.prev, next = nav.next }) do
      if r and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
        self._cal_nav_hover = (lbl == "prev") and "◀" or "▶"
      end
    end
    for _, cell in ipairs(self._cal_cells or {}) do
      for _, pill in ipairs(cell.pills or {}) do
        if mx >= pill.x and mx < pill.x + pill.w
           and my >= pill.y and my < pill.y + pill.h then
          self.hover_cal_item = pill.item
          break
        end
      end
    end
    self.cursor = (self.hover_cal_item or self._cal_nav_hover) and "hand" or "arrow"
    core.redraw = true
    return
  end
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
    self.cursor = (self.hover_item or self.hover_col) and "hand" or "arrow"
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
  -- calendar: nav buttons, then pills.  Clicks anywhere else in the calendar
  -- are swallowed (return true) — falling through to the list-view branch
  -- used to interpret calendar coordinates as list rows and open files.
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
    -- exact pill hit: toggle only when a pill was clicked
    for _, cell in ipairs(self._cal_cells or {}) do
      for _, pill in ipairs(cell.pills or {}) do
        if x >= pill.x and x < pill.x + pill.w
           and y >= pill.y and y < pill.y + pill.h then
          toggle_task_in_source(pill.item)
          core.redraw = true
          return true
        end
      end
    end
    return true  -- swallow clicks on empty calendar space
  end
  -- kanban: press on a card starts a drag; click on checkbox toggles
  if self.view_mode == "kanban" then
    local hit = self:kanban_hit(x, y)
    if hit and hit.kind == "card" then
      local item = hit.item
      -- checkbox zone: accent bar + padding + box (matches draw_card)
      local box = math.floor(hit.h * 0.4)
      if x < hit.x + style.padding.x + 2 * SCALE + box + 4 then
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
          (not item.checked) and date_lt(item.due, today_str()) and error_color() or style.dim,
          chip, "right", ix + w - chip_w - style.padding.x, iy, chip_w, h)
        remaining = remaining - chip_w - style.padding.x
      end
      draw_text_clipped(style.font, tcolor, label, "left", tx, iy, remaining, h)
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
