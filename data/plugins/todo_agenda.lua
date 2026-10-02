-- mod-version:4
-- todo_agenda: aggregate Markdown task-list items across the project into a
-- single view.  Scans every .md/.markdown file for GFM task lines
-- ("- [ ] …" / "- [x] …"), lists them grouped by status, lets you click a
-- checkbox to toggle it back in the source file, and click the text to jump
-- there.
--
-- Toggle with the "todo-agenda:toggle" command (bound to Ctrl+Shift+T here).
-- The view is a normal tab so it lives in the editor node and can be closed
-- like any other.  A dirwatch thread keeps the list fresh while it is open.
--
-- Toggling a task writes through to the document model when the file is open
-- (so the change lands on the undo stack and a dirty buffer is not silently
-- overwritten), and otherwise edits the file on disk directly.

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
  -- show completed tasks below the open ones
  show_completed = true,
}, config.plugins.todo_agenda)

-- A single task item:
--   { file = abs path, rel = display path, line = 1-based,
--     checked = bool, text = task text, bullet = "-", indent = leading spaces }

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
-- Scanning
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
  return {
    indent = #indent,
    bullet = bullet,
    checked = (box == "x" or box == "X"),
    text = text,
  }
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
-- Toggling a task back in the source
-----------------------------------------------------------------------

-- Find the Doc for `filename` if it is already open, so the toggle goes onto
-- the undo stack and a dirty buffer is not clobbered.
local function find_open_doc(abs_filename)
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename == abs_filename then return doc end
  end
end

-- Rewrite the checkbox on `line` of the given file.  When the file is open in
-- the editor, edit the live Doc (preserves undo + unsaved changes); otherwise
-- patch the file on disk.
local function toggle_task_in_source(item)
  local doc = find_open_doc(item.file)
  if doc then
    local text = doc.lines[item.line] or ""
    local new_text
    if item.checked then
      new_text = text:gsub("%[([ xX])%]", "[ ]", 1)
    else
      new_text = text:gsub("%[([ xX])%]", "[x]", 1)
    end
    if new_text ~= text then
      doc:remove(item.line, 1, item.line, #text + 1)
      doc:insert(item.line, 1, new_text)
    end
    return
  end
  -- file not open: edit on disk
  local fp = io.open(item.file, "r")
  if not fp then return end
  local lines = {}
  for line in fp:lines() do lines[#lines + 1] = line end
  fp:close()
  if not lines[item.line] then return end
  if item.checked then
    lines[item.line] = lines[item.line]:gsub("%[([ xX])%]", "[ ]", 1)
  else
    lines[item.line] = lines[item.line]:gsub("%[([ xX])%]", "[x]", 1)
  end
  fp = io.open(item.file, "w")
  if not fp then return end
  for _, line in ipairs(lines) do fp:write(line, "\n") end
  fp:close()
end

-----------------------------------------------------------------------
-- Layout / drawing
-----------------------------------------------------------------------

function TodoView:get_line_height()
  return style.padding.y + style.font:get_height()
end

function TodoView:get_header_height()
  return style.font:get_height() + style.padding.y * 3
end

function TodoView:get_scrollable_size()
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

function TodoView:on_mouse_moved(mx, my, ...)
  TodoView.super.on_mouse_moved(self, mx, my, ...)
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
  for i, item, ix, iy, w, h in self:each_visible_item() do
    if x >= ix and y >= iy and x < ix + w and y < iy + h then
      local bx, by, bw, bh = checkbox_rect(ix, iy, h)
      if x >= bx and x < bx + bw and y >= by and y < by + bh then
        -- toggle the checkbox
        toggle_task_in_source(item)
        item.checked = not item.checked
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

  -- header
  renderer.draw_rect(ox, oy, self.size.x, hy, style.background)
  local x, y = ox + style.padding.x, oy + style.padding.y
  local text
  if self.searching then
    text = string.format("正在扫描待办…（已找到 %d 项）", #self.items)
  else
    local open_n, done_n = 0, 0
    for _, it in ipairs(self.items) do
      if it.checked then done_n = done_n + 1 else open_n = open_n + 1 end
    end
    text = string.format("待办 %d · 已完成 %d", open_n, done_n)
  end
  common.draw_text(style.font, style.accent or style.text, text, "left", x, y, self.size.x, style.font:get_height())
  -- divider under the header
  renderer.draw_rect(ox, oy + hy - style.divider_size, self.size.x, style.divider_size, style.divider)

  -- items
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
    common.draw_text(style.font, tcolor, item.text, "left", tx, iy, remaining, h)
  end
  core.pop_clip_rect()

  self:draw_scrollbar()
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
})

command.add(TodoView, {
  ["todo-agenda:refresh"] = function() todo_view:rescan() end,
})

keymap.add({
  ["ctrl+shift+t"] = "todo-agenda:toggle",
})

return TodoView
