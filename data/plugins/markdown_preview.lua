-- mod-version:4
-- Markdown in-editor preview with line numbers and collapsible headings
-- Use cmd+shift+m to toggle preview

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local common = require "core.common"
local Doc = require "core.doc"

config.plugins.markdown_preview = {
  preview_width_ratio = 0.45,
  line_number_width = 40,
}

-- ============================================================
-- MarkdownPreviewView
-- ============================================================
local MarkdownPreviewView = View:extend()

function MarkdownPreviewView:__tostring() return "MarkdownPreviewView" end

function MarkdownPreviewView:new(doc)
  MarkdownPreviewView.super.new(self)
  self.scrollable = true
  self.doc = doc
  self.elements = {}
  self.content_height = 0
  self.collapsed = {}  -- collapsed[element_index] = true
  self.hovered_heading = nil
  self.copy_buttons = {}  -- {elem_idx, x, y, w, h} for copy buttons
  self.hovered_copy_btn = nil
  self:refresh()
end

function MarkdownPreviewView:get_name()
  return "Preview: " .. (self.doc.filename and self.doc.filename:match("([^/]+)$") or "untitled")
end

function MarkdownPreviewView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function MarkdownPreviewView:refresh()
  self.elements = self:parse_markdown()
end

function MarkdownPreviewView:parse_markdown()
  local elements = {}
  -- Use doc.lines directly so line numbers are accurate
  local lines = {}
  for i = 1, #self.doc.lines do
    lines[i] = self.doc.lines[i]:gsub("\n$", "")
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]

    if line:match("^%s*$") then
      table.insert(elements, {type = "empty", line = i})
      i = i + 1
      goto continue
    end

    local level, heading_text = line:match("^(#{1,6})%s+(.+)$")
    if level then
      table.insert(elements, {type = "heading", level = #level, text = heading_text, line = i})
      i = i + 1
      goto continue
    end

    local fence = line:match("^%s*```(.*)$")
    if fence then
      local start_line = i
      local code_lines = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*```%s*$") do
        table.insert(code_lines, lines[i])
        i = i + 1
      end
      table.insert(elements, {type = "code_block", lines = code_lines, line = start_line})
      if i <= #lines then i = i + 1 end
      goto continue
    end

    if line:match("^%-%-%-+%s*$") or line:match("^%*%*%*+%s*$") or line:match("^___+%s*$") then
      table.insert(elements, {type = "hr", line = i})
      i = i + 1
      goto continue
    end

    if line:match("^>%s?") then
      local start_line = i
      local quote_lines = {}
      while i <= #lines and lines[i]:match("^>%s?") do
        table.insert(quote_lines, lines[i]:gsub("^>%s?", ""))
        i = i + 1
      end
      table.insert(elements, {type = "blockquote", text = table.concat(quote_lines, " "), line = start_line})
      goto continue
    end

    local bullet, item_text = line:match("^([%-%*%+])%s+(.+)$")
    if bullet then
      local start_line = i
      local items = {}
      while i <= #lines do
        local b, t = lines[i]:match("^([%-%*%+])%s+(.+)$")
        if b then
          table.insert(items, t)
          i = i + 1
        elseif i <= #lines and lines[i]:match("^%s+") and #items > 0 then
          items[#items] = items[#items] .. " " .. lines[i]:gsub("^%s+", "")
          i = i + 1
        else
          break
        end
      end
      table.insert(elements, {type = "ul", items = items, line = start_line})
      goto continue
    end

    local num, t = line:match("^([0-9]+)%.%s+(.+)$")
    if num then
      local start_line = i
      local items = {}
      while i <= #lines do
        local n, tt = lines[i]:match("^([0-9]+)%.%s+(.+)$")
        if n then
          table.insert(items, tt)
          i = i + 1
        elseif i <= #lines and lines[i]:match("^%s+") and #items > 0 then
          items[#items] = items[#items] .. " " .. lines[i]:gsub("^%s+", "")
          i = i + 1
        else
          break
        end
      end
      table.insert(elements, {type = "ol", items = items, line = start_line})
      goto continue
    end

    local start_line = i
    local para_lines = {}
    while i <= #lines and not lines[i]:match("^%s*$") do
      table.insert(para_lines, lines[i])
      i = i + 1
    end
    table.insert(elements, {type = "paragraph", text = table.concat(para_lines, " "), line = start_line})

    ::continue::
  end

  return elements
end

function MarkdownPreviewView:wrap_text(text, max_width)
  local words = {}
  for word in text:gmatch("%S+") do
    table.insert(words, word)
  end

  local lines_out = {}
  local current_line = ""
  local font = style.font

  for _, word in ipairs(words) do
    local test = current_line == "" and word or current_line .. " " .. word
    if font:get_width(test) <= max_width then
      current_line = test
    else
      if current_line ~= "" then
        table.insert(lines_out, current_line)
      end
      if font:get_width(word) > max_width then
        local broken = ""
        for char in word:gmatch(".") do
          local test2 = broken .. char
          if font:get_width(test2) <= max_width then
            broken = test2
          else
            if broken ~= "" then
              table.insert(lines_out, broken)
            end
            broken = char
          end
        end
        current_line = broken
      else
        current_line = word
      end
    end
  end

  if current_line ~= "" then
    table.insert(lines_out, current_line)
  end

  return lines_out
end

-- Character-level wrap for code blocks using code_font
function MarkdownPreviewView:wrap_code_line(text, max_width)
  local lines_out = {}
  local current = ""
  local font = style.code_font
  for char in text:gmatch(".") do
    local test = current .. char
    if font:get_width(test) <= max_width then
      current = test
    else
      if current ~= "" then
        table.insert(lines_out, current)
      end
      current = char
    end
  end
  if current ~= "" then
    table.insert(lines_out, current)
  end
  return lines_out
end

function MarkdownPreviewView:get_scrollable_size()
  return self.content_height
end

-- Check if element at index is hidden by a collapsed heading above it
function MarkdownPreviewView:is_hidden(idx)
  for i = idx - 1, 1, -1 do
    local elem = self.elements[i]
    if elem.type == "heading" and self.collapsed[i] then
      -- this element is hidden only if it's at a deeper level than the collapsed heading,
      -- or it's not a heading at all (content under the heading)
      if self.elements[idx].type == "heading" and self.elements[idx].level <= elem.level then
        -- same or higher level heading - not hidden by this collapsed heading
      else
        return true
      end
    end
  end
  return false
end

-- Find the heading element index that controls collapsing at a given y position
function MarkdownPreviewView:get_heading_at_y(my)
  local ln_w = config.plugins.markdown_preview.line_number_width
  local ox, oy = self:get_content_offset()
  local x = ox + ln_w + style.padding.x
  local y = oy + style.padding.y
  local avail_w = self.size.x - ln_w - style.padding.x * 2

  for idx, elem in ipairs(self.elements) do
    if self:is_hidden(idx) then goto skip end

    if elem.type == "heading" then
      local scale = math.max(1, 1.6 - elem.level * 0.15)
      local lines_out = self:wrap_text(elem.text, avail_w - style.font:get_width("▶ ") )
      local h = 0
      for _ in ipairs(lines_out) do
        h = h + style.font:get_height() * scale + style.padding.y / 2
      end
      h = h + style.padding.y
      if my >= oy + style.padding.y and my < y + h then
        return idx
      end
      y = y + h
    elseif elem.type == "paragraph" then
      local lines_out = self:wrap_text(elem.text, avail_w)
      y = y + #lines_out * (style.font:get_height() + style.padding.y / 2) + style.padding.y
    elseif elem.type == "code_block" then
      local code_h = style.code_font:get_height()
      local code_w = avail_w - style.padding.x * 2
      local total_h = style.padding.y
      for _, line in ipairs(elem.lines) do
        local wrapped = self:wrap_code_line(line, code_w)
        total_h = total_h + #wrapped * code_h
      end
      total_h = total_h + style.padding.y
      y = y + total_h
    elseif elem.type == "empty" then
      y = y + style.font:get_height() + style.padding.y / 2
    elseif elem.type == "blockquote" then
      local lines_out = self:wrap_text(elem.text, avail_w - style.padding.x * 2)
      y = y + #lines_out * style.font:get_height() + style.padding.y * 2
    elseif elem.type == "ul" then
      for _ in ipairs(elem.items) do
        y = y + style.font:get_height()
      end
      y = y + style.padding.y
    elseif elem.type == "ol" then
      for _ in ipairs(elem.items) do
        y = y + style.font:get_height()
      end
      y = y + style.padding.y
    elseif elem.type == "hr" then
      y = y + style.padding.y * 2
    end

    ::skip::
  end
  return nil
end

function MarkdownPreviewView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    -- Check copy buttons first
    for _, btn in ipairs(self.copy_buttons) do
      if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
        local elem = self.elements[btn.idx]
        if elem and elem.lines then
          system.set_clipboard(table.concat(elem.lines, "\n"))
          core.log("Code copied to clipboard")
        end
        return true
      end
    end
    local heading_idx = self:get_heading_at_y(y)
    if heading_idx then
      self.collapsed[heading_idx] = not self.collapsed[heading_idx]
      return true
    end
  end
  return MarkdownPreviewView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function MarkdownPreviewView:on_mouse_moved(x, y, ...)
  -- Check copy button hover
  self.hovered_copy_btn = nil
  for _, btn in ipairs(self.copy_buttons) do
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      self.hovered_copy_btn = btn.idx
      break
    end
  end
  self.hovered_heading = self:get_heading_at_y(y)
  return MarkdownPreviewView.super.on_mouse_moved(self, x, y, ...)
end

function MarkdownPreviewView:draw()
  self:draw_background(style.background)

  self.copy_buttons = {}  -- reset each draw
  local ln_w = config.plugins.markdown_preview.line_number_width
  local ox, oy = self:get_content_offset()
  local ln_x = ox + style.padding.x
  local x = ox + ln_w + style.padding.x
  local y = oy + style.padding.y
  local avail_w = self.size.x - ln_w - style.padding.x * 2

  -- Draw line number gutter background
  if oy + self.size.y > self.position.y then
    local gutter_top = math.max(oy, self.position.y)
    local gutter_bottom = math.min(oy + self.content_height, self.position.y + self.size.y)
    if gutter_bottom > gutter_top then
      renderer.draw_rect(ox, gutter_top, ln_w, gutter_bottom - gutter_top, style.line_highlight)
    end
  end

  local heading_colors = {
    [1] = style.syntax["keyword"] or style.text,
    [2] = style.syntax["keyword2"] or style.text,
    [3] = style.syntax["function"] or style.text,
    [4] = style.text,
    [5] = style.text,
    [6] = style.dim,
  }

  for idx, elem in ipairs(self.elements) do
    if self:is_hidden(idx) then goto skip end

    -- Draw line number
    local ln_text = tostring(elem.line or "")
    local ln_y = y
    local font = style.font

    if elem.type == "heading" then
      local scale = math.max(1, 1.6 - elem.level * 0.15)
      local is_collapsed = self.collapsed[idx]
      local is_hovered = (self.hovered_heading == idx)
      local color = heading_colors[elem.level] or style.text
      local indicator = is_collapsed and "▶ " or "▽ "
      local text_to_wrap = indicator .. elem.text
      local lines_out = self:wrap_text(text_to_wrap, avail_w)

      -- Draw line number
      common.draw_text(font, style.dim, ln_text, "right", ln_x, y, ln_w - style.padding.x, style.font:get_height() * scale)

      -- Highlight on hover
      if is_hovered then
        local block_h = 0
        for _ in ipairs(lines_out) do
          block_h = block_h + style.font:get_height() * scale + style.padding.y / 2
        end
        block_h = block_h + style.padding.y
        renderer.draw_rect(x - style.padding.x / 2, y, avail_w + style.padding.x, block_h, style.line_highlight)
      end

      for _, line in ipairs(lines_out) do
        renderer.draw_text(style.font, line, x, y, color)
        y = y + style.font:get_height() * scale + style.padding.y / 2
      end
      y = y + style.padding.y

    elseif elem.type == "paragraph" then
      local lines_out = self:wrap_text(elem.text, avail_w)
      -- Draw line number for first line
      common.draw_text(font, style.dim, ln_text, "right", ln_x, y, ln_w - style.padding.x, style.font:get_height())
      for _, line in ipairs(lines_out) do
        renderer.draw_text(style.font, line, x, y, style.text)
        y = y + style.font:get_height() + style.padding.y / 2
      end
      y = y + style.padding.y

    elseif elem.type == "code_block" then
      local code_h = style.code_font:get_height()
      local code_w = avail_w - style.padding.x * 2
      -- Calculate total height first
      local total_h = style.padding.y
      for _, line in ipairs(elem.lines) do
        local wrapped = self:wrap_code_line(line, code_w)
        total_h = total_h + #wrapped * code_h
      end
      total_h = total_h + style.padding.y
      -- Draw code block background
      renderer.draw_rect(x, y, avail_w, total_h, style.line_highlight)
      -- Draw copy button in top-right corner
      local btn_text = "Copy"
      local btn_w = style.font:get_width(btn_text) + style.padding.x * 2
      local btn_h = style.font:get_height() + style.padding.y
      local btn_x = x + avail_w - btn_w - style.padding.x / 2
      local btn_y = y + style.padding.y / 2
      local is_hovered_btn = (self.hovered_copy_btn == idx)
      local btn_bg = is_hovered_btn and style.dim or style.background
      local btn_fg = is_hovered_btn and style.text or style.dim
      renderer.draw_rect(btn_x, btn_y, btn_w, btn_h, btn_bg)
      common.draw_text(style.font, btn_fg, btn_text, "center", btn_x, btn_y, btn_w, btn_h)
      table.insert(self.copy_buttons, {idx = idx, x = btn_x, y = btn_y, w = btn_w, h = btn_h})
      -- Draw each source line with its line number and wrapped content
      for li, line in ipairs(elem.lines) do
        local line_num = (elem.line or 0) + li
        local wrapped = self:wrap_code_line(line, code_w)
        for wi, wline in ipairs(wrapped) do
          if wi == 1 then
            common.draw_text(font, style.dim, tostring(line_num), "right", ln_x, y, ln_w - style.padding.x, code_h)
          end
          local text_x = x + style.padding.x
          if wi > 1 then
            text_x = text_x + style.code_font:get_width("  ")
          end
          renderer.draw_text(style.code_font, wline, text_x, y + style.padding.y / 2, style.syntax["string"] or style.text)
          y = y + code_h
        end
      end
      y = y + style.padding.y

    elseif elem.type == "empty" then
      common.draw_text(font, style.dim, ln_text, "right", ln_x, y, ln_w - style.padding.x, style.font:get_height())
      y = y + style.font:get_height() + style.padding.y / 2

    elseif elem.type == "blockquote" then
      local lines_out = self:wrap_text(elem.text, avail_w - style.padding.x * 2)
      local block_h = #lines_out * style.font:get_height() + style.padding.y
      -- Draw line number
      common.draw_text(font, style.dim, ln_text, "right", ln_x, y, ln_w - style.padding.x, style.font:get_height())
      renderer.draw_rect(x, y, 3 * SCALE, block_h, style.syntax["comment"] or style.dim)
      for _, line in ipairs(lines_out) do
        renderer.draw_text(style.font, line, x + style.padding.x * 2, y + style.padding.y / 2, style.dim)
        y = y + style.font:get_height()
      end
      y = y + style.padding.y

    elseif elem.type == "ul" then
      -- Draw line number
      common.draw_text(font, style.dim, ln_text, "right", ln_x, y, ln_w - style.padding.x, style.font:get_height())
      for _, item_text in ipairs(elem.items) do
        local text_x = x + style.padding.x * 3
        local lines_out = self:wrap_text(item_text, avail_w - style.padding.x * 3)
        renderer.draw_text(style.font, "•", x + style.padding.x, y, style.text)
        for _, line in ipairs(lines_out) do
          renderer.draw_text(style.font, line, text_x, y, style.text)
          y = y + style.font:get_height()
        end
      end
      y = y + style.padding.y

    elseif elem.type == "ol" then
      -- Draw line number
      common.draw_text(font, style.dim, ln_text, "right", ln_x, y, ln_w - style.padding.x, style.font:get_height())
      for idx2, item_text in ipairs(elem.items) do
        local text_x = x + style.padding.x * 3
        local lines_out = self:wrap_text(item_text, avail_w - style.padding.x * 3)
        renderer.draw_text(style.font, idx2 .. ".", x + style.padding.x, y, style.text)
        for _, line in ipairs(lines_out) do
          renderer.draw_text(style.font, line, text_x, y, style.text)
          y = y + style.font:get_height()
        end
      end
      y = y + style.padding.y

    elseif elem.type == "hr" then
      -- Draw line number
      common.draw_text(font, style.dim, ln_text, "right", ln_x, y, ln_w - style.padding.x, style.font:get_height())
      local cy = y + style.padding.y
      renderer.draw_rect(x, cy, avail_w, 1 * SCALE, style.divider)
      y = y + style.padding.y * 2
    end

    ::skip::
  end

  self.content_height = y - oy
  self:draw_scrollbar()
end

-- ============================================================
-- Preview toggle logic (in-place replace, no new tab)
-- ============================================================
local preview_view = nil
local preview_doc_ref = nil
local preview_node = nil
local preview_docview = nil

local function close_preview()
  if preview_view and preview_node then
    local idx
    for i, v in ipairs(preview_node.views) do
      if v == preview_view then
        idx = i
        break
      end
    end
    if idx and preview_docview then
      preview_node.views[idx] = preview_docview
      preview_node:set_active_view(preview_docview)
    end
    preview_view = nil
    preview_doc_ref = nil
    preview_node = nil
    preview_docview = nil
  end
end

local function open_preview()
  local av = core.active_view
  local doc = av and av.doc
  if not doc or not doc.filename or not doc.filename:match("%.md$") then
    core.log("Not a markdown file")
    return
  end

  if preview_view and preview_doc_ref == doc then
    return
  end

  close_preview()

  preview_view = MarkdownPreviewView(doc)
  preview_doc_ref = doc
  preview_docview = av

  local node = core.root_view:get_active_node()
  preview_node = node

  for i, v in ipairs(node.views) do
    if v == av then
      node.views[i] = preview_view
      break
    end
  end

  node:set_active_view(preview_view)
end

-- ============================================================
-- Hooks: auto-refresh and close on doc close
-- ============================================================
local orig_doc_on_text_change = Doc.on_text_change
function Doc:on_text_change(type)
  orig_doc_on_text_change(self, type)
  if preview_view and preview_doc_ref == self then
    preview_view:refresh()
  end
end

local orig_docview_try_close = DocView.try_close
function DocView:try_close(...)
  if preview_view and preview_doc_ref == self.doc then
    close_preview()
  end
  orig_docview_try_close(self, ...)
end

-- ============================================================
-- Commands and keymap
-- ============================================================
command.add(nil, {
  ["markdown-preview:toggle"] = function()
    local doc = core.active_view and core.active_view.doc
    if preview_view and preview_doc_ref == doc then
      close_preview()
      core.log("Markdown preview: off")
    else
      open_preview()
      core.log("Markdown preview: on")
    end
  end,
})

keymap.add { ["cmd+shift+m"] = "markdown-preview:toggle" }
