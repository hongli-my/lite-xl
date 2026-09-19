-- mod-version:4
-- ============================================================
-- Markdown rendered preview for Lite-XL
-- ------------------------------------------------------------
-- Features:
--   * Top-right "预览 / 编辑" toggle button on every Markdown file
--   * Inline formatting: **bold**, *italic*, ***bi***, `code`, ~~strike~~,
--     ==highlight==, [link](url), ![image](path), <url>, bare urls, <!--comment-->
--   * Block elements (GitHub/Typora-flavoured): headings (collapsible, with
--     bottom rule on h1/h2), paragraphs, fenced code (lang label + copy button +
--     left accent bar), blockquotes, bullet/ordered/task lists, tables, hr, images
--   * Clickable links / images / headings; copy-button on code blocks
--   * Theme-aware (dark & light), cached bold/italic fonts rebuilt on font change
-- ------------------------------------------------------------
-- Toggle: click the top-right button, or press cmd+shift+m / ctrl+shift+m
-- ============================================================

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local common = require "core.common"
local View = require "core.view"
local DocView = require "core.docview"
local Doc = require "core.doc"

config.plugins.markdown_preview = common.merge({
  max_cached_images = 32,
  max_image_pixels = 4096 * 4096,
  max_image_file_size = 8 * 1024 * 1024,
  show_line_numbers_in_preview = false,
  render_tables = true,
  font_scale_headings = true,
  button_label_preview = "预览",
  button_label_edit = "编辑",
}, config.plugins.markdown_preview)

-- ============================================================
-- Font cache: bold / italic / bold-italic / strike + scaled headings.
-- Rebuilt when style.font changes (theme / font switch).
-- ============================================================
local md_fonts = {}
local heading_fonts = {}
local last_font_ref, last_font_size

local function rebuild_fonts()
  local sz = style.font:get_size()
  md_fonts.normal      = style.font
  md_fonts.bold        = style.font:copy(sz, { bold = true })
  md_fonts.italic      = style.font:copy(sz, { italic = true })
  md_fonts.bold_italic = style.font:copy(sz, { bold = true, italic = true })
  md_fonts.strike      = style.font:copy(sz, { strikethrough = true })
  local scales = { 1.75, 1.45, 1.22, 1.08, 1.0, 0.92 }
  for lv = 1, 6 do
    if config.plugins.markdown_preview.font_scale_headings then
      heading_fonts[lv] = style.font:copy(sz * scales[lv], { bold = true })
    else
      heading_fonts[lv] = md_fonts.bold
    end
  end
  last_font_ref = style.font
  last_font_size = sz
end
rebuild_fonts()

-- ============================================================
-- Theme-aware colors
-- ============================================================
local function luminance(c) return (c[1] * 0.299 + c[2] * 0.587 + c[3] * 0.114) / 255 end
local function is_dark() return luminance(style.background) < 0.5 end

-- Truncate `text` to fit within `max_w` (in the given font), appending "…".
local function truncate_to_width(font, text, max_w)
  if max_w <= 0 then return "" end
  if font:get_width(text) <= max_w then return text end
  local ell = "…"
  local ew = font:get_width(ell)
  if max_w <= ew then return ell end
  local lo, hi = 1, #text
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if font:get_width(text:sub(1, mid)) + ew <= max_w then lo = mid else hi = mid - 1 end
  end
  return text:sub(1, lo) .. ell
end

-- Theme-aware background colors. Cached and rebuilt only when the theme
-- (style.background reference) changes, to avoid allocating tables every frame.
local _cached_colors, _cached_bg_ref = {}, nil
local function colors()
  if _cached_bg_ref ~= style.background then
    _cached_bg_ref = style.background
    local dark = is_dark()
    _cached_colors = {
      code_bg       = dark and { 255, 255, 255, 18 } or { 0, 0, 0, 14 },
      highlight_bg  = dark and { 255, 220, 0, 55 } or { 255, 235, 90, 110 },
      blockquote_bg = dark and { 255, 255, 255, 10 } or { 0, 0, 0, 8 },
      table_head_bg = dark and { 255, 255, 255, 14 } or { 0, 0, 0, 18 },
      table_zebra   = dark and { 255, 255, 255, 7 } or { 0, 0, 0, 9 },
      -- faint separator for heading rules / hr / table grid (much lighter than style.divider)
      rule          = { style.divider[1] or (dark and 90 or 0),
                        style.divider[2] or (dark and 90 or 0),
                        style.divider[3] or (dark and 90 or 0),
                        dark and 48 or 32 },
    }
  end
  return _cached_colors
end
local function code_bg_color() return colors().code_bg end
local function highlight_bg_color() return colors().highlight_bg end
local function blockquote_bg_color() return colors().blockquote_bg end
local function table_head_bg_color() return colors().table_head_bg end
local function table_zebra_bg_color() return colors().table_zebra end
local function rule_color() return colors().rule end

local function syntax_col(name, fallback)
  return style.syntax[name] or fallback or style.text
end

