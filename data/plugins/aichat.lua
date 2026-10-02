-- mod-version:4
-- aichat: AI chat panel for lite-xl (pi-bridge SSE agent, pluggable backend).
-- A docked chat panel with a pluggable backend:
--   "pibridge" (slate pi-bridge SSE agent, default) |
--   "mock" (simulated streaming, no server needed)  |
--   "openai" (OpenAI-compatible /v1/chat/completions over curl).
-- Toggle with Ctrl+Shift+A.  Enter: send / stop.  Shift+Enter: newline.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local View = require "core.view"
local RootView = require "core.rootview"
local style = require "core.style"
local process = require "core.process"
local ime = require "core.ime"

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------
config.plugins.aichat = common.merge({
  system_prompt = "You are a helpful assistant. Answer concisely and clearly.",
  panel_size = 380 * SCALE,
  -- collapsed by default: the panel is one click away on the floating button
  visible = false,
  -- backend: "pibridge" | "mock" | "openai"
  backend = "pibridge",
  -- pi-bridge endpoint (slate piweb-bridge)
  api_base = "http://127.0.0.1:8643",
  -- curl binary path (use full path because launchd-launched apps have no PATH)
  curl_path = "/usr/bin/curl",
  -- openai backend settings (only used when backend == "openai")
  api_key = os.getenv("OPENAI_API_KEY") or "",
  endpoint = "https://api.openai.com/v1",
  model = "gpt-4o-mini",
}, config.plugins.aichat)


local json = require "core.json"
local util = require "core.util"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"
-- Local aliases for the shared helpers in core.util; keeps the many call sites
-- unchanged while removing the per-plugin copies.
local blend, with_alpha = util.blend, util.with_alpha
local shell_escape, open_url = util.shell_escape, util.open_url

-------------------------------------------------------------------------------
-- Word-wrap helper: wraps text into lines fitting max_width using font metrics.
-------------------------------------------------------------------------------

-- UTF-8 aware cursor movement helpers (avoid splitting a multi-byte char).
local function utf8_prev(s, pos)
  local p = pos - 1
  while p > 1 and s:byte(p) >= 0x80 and s:byte(p) < 0xC0 do p = p - 1 end
  return p
end
local function utf8_next(s, pos)
  local p = pos + 1
  while p <= #s and s:byte(p) >= 0x80 and s:byte(p) < 0xC0 do p = p + 1 end
  return p
end

