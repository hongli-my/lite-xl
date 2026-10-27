-- mod-version:4
-- colormarks: manually highlight the selection with a marker color.
-- 选中文字 → 右键「标记」；单一突出的半透明高亮色，标记随编辑移动，关闭文件后失效。

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local command = require "core.command"

local LineWrapping = config.plugins.linewrapping
  and require "plugins.linewrapping" or nil

config.plugins.colormarks = common.merge(config.plugins.colormarks or {}, {
  -- the single translucent highlighter color drawn over the text
  color = { 255, 213, 79, 115 },
})

local M = { marks = {} } -- marks[doc] = { {l1,c1,l2,c2}, ... }


local function get_marks(doc)
  if not M.marks[doc] then M.marks[doc] = {} end
  return M.marks[doc]
end


local function clamp_point(doc, l, c)
  l = common.clamp(l, 1, #doc.lines)
  c = common.clamp(c, 1, #doc.lines[l] + 1)
  return l, c
end


--------------------------------------------------------------------------------
-- Mark shift on edits: raw_insert/raw_remove also fire for undo/redo, so the
-- marks follow the text in both directions without needing their own history.
--------------------------------------------------------------------------------

local function shift_insert(l, c, line, col, nlines, len)
  if l < line or (l == line and c <= col) then
    return l, c
  elseif l > line then
    return l + nlines, c
  elseif nlines > 0 then
    return line + nlines, len + (c - col) + 1
  else
    return l, c + len
  end
end


local function shift_remove(l, c, line1, col1, line2, col2)
  if l < line1 or (l == line1 and c <= col1) then
    return l, c
  elseif l > line2 or (l == line2 and c > col2) then
    if l == line2 then return line1, c - (col2 - col1) end
    return l - (line2 - line1), c
  else
    return line1, col1
  end
end


local function pack_shifted_marks(doc, fn, ...)
  local marks = M.marks[doc]
  if not marks or #marks == 0 then return end
  local kept = {}
  for _, mk in ipairs(marks) do
    local l1, c1 = fn(mk.l1, mk.c1, ...)
    local l2, c2 = fn(mk.l2, mk.c2, ...)
    if l1 ~= l2 or c1 ~= c2 then
      kept[#kept + 1] = { l1 = l1, c1 = c1, l2 = l2, c2 = c2 }
    end
  end
  M.marks[doc] = kept
end


local raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  raw_insert(self, line, col, text, undo_stack, time)
  if text ~= "" and M.marks[self] and #M.marks[self] > 0 then
    local nlines = select(2, text:gsub("\n", ""))
    local len = #text:match("[^\n]*$")
    pack_shifted_marks(self, shift_insert, line, col, nlines, len)
  end
end


local raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  if M.marks[self] and #M.marks[self] > 0 then
    pack_shifted_marks(self, shift_remove, line1, col1, line2, col2)
  end
end


--------------------------------------------------------------------------------
-- Rendering: drawn in draw_overlay so it works on both the wrapped and the
-- unwrapped rendering paths (linewrapping never overrides draw_overlay).
--------------------------------------------------------------------------------

function DocView:draw_colormarks(marks)
  local doc = self.doc
  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()
  local wrapped = self.wrapped_settings and LineWrapping
  local color = config.plugins.colormarks.color
  for _, mk in ipairs(marks) do
    local l1 = common.clamp(mk.l1, 1, #doc.lines)
    local l2 = common.clamp(mk.l2, l1, #doc.lines)
    for line = math.max(l1, minline), math.min(l2, maxline) do
      local text = doc.lines[line]
      local c1 = (line > l1) and 1 or common.clamp(mk.c1, 1, #text + 1)
      local c2 = (line < l2) and (#text + 1) or common.clamp(mk.c2, c1, #text + 1)
      if c1 ~= c2 then
        local x, y = self:get_line_screen_position(line)
        if wrapped then
          local idx0 = LineWrapping.get_line_idx_col_count(self, line)
          local idx1 = LineWrapping.get_line_idx_col_count(self, line, c1)
          -- line_end: a mark ending exactly at a wrap boundary extends the
          -- previous visual row to its right edge
          local idx2 = LineWrapping.get_line_idx_col_count(self, line, c2, true)
          for i = idx1, idx2 do
            local x1
            if i == idx1 then
              x1 = x + self:get_col_x_offset(line, c1)
            else
              local _, scol = LineWrapping.get_idx_line_col(self, i)
              x1 = x + self:get_col_x_offset(line, scol)
            end
            local x2
            if idx2 == i then
              x2 = x + self:get_col_x_offset(line, c2, true)
            else
              local _, next_col = LineWrapping.get_idx_line_col(self, i + 1)
              x2 = x + self:get_col_x_offset(line, next_col, true)
            end
            if x2 > x1 then
              renderer.draw_rect(x1, y + (i - idx0) * lh, x2 - x1, lh, color)
            end
          end
        else
          local x1 = x + self:get_col_x_offset(line, c1)
          local x2 = x + self:get_col_x_offset(line, c2)
          if x2 > x1 then
            renderer.draw_rect(x1, y, x2 - x1, lh, color)
          end
        end
      end
    end
  end
end


local old_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay()
  if self.doc then
    local marks = M.marks[self.doc]
    if marks and #marks > 0 then
      pcall(self.draw_colormarks, self, marks)
    end
  end
  return old_draw_overlay and old_draw_overlay(self)
end


--------------------------------------------------------------------------------
-- Commands and right-click menu.
--------------------------------------------------------------------------------

local function ordered_selections(doc)
  local sels = {}
  for _, l1, c1, l2, c2 in doc:get_selections(true) do
    if l1 > l2 or (l1 == l2 and c1 > c2) then
      l2, c2, l1, c1 = l1, c1, l2, c2
    end
    sels[#sels + 1] = { l1 = l1, c1 = c1, l2 = l2, c2 = c2 }
  end
  return sels
end


local function marks_intersect_selections(doc, mk, sels)
  for _, s in ipairs(sels) do
    if not (mk.l2 < s.l1 or (mk.l2 == s.l1 and mk.c2 <= s.c1)
      or mk.l1 > s.l2 or (mk.l1 == s.l2 and mk.c1 >= s.c2)) then
      return true
    end
  end
  return false
end


command.add("core.docview", {
  ["colormarks:mark"] = function(dv)
    local doc = dv.doc
    local marks = get_marks(doc)
    local n = 0
    for _, s in ipairs(ordered_selections(doc)) do
      if s.l1 ~= s.l2 or s.c1 ~= s.c2 then
        marks[#marks + 1] = { l1 = s.l1, c1 = s.c1, l2 = s.l2, c2 = s.c2 }
        n = n + 1
      end
    end
    if n == 0 then
      core.log("请先选中要标记的文字")
      return
    end
    core.redraw = true
    core.log("已标记 " .. n .. " 处")
  end,

  ["colormarks:clear"] = function(dv)
    local doc = dv.doc
    local marks = M.marks[doc]
    if not marks or #marks == 0 then
      core.log("没有标记")
      return
    end
    -- a cursor-only selection clears the marks of its whole line
    local sels = {}
    for _, s in ipairs(ordered_selections(doc)) do
      if s.l1 == s.l2 and s.c1 == s.c2 then
        s.c1, s.c2 = 1, #doc.lines[s.l1] + 1
      end
      sels[#sels + 1] = s
    end
    local kept = {}
    for _, mk in ipairs(marks) do
      if not marks_intersect_selections(doc, mk, sels) then
        kept[#kept + 1] = mk
      end
    end
    local n = #marks - #kept
    M.marks[doc] = kept
    core.redraw = true
    core.log("已清除 " .. n .. " 处标记")
  end,
})


-- the marking commands are reachable from the right-click menu
local old_DocView_on_context_menu = DocView.on_context_menu
function DocView:on_context_menu()
  local args = { old_DocView_on_context_menu(self) }
  local cmds = args[1]
  if self.doc then
    local has_selection = false
    for _, s in ipairs(ordered_selections(self.doc)) do
      if s.l1 ~= s.l2 or s.c1 ~= s.c2 then has_selection = true break end
    end
    local has_marks = M.marks[self.doc] and #M.marks[self.doc] > 0
    -- right after Replace, in the same navigation group
    local idx
    for k, it in ipairs(cmds.items) do
      if type(it) == "table" and it.command == "find-replace:replace" then idx = k + 1 end
    end
    idx = idx or (#cmds.items + 1)
    if has_selection then
      table.insert(cmds.items, idx, { text = "标记", command = "colormarks:mark" })
      idx = idx + 1
    end
    if has_marks then
      table.insert(cmds.items, idx, { text = "清除标记", command = "colormarks:clear" })
    end
  end
  return table.unpack(args)
end


M.get_marks = get_marks

return M