-- ============================================================
-- Inline parser
-- ------------------------------------------------------------
-- parse_inline(text) -> segments
--   segment = { text=, font=, color=, bg=, underline=, link=, image= }
--   bg in {"code","highlight",nil}; link = url string; image segment has
--   { image=true, alt=, path= }
-- ============================================================
local function parse_inline(text)
  local segs, plain = {}, {}
  local function flush()
    if #plain > 0 then
      segs[#segs + 1] = { text = table.concat(plain), font = md_fonts.normal, color = style.text }
      plain = {}
    end
  end
  local function push(seg) flush(); segs[#segs + 1] = seg end

  local i, n = 1, #text
  while i <= n do
    -- fast-forward to the next character that could start a marker (C-level
    -- scan), avoiding the per-character text:sub() copies that made the
    -- previous implementation O(n^2).
    local nxt = text:find("[`*_~<=!%[h]", i) or (n + 1)
    if nxt > i then
      plain[#plain + 1] = text:sub(i, nxt - 1)
      i = nxt
      if i > n then break end
    end
    local b = text:byte(i)

    -- inline code  `...`
    if b == 96 then -- `
      local e = text:find("`", i + 1, true)
      if e then
        push({ text = text:sub(i + 1, e - 1), font = style.code_font,
               color = syntax_col("string", style.text), bg = "code" })
        i = e + 1
        goto continue
      end
    end

    -- HTML comment  <!-- ... -->
    if b == 60 and text:sub(i, i + 3) == "<!--" then -- <
      local e = text:find("-->", i + 4, true)
      if e then i = e + 3 goto continue end
    end

    -- image  ![alt](path)
    if b == 33 then -- !
      local s, e, alt, path = text:find("%!%[([^%]]*)%]%(([^)]+)%)", i)
      if s == i then
        push({ image = true, alt = alt, path = path })
        i = e + 1
        goto continue
      end
    end

    -- link  [text](url)
    if b == 91 then -- [
      local s, e, ltxt, url = text:find("%[([^%]]*)%]%(([^)]+)%)", i)
      if s == i then
        push({ text = ltxt, font = md_fonts.normal, color = style.accent,
               underline = true, link = url })
        i = e + 1
        goto continue
      end
    end

    -- autolink  <url> or <email>
    if b == 60 then -- <
      local s, e, url = text:find("<([^>]+)>", i)
      if s == i and (url:match("^https?://") or url:match("@")) then
        push({ text = url, font = md_fonts.normal, color = style.accent,
               underline = true, link = url })
        i = e + 1
        goto continue
      end
    end

    -- bare url
    if b == 104 then -- h
      if text:sub(i, i + 6) == "http://" or text:sub(i, i + 7) == "https://" then
        local s, e = text:find("https?://%S+", i)
        if s == i then
          local url = text:sub(i, e)
          local trail = url:match("([.,;:!?)]*)$")
          if trail and #trail > 0 then url = url:sub(1, #url - #trail); e = e - #trail end
          if url ~= "" then
            push({ text = url, font = md_fonts.normal, color = style.accent,
                   underline = true, link = url })
            i = e + 1
            goto continue
          end
        end
      end
    end

    -- bold+italic / bold / italic  (*** ** *)
    if b == 42 or b == 95 then -- * or _
      local m3 = text:sub(i, i + 2)
      if m3 == "***" or m3 == "___" then
        local e = text:find(m3, i + 3, true)
        if e then
          push({ text = text:sub(i + 3, e - 1), font = md_fonts.bold_italic, color = style.text })
          i = e + 3
          goto continue
        end
      end
      local m2 = text:sub(i, i + 1)
      if m2 == "**" or m2 == "__" then
        local e = text:find(m2, i + 2, true)
        if e then
          push({ text = text:sub(i + 2, e - 1), font = md_fonts.bold, color = style.text })
          i = e + 2
          goto continue
        end
      end
      local nx = text:byte(i + 1)
      if nx and nx ~= 32 then -- not followed by a space
        local e = text:find(text:sub(i, i), i + 1, true)
        if e then
          push({ text = text:sub(i + 1, e - 1), font = md_fonts.italic, color = style.text })
          i = e + 1
          goto continue
        end
      end
    end

    -- strikethrough  ~~...~~
    if b == 126 then -- ~
      if text:find("~~", i, true) == i then
        local e = text:find("~~", i + 2, true)
        if e then
          push({ text = text:sub(i + 2, e - 1), font = md_fonts.strike, color = style.dim })
          i = e + 2
          goto continue
        end
      end
    end

    -- highlight  ==...==
    if b == 61 then -- =
      if text:find("==", i, true) == i then
        local e = text:find("==", i + 2, true)
        if e then
          push({ text = text:sub(i + 2, e - 1), font = md_fonts.normal,
                 color = style.text, bg = "highlight" })
          i = e + 2
          goto continue
        end
      end
    end

    -- soft line break (literal newline inside a paragraph block) -> space
    if b == 10 then
      plain[#plain + 1] = " "
      i = i + 1
      goto continue
    end

    -- not a marker: consume this one character as plain
    plain[#plain + 1] = text:sub(i, i)
    i = i + 1
    ::continue::
  end
  flush()
  return segs
end

-- ============================================================
-- Rich-text wrapping
-- ------------------------------------------------------------
-- wrap_rich(segments, max_w) -> lines
--   line = { tokens = {tok}, height = n }
--   tok  = { text, font, color, bg, underline, link, image, alt, path }
-- ============================================================
local function token_width(tok)
  if not tok.w then tok.w = tok.font:get_width(tok.text or "") end
  local w = tok.w
  if tok.bg == "code" then w = w + style.padding.x end
  return w
end

local function wrap_rich(segments, max_w)
  local lines = {}
  local cur = { tokens = {}, width = 0, height = 0 }
  local function newline()
    lines[#lines + 1] = cur
    cur = { tokens = {}, width = 0, height = 0 }
  end
  local function place(tok)
    local w = token_width(tok)
    local h = tok.font and tok.font:get_height() or style.font:get_height()
    -- word longer than the line: break by character
    if w > max_w and #cur.tokens == 0 and tok.text and not tok.image then
      local acc, accw = "", 0
      for ch in tok.text:gmatch(".") do
        local chw = tok.font:get_width(ch)
        local piece = (tok.bg == "code") and (accw + chw + style.padding.x) or (accw + chw)
        if piece > max_w and acc ~= "" then
          local t2 = { text = acc, font = tok.font, color = tok.color, bg = tok.bg,
                       underline = tok.underline, link = tok.link }
          cur.tokens[#cur.tokens + 1] = t2
          cur.width = token_width(t2)
          cur.height = math.max(cur.height, t2.font:get_height())
          newline()
          acc, accw = ch, chw
        else
          acc, accw = acc .. ch, accw + chw
        end
      end
      if acc ~= "" then
        local t2 = { text = acc, font = tok.font, color = tok.color, bg = tok.bg,
                     underline = tok.underline, link = tok.link }
        cur.tokens[#cur.tokens + 1] = t2
        cur.width = cur.width + token_width(t2)
        cur.height = math.max(cur.height, t2.font:get_height())
      end
      return
    end
    if cur.width + w > max_w and #cur.tokens > 0 then newline() end
    cur.tokens[#cur.tokens + 1] = tok
    cur.width = cur.width + w
    cur.height = math.max(cur.height, math.ceil(h * 1.5))
  end

  for _, seg in ipairs(segments) do
    if seg.image then
      if #cur.tokens > 0 then newline() end
      cur.tokens[#cur.tokens + 1] = seg
      cur.height = math.max(cur.height, style.font:get_height())
      newline()
    else
      local s, pos = seg.text, 1
      while pos <= #s do
        local sp = s:match("^%s+", pos)
        if sp then
          place({ text = sp, font = seg.font, color = seg.color, bg = seg.bg,
                  underline = seg.underline, link = seg.link })
          pos = pos + #sp
        else
          local w = s:match("^%S+", pos)
          if not w then break end
          place({ text = w, font = seg.font, color = seg.color, bg = seg.bg,
                  underline = seg.underline, link = seg.link })
          pos = pos + #w
        end
      end
    end
  end
  if #cur.tokens > 0 then newline() end
  if #lines == 0 then
    lines[1] = { tokens = {}, width = 0, height = style.font:get_height() }
  end
  return lines
end

-- Draw one wrapped line. Records link hit-areas on self._link_hits.
local function draw_rich_line(self, line, x, y)
  local cx, h = x, line.height
  for _, t in ipairs(line.tokens) do
    if t.image then
      -- inline images are rendered as a small placeholder chip; block-level
      -- images are handled by the image element.
      local chip = "[图]"
      local tw = style.code_font:get_width(chip)
      renderer.draw_rect(cx, y, tw + style.padding.x, h, code_bg_color())
      renderer.draw_text(style.code_font, chip, cx + style.padding.x / 2,
                         y + (h - style.code_font:get_height()) / 2, syntax_col("string", style.text))
      cx = cx + tw + style.padding.x
    else
      local tw = t.w or t.font:get_width(t.text)
      local ty = y + (h - t.font:get_height()) / 2
      if t.bg == "code" then
        renderer.draw_rect(cx, y, tw + style.padding.x, h, code_bg_color())
        renderer.draw_text(t.font, t.text, cx + style.padding.x / 2, ty, t.color)
        cx = cx + tw + style.padding.x
      elseif t.bg == "highlight" then
        renderer.draw_rect(cx, y, tw, h, highlight_bg_color())
        renderer.draw_text(t.font, t.text, cx, ty, t.color)
        cx = cx + tw
      else
        local link_hov = self.hovered_link and self.hovered_link.url == t.link
        if link_hov then
          renderer.draw_rect(cx, y, tw, h, is_dark() and { 255, 255, 255, 22 } or { 0, 0, 0, 12 })
        end
        renderer.draw_text(t.font, t.text, cx, ty, t.color)
        if t.underline or link_hov then
          renderer.draw_rect(cx, y + h - common.round(1 * SCALE), tw, common.round(1 * SCALE), t.color)
        end
        if t.link then
          self._link_hits[#self._link_hits + 1] = { x = cx, y = y, w = tw, h = h, url = t.link }
        end
        cx = cx + tw
      end
    end
  end
  return h
end

local function measure_rich_height(segments, max_w)
  local lines = wrap_rich(segments, max_w)
  local h = 0
  for _, l in ipairs(lines) do h = h + l.height end
  return h, lines
end

-- ============================================================
-- MarkdownPreviewView
-- ============================================================
local close_preview  -- forward declaration (used by view methods below)

local MarkdownPreviewView = View:extend()
function MarkdownPreviewView:__tostring() return "MarkdownPreviewView" end

function MarkdownPreviewView:new(doc)
  MarkdownPreviewView.super.new(self)
  self.scrollable = true
  self.cursor = "arrow"
  self.doc = doc
  self.elements = {}
  self.collapsed = {}
  self.hovered_heading = nil
  self.hovered_copy_btn = nil
  self.hovered_link = nil
  self.hovered_button = false
  self.image_cache = {}
  self.image_sizes = {}
  self.copy_buttons = {}
  self._link_hits = {}
  self._image_hits = {}
  self._layout_dirty = true
  self._last_size_x = -1
  self.content_height = 0
  self:refresh()
end

function MarkdownPreviewView:get_name()
  return "Preview: " .. (self.doc.filename and self.doc.filename:match("([^/]+)$") or "untitled")
end

function MarkdownPreviewView:refresh()
  self.elements = self:parse_markdown()
  self:load_images()
  self._layout_dirty = true
end

function MarkdownPreviewView:update()
  View.update(self)
  if last_font_ref ~= style.font or last_font_size ~= style.font:get_size() then
    rebuild_fonts()
    self._layout_dirty = true
  end
  if self._copy_feedback_until and system.get_time() > self._copy_feedback_until then
    self._copy_feedback_idx = nil
    self._copy_feedback_until = nil
    core.redraw = true
  end
  if self._needs_refresh then
    self._needs_refresh = false
    self:refresh()
  end
  if self._layout_dirty or self._last_size_x ~= self.size.x then
    self:compute_layout()
    self._last_size_x = self.size.x
    self._layout_dirty = false
  end
end

-- ---------- image loading (cached, bounded) ----------
function MarkdownPreviewView:load_image(path)
  local cfg = config.plugins.markdown_preview
  local abs_path = path
  if not abs_path:match("^/") then
    local doc_dir = self.doc.abs_filename and self.doc.abs_filename:match("(.*)[/\\]") or "."
    abs_path = doc_dir .. "/" .. path
  end
  local info = system.get_file_info(abs_path)
  if info and cfg.max_image_file_size and info.size and info.size > cfg.max_image_file_size then
    return nil
  end
  local ok, img = pcall(renderer.image.load, abs_path)
  if not ok or not img then return nil end
  local iw, ih = img:get_size()
  if cfg.max_image_pixels and iw * ih > cfg.max_image_pixels then return nil end
  return img, { w = iw, h = ih }
end

function MarkdownPreviewView:load_images()
  local cfg = config.plugins.markdown_preview
  local limit = math.max(1, cfg.max_cached_images or 32)
  local kept, kept_set = {}, {}
  for _, elem in ipairs(self.elements) do
    local path = elem.type == "image" and elem.path or nil
    if path and not kept_set[path] and #kept < limit then
      kept_set[path] = true
      kept[#kept + 1] = path
      if self.image_cache[path] == nil then
        local img, size = self:load_image(path)
        self.image_cache[path] = img or false
        if img then self.image_sizes[path] = size end
      end
    end
  end
  for path in pairs(self.image_cache) do
    if not kept_set[path] then
      self.image_cache[path] = nil
      self.image_sizes[path] = nil
    end
  end
end

-- ============================================================
-- Block parser
-- ============================================================
local function split_table_row(row)
  local cells = {}
  local r = row:gsub("^%s*|%s*", ""):gsub("%s*|%s*$", "")
  for cell in (r .. "|"):gmatch("([^|]*)|") do
    cells[#cells + 1] = cell:gsub("^%s+", ""):gsub("%s+$", "")
  end
  return cells
end

local function parse_table_aligns(sep_row)
  local cells = split_table_row(sep_row)
  local aligns = {}
  for _, c in ipairs(cells) do
    local l, r = c:sub(1, 1) == ":", c:sub(-1) == ":"
    aligns[#aligns + 1] = (l and r) and "center" or (r and "right" or "left")
  end
  return aligns
end

function MarkdownPreviewView:parse_markdown()
  local elements = {}
  local lines = {}
  for i = 1, #self.doc.lines do
    lines[i] = self.doc.lines[i]:gsub("\n$", "")
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]

    if line:match("^%s*$") then
      elements[#elements + 1] = { type = "empty", line = i }
      i = i + 1
      goto continue
    end

    -- fenced code block  ``` / ~~~
    do
      local fc = line:match("^%s*[`~][`~][`~]+")
      if fc then
        local lang = line:match("^%s*[`~]+%s*(.-)%s*$")
        local start_line = i
        local code_lines = {}
        i = i + 1
        while i <= #lines and not lines[i]:match("^%s*[`~][`~][`~]+%s*$") do
          code_lines[#code_lines + 1] = lines[i]
          i = i + 1
        end
        if i <= #lines then i = i + 1 end
        elements[#elements + 1] = { type = "code_block", lines = code_lines,
                                    lang = lang, line = start_line }
        goto continue
      end
    end

    -- ATX heading  # ..
    do
      local level, text = line:match("^(#+)%s+(.+)$")
      if level and #level <= 6 then
        elements[#elements + 1] = { type = "heading", level = #level,
                                    text = text:gsub("%s*#+%s*$", ""), line = i }
        i = i + 1
        goto continue
      end
    end

    -- horizontal rule
    if line:match("^%s*([-*_])%1%1[%1%s]*$") then
      elements[#elements + 1] = { type = "hr", line = i }
      i = i + 1
      goto continue
    end

    -- table (GFM)
    if config.plugins.markdown_preview.render_tables and line:match("|") and i + 1 <= #lines then
      local nxt = lines[i + 1]
      if nxt:match("|") and nxt:match("-") and nxt:match("^%s*|?[%s:|-]+$") then
        local headers = split_table_row(line)
        local aligns = parse_table_aligns(nxt)
        local rows = {}
        local start_line = i
        i = i + 2
        while i <= #lines and lines[i]:match("|") and not lines[i]:match("^%s*$") do
          rows[#rows + 1] = split_table_row(lines[i])
          i = i + 1
        end
        elements[#elements + 1] = { type = "table", headers = headers,
                                    aligns = aligns, rows = rows, line = start_line }
        goto continue
      end
    end

    -- blockquote
    if line:match("^>%s?") then
      local start_line = i
      local qlines = {}
      while i <= #lines and lines[i]:match("^>%s?") do
        qlines[#qlines + 1] = lines[i]:gsub("^>%s?", "")
        i = i + 1
      end
      elements[#elements + 1] = { type = "blockquote",
                                  text = table.concat(qlines, "\n"), line = start_line }
      goto continue
    end

    -- bullet list (with task-list support)
    do
      local bullet, rest = line:match("^([%-%*%+])%s+(.+)$")
      if bullet then
        local start_line = i
        local items = {}
        while i <= #lines do
          local b, t = lines[i]:match("^([%-%*%+])%s+(.+)$")
          if b then
            local checked, body = t:match("^%[([ xX])%]%s+(.*)$")
            if checked then
              items[#items + 1] = { text = body, task = (checked == "x" or checked == "X") and "done" or "todo" }
            else
              items[#items + 1] = { text = t, task = nil }
            end
            i = i + 1
          elseif i <= #lines and lines[i]:match("^%s+") and #items > 0 then
            items[#items].text = items[#items].text .. "\n" .. lines[i]:gsub("^%s+", "")
            i = i + 1
          else
            break
          end
        end
        elements[#elements + 1] = { type = "ul", items = items, line = start_line }
        goto continue
      end
    end

    -- ordered list
    do
      local num, rest = line:match("^([0-9]+)%.%s+(.+)$")
      if num then
        local start_line = i
        local items = {}
        while i <= #lines do
          local nn, tt = lines[i]:match("^([0-9]+)%.%s+(.+)$")
          if nn then
            items[#items + 1] = { text = tt, task = nil }
            i = i + 1
          elseif i <= #lines and lines[i]:match("^%s+") and #items > 0 then
            items[#items].text = items[#items].text .. "\n" .. lines[i]:gsub("^%s+", "")
            i = i + 1
          else
            break
          end
        end
        elements[#elements + 1] = { type = "ol", items = items, start = tonumber(num) or 1,
                                    line = start_line }
        goto continue
      end
    end

    -- standalone image line  ![alt](path)
    do
      local alt, path = line:match("^%s*%!%[([^%]]*)%]%(([^)]+)%)%s*$")
      if alt or path then
        elements[#elements + 1] = { type = "image", alt = alt or "", path = path or "", line = i }
        i = i + 1
        goto continue
      end
    end

    -- setext heading / paragraph
    local start_line = i
    local first = line
    if i + 1 <= #lines then
      local nl = lines[i + 1]
      if nl:match("^=+%s*$") then
        elements[#elements + 1] = { type = "heading", level = 1,
                                    text = first:gsub("^%s+", ""), line = i }
        i = i + 2
        goto continue
      elseif nl:match("^-+%s*$") then
        elements[#elements + 1] = { type = "heading", level = 2,
                                    text = first:gsub("^%s+", ""), line = i }
        i = i + 2
        goto continue
      end
    end
    do
      local para = {}
      while i <= #lines and not lines[i]:match("^%s*$") do
        para[#para + 1] = lines[i]
        i = i + 1
      end
      elements[#elements + 1] = { type = "paragraph",
                                  text = table.concat(para, "\n"), line = start_line }
    end
    ::continue::
  end
  return elements
end

-- ============================================================
-- Layout
-- ------------------------------------------------------------
-- compute_layout builds self.layout = { blocks = {blk}, x0, avail_w, gw }
-- each blk = { elem, idx, y, h, <render-data> }
-- ============================================================
local wrap_code_line  -- forward declaration (used in compute_layout)

function MarkdownPreviewView:is_hidden(idx)
  return self._hidden and self._hidden[idx] or false
end

function MarkdownPreviewView:compute_layout()
  local cfg = config.plugins.markdown_preview
  local show_ln = cfg.show_line_numbers_in_preview
  local pad = style.padding
  local gw = show_ln and (style.font:get_width(tostring(#self.doc.lines)) + pad.x * 2) or 0
  local full_w = math.max(50, self.size.x - gw - pad.x * 2)
  -- left-aligned content column (full available width)
  local avail_w = full_w
  local x0 = pad.x + gw
  local y = pad.y
  local blocks = {}
  local code_font_h = style.code_font:get_height()

  -- precompute the hidden mask in a single forward pass (O(n)) instead of
  -- re-scanning from each element (O(n^2))
  local hidden = {}
  do
    local collapse = nil
    for idx2, elem in ipairs(self.elements) do
      if elem.type == "heading" and collapse and elem.level <= collapse.level then
        collapse = nil
      end
      if collapse then hidden[idx2] = true end
      if elem.type == "heading" and self.collapsed[idx2] then
        collapse = { level = elem.level }
      end
    end
  end
  self._hidden = hidden

  for idx, elem in ipairs(self.elements) do
    if not hidden[idx] then
      local blk = { elem = elem, idx = idx, y = y, h = 0 }
      if elem.type == "heading" then
        local font = heading_fonts[elem.level] or md_fonts.bold
        local segs = parse_inline(elem.text)
        local lines = wrap_rich(segs, avail_w - pad.x)
        local h = 0
        for _, l in ipairs(lines) do h = h + l.height end
        h = h + pad.y + (elem.level <= 2 and pad.y or 0)
        blk.font, blk.lines, blk.h = font, lines, h
      elseif elem.type == "paragraph" then
        local segs = parse_inline(elem.text)
        local h, lines = measure_rich_height(segs, avail_w)
        blk.lines, blk.h = lines, h + pad.y * 1.0
      elseif elem.type == "empty" then
        blk.h = style.font:get_height() * 0.6
      elseif elem.type == "hr" then
        blk.h = pad.y * 2 + common.round(1 * SCALE)
      elseif elem.type == "blockquote" then
        local segs = parse_inline(elem.text)
        local h, lines = measure_rich_height(segs, avail_w - pad.x * 2)
        blk.lines, blk.h = lines, h + pad.y
      elseif elem.type == "code_block" then
        local inner_w = avail_w - pad.x * 2
        local wrapped = {}
        local header_h = style.code_font:get_height() + math.ceil(pad.y * 0.8)
        local h = header_h
        for _, cl in ipairs(elem.lines) do
          local wlines = wrap_code_line(cl, inner_w)
          wrapped[#wrapped + 1] = wlines
          h = h + #wlines * code_font_h
        end
        blk.wrapped, blk.h, blk.header_h = wrapped, h + pad.y, header_h
      elseif elem.type == "ul" or elem.type == "ol" then
        local items_l = {}
        local h = 0
        local indent = pad.x * 2.5
        local is_ul = (elem.type == "ul")
        for n, item in ipairs(elem.items) do
          local segs = parse_inline(item.text)
          local lines = wrap_rich(segs, avail_w - indent - pad.x)
          items_l[#items_l + 1] = lines
          for _, l in ipairs(lines) do h = h + l.height end
        end
        blk.items_l, blk.h, blk.indent = items_l, h + pad.y, indent
      elseif elem.type == "table" then
        local font, bfont = md_fonts.normal, md_fonts.bold
        local pad_c = pad.x / 2
        local col_w = {}
        local function cw(txt, f) return f:get_width(txt) + pad_c * 2 end
        for ci, hcell in ipairs(elem.headers) do
          col_w[ci] = math.max(col_w[ci] or 0, cw(hcell, bfont))
        end
        for _, row in ipairs(elem.rows) do
          for ci, c in ipairs(row) do
            col_w[ci] = math.max(col_w[ci] or 0, cw(c, font))
          end
        end
        -- shrink columns proportionally so the table never silently drops columns
        local total = 0
        for _, w in ipairs(col_w) do total = total + w end
        if total > avail_w and total > 0 then
          local sc = avail_w / total
          for i = 1, #col_w do col_w[i] = col_w[i] * sc end
          total = avail_w
        end
        blk.col_w, blk.total_w = col_w, total
        blk.h = (style.code_font:get_height() + pad.y) * (#elem.rows + 1) + pad.y * 0.5
      elseif elem.type == "image" then
        local img = self.image_cache[elem.path]
        local sz = self.image_sizes[elem.path]
        if img and sz then
          local max_w = avail_w * 0.9
          local max_h = 320
          local sc = math.min(max_w / sz.w, max_h / sz.h, 1)
          blk.draw_w = math.floor(sz.w * sc)
          blk.draw_h = math.floor(sz.h * sc)
        else
          blk.draw_w, blk.draw_h = 0, 0
        end
        blk.h = blk.draw_h + (elem.alt ~= "" and style.font:get_height() or 0) + pad.y
      end
      blocks[#blocks + 1] = blk
      y = y + blk.h
    end
  end
  self.layout = { blocks = blocks, x0 = x0, avail_w = avail_w, gw = gw }
  self.content_height = y - pad.y + pad.y
end

-- character-level wrap for code blocks
function wrap_code_line(text, max_w)
  local out, cur, curw = {}, {}, 0
  local font = style.code_font
  for ch in text:gmatch(".") do
    local chw = font:get_width(ch)
    if curw + chw > max_w and #cur > 0 then
      out[#out + 1] = table.concat(cur)
      cur, curw = {}, 0
    end
    cur[#cur + 1] = ch
    curw = curw + chw
  end
  if #cur > 0 then out[#out + 1] = table.concat(cur) end
  return out
end

function MarkdownPreviewView:get_scrollable_size()
  return self.content_height + style.padding.y
end

-- ============================================================
-- Hit testing
-- ============================================================
function MarkdownPreviewView:get_button_rect()
  local label = config.plugins.markdown_preview.button_label_edit
  local font = style.font
  local w = font:get_width(label) + style.padding.x * 2
  local h = font:get_height() + style.padding.y
  local sb = style.expanded_scrollbar_size or style.scrollbar_size or 0
  local x = self.position.x + self.size.x - w - style.padding.x - sb
  local y = self.position.y + style.padding.y
  return x, y, w, h
end

function MarkdownPreviewView:heading_at_y(my)
  if not self.layout then return nil end
  local ox, oy = self:get_content_offset()
  for _, blk in ipairs(self.layout.blocks) do
    if blk.elem.type == "heading" then
      local by = oy + blk.y
      if my >= by and my < by + blk.h then return blk.idx end
    end
  end
  return nil
end

-- ============================================================
-- Mouse
-- ============================================================
function MarkdownPreviewView:on_mouse_moved(x, y, ...)
  MarkdownPreviewView.super.on_mouse_moved(self, x, y, ...)
  local bx, by, bw, bh = self:get_button_rect()
  self.hovered_button = (x >= bx and x <= bx + bw and y >= by and y <= by + bh)
  self.hovered_link = nil
  for _, hit in ipairs(self._link_hits) do
    if x >= hit.x and x <= hit.x + hit.w and y >= hit.y and y <= hit.y + hit.h then
      self.hovered_link = hit
      break
    end
  end
  self.hovered_copy_btn = nil
  for _, btn in ipairs(self.copy_buttons) do
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      self.hovered_copy_btn = btn.idx
      break
    end
  end
  self.hovered_heading = self:heading_at_y(y)
  if self.hovered_link then
    self.cursor = "hand"
  elseif self.hovered_button or self.hovered_copy_btn or self.hovered_heading then
    self.cursor = "arrow"
  else
    self.cursor = "arrow"
  end
  core.redraw = true
end

function MarkdownPreviewView:on_mouse_left(...)
  MarkdownPreviewView.super.on_mouse_left(self, ...)
  self.hovered_button = false
  self.hovered_link = nil
  self.hovered_copy_btn = nil
  self.hovered_heading = nil
end

local function shell_escape(s)
  -- POSIX single-quote escape; safe against shell metacharacters
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function open_url(url)
  -- only allow safe schemes to prevent shell injection via crafted URLs
  if not (url:match("^https?://") or url:match("^mailto:") or url:match("^file://") or url:match("^ftp://")) then
    core.log("Refused to open unsafe link: %s", url)
    return
  end
  if PLATFORM == "macOS" or PLATFORM == "Mac OS X" then
    os.execute("open " .. shell_escape(url) .. " 2>/dev/null")
  elseif PLATFORM == "Linux" then
    os.execute("xdg-open " .. shell_escape(url) .. " 2>/dev/null")
  elseif PLATFORM == "Windows" then
    os.execute('start "" "' .. url:gsub('"', '') .. '"')
  end
end

local function open_path(path)
  if PLATFORM == "macOS" or PLATFORM == "Mac OS X" then
    os.execute("open " .. shell_escape(path) .. " 2>/dev/null")
  elseif PLATFORM == "Linux" then
    os.execute("xdg-open " .. shell_escape(path) .. " 2>/dev/null")
  elseif PLATFORM == "Windows" then
    os.execute('start "" "' .. path:gsub('"', '') .. '"')
  end
end

function MarkdownPreviewView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then
    return MarkdownPreviewView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  -- toggle button
  local bx, by, bw, bh = self:get_button_rect()
  if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
    close_preview()
    return true
  end
  -- links
  for _, hit in ipairs(self._link_hits) do
    if x >= hit.x and x <= hit.x + hit.w and y >= hit.y and y <= hit.y + hit.h then
      open_url(hit.url)
      core.log("Opened: %s", hit.url)
      return true
    end
  end
  -- copy buttons
  for _, btn in ipairs(self.copy_buttons) do
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      local elem = self.elements[btn.idx]
      if elem and elem.lines then
        system.set_clipboard(table.concat(elem.lines, "\n"))
        self._copy_feedback_idx = btn.idx
        self._copy_feedback_until = system.get_time() + 1.2
        core.redraw = true
        core.log("Code copied to clipboard")
      end
      return true
    end
  end
  -- images
  for _, area in ipairs(self._image_hits) do
    if x >= area.x and x <= area.x + area.w and y >= area.y and y <= area.y + area.h then
      local elem = self.elements[area.idx]
      if elem and elem.path then
        local abs = elem.path
        if not abs:match("^/") then
          local dir = self.doc.abs_filename and self.doc.abs_filename:match("(.*)[/\\]") or "."
          abs = dir .. "/" .. elem.path
        end
        open_path(abs)
        core.log("Opened image: %s", elem.path)
      end
      return true
    end
  end
  -- heading collapse
  local hidx = self:heading_at_y(y)
  if hidx then
    self.collapsed[hidx] = not self.collapsed[hidx]
    self._layout_dirty = true
    return true
  end
  return MarkdownPreviewView.super.on_mouse_pressed(self, button, x, y, clicks)
end

-- ============================================================
-- Draw
-- ============================================================
function MarkdownPreviewView:draw_toggle_button()
  local label = config.plugins.markdown_preview.button_label_edit
  local font = style.font
  local x, y, w, h = self:get_button_rect()
  local border = common.round(1 * SCALE)
  local bg, fg
  if self.hovered_button then
    bg, fg = style.accent, style.background
  else
    bg = is_dark() and { 255, 255, 255, 22 } or { 0, 0, 0, 18 }
    fg = style.text
  end
  renderer.draw_rect(x - border, y - border, w + border * 2, h + border * 2, style.divider)
  renderer.draw_rect(x, y, w, h, bg)
  common.draw_text(font, fg, label, "center", x, y, w, h)
end

function MarkdownPreviewView:draw()
  self:draw_background(style.background)
  if not self.layout then return end

  self.copy_buttons = {}
  self._link_hits = {}
  self._image_hits = {}

  local layout = self.layout
  local x0, avail_w, gw = layout.x0, layout.avail_w, layout.gw
  local pad = style.padding
  local ox, oy = self:get_content_offset()

  local show_ln = config.plugins.markdown_preview.show_line_numbers_in_preview
  if show_ln and gw > 0 then
    renderer.draw_rect(ox, self.position.y, gw, self.size.y, style.line_highlight)
  end

  for _, blk in ipairs(layout.blocks) do
    local elem = blk.elem
    local x = ox + x0
    local y = oy + blk.y
    -- viewport culling: skip blocks entirely outside the visible region so we
    -- only draw what is on screen (important for large documents).
    local vy = self.position.y
    if y + blk.h < vy - 64 or y > vy + self.size.y + 64 then
      goto next_block
    end

    if elem.type == "heading" then
      local is_col = self.collapsed[blk.idx]
      local is_hov = (self.hovered_heading == blk.idx)
      local color = (elem.level <= 1) and style.accent
                   or (elem.level == 2) and syntax_col("keyword", style.text)
                   or style.text
      if is_hov then
        renderer.draw_rect(x - pad.x / 2, y, avail_w + pad.x, blk.h, style.line_highlight)
      end
      local ind = is_col and "▶ " or ""
      local cx = x
      if ind ~= "" then
        renderer.draw_text(blk.font, ind, cx, y + pad.y / 2, style.dim)
        cx = cx + blk.font:get_width(ind)
      end
      local ly = y + pad.y / 2
      for _, l in ipairs(blk.lines) do
        draw_rich_line(self, l, cx, ly)
        ly = ly + l.height
      end
      if elem.level <= 2 then
        renderer.draw_rect(x, y + blk.h - pad.y * 0.5, avail_w, common.round(1 * SCALE), rule_color())
      end

    elseif elem.type == "paragraph" then
      local ly = y
      for _, l in ipairs(blk.lines) do
        draw_rich_line(self, l, x, ly)
        ly = ly + l.height
      end

    elseif elem.type == "empty" then
      -- nothing

    elseif elem.type == "hr" then
      renderer.draw_rect(x, y + pad.y, avail_w, common.round(1 * SCALE), rule_color())

    elseif elem.type == "blockquote" then
      local bh = blk.h
      renderer.draw_rect(x, y, avail_w, bh, blockquote_bg_color())
      renderer.draw_rect(x, y, common.round(3 * SCALE), bh, syntax_col("comment", style.dim))
      local ly = y + pad.y / 2
      for _, l in ipairs(blk.lines) do
        draw_rich_line(self, l, x + pad.x, ly)
        ly = ly + l.height
      end

    elseif elem.type == "code_block" then
      local inner_w = avail_w - pad.x * 2
      local header_h = blk.header_h or (style.code_font:get_height() + pad.y)
      renderer.draw_rect(x, y, avail_w, blk.h, code_bg_color())
      renderer.draw_rect(x, y, common.round(3 * SCALE), blk.h, syntax_col("keyword", style.accent))
      -- header band: language label (left) + copy button (right), above the code
      if elem.lang and elem.lang ~= "" then
        common.draw_text(style.code_font, style.dim, elem.lang, "left",
                         x + pad.x, y + (header_h - style.code_font:get_height()) / 2,
                         inner_w, style.code_font:get_height())
      end
      local copied = (self._copy_feedback_idx == blk.idx)
      local btxt = copied and "已复制 ✓" or "Copy"
      local bw = style.font:get_width(btxt) + style.padding.x
      local bh = style.font:get_height() + style.padding.y / 2
      local bxp = x + avail_w - bw - pad.x / 2
      local byp = y + (header_h - bh) / 2
      local hov = (self.hovered_copy_btn == blk.idx)
      renderer.draw_rect(bxp, byp, bw, bh, (hov or copied) and style.accent or (is_dark() and { 255,255,255,18 } or { 0,0,0,14 }))
      common.draw_text(style.font, (hov or copied) and style.background or style.dim, btxt, "center", bxp, byp, bw, bh)
      self.copy_buttons[#self.copy_buttons + 1] = { idx = blk.idx, x = bxp, y = byp, w = bw, h = bh }
      -- code text starts below the header band
      local cy = y + header_h
      local code_color = is_dark() and style.text or syntax_col("normal", style.text)
      for _, wlines in ipairs(blk.wrapped) do
        for _, wl in ipairs(wlines) do
          renderer.draw_text(style.code_font, wl, x + pad.x, cy, code_color)
          cy = cy + style.code_font:get_height()
        end
      end

    end

    if elem.type == "ul" then
      local indent = blk.indent or pad.x * 2.5
      local ly = y
      for n, lines in ipairs(blk.items_l) do
        local item = elem.items[n]
        local bxm = x + pad.x / 2
        if item.task then
          local box = math.floor(style.font:get_height() * 0.85)
          local byb = ly + (lines[1] and ((lines[1].height - box) / 2) or 0) + 1
          if item.task == "done" then
            renderer.draw_rect(bxm, byb, box, box, style.accent)
            common.draw_text(style.code_font, style.background, "✓", "center", bxm, byb, box, box)
          else
            renderer.draw_rect(bxm - 1, byb - 1, box + 2, box + 2, style.dim)
            renderer.draw_rect(bxm, byb, box, box, style.background)
          end
        else
          renderer.draw_text(style.font, "•", bxm, ly, style.text)
        end
        local tx = x + indent
        for _, l in ipairs(lines) do
          draw_rich_line(self, l, tx, ly)
          ly = ly + l.height
        end
      end

    elseif elem.type == "ol" then
      local indent = blk.indent or pad.x * 2.5
      local ly = y
      for n, lines in ipairs(blk.items_l) do
        local num = tostring((elem.start or 1) + n - 1) .. "."
        renderer.draw_text(style.font, num, x + pad.x / 2, ly, style.text)
        local tx = x + indent
        for _, l in ipairs(lines) do
          draw_rich_line(self, l, tx, ly)
          ly = ly + l.height
        end
      end

    elseif elem.type == "table" then
      local font, bfont = md_fonts.normal, md_fonts.bold
      local pad_c = pad.x / 2
      local draw_w = blk.total_w or avail_w
      local row_h = style.code_font:get_height() + pad.y
      local ry = y
      renderer.draw_rect(x, ry, draw_w, row_h, table_head_bg_color())
      local cx = x
      for ci, hcell in ipairs(elem.headers) do
        local colw = blk.col_w[ci] or 0
        local txt = truncate_to_width(bfont, hcell, colw - pad_c * 2)
        common.draw_text(bfont, style.text, txt, "left", cx + pad_c, ry, colw - pad_c * 2, row_h)
        cx = cx + colw
      end
      ry = ry + row_h
      renderer.draw_rect(x, ry, draw_w, common.round(1 * SCALE), rule_color())
      for ri, row in ipairs(elem.rows) do
        if ri % 2 == 0 then
          renderer.draw_rect(x, ry, draw_w, row_h, table_zebra_bg_color())
        end
        cx = x
        for ci, cell in ipairs(row) do
          local colw = blk.col_w[ci] or 0
          local al = elem.aligns[ci] or "left"
          local txt = truncate_to_width(font, cell, colw - pad_c * 2)
          local tw = font:get_width(txt)
          local txx = cx + pad_c
          if al == "center" then txx = cx + (colw - tw) / 2
          elseif al == "right" then txx = cx + colw - pad_c - tw end
          renderer.draw_text(font, txt, txx, ry + (row_h - font:get_height()) / 2, style.text)
          cx = cx + colw
        end
        ry = ry + row_h
      end
      renderer.draw_rect(x, ry, draw_w, common.round(1 * SCALE), rule_color())

    elseif elem.type == "image" then
      local img = self.image_cache[elem.path]
      if img and blk.draw_w and blk.draw_w > 0 then
        local ix = x + (avail_w - blk.draw_w) / 2
        renderer.draw_image(img, ix, y, blk.draw_w, blk.draw_h)
        self._image_hits[#self._image_hits + 1] = { idx = blk.idx, x = ix, y = y, w = blk.draw_w, h = blk.draw_h }
        if elem.alt ~= "" then
          common.draw_text(style.font, style.dim, elem.alt, "center", x, y + blk.draw_h, avail_w, style.font:get_height())
        end
      else
        local ph = style.font:get_height() + pad.y
        renderer.draw_rect(x, y, avail_w, ph, code_bg_color())
        local label = "[IMG] " .. (elem.alt ~= "" and elem.alt or elem.path)
        renderer.draw_text(style.code_font, label, x + pad.x, y + pad.y / 2, syntax_col("string", style.text))
      end
    end
    ::next_block::
  end

  self:draw_scrollbar()
  self:draw_toggle_button()
end

-- ============================================================
-- Preview open / close (in-place view swap, no extra tab)
-- ============================================================
local preview_view = nil
local preview_doc_ref = nil
local preview_node = nil
local preview_docview = nil

function close_preview()
  if preview_view and preview_node then
    local idx
    for i, v in ipairs(preview_node.views) do
      if v == preview_view then idx = i break end
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
  if not doc or not doc.filename or not (doc.filename:match("%.md$") or doc.filename:match("%.markdown$")) then
    core.log("Not a markdown file")
    return
  end
  if preview_view and preview_doc_ref == doc then return end
  close_preview()
  preview_view = MarkdownPreviewView(doc)
  preview_doc_ref = doc
  preview_docview = av
  local node = core.root_view:get_active_node()
  preview_node = node
  for i, v in ipairs(node.views) do
    if v == av then node.views[i] = preview_view break end
  end
  node:set_active_view(preview_view)
end

-- ============================================================
-- Hooks
-- ============================================================
local orig_doc_on_text_change = Doc.on_text_change
function Doc:on_text_change(type)
  orig_doc_on_text_change(self, type)
  if preview_view and preview_doc_ref == self then
    preview_view._needs_refresh = true
  end
end

local orig_docview_try_close = DocView.try_close
function DocView:try_close(...)
  if preview_view and preview_doc_ref == self.doc then close_preview() end
  orig_docview_try_close(self, ...)
end

-- ============================================================
-- Top-right "预览" button on the DocView (edit mode)
-- ============================================================
local function is_markdown_docview(dv)
  local doc = dv.doc
  if not doc then return false end
  if doc.syntax and doc.syntax.name == "Markdown" then return true end
  local fn = doc.filename
  if fn and (fn:match("%.md$") or fn:match("%.markdown$")) then return true end
  return false
end

local function dv_button_rect(dv)
  local label = config.plugins.markdown_preview.button_label_preview
  local font = style.font
  local w = font:get_width(label) + style.padding.x * 2
  local h = font:get_height() + style.padding.y
  local sb = style.expanded_scrollbar_size or style.scrollbar_size or 0
  local x = dv.position.x + dv.size.x - w - style.padding.x - sb
  local y = dv.position.y + style.padding.y
  return x, y, w, h
end

local function dv_button_hit(dv, x, y)
  local bx, by, bw, bh = dv_button_rect(dv)
  return x >= bx and x <= bx + bw and y >= by and y <= by + bh
end

local orig_dv_draw = DocView.draw
function DocView:draw(...)
  orig_dv_draw(self, ...)
  if not is_markdown_docview(self) then return end
  local label = config.plugins.markdown_preview.button_label_preview
  local font = style.font
  local x, y, w, h = dv_button_rect(self)
  local border = common.round(1 * SCALE)
  local bg, fg
  if self.md_preview_btn_hover then
    bg, fg = style.accent, style.background
  else
    bg = is_dark() and { 255, 255, 255, 22 } or { 0, 0, 0, 18 }
    fg = style.text
  end
  renderer.draw_rect(x - border, y - border, w + border * 2, h + border * 2, style.divider)
  renderer.draw_rect(x, y, w, h, bg)
  common.draw_text(font, fg, label, "center", x, y, w, h)
end

local orig_dv_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  orig_dv_mouse_moved(self, x, y, ...)
  local hov = is_markdown_docview(self) and dv_button_hit(self, x, y)
  if hov ~= self.md_preview_btn_hover then
    self.md_preview_btn_hover = hov
    core.redraw = true
  end
  if hov then self.cursor = "arrow" end
end

local orig_dv_mouse_left = DocView.on_mouse_left
function DocView:on_mouse_left(...)
  orig_dv_mouse_left(self, ...)
  self.md_preview_btn_hover = false
end

local orig_dv_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if is_markdown_docview(self) and button == "left" and dv_button_hit(self, x, y) then
    command.perform("markdown-preview:toggle")
    return true
  end
  return orig_dv_mouse_pressed(self, button, x, y, clicks)
end

-- ============================================================
-- Commands & keymap
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
keymap.add { ["ctrl+shift+m"] = "markdown-preview:toggle" }

-- Esc exits the preview (only active while the preview view has focus)
command.add(function()
  return preview_view ~= nil and core.active_view == preview_view
end, {
  ["markdown-preview:exit"] = function()
    close_preview()
    core.log("Markdown preview: off")
  end,
})
keymap.add { ["escape"] = "markdown-preview:exit" }