-- Break a run that is wider than max_width (a long path, URL or unbreakable
-- token) at character boundaries, pushing every chunk but the last into
-- `lines` and returning the remainder.  Without this such a token simply
-- overflowed and got cut off by the panel's clip rect.
local function break_long_run(run, font, max_width, lines)
  local chunk, chunk_w = "", 0
  local p = 1
  while p <= #run do
    local nxt = utf8_next(run, p)
    local ch = run:sub(p, nxt - 1)
    local w = font:get_width(ch)
    if chunk_w > 0 and chunk_w + w > max_width then
      lines[#lines + 1] = chunk
      chunk, chunk_w = "", 0
    end
    chunk = chunk .. ch
    chunk_w = chunk_w + w
    p = nxt
  end
  return chunk
end

local function wrap_text(text, font, max_width)
  local lines = {}
  local n = #text
  local i = 1
  while i <= n do
    local j = i
    while j <= n and text:byte(j) ~= 10 do j = j + 1 end -- find newline
    local paragraph = text:sub(i, j - 1)
    if #paragraph == 0 then
      lines[#lines + 1] = ""
    else
      local line = ""
      local p = 1
      local plen = #paragraph
      while p <= plen do
        local sp, ep = paragraph:find("%S+%s*", p)
        if not sp then break end
        local word = paragraph:sub(sp, ep)
        if font:get_width(line .. word) > max_width and #line > 0 then
          lines[#lines + 1] = line
          line = word:gsub("^%s+", "")
        else
          line = line .. word
        end
        -- the word may itself exceed the width (first word of the line, or an
        -- unbreakable token): hard-break it rather than letting it overflow
        if font:get_width(line) > max_width then
          line = break_long_run(line, font, max_width, lines)
        end
        p = ep + 1
      end
      if #line > 0 then lines[#lines + 1] = line end
    end
    i = j + 1 -- skip the newline
  end
  if #lines == 0 then lines = {""} end
  return lines
end

-- Wrap STYLED segments to max_width.  Inline markup has to be parsed before the
-- line is broken: wrapping first split "[the docs](url)", `code` or **bold**
-- across two lines, and the markers then rendered as literal text.
-- Returns a list of lines, each a list of { text = ..., seg = <style table> }.
-- GFM table helpers (a row of | cells, a ---|:--: delimiter row, body rows).
local function split_table_row(row)
  local cells = {}
  local r = row:gsub("^%s*|", ""):gsub("|%s*$", "")
  for cell in (r .. "|"):gmatch("([^|]*)|") do
    cells[#cells + 1] = cell:gsub("^%s+", ""):gsub("%s+$", "")
  end
  return cells
end

-- `|---|:--:|` style delimiter row (an <hr> has no pipe, so it is excluded)
local function is_table_sep(line)
  return line ~= nil and line:find("|", 1, true) ~= nil
    and line:match("^%s*|?[%s:%-|]*%-[%s:%-|]*$") ~= nil
end

local function parse_table_aligns(sep_row)
  local aligns = {}
  for _, c in ipairs(split_table_row(sep_row)) do
    local l, r = c:sub(1, 1) == ":", c:sub(-1) == ":"
    aligns[#aligns + 1] = (l and r) and "center" or (r and "right" or "left")
  end
  return aligns
end

-- Closing punctuation must not start a line (it sticks to the previous char).
local NO_BREAK_BEFORE = {}
for _, ch in ipairs({ "，", "。", "、", "；", "：", "！", "？", "）", "》", "」",
  "』", "】", "”", "’", "…", "·" }) do NO_BREAK_BEFORE[ch] = true end

-- Split a non-space run into wrap units: ASCII/Latin runs stay together (a
-- word), every wide char (CJK, fullwidth punctuation: UTF-8 lead >= 0xE0) is
-- a unit of its own.  Chinese has no spaces, so without this a whole sentence
-- was one unbreakable token that jumped to the next line as a block.
local function split_wrap_units(piece)
  local units, run = {}, ""
  local p = 1
  while p <= #piece do
    local nxt = utf8_next(piece, p)
    local ch = piece:sub(p, nxt - 1)
    if piece:byte(p) >= 0xE0 then
      if #run > 0 then units[#units + 1] = { text = run }; run = "" end
      units[#units + 1] = { text = ch, wide = true }
    else
      run = run .. ch
    end
    p = nxt
  end
  if #run > 0 then units[#units + 1] = { text = run } end
  return units
end

local function wrap_segments(segs, max_width)
  -- tokenise on whitespace (and between wide chars), keeping trailing spaces
  -- attached to their token; a token continues into the next segment when it
  -- did not end on a space
  local tokens = {}
  local function add_piece(tok, text, seg)
    tok.pieces[#tok.pieces + 1] = { text = text, seg = seg }
    tok.w = tok.w + seg.font:get_width(text)
  end
  for _, seg in ipairs(segs) do
    local text = seg.text
    -- whitespace at the start of a segment (" world" after **bold**) belongs
    -- to the previous token; it used to be skipped, gluing the words together
    local lead = text:match("^%s+")
    if lead and tokens[#tokens] then
      add_piece(tokens[#tokens], lead, seg)
      tokens[#tokens].open = false
    end
    local p = 1
    while p <= #text do
      local sp, ep = text:find("%S+%s*", p)
      if not sp then break end
      for _, u in ipairs(split_wrap_units(text:sub(sp, ep))) do
        local last = tokens[#tokens]
        local join
        if not last then
          join = false
        elseif u.text:match("^%s+$") or NO_BREAK_BEFORE[u.text] then
          join = true
        else
          join = last.open and not (last.wide or u.wide)
        end
        if not join then
          last = { pieces = {}, w = 0 }
          tokens[#tokens + 1] = last
        end
        add_piece(last, u.text, seg)
        last.open = not u.text:match("%s$")
        last.wide = u.wide
      end
      p = ep + 1
    end
  end

  local lines, cur, cur_w = {}, {}, 0
  local function flush()
    lines[#lines + 1] = cur
    cur, cur_w = {}, 0
  end
  -- append a run, merging it into the previous piece when the style matches
  local function put(text, seg)
    local last = cur[#cur]
    if last and last.seg == seg then
      last.text = last.text .. text
    else
      cur[#cur + 1] = { text = text, seg = seg }
    end
    cur_w = cur_w + seg.font:get_width(text)
  end

  for _, tok in ipairs(tokens) do
    if cur_w > 0 and cur_w + tok.w > max_width then flush() end
    if tok.w <= max_width then
      for _, piece in ipairs(tok.pieces) do put(piece.text, piece.seg) end
    else
      -- wider than a whole line: break it at character boundaries
      for _, piece in ipairs(tok.pieces) do
        local text = piece.text
        local p = 1
        while p <= #text do
          local nxt = utf8_next(text, p)
          local ch = text:sub(p, nxt - 1)
          if cur_w > 0 and cur_w + piece.seg.font:get_width(ch) > max_width then
            flush()
          end
          put(ch, piece.seg)
          p = nxt
        end
      end
    end
  end
  if #cur > 0 then flush() end
  if #lines == 0 then lines = { {} } end
  return lines
end

-- Cached custom colors (style.* colors are read live in draw so theme switches work).
local COLOR_ERROR = { common.color("#ff5555") }
local COLOR_OK    = { common.color("#5fd75f") }

-- Advance width of a segment.  Segments may carry an explicit advance instead
-- of deriving it from the font: table cells use it so columns line up exactly
-- even when glyph advances are not uniform (CJK in a monospace font is not a
-- whole multiple of the space width, so space padding always drifted).
local function seg_advance(seg)
  if seg.pad_to then return seg.pad_to end
  return seg.font:get_width(seg.text) + (seg.pad or 0) * 2
end

-- Left edge of a segment's text (skipping chip padding and cell alignment).
local function seg_text_x(seg, sx)
  return sx + (seg.off or 0) + (seg.pad or 0)
end

-- Vertical bookkeeping shared by layout, hit-testing and drawing.  A render
-- line has a text height `h`, plus two kinds of extra space:
--   sp        space above the line, outside any background (paragraph gaps,
--             heading breathing room, the gap before a code block)
--   mt / mb   padding above/below the text that belongs to the line itself
--             (top/bottom padding inside a fenced code block)
-- Keeping them separate is what lets the code-block background cover its own
-- padding without swallowing the gap that precedes the block.
local function rline_outer(rl)
  return (rl.sp or 0) + (rl.mt or 0) + rl.h + (rl.mb or 0)
end

local function rline_text_top(rl, y)
  return y + (rl.sp or 0) + (rl.mt or 0)
end

-- Markdown fonts (synthetic bold/italic from the single regular TTF).
-- Rebuild the font groups at the text font's size so emoji (which the user may
-- have loaded at a larger size e.g. 32*SCALE for the editor) is scaled down to
-- fit the compact chat line height.  ren_font_group_get_height only returns
-- the FIRST font's height (15px), so a 32px emoji would overflow vertically
-- and overlap the next line.  :copy(size) re-sizes ALL fonts in the group.
local ai_font        = style.font:copy(style.font:get_size())
local ai_code_font   = style.code_font:copy(style.code_font:get_size())
local md_bold_font   = ai_font:copy(ai_font:get_size(), { bold = true })
local md_italic_font = ai_font:copy(ai_font:get_size(), { italic = true })
local md_code_font   = ai_code_font
-- Heading type scale.  Without this, # / ## / ### rendered at the same size and
-- were told apart only by color, which read as three identical paragraphs.
local md_h1_font     = ai_font:copy(math.floor(ai_font:get_size() * 1.34), { bold = true })
local md_h2_font     = ai_font:copy(math.floor(ai_font:get_size() * 1.16), { bold = true })
local md_h3_font     = ai_font:copy(ai_font:get_size(), { bold = true })

-- Horizontal padding around inline `code` chips.
local CODE_CHIP_PAD = math.floor(3 * SCALE)

-------------------------------------------------------------------------------
-- Markdown rendering for assistant messages
-- Composes styled segments from inline markers (**bold**, *italic*, `code`,
-- ~~strike~~) and block structures (headers, lists, quotes, code fences).
-------------------------------------------------------------------------------

-- Parse inline markdown into styled segments.  Single-pass, no nesting.

-- [label](url) at position i, or nil.
local function parse_link_at(text, i)
  if text:byte(i) ~= 91 then return nil end -- '['
  local close = text:find("]", i + 1, true)
  if not close or text:byte(close + 1) ~= 40 then return nil end -- '('
  -- scan to the matching ')': URLs may contain parentheses (e.g. wikipedia)
  local depth, p = 1, close + 2
  while p <= #text do
    local ch = text:sub(p, p)
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then break end
    end
    p = p + 1
  end
  if depth ~= 0 then return nil end
  local label = text:sub(i + 1, close - 1)
  local url = text:sub(close + 2, p - 1)
  if url == "" or url:find("[%s%c]") then return nil end
  return { label = (label ~= "") and label or url, url = url }, p + 1
end

local function is_word_byte(b)
  return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- Closing "_" / "__" that is not followed by a word char, or nil.  With the
-- CommonMark intraword rule this keeps snake_case identifiers literal
-- ("draw_round_rect" rendered as draw*round*rect before).
local function find_closing_underscore(text, from, delim)
  local p = from
  while true do
    local s = text:find(delim, p, true)
    if not s then return nil end
    if not is_word_byte(text:byte(s + #delim)) then return s end
    p = s + 1
  end
end

-- ASCII URL characters (RFC 3986) minus parentheses: stops at CJK text and
-- fullwidth punctuation, which used to be swallowed into the link.
local URL_CHARS = "^[%w%-%._~:/%?#@!%$&'%*%+,;=%%]+"

local function parse_md_inline(text, base_color, base_font)
  local segments = {}
  local i, n = 1, #text
  local pending = ""
  local function flush()
    if #pending > 0 then
      segments[#segments + 1] = { text = pending, font = base_font, color = base_color }
      pending = ""
    end
  end
  while i <= n do
    local c = text:byte(i)
    local link, link_next = parse_link_at(text, i)
    -- [label](url)
    if link then
      flush()
      segments[#segments + 1] = {
        text = link.label, font = base_font,
        color = style.accent or base_color, link = link.url, underline = true,
      }
      i = link_next
    -- bare URL
    elseif text:sub(i, i + 7):match("^https?://") or text:sub(i, i + 3) == "www." then
      local url = (text:match(URL_CHARS, i) or text:sub(i, i)):gsub("[%.,;:!%?'%*]+$", "")
      flush()
      segments[#segments + 1] = {
        text = url, font = base_font,
        color = style.accent or base_color,
        link = url:match("^www%.") and ("https://" .. url) or url,
        underline = true,
      }
      i = i + #url
    -- **bold** or __bold__
    elseif (c == 42 and text:byte(i + 1) == 42)
        or (c == 95 and text:byte(i + 1) == 95 and not is_word_byte(text:byte(i - 1))) then
      local delim = text:sub(i, i + 1)
      local close
      if c == 95 then
        close = find_closing_underscore(text, i + 2, delim)
      else
        close = text:find(delim, i + 2, true)
      end
      if close then
        flush()
        segments[#segments + 1] = {
          text = text:sub(i + 2, close - 1),
          font = md_bold_font, color = base_color,
        }
        i = close + 2
      else
        pending = pending .. text:sub(i, i); i = i + 1
      end
    -- ~~strike~~
    elseif c == 126 and text:byte(i + 1) == 126 then
      local close = text:find("~~", i + 2, true)
      if close then
        flush()
        segments[#segments + 1] = {
          text = text:sub(i + 2, close - 1),
          font = base_font, color = style.dim or base_color,
        }
        i = close + 2
      else
        pending = pending .. "~"; i = i + 1
      end
    -- `code` — inline chip: padded, tinted background, monospace
    elseif c == 96 then
      local close = text:find("`", i + 1, true)
      if close then
        flush()
        segments[#segments + 1] = {
          text = text:sub(i + 1, close - 1),
          font = md_code_font, color = style.accent or base_color,
          pad = CODE_CHIP_PAD, bg = with_alpha(style.text, 30),
        }
        i = close + 1
      else
        pending = pending .. "`"; i = i + 1
      end
    -- *italic*
    elseif c == 42 then
      local close = text:find("*", i + 1, true)
      if close and close > i + 1 then
        flush()
        segments[#segments + 1] = {
          text = text:sub(i + 1, close - 1),
          font = md_italic_font, color = base_color,
        }
        i = close + 1
      else
        pending = pending .. "*"; i = i + 1
      end
    -- _italic_
    elseif c == 95 and not is_word_byte(text:byte(i - 1)) then
      local close = find_closing_underscore(text, i + 1, "_")
      if close and close > i + 1 then
        flush()
        segments[#segments + 1] = {
          text = text:sub(i + 1, close - 1),
          font = md_italic_font, color = base_color,
        }
        i = close + 1
      else
        pending = pending .. "_"; i = i + 1
      end
    else
      pending = pending .. text:sub(i, i); i = i + 1
    end
  end
  flush()
  if #segments == 0 then
    segments[1] = { text = "", font = base_font, color = base_color }
  end
  return segments
end

-------------------------------------------------------------------------------
-- Syntax highlighting for fenced code blocks.
-- Reuses the editor's own tokenizer and the language_* plugins, so code in the
-- chat is coloured exactly like code in the editor (style.syntax[...]).
-------------------------------------------------------------------------------

-- Fence tags that do not match a file extension of a bundled syntax.
local LANG_ALIAS = {
  javascript = "js", typescript = "js", ts = "js", jsx = "js", tsx = "js",
  node = "js", jsonc = "json",
  python = "py", python3 = "py", py3 = "py",
  bash = "sh", shell = "sh", zsh = "sh", console = "sh", shellscript = "sh",
  ["c++"] = "cpp", cxx = "cpp", cc = "cpp", hpp = "cpp",
  markdown = "md", golang = "go", htm = "html", svg = "xml",
  conf = "ini", cfg = "ini",
}

-- Only positive lookups are cached: a language plugin loaded later (e.g. from
-- the user module) must still be picked up.
local code_syntax_cache = {}

---Syntax for a fence info string ("lua", "Python", "sql title=x", ...), or nil.
local function code_syntax(lang)
  if not lang then return nil end
  local key = lang:lower():match("^[%w_+#%.%-]+")
  if not key then return nil end
  if code_syntax_cache[key] then return code_syntax_cache[key] end
  local syn = syntax.get("code." .. (LANG_ALIAS[key] or key))
  if syn == syntax.plain_text_syntax then
    syn = nil
    for _, s in ipairs(syntax.items) do
      if s.name and s.name:lower() == key then syn = s; break end
    end
  end
  if syn then code_syntax_cache[key] = syn end
  return syn
end

---Tokenize one code line into coloured runs { {text=, color=}, ... }.
---`state` carries multi-line constructs (block comments, long strings) over
---to the next line; returns the runs and the new state.
local function highlight_code_line(syn, line, state)
  local normal = style.syntax["normal"] or style.text
  if not syn or line == "" then
    return { { text = line, color = normal } }, state
  end
  -- the language patterns expect the trailing newline an editor line has
  local ok, toks, new_state = pcall(tokenizer.tokenize, syn, line .. "\n", state)
  if not ok or type(toks) ~= "table" then
    return { { text = line, color = normal } }, state
  end
  local runs = {}
  for _, ttype, ttext in tokenizer.each_token(toks) do
    ttext = ttext:gsub("\n", "")
    if #ttext > 0 then
      local color = style.syntax[ttype] or normal
      local last = runs[#runs]
      if last and last.color == color then
        last.text = last.text .. ttext
      else
        runs[#runs + 1] = { text = ttext, color = color }
      end
    end
  end
  if #runs == 0 then runs[1] = { text = "", color = normal } end
  return runs, new_state
end

---Hard-wrap coloured runs at character boundaries (code keeps its
---indentation, so the whitespace-based wrap used for prose does not fit).
local function wrap_code_runs(runs, font, max_w)
  local total = 0
  for _, r in ipairs(runs) do total = total + font:get_width(r.text) end
  if total <= max_w then return { runs } end
  local lines, cur, cur_w = {}, {}, 0
  for _, r in ipairs(runs) do
    local p = 1
    while p <= #r.text do
      local nxt = utf8_next(r.text, p)
      local ch = r.text:sub(p, nxt - 1)
      local w = font:get_width(ch)
      if cur_w > 0 and cur_w + w > max_w then
        lines[#lines + 1] = cur
        cur, cur_w = {}, 0
      end
      local last = cur[#cur]
      if last and last.color == r.color then
        last.text = last.text .. ch
      else
        cur[#cur + 1] = { text = ch, color = r.color }
      end
      cur_w = cur_w + w
      p = nxt
    end
  end
  if #cur > 0 then lines[#lines + 1] = cur end
  return lines
end

-- Layout markdown text into render lines.  Each render line is:
--   { segments, h, sp, mt, mb, is_code_block, is_code_bar, is_header,
--     is_table_rule, table_w, indent, bg, is_quote }
-- See rline_outer()/rline_text_top() for how the vertical fields add up.
local function layout_md(text, max_width)
  local rlines = {}
  local pad_x = style.padding.x
  local lh = math.floor(ai_font:get_height() * 1.32)
  local code_lh = math.floor(md_code_font:get_height() * 1.3)
  -- Code blocks get a solid background a step darker than the editor (a step
  -- lighter on light themes): syntax colours are tuned for style.background,
  -- and a translucent light wash washed them out.  The header bar is a shade
  -- lighter than the body so language tag + copy button read as a title bar.
  local black = { 0, 0, 0, 255 }
  local code_bg = util.is_dark() and blend(style.background, black, 0.28)
    or blend(style.background, black, 0.05)
  local code_bar_bg = blend(code_bg, style.text, 0.1)
  local table_head_bg = with_alpha(style.text, 34)
  local quote_color = blend(style.text, style.dim or style.text, 0.45)
  -- Whitespace scale: paragraphs and blocks breathe, lines inside one stay tight.
  local para_gap = math.ceil(lh * 0.5)
  local head_gap = math.ceil(lh * 0.6)
  local code_indent = math.floor(pad_x * 1.5)
  local code_pad_y = math.ceil(lh * 0.34)

  -- Split into raw lines
  local raw_lines = {}
  local i, n = 1, #text
  while i <= n do
    local j = i
    while j <= n and text:byte(j) ~= 10 do j = j + 1 end
    raw_lines[#raw_lines + 1] = text:sub(i, j - 1)
    i = j + 1
  end

  -- Space asked for by a blank line / before a block, consumed by the next
  -- emitted render line so trailing blanks never add height.
  local pending_gap = 0

  local function add_rline(segs, h, opts)
    opts = opts or {}
    rlines[#rlines + 1] = {
      segments = segs, h = h,
      sp = math.max(opts.sp or 0, pending_gap),
      mt = opts.mt or 0,
      mb = opts.mb or 0,
      is_code_block = opts.is_code_block or false,
      is_code_bar = opts.is_code_bar or false,
      is_header = opts.is_header or false,
      is_table_rule = opts.is_table_rule or false,
      table_w = opts.table_w,
      indent = opts.indent or 0,
      bg = opts.bg, is_quote = opts.is_quote or false,
    }
    pending_gap = 0
  end

  -- Parse inline markup first, then wrap the styled segments (see
  -- wrap_segments) so markers are never split by the line break.
  local function add_md_lines(src, font, color, indent, opts)
    opts = opts or {}
    local segs = parse_md_inline(src, color, font)
    if opts.force_font then
      for _, s in ipairs(segs) do s.font = opts.force_font end
    end
    if opts.color then
      for _, s in ipairs(segs) do s.color = opts.color end
    end
    local cont_indent = opts.cont_indent or indent
    local avail = max_width - math.max(indent, cont_indent) - pad_x
    local first = true
    for _, pieces in ipairs(wrap_segments(segs, avail)) do
      local rsegs = {}
      if first and opts.bullet then
        rsegs[1] = {
          text = opts.bullet, font = ai_font,
          color = style.accent or style.text,
        }
      end
      for _, pc in ipairs(pieces) do
        local o = {}
        for k, v in pairs(pc.seg) do o[k] = v end
        o.text = pc.text
        rsegs[#rsegs + 1] = o
      end
      add_rline(rsegs, opts.h or lh, {
        indent = first and indent or cont_indent,
        sp = first and (opts.sp or 0) or 0,
        is_header = opts.is_header,
        is_quote = opts.is_quote,
      })
      first = false
    end
  end

  -- GFM table.  Column widths come from the widest cell and are shrunk
  -- proportionally (then trimmed) to fit the panel.  Each cell carries an
  -- explicit advance (pad_to) plus an alignment offset (off) instead of being
  -- padded with spaces: glyph advances are not uniform — CJK in a monospace
  -- font is not a whole multiple of the space width — so space padding always
  -- drifted and the columns never lined up.
  local function emit_table(header, aligns, rows)
    local tfont = md_code_font
    local unit = tfont:get_width(" ")
    local pad_c = 1                -- cell padding, in space widths
    local sep_text = " │ "         -- between columns
    local ncols = #header
    local row_lh = math.floor(tfont:get_height() * 1.35)

    local min_col = math.max(24 * SCALE, pad_c * 4 * unit)
    local sep_w = tfont:get_width(sep_text)
    local avail = max_width - pad_x

    -- natural column width in pixels (content + padding)
    local col_w = {}
    for ci = 1, ncols do
      local w = tfont:get_width(header[ci] or "")
      for _, row in ipairs(rows) do
        w = math.max(w, tfont:get_width(row[ci] or ""))
      end
      col_w[ci] = w + pad_c * 2 * unit
    end

    local fixed = (ncols - 1) * sep_w
    local function total_w()
      local t = fixed
      for ci = 1, ncols do t = t + col_w[ci] end
      return t
    end
    if total_w() > avail then
      local scale = math.max(0, avail - fixed) / math.max(1, total_w() - fixed)
      for ci = 1, ncols do
        col_w[ci] = math.max(min_col, math.floor(col_w[ci] * scale))
      end
      -- proportional scaling can overshoot: shave the widest column until it fits
      while total_w() > avail do
        local widest, wi = min_col, 1
        for ci = 1, ncols do
          if col_w[ci] > widest then widest, wi = col_w[ci], ci end
        end
        if widest <= min_col then break end
        col_w[wi] = col_w[wi] - 1
      end
    end
    local table_w = total_w()

    local function cell_text(cells, ci)
      local w = col_w[ci]
      local text = util.truncate_to_width(tfont, cells[ci] or "", w - pad_c * 2 * unit)
      local slack = math.max(0, w - tfont:get_width(text))
      local off = pad_c * unit
      local align = aligns[ci] or "left"
      if align == "right" then
        off = slack - pad_c * unit
      elseif align == "center" then
        off = math.floor(slack / 2)
      end
      return text, math.max(0, off), w
    end

    local function row_segments(cells)
      local segs = {}
      for ci = 1, ncols do
        local text, off, col_w_ci = cell_text(cells, ci)
        segs[#segs + 1] = {
          text = text, font = tfont, color = style.text,
          off = off, pad_to = col_w_ci,
        }
        if ci < ncols then
          segs[#segs + 1] = { text = sep_text, font = tfont, color = style.dim }
        end
      end
      return segs
    end

    add_rline(row_segments(header), row_lh, { bg = table_head_bg, table_w = table_w })
    add_rline({}, math.max(1, math.floor(1 * SCALE)), {
      is_table_rule = true, table_w = table_w,
      mb = math.floor(row_lh * 0.45),
    })
    for _, r in ipairs(rows) do
      add_rline(row_segments(r), row_lh, { table_w = table_w })
    end
    pending_gap = math.max(pending_gap, para_gap)
  end

  local in_code_block = false
  local code_lang
  local code_bar_idx
  local code_lines
  local last_code_idx
  local code_syn     -- syntax of the open block (nil: no highlighting)
  local code_state   -- tokenizer state carried from line to line

  -- Emit one line of a fenced block.  The bar is emitted when the block opens so
  -- a copy button is available even without a language tag; it is dropped again
  -- if the block turns out to be empty (see the closing fence).
  local function emit_code_line(code_line)
    local avail_w = max_width - code_indent - pad_x
    -- tabs are expanded for display only; the copy button keeps the original
    local shown = code_line:gsub("\t", "    ")
    local runs
    runs, code_state = highlight_code_line(code_syn, shown, code_state)
    for _, wruns in ipairs(wrap_code_runs(runs, md_code_font, avail_w)) do
      local segs = {}
      for _, r in ipairs(wruns) do
        segs[#segs + 1] = { text = r.text, font = md_code_font, color = r.color }
      end
      if #segs == 0 then
        segs[1] = { text = "", font = md_code_font, color = style.text }
      end
      add_rline(segs, code_lh,
        { is_code_block = true, bg = code_bg, indent = code_indent,
          mt = (last_code_idx == nil) and code_pad_y or 0 })
      last_code_idx = #rlines
    end
    code_lines[#code_lines + 1] = code_line
  end

  -- rows already consumed by a table above (delimiter row + body rows)
  local table_row_used = {}

  for li, line in ipairs(raw_lines) do
    local info = line:match("^%s*```%s*(.-)%s*$")
    if table_row_used[li] then
      -- already emitted as part of the table above
    elseif info then
      if in_code_block then
        if #code_lines == 0 then
          -- empty block: drop the bar again, nothing to show or copy
          if code_bar_idx then table.remove(rlines, code_bar_idx) end
        else
          -- bottom padding belongs to the last line of the block, so the tinted
          -- background covers it instead of leaving the text flush with the edge
          if last_code_idx then rlines[last_code_idx].mb = code_pad_y end
          if code_bar_idx then
            rlines[code_bar_idx].code_text = table.concat(code_lines, "\n")
          end
        end
        in_code_block = false
        code_lang, code_bar_idx, code_lines, last_code_idx = nil, nil, nil, nil
        code_syn, code_state = nil, nil
        pending_gap = math.max(pending_gap, para_gap)  -- gap after the block
      else
        in_code_block = true
        code_lang = (info ~= "") and info or nil
        code_lines = {}
        last_code_idx = nil
        code_syn, code_state = code_syntax(code_lang), nil
        -- the gap belongs in front of the block, not between bar and code
        pending_gap = math.max(pending_gap, para_gap)
        add_rline({ { text = code_lang or " ", font = ai_font, color = style.dim } },
          math.floor(lh * 0.9),
          { is_code_block = true, is_code_bar = true, bg = code_bar_bg,
            indent = code_indent })
        rlines[#rlines].code_lang = code_lang
        code_bar_idx = #rlines
      end
    elseif in_code_block then
      emit_code_line(line)
    elseif line:match("^%s*$") then
      pending_gap = math.max(pending_gap, para_gap)
    -- GFM table: a pipe row followed by a delimiter row
    elseif line:find("|", 1, true) and is_table_sep(raw_lines[li + 1]) then
      local rows = {}
      local r = li + 2
      while r <= #raw_lines and raw_lines[r]:find("|", 1, true)
        and not raw_lines[r]:match("^%s*$") do
        rows[#rows + 1] = split_table_row(raw_lines[r])
        table_row_used[r] = true
        r = r + 1
      end
      table_row_used[li + 1] = true -- the delimiter row
      emit_table(split_table_row(line), parse_table_aligns(raw_lines[li + 1]), rows)
    else
      -- Headers: # ## ###
      local h_marks, h_text = line:match("^(%#+)%s+(.*)$")
      if h_marks and h_text and #h_marks <= 3 then
        local hfont = (#h_marks == 1 and md_h1_font)
          or (#h_marks == 2 and md_h2_font) or md_h3_font
        add_md_lines(h_text, hfont, style.accent or style.text, 0, {
          h = math.floor(hfont:get_height() * 1.22),
          is_header = true, sp = head_gap, force_font = hfont,
        })
      -- Blockquotes: >
      elseif line:match("^>%s?") then
        add_md_lines(line:gsub("^>%s?", ""), ai_font, quote_color,
          math.floor(pad_x * 1.4), {
            is_quote = true, color = quote_color,
            sp = math.ceil(lh * 0.25),
          })
      else
        -- List items: - * + or "1."
        local bullet, content = line:match("^%s*([-*+])%s+(.*)$")
        if not bullet then
          local num = line:match("^%s*(%d+)%.")
          if num then
            content = line:match("^%s*%d+%.%s+(.*)$")
            bullet = num .. "."
          end
        end
        if bullet and content then
          local bullet_str = (bullet == "-" or bullet == "*" or bullet == "+")
            and "•" or bullet
          -- Hanging indent: wrapped lines line up under the item text, not
          -- under the bullet (they used to shift left by the bullet width).
          add_md_lines(content, ai_font, style.text, pad_x, {
            bullet = bullet_str .. " ",
            cont_indent = pad_x + ai_font:get_width(bullet_str .. " "),
          })
        else
          add_md_lines(line, ai_font, style.text, 0, {})
        end
      end
    end
  end

  if #rlines == 0 then
    add_rline({ { text = "", font = ai_font, color = style.text } }, lh, {})
  end
  return rlines
end

-- Draw an animated spinner: 8 dots in a circle, brightness wave sweeping.
local function draw_spinner(cx, cy, radius, color)
  local now = system.get_time()
  local num_dots = 8
  local dot_size = math.max(2, math.floor(2.5 * SCALE))
  local rotation = (now * 4) % (math.pi * 2)
  for k = 0, num_dots - 1 do
    local angle = (k / num_dots) * math.pi * 2
    local dx = cx + math.cos(angle) * radius
    local dy = cy + math.sin(angle) * radius
    local diff = angle - rotation
    diff = (diff + math.pi) % (math.pi * 2) - math.pi
    local t = (math.cos(diff) + 1) / 2
    local alpha = math.floor(40 + t * 215)
    renderer.draw_rect(math.floor(dx - dot_size / 2), math.floor(dy - dot_size / 2),
      dot_size, dot_size, with_alpha(color, alpha))
  end
end

-- Rounded rectangle built from axis-aligned rects (the renderer has no
-- round-rect primitive): the corner rows are 1px spans inset along a circle,
-- so the corners are actually round instead of chamfered.  No two rects
-- overlap, so translucent colours do not stack.
local function draw_round_rect(x, y, w, h, r, color)
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  if w <= 0 or h <= 0 then return end
  r = math.floor(math.min(r or 0, w / 2, h / 2))
  if r < 1 then
    renderer.draw_rect(x, y, w, h, color)
    return
  end
  renderer.draw_rect(x, y + r, w, h - r * 2, color)
  for i = 0, r - 1 do
    local dy = r - i - 0.5
    local inset = math.floor(r - math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
    renderer.draw_rect(x + inset, y + i, w - inset * 2, 1, color)
    renderer.draw_rect(x + inset, y + h - 1 - i, w - inset * 2, 1, color)
  end
end

-- Rounded box with a 1px border: border colour underneath, fill inset by 1px.
local function draw_card(x, y, w, h, r, fill, border)
  draw_round_rect(x, y, w, h, r, border)
  draw_round_rect(x + 1, y + 1, w - 2, h - 2, math.max(0, r - 1), fill)
end

-- Panel palette.  Everything is derived from the theme by blending towards
-- style.text (the contrast colour), so the panel works on dark and light
-- themes alike.  style.divider is deliberately NOT used inside the panel: on
-- themes with a light sidebar it is a light grey that cut bright lines
-- through the dark panel.
local BLACK = { 0, 0, 0, 255 }
local WHITE = { 255, 255, 255, 255 }
local function ai_palette()
  local bg = blend(style.background, style.background2, 0.05)
  local text = style.text
  return {
    bg        = bg,
    header    = blend(bg, text, 0.035),
    line      = blend(bg, text, 0.12),
    card      = blend(bg, text, 0.07),
    card_line = blend(bg, text, 0.16),
    input     = util.is_dark() and blend(bg, BLACK, 0.22) or blend(bg, WHITE, 0.7),
  }
end


-------------------------------------------------------------------------------
-- AIView: the chat panel.
-- IMPORTANT: we use self.caret for the text-editing cursor position, NOT
-- self.cursor — View.cursor is the mouse cursor type ("arrow"/"ibeam"/…)
-- and rootview reads it via core.request_cursor(view.cursor).  Reusing
-- self.cursor for a numeric byte offset caused a crash:
-- "bad argument #1 to 'set_cursor' (invalid option '1')".
-------------------------------------------------------------------------------
local AIView = View:extend()

function AIView:new()
  AIView.super.new(self)
  -- self.cursor is inherited from View (= "arrow"); leave it alone.
  self.messages = {}
  self.input = ""
  self.caret = 1 -- 1-indexed byte offset into self.input
  self.streaming = false
  self.visible = config.plugins.aichat.visible
  self.target_size = config.plugins.aichat.panel_size
  self.scrollable = true
  self.content_height = 0
  self._dirty = true
  self._layout_key = nil
  self._wrapped = {}
  self._send_hover = false
  -- pi-bridge session cache: working_dir -> session_id
  self._sessions = {}
  self._stream_proc = nil
  self._aborting = false
  self._new_btn_hover = false
  -- copy button / link interaction state
  self._copy_hover = nil   -- code bar whose copy button is hovered
  self._link_hover = nil   -- URL hovered in the message area
  self._copied_rline = nil -- code bar that was just copied
  self._copied_at = nil
  -- Text selection in the message area.
  self._selecting = false   -- true while mouse drag-selecting
  self._sel_start = nil     -- {msg_idx, rline_idx, seg_idx, char_pos}
  self._sel_end = nil       -- same structure
  -- IME composition state
  self.ime_status = false
  self.ime_text = ""
  local backend_now = config.plugins.aichat.backend or "pibridge"
  table.insert(self.messages, {
    role = "system",
    content = "AI Chat 就绪。后端: " .. backend_now
      .. (backend_now == "mock"
          and "（模拟模式，无需服务端）"
          or "（确认 pi-bridge 已启动: " .. (config.plugins.aichat.api_base or "") .. "）"),
  })
end

function AIView:get_name() return "AI Chat" end

-- Toggle mechanism mirrors TreeView: the view owns its own width; the node reads
-- view.size.x for the locked pane. We animate size.x toward target_size (visible)
-- or 0 (hidden).
function AIView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function AIView:header_height()
  return math.floor(style.font:get_height() + style.padding.y * 2.4)
end

-- Input box geometry: a rounded card with up to three text lines, and a footer
-- row holding the key hint and the send/stop button.  Shared by draw(), the
-- caret / IME placement and the send-button hit test so they never drift.
local INPUT_LINES = 3

local function input_metrics()
  local pad = style.padding
  local lh = style.font:get_height()
  return {
    lh = lh,
    margin = math.floor(pad.x * 0.6),       -- card inset from the panel edge
    ipx = math.floor(pad.x * 0.8),          -- card inner padding, horizontal
    ipy = math.floor(pad.y * 0.9),          -- card inner padding, vertical
    gap = math.floor(4 * SCALE),            -- text area -> footer row
    btn_h = lh + math.floor(6 * SCALE),
  }
end

function AIView:get_input_height()
  local m = input_metrics()
  return m.margin * 2 + m.ipy + m.lh * INPUT_LINES + m.gap + m.btn_h
    + math.floor(m.ipy * 0.7)
end

function AIView:input_layout()
  local m = input_metrics()
  local ih = self:get_input_height()
  local input_y = self.position.y + self.size.y - ih
  local cx, cy = self.position.x + m.margin, input_y + m.margin
  local cw, ch = self.size.x - m.margin * 2, ih - m.margin * 2
  local text_x, text_y = cx + m.ipx, cy + m.ipy
  local text_h = m.lh * INPUT_LINES
  local label = self.streaming and "停止" or "发送"
  local btn_w = style.font:get_width("停止") + math.floor(style.padding.x * 1.6)
  local bx = cx + cw - math.floor(m.ipx * 0.6) - btn_w
  local by = text_y + text_h + m.gap
  return {
    input_y = input_y, input_h = ih,
    card = { cx, cy, cw, ch },
    text_x = text_x, text_y = text_y, text_w = cw - m.ipx * 2, text_h = text_h,
    btn = { bx, by, btn_w, m.btn_h }, btn_label = label,
    lh = m.lh,
  }
end

function AIView:message_area()
  local x = self.position.x
  local y = self.position.y + self:header_height()
  local w = self.size.x
  local h = self.size.y - self:header_height() - self:get_input_height()
  return x, y, w, math.max(0, h)
end

function AIView:get_scrollable_size()
  return self.content_height
end

function AIView:clamp_scroll_position()
  local _, _, _, msg_h = self:message_area()
  local max = math.max(0, self.content_height - msg_h)
  self.scroll.to.y = common.clamp(self.scroll.to.y, 0, max)
  self.scroll.to.x = 0
end

function AIView:update_scrollbar()
  local msg_x, msg_y, msg_w, msg_h = self:message_area()
  local scrollable = self.content_height
  self.v_scrollbar:set_size(msg_x, msg_y, msg_w, msg_h, scrollable)
  local max = math.max(1, scrollable - msg_h)
  local percent = scrollable > msg_h and self.scroll.y / max or 0
  self.v_scrollbar:set_percent(percent == percent and percent or 0)
  self.v_scrollbar:update()
end

function AIView:update()
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, 0.3, "aichat_toggle")
  if not self.visible or self.size.x < 1 or self.size.y < 1 then return end
  AIView.super.update(self)
  -- accumulate the shared blink timer so the caret blinks while AIView is
  -- focused (DocView:update() does the same; without this core.blink_timer
  -- would freeze and the caret would never toggle).
  if not config.disable_blink
     and system.window_has_focus(core.window)
     and self == core.active_view then
    core.blink_timer = system.get_time()
    core.redraw = true
  end
  -- Force continuous redraw while streaming so the spinner animates.
  if self.streaming then core.redraw = true end
  -- ...and while the copy button shows its "已复制" feedback.
  if self._copied_at and system.get_time() - self._copied_at < 1.6 then
    core.redraw = true
  end
  -- Keep IME candidate window pinned to the input caret.
  if self.ime_status then self:update_ime_location() end
end

-- Compact role label drawn above a message.  Assistant is the default voice in
-- a chat panel, so it gets none: an all-caps "ASSISTANT" line on top of every
-- reply was pure noise and cost a full line of height each time.
-- User messages and errors are drawn as rounded cards; the card itself marks
-- "your turn", so only errors keep a text label.
local ROLE_LABEL = { error = "错误" }

local function is_card_role(role)
  return role == "user" or role == "error"
end

-- Padding between a card's top edge and its first line.
local function card_inset()
  return math.floor(style.padding.y * 0.9)
end

-- Extra horizontal inset of the text inside a card.
local function card_text_inset()
  return math.floor(style.padding.x * 0.4)
end

-- Height reserved above the message content: card padding plus the label.
local function role_label_height(role, lh)
  local h = is_card_role(role) and card_inset() or 0
  if ROLE_LABEL[role] then h = h + lh + math.floor(style.padding.y * 0.4) end
  return h
end

-- Wrapped render lines of a single message.  Markdown for everything the user
-- or the agent writes — user messages carry the "[当前文件] …" header and the
-- selected-code fence injected by build_message, so they need it too.  Only
-- system notices stay plain (and dim: they are status, not conversation).
local function message_rlines(msg, font, lh, text_w)
  if msg.role == "system" then
    local rlines = {}
    for _, line in ipairs(wrap_text(msg.content, font, text_w)) do
      rlines[#rlines + 1] = {
        segments = { { text = line, font = font, color = style.dim } },
        h = math.floor(lh * 1.25), indent = 0,
      }
    end
    return rlines
  end
  if not is_card_role(msg.role) then
    return layout_md(msg.content, text_w)
  end

  local inset = card_text_inset()
  local inner_w = text_w - inset * 2
  local rlines = {}
  local body = msg.content
  -- The "[当前文件] path" header added by build_message becomes a file chip
  -- instead of a bracketed line of plain text.
  local path, rest = body:match("^%[当前文件%] ([^\n]*)\n*(.*)$")
  if path then
    local label = util.truncate_to_width(ai_font, path, inner_w - CODE_CHIP_PAD * 2)
    rlines[1] = {
      segments = { {
        text = label, font = ai_font, color = style.dim,
        pad = CODE_CHIP_PAD, bg = with_alpha(style.text, 22),
      } },
      h = math.floor(ai_font:get_height() * 1.32), indent = 0,
    }
    body = rest
  end
  if body:match("%S") then
    local md = layout_md(body, inner_w)
    if path and md[1] then
      md[1].sp = math.max(md[1].sp or 0, math.floor(style.padding.y * 0.5))
    end
    for _, rl in ipairs(md) do rlines[#rlines + 1] = rl end
  end
  if #rlines == 0 then return layout_md(msg.content, inner_w) end
  for _, rl in ipairs(rlines) do rl.indent = (rl.indent or 0) + inset end
  return rlines
end


function AIView:layout_messages()
  local msg_x, msg_y, msg_w, msg_h = self:message_area()
  local text_w = msg_w - style.padding.x * 2
  if text_w <= 0 then return end
  if self._layout_key == text_w and not self._dirty then return end
  -- While a reply streams in, _dirty is set for every token.  Re-wrapping the
  -- whole conversation every time made long chats quadratic, so the wrapped
  -- lines of each message are cached and only the changed ones are rebuilt.
  local cache = self._layout_cache
  if cache == nil or self._layout_key ~= text_w then
    cache = {}
    self._layout_cache = cache
  end
  self._layout_key = text_w
  self._dirty = false

  local wrapped = {}
  -- breathing room between the header and the first message
  local y = math.floor(style.padding.y * 0.9)
  local font = ai_font
  local lh = font:get_height()
  -- gap between messages: without it consecutive blocks ran together and the
  -- only cue for "a new turn started" was the 3px role strip
  local msg_gap = math.ceil(lh * 0.85)
  for i, msg in ipairs(self.messages) do
    local entry = cache[i]
    local rlines
    if entry and entry.content == msg.content and entry.role == msg.role then
      rlines = entry.rlines
    else
      rlines = message_rlines(msg, font, lh, text_w)
      cache[i] = { content = msg.content, role = msg.role, rlines = rlines }
    end
    local content_h = 0
    for _, rl in ipairs(rlines) do content_h = content_h + rline_outer(rl) end
    local label_h = role_label_height(msg.role, lh)
    local gap = (i > 1) and msg_gap or 0
    wrapped[i] = {
      role = msg.role, rlines = rlines, y = y + gap,
      h = label_h + content_h + style.padding.y,
      label_h = label_h, gap = gap,
      inset = is_card_role(msg.role) and card_inset() or 0,
      is_empty = not msg.content:match("%S"),
    }
    y = y + gap + wrapped[i].h
  end
  self._wrapped = wrapped
  self.content_height = y
  -- forget the cached layouts of messages that are gone
  if #self.messages < #cache then
    for i = #self.messages + 1, #cache do cache[i] = nil end
  end
end

function AIView:scroll_to_bottom()
  self:layout_messages()
  local _, _, _, msg_h = self:message_area()
  local max = math.max(0, self.content_height - msg_h)
  self.scroll.to.y = max
  self.scroll.y = max
end

function AIView:on_mouse_wheel(y, x)
  self.scroll.to.y = self.scroll.to.y - y * (style.font:get_height() * 3)
  self:clamp_scroll_position()
end

-------------------------------------------------------------------------------
-- Text selection in the message area
-------------------------------------------------------------------------------

-- Map an (x, y) screen coordinate to a position in the message text.
-- Returns {msg_idx, rline_idx, seg_idx, char_pos} or nil if outside messages.
function AIView:_hit_test_msg(x, y)
  if self._dirty then self:layout_messages() end
  local msg_x, msg_y, msg_w, msg_h = self:message_area()
  if y < msg_y or y >= msg_y + msg_h
     or x < msg_x or x >= msg_x + msg_w then
    return nil
  end
  local pad = style.padding
  local offset_y = msg_y - self.scroll.y
  for blk_idx, blk in ipairs(self._wrapped) do
    local block_y = offset_y + blk.y
    -- Role-label line is not selectable; skip to content.  The block's own
    -- leading gap is dead space as well.
    if y >= block_y + blk.label_h and y < block_y + blk.h then
      local cum_y = block_y + blk.label_h
      for rl_idx, rline in ipairs(blk.rlines) do
        local text_top = rline_text_top(rline, cum_y)
        if y < text_top + rline.h then
          local sx = msg_x + pad.x + (rline.indent or 0)
          local seg_idx, seg, seg_x
          -- Find which segment x falls into (or clamp to last).
          for si, s in ipairs(rline.segments) do
            local sw = seg_advance(s)
            if x < sx + sw then
              seg_idx, seg, seg_x = si, s, sx
              break
            end
            sx = sx + sw
          end
          -- Clamp to end of last segment.
          if not seg_idx then
            if #rline.segments == 0 then return nil end
            seg_idx = #rline.segments
            seg = rline.segments[seg_idx]
            seg_x = sx - seg_advance(seg)
          end
          -- Linear-scan char position within seg.text (UTF-8 aware).  seg_x is
          -- the chip's left edge, so drop its padding before measuring.
          local best_pos = 1
          local best_dist = math.huge
          local rel_x = x - seg_text_x(seg, seg_x)
          local p = 1
          while p <= #seg.text + 1 do
            local w = seg.font:get_width(seg.text:sub(1, p - 1))
            local dist = math.abs(rel_x - w)
            if dist < best_dist then
              best_dist = dist
              best_pos = p
            end
            if p > #seg.text then break end
            p = utf8_next(seg.text, p)
          end
          return {
            msg_idx = blk_idx, rline_idx = rl_idx,
            seg_idx = seg_idx, char_pos = best_pos,
          }
        end
        cum_y = cum_y + rline_outer(rline)
      end
      return nil
    end
  end
  return nil
end

-- Compare two positions: returns -1 if a before b, 0 if equal, 1 if after.
local function cmp_pos(a, b)
  if a.msg_idx ~= b.msg_idx then return a.msg_idx < b.msg_idx and -1 or 1 end
  if a.rline_idx ~= b.rline_idx then return a.rline_idx < b.rline_idx and -1 or 1 end
  if a.seg_idx ~= b.seg_idx then return a.seg_idx < b.seg_idx and -1 or 1 end
  if a.char_pos ~= b.char_pos then return a.char_pos < b.char_pos and -1 or 1 end
  return 0
end

-- Returns true if selection exists and is non-empty (start != end).
function AIView:_has_selection()
  return self._sel_start and self._sel_end
    and cmp_pos(self._sel_start, self._sel_end) ~= 0
end

-- Extract the text between _sel_start and _sel_end (inclusive).
function AIView:_get_selected_text()
  if not self:_has_selection() then return "" end
  local s, e = self._sel_start, self._sel_end
  if cmp_pos(s, e) > 0 then s, e = e, s end -- normalize order

  local parts = {}
  local mi = s.msg_idx
  while mi <= e.msg_idx do
    local blk = self._wrapped[mi]
    if not blk then break end
    local rl_start = (mi == s.msg_idx) and s.rline_idx or 1
    local rl_end   = (mi == e.msg_idx) and e.rline_idx or #blk.rlines
    for ri = rl_start, rl_end do
      local rline = blk.rlines[ri]
      if rline then
        local seg_start = (mi == s.msg_idx and ri == s.rline_idx) and s.seg_idx or 1
        local seg_end   = (mi == e.msg_idx and ri == e.rline_idx) and e.seg_idx or #rline.segments
        local line_text = ""
        for si = seg_start, seg_end do
          local seg = rline.segments[si]
          if seg then
            if mi == s.msg_idx and ri == s.rline_idx and si == s.seg_idx then
              line_text = line_text .. seg.text:sub(s.char_pos)
            elseif mi == e.msg_idx and ri == e.rline_idx and si == e.seg_idx then
              line_text = line_text .. seg.text:sub(1, e.char_pos - 1)
            else
              line_text = line_text .. seg.text
            end
          end
        end
        parts[#parts + 1] = line_text
      end
    end
    if mi < e.msg_idx then parts[#parts + 1] = "" end -- blank line between msgs
    mi = mi + 1
  end
  return table.concat(parts, "\n")
end

-- Returns "all", {start_byte, end_byte}, or nil for a given segment.
-- Bytes are 1-indexed, end exclusive. start/end are already normalized.
function AIView:_seg_in_selection(blk_idx, rl_idx, sg_idx, seg, ns, ne)
  if not ns or not ne then return nil end
  -- Fully before or after selection range?
  local here = { msg_idx = blk_idx, rline_idx = rl_idx, seg_idx = sg_idx, char_pos = 1 }
  local after_last = { msg_idx = blk_idx, rline_idx = rl_idx, seg_idx = sg_idx,
                       char_pos = #seg.text + 1 }
  if cmp_pos(after_last, ns) <= 0 then return nil end -- segment before selection
  if cmp_pos(here, ne) >= 0 then return nil end       -- segment after selection
  -- Fully inside?
  if cmp_pos(here, ns) >= 0 and cmp_pos(after_last, ne) <= 0 then
    return "all"
  end
  -- Partial: compute byte range.
  local start_byte = 1
  if cmp_pos(here, ns) < 0 then
    -- Selection starts inside this segment.
    start_byte = ns.char_pos
  end
  local end_byte = #seg.text + 1
  if cmp_pos(after_last, ne) > 0 then
    -- Selection ends inside this segment.
    end_byte = ne.char_pos
  end
  if start_byte >= end_byte then return nil end
  return { start_byte, end_byte }
end

-- Clear the current selection.
function AIView:_clear_selection()
  self._sel_start = nil
  self._sel_end = nil
  self._selecting = false
end

-------------------------------------------------------------------------------
-- Per-code-block copy button
-------------------------------------------------------------------------------
local COPY_LABEL = "复制"
local COPY_LABEL_DONE = "已复制"

function AIView:_copy_btn_rect(rline, msg_x, msg_w, ly)
  -- sized for the wider "已复制" label so the button does not jitter on click
  local label_w = math.max(ai_font:get_width(COPY_LABEL), ai_font:get_width(COPY_LABEL_DONE))
  local bw = label_w + math.floor(style.padding.x * 1.2)
  local bh = math.min(rline.h, ai_font:get_height() + math.floor(4 * SCALE))
  local bx = msg_x + msg_w - math.floor(style.padding.x * 1.1) - bw
  local by = ly + math.floor((rline.h - bh) / 2)
  return bx, by, bw, bh
end

-- Walk the same geometry draw() uses to find the copy button under (x, y).
function AIView:_copy_btn_at(x, y)
  local msg_x, msg_y, msg_w, msg_h = self:message_area()
  if x < msg_x or x >= msg_x + msg_w or y < msg_y or y >= msg_y + msg_h then
    return nil
  end
  local offset_y = msg_y - self.scroll.y
  for _, blk in ipairs(self._wrapped or {}) do
    local cum_y = offset_y + blk.y + blk.label_h
    for _, rline in ipairs(blk.rlines) do
      if rline.is_code_bar then
        local ly = rline_text_top(rline, cum_y)
        local bx, by, bw, bh = self:_copy_btn_rect(rline, msg_x, msg_w, ly)
        if x >= bx and x < bx + bw and y >= by and y < by + bh then return rline end
      end
      cum_y = cum_y + rline_outer(rline)
    end
  end
  return nil
end

function AIView:_copy_code(rline)
  if not (rline and rline.code_text) then return end
  system.set_clipboard(rline.code_text)
  self._copied_rline = rline
  self._copied_at = system.get_time()
  core.log("已复制代码块（%d 字符）", #rline.code_text)
  core.redraw = true
end

-- Link under (x, y), if any.
function AIView:_link_at(x, y)
  local pos = self:_hit_test_msg(x, y)
  if not pos then return nil end
  local blk = self._wrapped and self._wrapped[pos.msg_idx]
  local rline = blk and blk.rlines[pos.rline_idx]
  local seg = rline and rline.segments[pos.seg_idx]
  return seg and seg.link
end

-- Handle clicks on the header "新对话" button and text selection in the
-- message area; everything else delegates to the default View handler
-- (scrollbar etc.).
local function in_rect(px, py, rx, ry, rw, rh)
  return px >= rx and px < rx + rw and py >= ry and py < ry + rh
end

-- Send / stop button in the input footer.  Hidden (not clickable) when there
-- is nothing to send and nothing to stop.
function AIView:_send_btn_active()
  return self.streaming or self.input:match("%S") ~= nil
end

function AIView:_over_send_btn(x, y)
  local L = self:input_layout()
  return self:_send_btn_active() and in_rect(x, y, table.unpack(L.btn))
end

function AIView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    if in_rect(x, y, self:new_btn_rect()) then
      self:new_session()
      return true
    end
    if self:_over_send_btn(x, y) then
      core.set_active_view(self)
      self:submit()
      return true
    end
    -- a click anywhere in the input card focuses the input
    local L = self:input_layout()
    if in_rect(x, y, table.unpack(L.card)) then
      core.set_active_view(self)
      return true
    end
    -- Copy button: must win over the drag-to-select handler below.
    local btn = self:_copy_btn_at(x, y)
    if btn then
      self:_copy_code(btn)
      return true
    end
    -- Text selection in message area.
    local msg_x, msg_y, msg_w, msg_h = self:message_area()
    if x >= msg_x and x < msg_x + msg_w and y >= msg_y and y < msg_y + msg_h then
      self._selecting = true
      self._sel_start = self:_hit_test_msg(x, y)
      self._sel_end = self._sel_start
      core.redraw = true
      return true
    end
  end
  return AIView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function AIView:on_mouse_moved(x, y, dx, dy)
  local over = in_rect(x, y, self:new_btn_rect())
  if over ~= self._new_btn_hover then
    self._new_btn_hover = over
    core.redraw = true
  end
  local over_send = self:_over_send_btn(x, y)
  if over_send ~= self._send_hover then
    self._send_hover = over_send
    core.redraw = true
  end
  if over_send then over = true end
  if self._selecting then
    self._sel_end = self:_hit_test_msg(x, y)
    core.redraw = true
    core.request_cursor("ibeam")
    return true
  end
  if over then core.request_cursor("hand") end
  -- copy buttons and links are clickable: show a hand and repaint on change
  local btn = self:_copy_btn_at(x, y)
  if btn ~= self._copy_hover then
    self._copy_hover = btn
    core.redraw = true
  end
  local link = btn and nil or self:_link_at(x, y)
  if link ~= self._link_hover then
    self._link_hover = link
    core.redraw = true
  end
  if btn or link then core.request_cursor("hand") end
  return AIView.super.on_mouse_moved(self, x, y, dx, dy)
end

function AIView:on_mouse_released(button, x, y)
  if self._selecting then
    self._selecting = false
    if self:_has_selection() then
      local text = self:_get_selected_text()
      if #text > 0 then
        system.set_clipboard(text)
        core.log("已复制 %d 字", #text)
      end
    else
      -- a plain click (no drag) on a link opens it
      local url = self:_link_at(x, y)
      if url then open_url(url) end
    end
    core.redraw = true
    return true
  end
  return AIView.super.on_mouse_released(self, button, x, y)
end

function AIView:on_mouse_left()
  self._new_btn_hover = false
  self._send_hover = false
  self._selecting = false
  self._copy_hover = nil
  self._link_hover = nil
  AIView.super.on_mouse_left(self)
end

function AIView:supports_text_input() return true end

-- Compute the screen-space caret position in the input box (used for IME).
-- Split self.input into lines at '\n', returning the lines table and a
-- parallel table of each line's starting byte offset in self.input.
-- Always returns at least one line.
function AIView:_input_lines()
  local s = self.input
  local lines, starts = {}, {}
  local i, n = 1, #s
  while i <= n do
    local j = i
    while j <= n and s:byte(j) ~= 10 do j = j + 1 end
    lines[#lines + 1] = s:sub(i, j - 1)
    starts[#starts + 1] = i
    i = j + 1
  end
  if #lines == 0 then lines, starts = { "" }, { 1 } end
  return lines, starts
end

-- Returns (line_idx, col, line_text) for the current caret position.
-- col is 1-based into line_text.  Mirrors the scan in _draw_caret.
function AIView:_caret_line_info()
  local lines, starts = self:_input_lines()
  local target = self.caret
  for li, line in ipairs(lines) do
    local line_start = starts[li]
    local line_end = line_start + #line  -- last byte offset of this line
    -- caret may sit at line_end + 1 (just past the line, on the '\n' or EOL)
    if target >= line_start and target <= line_end + 1 then
      return li, target - line_start + 1, line
    end
  end
  return 1, 1, lines[1] or ""
end

-- Visual rows of the input: logical lines soft-wrapped to `width` (at the last
-- space when there is one, otherwise at a character boundary, which also
-- covers CJK).  Every row keeps the byte offset it starts at, so the caret is
-- placed on exactly the row that is drawn — drawing word-wrapped text while
-- placing the caret on logical lines put it on the wrong row.
function AIView:_input_rows(width)
  local font = style.font
  local rows = {}
  local lines, starts = self:_input_lines()
  for li, line in ipairs(lines) do
    local base = starts[li]
    if #line == 0 then rows[#rows + 1] = { text = "", start = base } end
    local p = 1
    while p <= #line do
      local q, w, last_space = p, 0, nil
      while q <= #line do
        local nxt = utf8_next(line, q)
        local ch = line:sub(q, nxt - 1)
        local cw = font:get_width(ch)
        if w + cw > width and q > p then break end
        w = w + cw
        if ch == " " then last_space = nxt end
        q = nxt
      end
      if q <= #line and last_space and last_space > p then q = last_space end
      rows[#rows + 1] = { text = line:sub(p, q - 1), start = base + p - 1 }
      p = q
    end
  end
  return rows
end

-- Rows, the caret's row and x offset, and the first row to show (the box
-- scrolls so the caret row stays visible).
function AIView:_input_view(width)
  local rows = self:_input_rows(width)
  local crow = 1
  for i, r in ipairs(rows) do
    if r.start <= self.caret then crow = i end
  end
  local row = rows[crow]
  local cx = style.font:get_width(row.text:sub(1, math.max(0, self.caret - row.start)))
  local first = math.max(1, crow - INPUT_LINES + 1)
  return rows, crow, cx, first
end

-- Screen position of the input caret (used for the IME candidate window).
function AIView:_caret_screen_pos()
  local L = self:input_layout()
  local _, crow, cx, first = self:_input_view(L.text_w)
  return L.text_x + cx, L.text_y + (crow - first) * L.lh, L.lh
end

-- Set the IME candidate window location to the input caret position.
function AIView:update_ime_location()
  if not self.ime_status and core.active_view ~= self then return end
  local cx, cy, lh = self:_caret_screen_pos()
  ime.set_location(cx, cy, math.max(2, math.floor(4 * SCALE)), lh)
end

function AIView:on_ime_text_editing(text, start, length)
  self.ime_status = #text > 0
  self.ime_text = text
  if self.ime_status then
    self:update_ime_location()
  end
  core.redraw = true
end

function AIView:on_text_input(text)
  self.input = self.input:sub(1, self.caret - 1) .. text .. self.input:sub(self.caret)
  self.caret = self.caret + #text
  core.blink_reset()
  core.redraw = true
end

function AIView:insert_newline()
  self.input = self.input:sub(1, self.caret - 1) .. "\n" .. self.input:sub(self.caret)
  self.caret = self.caret + 1
  core.blink_reset()
  core.redraw = true
end

function AIView:backspace()
  if self.caret > 1 then
    local prev = utf8_prev(self.input, self.caret)
    self.input = self.input:sub(1, prev - 1) .. self.input:sub(self.caret)
    self.caret = prev
    core.blink_reset()
    core.redraw = true
  end
end

function AIView:cursor_left()
  if self.caret > 1 then self.caret = utf8_prev(self.input, self.caret); core.blink_reset(); core.redraw = true end
end

function AIView:cursor_right()
  if self.caret <= #self.input then self.caret = utf8_next(self.input, self.caret); core.blink_reset(); core.redraw = true end
end

-- Move the caret up/down within the multi-line input.  When the input is a
-- single line, fall through to scrolling the message area (preserves the old
-- single-line behaviour).  Column is clamped to the target line's length.
function AIView:cursor_up()
  local lines, starts = self:_input_lines()
  if #lines <= 1 then return self:scroll_up() end
  local li, col = self:_caret_line_info()
  if li <= 1 then
    self.caret = 1
  else
    local prev_line = lines[li - 1]
    local new_col = math.min(col, #prev_line + 1)
    self.caret = starts[li - 1] + new_col - 1
  end
  core.blink_reset(); core.redraw = true
end

function AIView:cursor_down()
  local lines, starts = self:_input_lines()
  if #lines <= 1 then return self:scroll_down() end
  local li, col = self:_caret_line_info()
  if li >= #lines then
    self.caret = #self.input + 1
  else
    local next_line = lines[li + 1]
    local new_col = math.min(col, #next_line + 1)
    self.caret = starts[li + 1] + new_col - 1
  end
  core.blink_reset(); core.redraw = true
end

-- Home / End: move to the start / end of the current input line.
function AIView:line_home()
  local li = self:_caret_line_info()
  local _, starts = self:_input_lines()
  self.caret = starts[li]
  core.blink_reset(); core.redraw = true
end

function AIView:line_end()
  local lines, starts = self:_input_lines()
  local li = self:_caret_line_info()
  self.caret = starts[li] + #lines[li]
  core.blink_reset(); core.redraw = true
end

-- Delete the previous word (up to the previous word boundary).  A "word" here
-- is a run of word characters or a run of non-word non-space characters,
-- matching the editor's symbol_pattern notion loosely.
local function word_boundary_back(s, pos)
  local p = pos - 1
  -- skip trailing whitespace
  while p >= 1 and s:byte(p) == 32 do p = p - 1 end
  if p < 1 then return pos end
  local c = s:byte(p)
  local is_word = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
    or (c >= 48 and c <= 57) or c == 95  -- [A-Za-z0-9_]
  while p >= 1 do
    local pc = s:byte(p)
    local pis_word = (pc >= 65 and pc <= 90) or (pc >= 97 and pc <= 122)
      or (pc >= 48 and pc <= 57) or pc == 95
    if is_word ~= pis_word then break end
    if pc == 32 then break end
    p = p - 1
  end
  return p + 1
end

function AIView:delete_word_back()
  if self.caret <= 1 then return end
  local target = word_boundary_back(self.input, self.caret)
  self.input = self.input:sub(1, target - 1) .. self.input:sub(self.caret)
  self.caret = target
  core.blink_reset(); core.redraw = true
end

-- Delete from the caret back to the start of the current line.
function AIView:delete_to_line_start()
  local li = self:_caret_line_info()
  local _, starts = self:_input_lines()
  local line_start = starts[li]
  if self.caret <= line_start then return end
  self.input = self.input:sub(1, line_start - 1) .. self.input:sub(self.caret)
  self.caret = line_start
  core.blink_reset(); core.redraw = true
end

function AIView:scroll_up()
  self.scroll.to.y = self.scroll.to.y - style.font:get_height() * 3
  self:clamp_scroll_position()
  core.redraw = true
end

function AIView:scroll_down()
  self.scroll.to.y = self.scroll.to.y + style.font:get_height() * 3
  self:clamp_scroll_position()
  core.redraw = true
end

function AIView:clear()
  self.messages = {}
  self._layout_cache = nil
  self.input = ""
  self.caret = 1
  self._dirty = true
  self.scroll.to.y = 0
  self.scroll.y = 0
  self:_clear_selection()
  core.redraw = true
end

-- Working directory handed to the pi-bridge session (the agent's cwd).
-- NOTE: core.project_dir no longer exists in this fork (upstream removed it in
-- favour of core.projects / core.root_project()), so reading it silently fell
-- back to $HOME and pointed the agent at the home directory.  Use the root
-- project path, falling back to the old behaviour when there is no project.
local function project_working_dir()
  local project = core.root_project and core.root_project()
  return (project and project.path) or os.getenv("HOME") or "."
end

-- Start a fresh session: abort any active stream, clear messages, and
-- invalidate the cached pi-bridge session for the current working dir so the
-- next submit creates a brand-new conversation.
function AIView:new_session()
  if self.streaming then
    self:abort_stream()
  end
  -- drop the cached session so _ensure_session creates a new one next time
  local working_dir = project_working_dir()
  self._sessions[working_dir] = nil
  self:clear()
  table.insert(self.messages, {
    role = "system",
    content = "已开启新对话。",
  })
  self._dirty = true
  core.redraw = true
end

-- Rect of the "新对话" button in the header (right-aligned).
-- Rect of the "新对话" pill button, vertically centred in the header.
function AIView:new_btn_rect()
  local font = style.font
  local label = "＋ 新对话"
  local pad = style.padding
  local bw = font:get_width(label) + math.floor(pad.x * 1.2)
  local bh = font:get_height() + math.floor(6 * SCALE)
  local bx = self.position.x + self.size.x - math.floor(pad.x * 0.7) - bw
  local by = self.position.y + math.floor((self:header_height() - bh) / 2)
  return bx, by, bw, bh, label
end

-- Mount the panel into the active node if not already docked. Called at load
-- time and again on toggle, so a transient failure at startup can self-heal.
function AIView:ensure_mounted()
  if self.node then return true end
  local node = core.root_view and core.root_view:get_active_node()
  if not node then return false end
  self.node = node:split("right", self, { x = true }, true)
  return true
end

-- Locate the DocView the user was editing when the AI panel took focus.
-- core.last_active_view is whatever view had focus before the panel did, so it
-- normally points at the editor; when it is nil or stale (file closed, panel
-- focused first) fall back to scanning the root view for a DocView.  Wrapped in
-- pcall and duck-typed on .doc, so a stale view or a build without DocView can
-- never break the submit.
local function find_active_doc_view()
  local ok, av = pcall(function() return core.last_active_view end)
  if ok and av and av.doc then return av end
  local found
  local function scan(node)
    if not node or found then return end
    for _, v in ipairs(node.views or {}) do
      if v.doc then found = v end
    end
    scan(node.a)
    scan(node.b)
  end
  pcall(function() scan(core.root_view and core.root_view.root_node) end)
  return found
end

-- Path of a document the way the user sees it in the treeview: relative to the
-- project root when it lives inside it, home-encoded absolute path otherwise.
-- Returns nil for unsaved buffers.
local function doc_display_path(doc)
  local path = doc.filename
  if not path or path == "" then return nil end
  local ok, project = pcall(function() return core.projects and core.projects[1] end)
  if ok and project and common.path_belongs_to(path, project.path) then
    local rok, rel = pcall(function() return project:normalize_path(path) end)
    if rok and rel and rel ~= "" then return rel end
  end
  return common.home_encode(path)
end

-- Build the message to send: the user text, prefixed with the name of the file
-- the editor is showing, so "分析下这个 sql" has a target to look at.  Only the
-- NAME is sent — the backend session's cwd is the project root, so the agent
-- reads the file itself when it needs the content.  A real selection is the one
-- exception: that is explicit user intent, so the snippet rides along.
function AIView:build_message(user_text)
  local av = find_active_doc_view()
  if not av then return user_text end
  local doc = av.doc
  local header = "[当前文件] " .. (doc_display_path(doc) or "未保存的缓冲区")

  local sel_ok, sel = pcall(function() return doc:get_selection_text() end)
  if not (sel_ok and sel and #sel > 0 and #sel < 30000) then
    return header .. "\n\n" .. user_text
  end

  local l1, _, l2 = doc:get_selection()
  if l2 and l2 > l1 then header = header .. string.format("（选中 L%d-%d）", l1, l2) end
  return header .. "\n\n<选中的代码>\n" .. sel .. "\n</选中的代码>\n\n" .. user_text
end

function AIView:submit()
  if self.streaming then
    self:abort_stream()
    return
  end
  local text = self.input
  if text:match("^%s*$") then return end
  local msg = self:build_message(text)
  self:_send(msg)
  self.input = ""
  self.caret = 1
end

function AIView:_send(user_text)
  table.insert(self.messages, { role = "user", content = user_text })
  table.insert(self.messages, { role = "assistant", content = "" })
  self._dirty = true
  self.streaming = true
  self:_clear_selection()
  core.redraw = true

  local cfg = config.plugins.aichat
  local backend = cfg.backend or "pibridge"
  local assistant_idx = #self.messages
  if backend == "mock" then
    self:_send_mock(assistant_idx, user_text)
  elseif backend == "openai" then
    self:_send_openai(assistant_idx)
  else
    self:_send_pibridge(assistant_idx, user_text)
  end
end

-------------------------------------------------------------------------------
-- pi-bridge backend (slate-compatible SSE agent at api_base)
--   POST /sessions        {working_dir, clip}        -> {ok, session_id}
--   POST /chat/stream     {session_id, message}      -> text/event-stream
--   POST /abort           {session_id}               -> {ok}
-- SSE frames: "data: {json}\n\n", heartbeat ": ping\n\n".
--   text_delta: {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"..."}}
--   thinking_delta: 同样的 assistantMessageEvent 形状，内容是模型的思考过程；
--                   面板不显示，直接忽略（只渲染 text_delta）。
--   error:      {"type":"message_end","message":{"stopReason":"error","errorMessage":"..."}}
--   done:       {"type":"agent_settled"}
-------------------------------------------------------------------------------

-- Create (and cache) a pi-bridge session for the current working directory.
-- Returns session_id or nil, errmsg.
function AIView:_ensure_session()
  local cfg = config.plugins.aichat
  local working_dir = project_working_dir()
  if self._sessions[working_dir] then
    return self._sessions[working_dir]
  end
  local sbody = json.encode({ working_dir = working_dir, clip = false })
  local ok, proc = pcall(process.start, {
    cfg.curl_path, "-s", "-m", "10",
    "-X", "POST", "-H", "Content-Type: application/json",
    "-d", sbody, cfg.api_base .. "/sessions"
  })
  if not ok or not proc then
    return nil, "curl 启动失败，请确认已安装 curl"
  end
  -- Wait for curl to finish (yields in coroutine; curl -m 10 ≤ 12s wait).
  proc:wait(12)
  -- read("all") returns as soon as the child exited: EOF is reported as nil
  -- instead of an empty string, so there is nothing to recover here.
  local pok, out = pcall(proc.stdout.read, proc.stdout, "all", { timeout = 2 })
  if not pok then out = nil end
  if not out or out == "" then
    return nil, "无法连接 AI 引擎 (" .. cfg.api_base .. ")，请确认 pi-bridge 已启动"
  end
  local pok, obj = pcall(json.decode, out)
  if not pok or type(obj) ~= "table" or not obj.ok or not obj.session_id then
    return nil, "会话创建失败: " .. out:sub(1, 200)
  end
  self._sessions[working_dir] = obj.session_id
  return obj.session_id
end

-- Handle one SSE frame (the concatenated "data:" payload).
function AIView:_handle_sse_frame(data, assistant_idx)
  if not data or data == "" then return end
  local pok, obj = pcall(json.decode, data)
  if not pok or type(obj) ~= "table" then return end
  local t = obj.type
  if t == "message_update" and obj.assistantMessageEvent then
    local ae = obj.assistantMessageEvent
    -- 只渲染正式回答。thinking_delta 是模型的思考过程，面板不显示。
    if ae.type == "text_delta" and ae.delta then
      self.messages[assistant_idx].content =
        self.messages[assistant_idx].content .. ae.delta
      self._dirty = true
      self:scroll_to_bottom()
      core.redraw = true
    end
  elseif (t == "message_end" or t == "message_start") and obj.message then
    if obj.message.stopReason == "error" then
      local em = obj.message.errorMessage or "unknown error"
      -- strip HTML tags (e.g. 403 proxy pages) and collapse whitespace
      em = em:gsub("<[^>]+>", " "):gsub("%s+", " "):gsub("^%s+", "")
      if #em > 300 then em = em:sub(1, 300) .. "…" end
      if #self.messages[assistant_idx].content == 0 then
        self.messages[assistant_idx].role = "error"
        self.messages[assistant_idx].content = em
      else
        self.messages[assistant_idx].content =
          self.messages[assistant_idx].content .. "\n[error: " .. em .. "]"
      end
      self._stream_error = true
    end
  elseif t == "error" then
    self.messages[assistant_idx].role = "error"
    self.messages[assistant_idx].content = obj.error or "unknown error"
    self._stream_error = true
  elseif t == "agent_settled" then
    self._stream_done = true
  end
end

-- Terminal failure: mark the assistant message as an error and stop
-- streaming. Used by every backend when the request cannot start or the
-- body cannot be sent (session/curl/stdin failures).  In-progress stream
-- errors (SSE frames, finalize) keep their own logic.
function AIView:_fail(idx, text)
  self.messages[idx].role = "error"
  self.messages[idx].content = text
  self.streaming = false
  self._dirty = true
  core.redraw = true
end

function AIView:_send_pibridge(assistant_idx, user_text)
  local cfg = config.plugins.aichat
  core.add_thread(function()
    -- 1. ensure session
    local session_id, serr = self:_ensure_session()
    if not session_id then
      self:_fail(assistant_idx, serr or "无法创建会话")
      return
    end

    -- 2. start streaming request
    local body = json.encode({ session_id = session_id, message = user_text })
    local ok, proc = pcall(process.start, {
      cfg.curl_path, "-sN", "-m", "300",
      "-X", "POST", "-H", "Content-Type: application/json",
      "--data-binary", "@-",
      cfg.api_base .. "/chat/stream"
    })
    if not ok or not proc then
      self:_fail(assistant_idx, "curl 启动失败: " .. tostring(proc))
      return
    end
    self._stream_proc = proc
    self._stream_error = false
    self._stream_done = false

    -- write request body
    local wok, werr = pcall(function()
      proc.stdin:write(body)
      proc.stdin:close()
    end)
    if not wok then
      self:_fail(assistant_idx, "请求发送失败: " .. tostring(werr))
      self._stream_proc = nil
      return
    end

    -- 3. parse SSE stream line by line.
    --    A frame is: one or more "data: ..." lines followed by a blank line.
    --    read("line") yields until a line is available, returns nil once the
    --    process exited and the stream is drained, and raises on timeout.
    local data_buf = ""
    local function handle_line(raw)
      local line = raw:gsub("\r\n", "\n"):gsub("[\r\n]", "")
      if line == "" then
        if data_buf ~= "" then
          self:_handle_sse_frame(data_buf, assistant_idx)
          data_buf = ""
        end
      elseif line:sub(1, 1) == ":" then
        -- comment / heartbeat (": ping"), ignore
      elseif line:sub(1, 5) == "data:" then
        data_buf = data_buf .. line:sub(6):gsub("^%s", "")
      end
    end

    while true do
      if self._aborting then break end
      local line
      local pok = pcall(function()
        line = proc.stdout:read("line", { timeout = 2 })
      end)
      if not pok then
        -- timeout: the server sent nothing for 2s.  Keep waiting while curl
        -- is still alive, stop once it exited (the stream is over).
        if proc:returncode() ~= nil then break end
      elseif line == nil then
        break -- end of stream
      else
        handle_line(line)
      end
      coroutine.yield()
    end
    -- flush any trailing buffered frame
    if data_buf ~= "" then
      self:_handle_sse_frame(data_buf, assistant_idx)
    end

    -- 4. finalize
    pcall(function() proc:wait(2) end)
    local rc = proc:returncode()
    if self._aborting then
      -- tell the server to abort the agent
      self:_post_abort(session_id)
      if #self.messages[assistant_idx].content > 0 then
        self.messages[assistant_idx].content =
          self.messages[assistant_idx].content .. "\n（已停止）"
      else
        self.messages[assistant_idx].role = "system"
        self.messages[assistant_idx].content = "（已停止）"
      end
    elseif not self._stream_error and #self.messages[assistant_idx].content == 0 then
      self.messages[assistant_idx].role = "error"
      self.messages[assistant_idx].content =
        "未收到响应" .. (rc and (" (exit " .. rc .. ")") or "")
    end
    self._aborting = false
    self._stream_proc = nil
    self.streaming = false
    self._dirty = true
    core.redraw = true
  end, self)
end

-- Fire-and-forget POST /abort to tell pi-bridge to stop the agent.
function AIView:_post_abort(session_id)
  local cfg = config.plugins.aichat
  local body = json.encode({ session_id = session_id })
  local ok, proc = pcall(process.start, {
    cfg.curl_path, "-s", "-m", "5",
    "-X", "POST", "-H", "Content-Type: application/json",
    "-d", body, cfg.api_base .. "/abort"
  })
  if ok and proc then
    pcall(function() proc:wait(3) end)
  end
end

-- Abort the current streaming request (user pressed Enter / stop).
function AIView:abort_stream()
  if not self.streaming then return end
  self._aborting = true
  if self._stream_proc then
    pcall(function() self._stream_proc:terminate() end)
  end
  core.redraw = true
end


-------------------------------------------------------------------------------
-- OpenAI backend (OpenAI-compatible /v1/chat/completions over curl, streaming)
-------------------------------------------------------------------------------
function AIView:_send_openai(assistant_idx)
  local cfg = config.plugins.aichat
  local api_messages = {}
  if cfg.system_prompt and #cfg.system_prompt > 0 then
    table.insert(api_messages, { role = "system", content = cfg.system_prompt })
  end
  for i = 1, #self.messages - 1 do
    local m = self.messages[i]
    if m.role == "user" or m.role == "assistant" then
      table.insert(api_messages, { role = m.role, content = m.content })
    end
  end

  local body = json.encode({
    model = cfg.model,
    messages = api_messages,
    stream = true,
  })

  local api_key = cfg.api_key
  if not api_key or #api_key == 0 then
    self:_fail(assistant_idx,
      "No API key set. Set OPENAI_API_KEY env var or config.plugins.aichat.api_key.")
    return
  end

  core.add_thread(function()
    local ok, proc = pcall(process.start, {
      cfg.curl_path, "-sN",
      "-H", "Authorization: Bearer " .. api_key,
      "-H", "Content-Type: application/json",
      "-d", "@-",
      cfg.endpoint .. "/chat/completions",
    })
    if not ok or not proc then
      self:_fail(assistant_idx, "Failed to start curl: " .. tostring(proc))
      return
    end

    local wok, werr = pcall(function()
      proc.stdin:write(body)
      proc.stdin:close()
    end)
    if not wok then
      self:_fail(assistant_idx, "Failed to send request: " .. tostring(werr))
      return
    end

    -- Parse one SSE line from OpenAI streaming format.
    -- Returns true if stream is done ([DONE] marker).
    local function handle_oai_line(raw)
      local line = raw:match("^%s*(.-)%s*$")
      if #line == 0 then return false end
      local data = line:match("^data:%s*(.*)$") or line:match("^data:(.*)$")
      if not data then return false end
      if data:sub(1, 6) == "[DONE]" then return true end
      local jok, parsed = pcall(json.decode, data)
      if jok and parsed and parsed.choices then
        local choices = parsed.choices
        if choices[1] then
          local delta = choices[1].delta
          if delta and delta.content then
            self.messages[assistant_idx].content =
              self.messages[assistant_idx].content .. delta.content
            self._dirty = true
            self:scroll_to_bottom()
            core.redraw = true
          end
        end
      end
      return false
    end

    local done = false
    while not done do
      if self._aborting then break end
      local line
      local pok = pcall(function()
        line = proc.stdout:read("line", { timeout = 2 })
      end)
      if pok and line then
        done = handle_oai_line(line)
      elseif not pok then
        -- timeout: EOF (process exited) or EAGAIN (still running)
        local rc = proc:returncode()
        if rc ~= nil then
          -- EOF: drain remaining buffered data from stream internals.
          local stream = proc.stdout
          if stream and stream.len and stream.len > 0 then
            local remaining = table.concat(stream.buf)
            stream.buf = {}; stream.len = 0
            for l in (remaining .. "\n"):gmatch("([^\r\n]*)\r?\n") do
              done = handle_oai_line(l) or done
            end
          end
          break
        end
        -- else: still running, no data yet — continue
      else
        break -- nil return (shouldn't happen in coroutine)
      end
      coroutine.yield()
    end

    pcall(function() proc:wait(2) end)
    local rc = proc:returncode()
    -- Helper to drain a stream (stderr) recovering data from internals on EOF.
    local function drain_stream(stream)
      if not stream then return nil end
      local out
      pcall(function() out = stream:read("all", { timeout = 1 }) end)
      if not out or out == "" then
        if stream and stream.len and stream.len > 0 then
          out = table.concat(stream.buf)
        end
      end
      return out
    end
    if self.messages[assistant_idx].content == "" then
      self.messages[assistant_idx].role = "error"
      local serr = drain_stream(proc.stderr) or ""
      self.messages[assistant_idx].content =
        "No response received" .. (rc and (" (exit " .. rc .. ")") or "") ..
        (serr ~= "" and (": " .. serr) or "")
    elseif rc and rc ~= 0 then
      local serr = drain_stream(proc.stderr) or ""
      if #serr > 0 then
        self.messages[assistant_idx].content =
          self.messages[assistant_idx].content .. "\n[error exit " .. rc .. ": " .. serr .. "]"
      end
    end
    self.streaming = false
    self._dirty = true
    core.redraw = true
  end, self)
end


-------------------------------------------------------------------------------
-- Mock backend (simulated streaming, no server needed — for UI testing)
-------------------------------------------------------------------------------
function AIView:_send_mock(assistant_idx, user_text)
  core.add_thread(function()
    local reply = string.format(
      '（模拟回复）收到你的消息：%q\n\n这是 mock 流式后端，用于验证面板布局与逐字流式显示。'
      .. '将 config.plugins.aichat.backend 设为 "pibridge"（默认）即可连接 pi-bridge 真实后端。',
      user_text)
    local chunks = {}
    for cp in reply:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      chunks[#chunks + 1] = cp
    end
    for _, ch in ipairs(chunks) do
      if self._aborting then break end
      self.messages[assistant_idx].content = self.messages[assistant_idx].content .. ch
      self._dirty = true
      self:scroll_to_bottom()
      core.redraw = true
      coroutine.yield(0.018)
    end
    self.streaming = false
    self._dirty = true
    core.redraw = true
  end, self)
end


-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------
-- Header: accent dot + bold title + status (backend name, or a spinner while
-- a reply streams in), and the "新对话" pill on the right.
function AIView:_draw_header(P)
  local x, y, w = self.position.x, self.position.y, self.size.x
  local font = style.font
  local lh = font:get_height()
  local pad = style.padding
  local hh = self:header_height()
  local accent = style.accent or style.text

  renderer.draw_rect(x, y, w, hh, P.header)
  renderer.draw_rect(x, y + hh - 1, w, 1, P.line)

  local nbx, nby, nbw, nbh, nlabel = self:new_btn_rect()
  local hx = x + math.floor(pad.x * 0.9)
  local dot = math.floor(8 * SCALE)
  draw_round_rect(hx, y + math.floor((hh - dot) / 2), dot, dot, math.floor(dot / 2),
    self.streaming and COLOR_OK or accent)
  hx = hx + dot + math.floor(7 * SCALE)

  core.push_clip_rect(x, y, math.max(0, nbx - x - math.floor(6 * SCALE)), hh)
  local title = "AI 助手"
  renderer.draw_text(md_bold_font, title, hx,
    y + math.floor((hh - md_bold_font:get_height()) / 2), style.text)
  hx = hx + md_bold_font:get_width(title) + math.floor(10 * SCALE)
  local ty = y + math.floor((hh - lh) / 2)
  if self.streaming then
    local r = math.floor(5 * SCALE)
    draw_spinner(hx + r, y + math.floor(hh / 2), r, COLOR_OK)
    renderer.draw_text(font, "生成中…", hx + r * 2 + math.floor(6 * SCALE), ty, COLOR_OK)
  else
    renderer.draw_text(font, config.plugins.aichat.backend or "pibridge", hx, ty, style.dim)
  end
  core.pop_clip_rect()

  local hover = self._new_btn_hover
  draw_card(nbx, nby, nbw, nbh, math.floor(nbh / 2),
    hover and blend(P.header, accent, 0.16) or P.header,
    hover and blend(P.header, accent, 0.6) or P.card_line)
  common.draw_text(font, hover and accent or style.text, nlabel, "center",
    nbx, nby, nbw, nbh)
end

-- Input: rounded card (accent border while focused), up to INPUT_LINES rows of
-- text that scroll with the caret, a key hint and the send / stop button.
function AIView:_draw_input(P)
  local L = self:input_layout()
  local font = style.font
  local lh = L.lh
  local accent = style.accent or style.text
  local focused = core.active_view == self

  renderer.draw_rect(self.position.x, L.input_y, self.size.x, L.input_h, P.bg)
  local cx, cy, cw, ch = table.unpack(L.card)
  draw_card(cx, cy, cw, ch, math.floor(8 * SCALE), P.input,
    focused and blend(P.input, accent, 0.7) or P.card_line)

  core.push_clip_rect(L.text_x, L.text_y, L.text_w + style.caret_width, L.text_h)
  local rows, crow, caret_x, first = self:_input_view(L.text_w)
  if self.input == "" and not self.ime_status then
    renderer.draw_text(font, "问点什么…（会附带当前文件名）", L.text_x, L.text_y, style.dim)
  else
    for i = first, math.min(#rows, first + INPUT_LINES - 1) do
      renderer.draw_text(font, rows[i].text, L.text_x, L.text_y + (i - first) * lh, style.text)
    end
  end
  -- blink the caret (reuses lite-xl's core.blink_* system, same condition as
  -- DocView:draw): visible for the first half of each blink_period.
  if focused then
    local T = config.blink_period or 0.8
    if config.disable_blink or (core.blink_timer - core.blink_start) % T < T / 2 then
      renderer.draw_rect(L.text_x + caret_x, L.text_y + (crow - first) * lh,
        style.caret_width, lh, style.caret or style.text)
    end
  end
  core.pop_clip_rect()

  local bx, by, bw, bh = table.unpack(L.btn)
  local hint = self.streaming and "Enter 停止生成" or "Enter 发送 · Shift+Enter 换行"
  core.push_clip_rect(L.text_x, by, math.max(0, bx - L.text_x - math.floor(6 * SCALE)), bh)
  renderer.draw_text(font, hint, L.text_x, by + math.floor((bh - lh) / 2),
    with_alpha(style.dim, 200))
  core.pop_clip_rect()

  local fill, tcol
  if self.streaming then
    fill = with_alpha(COLOR_ERROR, self._send_hover and 255 or 215)
    tcol = WHITE
  elseif self:_send_btn_active() then
    fill = with_alpha(accent, self._send_hover and 255 or 225)
    tcol = style.background
  else
    fill, tcol = P.card, style.dim
  end
  draw_round_rect(bx, by, bw, bh, math.floor(bh / 2), fill)
  common.draw_text(font, tcol, L.btn_label, "center", bx, by, bw, bh)
end

-- The wrapped layout bakes colours (system text, the file chip, headings,
-- links) and font metrics into its segments, and layout_messages only rebuilds
-- an entry when its text, its role or the wrap width changes.  So changing the
-- theme (core.reload_module("colors.*")) or the font has to invalidate the
-- cache explicitly, otherwise the panel keeps drawing the old look until the
-- next message arrives.  The signature is a few tens of bytes of numbers built
-- once per frame while the panel is visible.
local function appearance_signature()
  local parts = {
    string.format("%.2f/%.2f", ai_font:get_size(), ai_font:get_height()),
    string.format("%d/%d", style.padding.x, style.padding.y),
  }
  for _, name in ipairs({ "text", "dim", "accent", "background", "background2", "selection" }) do
    local c = style[name]
    if c then
      parts[#parts + 1] = string.format("%d,%d,%d,%d", c[1], c[2], c[3], c[4] or 255)
    end
  end
  return table.concat(parts, "|")
end

function AIView:draw()
  if not self.visible then return end
  if self.size.x < 1 or self.size.y < 1 then return end
  -- theme/font changed since the layout was computed: throw it away so the
  -- rebuilt segments pick up the new colours and metrics
  local signature = appearance_signature()
  if signature ~= self._appearance_signature then
    self._appearance_signature = signature
    self._layout_cache = nil
    self._dirty = true
  end
  self:layout_messages()

  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local font = style.font
  local pad = style.padding
  local P = ai_palette()

  -- background: the dark editor background (NOT style.background2, which is
  -- the light treeview sidebar in some themes → light bg + light text =
  -- invisible messages), nudged a touch so the panel reads as its own surface.
  renderer.draw_rect(x, y, w, h, P.bg)
  self:_draw_header(P)

  -- message area
  local msg_x, msg_y, msg_w, msg_h = self:message_area()
  core.push_clip_rect(msg_x, msg_y, msg_w, msg_h)
  local offset_y = msg_y - self.scroll.y
  -- Normalize selection range for highlight drawing.
  local ns, ne
  if self._sel_start and self._sel_end
     and cmp_pos(self._sel_start, self._sel_end) ~= 0 then
    ns, ne = self._sel_start, self._sel_end
    if cmp_pos(ns, ne) > 0 then ns, ne = ne, ns end
  end
  for blk_idx, blk in ipairs(self._wrapped) do
    local block_y = offset_y + blk.y
    if block_y + blk.h >= msg_y and block_y <= msg_y + msg_h then
      -- Your messages and errors are cards; assistant replies stay flat on
      -- the panel so the (much longer) answers read as the main content.
      local is_card = is_card_role(blk.role)
      if is_card then
        local card_x, card_w = msg_x + math.floor(pad.x * 0.5), msg_w - pad.x
        if blk.role == "error" then
          draw_card(card_x, block_y, card_w, blk.h, math.floor(6 * SCALE),
            blend(P.bg, COLOR_ERROR, 0.1), blend(P.bg, COLOR_ERROR, 0.5))
        else
          draw_card(card_x, block_y, card_w, blk.h, math.floor(6 * SCALE),
            P.card, P.card_line)
        end
      end
      local label = ROLE_LABEL[blk.role]
      if label then
        renderer.draw_text(font, label, msg_x + pad.x + card_text_inset(),
          block_y + (blk.inset or 0), COLOR_ERROR)
      end
      local cum_y = block_y + blk.label_h
      if self.streaming and blk.role == "assistant" and blk.is_empty then
        local first = blk.rlines[1]
        renderer.draw_text(font, "▍", msg_x + pad.x,
          cum_y + (first and ((first.sp or 0) + (first.mt or 0)) or 0), COLOR_OK)
      else
        for rl_idx, rline in ipairs(blk.rlines) do
          local ly = rline_text_top(rline, cum_y)
          local sx = msg_x + pad.x + (rline.indent or 0)
          -- fenced-block / table background.  Previously each line drew its
          -- own rect with a translucent fill and a +1 merge hack; the +1 made
          -- adjacent rects overlap by 1px, and because the fill is translucent
          -- the overlap stacked alpha into a visible dark rule between every
          -- pair of code lines.  Now each rect covers exactly mt+h+mb with no
          -- +1: code-block body lines have sp=0 between them, so their rects
          -- abut exactly — no overlap (no stacked alpha), no seam.
          if rline.bg then
            local bg_x, bg_w = msg_x + math.floor(pad.x * 0.5), msg_w - pad.x
            if is_card then
              -- keep code blocks inside the card border
              local ci = math.floor(pad.x * 0.3)
              bg_x, bg_w = bg_x + ci, bg_w - ci * 2
            end
            if rline.table_w then
              bg_x, bg_w = msg_x + pad.x + (is_card and card_text_inset() or 0), rline.table_w
            end
            local bg_y = cum_y + (rline.sp or 0)
            local bg_h = math.max(1, (rline.mt or 0) + rline.h + (rline.mb or 0))
            renderer.draw_rect(bg_x, bg_y, bg_w, bg_h, rline.bg)
            -- accent strip down the left edge of a fenced block: the rects of
            -- bar + body lines abut, so the strips join into one line that
            -- ties the block together
            if rline.is_code_block then
              renderer.draw_rect(bg_x, bg_y, math.max(2, math.floor(2 * SCALE)),
                bg_h, with_alpha(style.accent or style.text, 170))
            end
          end
          -- table header rule
          if rline.is_table_rule then
            renderer.draw_rect(msg_x + pad.x + (rline.indent or 0), ly,
              rline.table_w or (msg_w - pad.x * 2),
              math.max(1, math.floor(1 * SCALE)), P.card_line)
          end
          -- blockquote left bar
          if rline.is_quote then
            renderer.draw_rect(msg_x + pad.x + math.floor(pad.x * 0.4), ly,
              math.max(1, math.floor(2 * SCALE)), rline.h, style.dim)
          end
          for sg_idx, seg in ipairs(rline.segments) do
            local seg_pad = seg.pad or 0
            -- inline `code` chip background
            if seg_pad > 0 and seg.bg then
              local chip_h = math.min(rline.h,
                seg.font:get_height() + math.floor(4 * SCALE))
              draw_round_rect(sx + (seg.off or 0), ly + math.floor((rline.h - chip_h) / 2),
                seg_advance(seg), chip_h, math.floor(3 * SCALE), seg.bg)
            end
            -- selection highlight (drawn before text so text sits on top)
            if ns then
              local sel = self:_seg_in_selection(blk_idx, rl_idx, sg_idx, seg, ns, ne)
              if sel then
                local text_x = seg_text_x(seg, sx)
                local sel_x, sel_w
                if sel == "all" then
                  sel_x, sel_w = text_x, seg.font:get_width(seg.text)
                else
                  sel_x = text_x + seg.font:get_width(seg.text:sub(1, sel[1] - 1))
                  sel_w = seg.font:get_width(seg.text:sub(sel[1], sel[2] - 1))
                end
                if sel_w > 0 then
                  renderer.draw_rect(sel_x, ly, sel_w, rline.h,
                    style.selection or style.accent)
                end
              end
            end
            renderer.draw_text(seg.font, seg.text, seg_text_x(seg, sx), ly, seg.color)
            -- link underline
            if seg.underline then
              local uw = seg.font:get_width(seg.text)
              renderer.draw_rect(seg_text_x(seg, sx),
                ly + math.min(rline.h, seg.font:get_height()) - 1,
                uw, math.max(1, math.floor(1 * SCALE)), with_alpha(seg.color, 150))
            end
            sx = sx + seg_advance(seg)
          end
          -- copy button, drawn on top of the bar
          if rline.is_code_bar then
            local bx, by, bw, bh = self:_copy_btn_rect(rline, msg_x, msg_w, ly)
            local hovered = (self._copy_hover == rline)
            local just = (self._copied_rline == rline)
              and (system.get_time() - (self._copied_at or 0) < 1.6)
            local label = just and COPY_LABEL_DONE or COPY_LABEL
            local color = just and COLOR_OK
              or (hovered and (style.accent or style.text) or style.dim)
            draw_round_rect(bx, by, bw, bh, math.floor(4 * SCALE),
              with_alpha(style.text, hovered and 46 or 24))
            renderer.draw_text(ai_font, label,
              bx + math.floor((bw - ai_font:get_width(label)) / 2),
              by + math.floor((bh - ai_font:get_height()) / 2), color)
          end
          cum_y = cum_y + rline_outer(rline)
        end
      end
    end
  end
  core.pop_clip_rect()

  self:_draw_input(P)
  self:draw_scrollbar()
end


-------------------------------------------------------------------------------
-- Commands & keymap
-------------------------------------------------------------------------------
local ai_view = nil

command.add(nil, {
  ["aichat:toggle"] = function()
    if not ai_view then return end
    ai_view.visible = not ai_view.visible
    if ai_view.visible then
      ai_view:ensure_mounted()
      core.set_active_view(ai_view)
    end
    core.redraw = true
  end,
  ["aichat:clear"] = function() if ai_view then ai_view:clear() end end,
  ["aichat:new-session"] = function() if ai_view then ai_view:new_session() end end,
  ["aichat:focus"] = function()
    if ai_view and ai_view.visible then core.set_active_view(ai_view) end
  end,
  ["aichat:abort"] = function() if ai_view then ai_view:abort_stream() end end,
  -- External entry point for quick actions: send a prefilled prompt (with the
  -- current file/selection context built by build_message) without the caller
  -- needing access to the local ai_view.  Used by context-menu quick actions.
  -- Stays silent when the panel is streaming so a misclick cannot pile on.
  ["aichat:ask"] = function(prompt)
    if not ai_view or not prompt or prompt == "" then return end
    if ai_view.streaming then return end
    -- Build the message while the editor still has focus (build_message reads
    -- the active DocView / its selection), then reveal the panel.
    local msg = ai_view:build_message(prompt)
    ai_view.visible = true
    ai_view:ensure_mounted()
    ai_view:_send(msg)
    core.set_active_view(ai_view)
    core.redraw = true
  end,
})

command.add(function()
  return core.active_view and core.active_view:is(AIView)
end, {
  ["aichat:submit"]    = function() if ai_view then ai_view:submit() end end,
  ["aichat:newline"]   = function() if ai_view then ai_view:insert_newline() end end,
  ["aichat:backspace"] = function() if ai_view then ai_view:backspace() end end,
  ["aichat:left"]      = function() if ai_view then ai_view:cursor_left() end end,
  ["aichat:right"]     = function() if ai_view then ai_view:cursor_right() end end,
  ["aichat:up"]        = function() if ai_view then ai_view:cursor_up() end end,
  ["aichat:down"]      = function() if ai_view then ai_view:cursor_down() end end,
  ["aichat:line-home"] = function() if ai_view then ai_view:line_home() end end,
  ["aichat:line-end"]  = function() if ai_view then ai_view:line_end() end end,
  ["aichat:delete-word-back"] = function() if ai_view then ai_view:delete_word_back() end end,
  ["aichat:delete-to-line-start"] = function() if ai_view then ai_view:delete_to_line_start() end end,
  ["aichat:copy"]      = function()
    if ai_view and ai_view:_has_selection() then
      local text = ai_view:_get_selected_text()
      if #text > 0 then
        system.set_clipboard(text)
        core.log("已复制 %d 字", #text)
      end
    end
  end,
})

keymap.add({
  ["ctrl+shift+a"] = "aichat:toggle",
  ["return"]       = "aichat:submit",
  ["shift+return"] = "aichat:newline",
  ["backspace"]    = "aichat:backspace",
  ["left"]         = "aichat:left",
  ["right"]        = "aichat:right",
  ["up"]           = "aichat:up",
  ["down"]         = "aichat:down",
  ["cmd+left"]     = "aichat:line-home",
  ["cmd+right"]    = "aichat:line-end",
  ["ctrl+left"]    = "aichat:line-home",
  ["ctrl+right"]   = "aichat:line-end",
  ["home"]         = "aichat:line-home",
  ["end"]          = "aichat:line-end",
  ["alt+backspace"]    = "aichat:delete-word-back",
  ["ctrl+backspace"]   = "aichat:delete-word-back",
  ["cmd+backspace"]    = "aichat:delete-to-line-start",
  ["cmd+c"]        = "aichat:copy",
  ["ctrl+c"]       = "aichat:copy",
})


-------------------------------------------------------------------------------
-- Floating action button (FAB): a small accent button pinned to the
-- bottom-right corner that toggles the AI panel from anywhere. It draws on
-- top of the root view and intercepts clicks in its own rect, mirroring the
-- RootView monkey-patching pattern used by core/dialog.lua.
-------------------------------------------------------------------------------
local fab_hover = false

-- Compute the button rect: pinned to the bottom-right of the EDITOR AREA
-- (the pane left of the AI panel and above the status bar), never overlapping
-- either.  ai_view.position.x tracks the panel's left edge (= editor right
-- edge) even when the panel is hidden (size.x→0 ⇒ position.x→window right).
local function fab_rect()
  local btn_size = math.floor(42 * SCALE)
  local btn_margin = math.floor(12 * SCALE)
  local rv = core.root_view
  local editor_right = (ai_view and ai_view.position and ai_view.position.x)
    or rv.size.x
  local editor_bottom = (core.status_view and core.status_view.position
    and core.status_view.position.y) or rv.size.y
  return editor_right - btn_size - btn_margin,
         editor_bottom - btn_size - btn_margin,
         btn_size, btn_size
end

local function fab_hit_test(x, y)
  local bx, by, bs = fab_rect()
  return x >= bx and x < bx + bs and y >= by and y < by + bs
end

local function draw_fab()
  if not ai_view then return end
  local bx, by, bs = fab_rect()
  local accent = style.accent or { 166, 226, 46, 255 }
  local glyph = style.background          -- dark glyph on green body
  local S = SCALE
  local radius = math.floor(11 * S)

  -- hover halo (soft glow behind the button)
  if fab_hover then
    draw_round_rect(bx - math.floor(4 * S), by - math.floor(4 * S),
      bs + math.floor(8 * S), bs + math.floor(8 * S),
      radius + math.floor(4 * S), with_alpha(accent, 50))
  end

  -- body
  draw_round_rect(bx, by, bs, bs, radius,
    with_alpha(accent, fab_hover and 255 or 232))

  -- ── chat-bubble glyph (composed entirely from rects) ──────────────
  --  ┌────────────────────┐
  --  │  •  •  •           │   ← three message dots
  --  └──┐                 │
  --     └──┐              │   ← 2-step tail (stair going down-left)
  --        └──┐
  -- The bubble body is dark (glyph); the dots are accent-green (same as
  -- the button body) so they read as cutouts — the classic "typing…"
  -- chat indicator. Universally reads as "chat / message".

  local bub_x = bx + math.floor(8  * S)
  local bub_y = by + math.floor(7  * S)
  local bub_w = math.floor(26 * S)
  local bub_h = math.floor(19 * S)

  -- bubble body (rounded)
  draw_round_rect(bub_x, bub_y, bub_w, bub_h, math.floor(5 * S), glyph)

  -- tail: 2-step stair descending from the bottom-left of the bubble
  local tail_w = math.floor(5 * S)
  local tail_h = math.floor(3 * S)
  renderer.draw_rect(bub_x + math.floor(3 * S), bub_y + bub_h,
    tail_w, tail_h, glyph)
  renderer.draw_rect(bub_x, bub_y + bub_h + tail_h,
    tail_w, tail_h, glyph)

  -- three message dots, centered inside the bubble
  local dot_s  = math.floor(4 * S)
  local pitch  = math.floor(6 * S)          -- center-to-center spacing
  local dtotal = 2 * pitch + dot_s
  local dot_x0 = bub_x + math.floor((bub_w - dtotal) / 2)
  local dot_yc = bub_y + math.floor((bub_h - dot_s) / 2)
  for i = 0, 2 do
    renderer.draw_rect(dot_x0 + i * pitch, dot_yc, dot_s, dot_s, accent)
  end

  -- ── close badge (only when panel is open) ─────────────────────────
  -- A small dark rounded-rect with "×" in the top-right corner, like a
  -- notification badge. The chat icon stays visible so the button is
  -- always recognisable; the badge just signals "click to close".
  if ai_view.visible then
    local bgs = math.floor(14 * S)
    local bgx = bx + bs - bgs - math.floor(2 * S)
    local bgy = by + math.floor(2 * S)
    draw_round_rect(bgx, bgy, bgs, bgs, math.floor(4 * S), glyph)
    common.draw_text(style.font, accent, "×", "center", bgx, bgy, bgs, bgs)
  end
end

-- Hook RootView.draw to paint the FAB on top of everything.
local old_root_draw = RootView.draw
function RootView:draw(...)
  old_root_draw(self, ...)
  draw_fab()
end

-- Hook RootView.on_mouse_pressed to handle button clicks.
local old_root_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and fab_hit_test(x, y) then
    if ai_view then
      ai_view.visible = not ai_view.visible
      if ai_view.visible then
        ai_view:ensure_mounted()
        core.set_active_view(ai_view)
      end
      core.redraw = true
    end
    return true
  end
  return old_root_mouse_pressed(self, button, x, y, clicks)
end

-- Hook RootView.on_mouse_moved to track hover and show a hand cursor.
-- The cursor request is issued AFTER the original handler so it wins over
-- any cursor the view under the pointer requested.
local old_root_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  local over = fab_hit_test(x, y)
  if over ~= fab_hover then
    fab_hover = over
    core.redraw = true
  end
  local r = old_root_mouse_moved(self, x, y, dx, dy)
  if over then core.request_cursor("hand") end
  return r
end


-------------------------------------------------------------------------------
-- Mount: dock to the right of the active node (resizable + toggleable).
-------------------------------------------------------------------------------
ai_view = AIView()
local ok, merr = pcall(function()
  local node = core.root_view:get_active_node()
  ai_view.node = node:split("right", ai_view, { x = true }, true)
end)
if not ok then
  core.log("aichat: panel mount failed: " .. tostring(merr))
end
