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

-------------------------------------------------------------------------------
-- Minimal JSON (encode + decode) — core has no JSON module.
-------------------------------------------------------------------------------
local json = {}

local function json_escape(s)
  local map = {
    ['\\'] = '\\\\',
    ['"']  = '\\"',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
  }
  s = s:gsub('[\\"\n\r\t]', map)
  s = s:gsub('[%z\1-\31]', function(c)
    return string.format('\\u%04x', c:byte())
  end)
  return s
end

local function json_encode(value)
  local t = type(value)
  if t == "string" then
    return '"' .. json_escape(value) .. '"'
  elseif t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return string.format("%.14g", value)
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    local is_array = true
    local count = 0
    for k in pairs(value) do
      count = count + 1
      if type(k) ~= "number" then is_array = false; break end
    end
    if count == 0 then return "{}" end
    local parts = {}
    if is_array then
      for i = 1, #value do parts[i] = json_encode(value[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, v in pairs(value) do
        parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(v)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local decode_value
local function decode_whitespace(s, pos)
  while pos <= #s and s:byte(pos) <= 32 do pos = pos + 1 end
  return pos
end
local function decode_string(s, pos)
  pos = pos + 1 -- skip opening quote
  local buf = {}
  while pos <= #s do
    local b = s:byte(pos)
    if b == 34 then -- closing quote
      return table.concat(buf), pos + 1
    elseif b == 92 then -- backslash escape
      pos = pos + 1
      local c = s:byte(pos)
      if c == 110 then buf[#buf+1] = "\n"
      elseif c == 114 then buf[#buf+1] = "\r"
      elseif c == 116 then buf[#buf+1] = "\t"
      elseif c == 98 then buf[#buf+1] = "\b"
      elseif c == 102 then buf[#buf+1] = "\f"
      elseif c == 34 then buf[#buf+1] = '"'
      elseif c == 92 then buf[#buf+1] = "\\"
      elseif c == 47 then buf[#buf+1] = "/" -- '/'
      elseif c == 117 then -- 'u' followed by 4 hex digits
        local hex = s:sub(pos+1, pos+4)
        local code = tonumber(hex, 16)
        pos = pos + 4
        if code then
          if code < 0x80 then
            buf[#buf+1] = string.char(code)
          elseif code < 0x800 then
            buf[#buf+1] = string.char(0xC0 + math.floor(code/64), 0x80 + code%64)
          else
            buf[#buf+1] = string.char(0xE0 + math.floor(code/4096),
                                    0x80 + math.floor(code/64)%64,
                                    0x80 + code%64)
          end
        end
      else
        buf[#buf+1] = string.char(c)
      end
      pos = pos + 1
    else
      buf[#buf+1] = string.char(b)
      pos = pos + 1
    end
  end
  error("unterminated string")
end
local function decode_number(s, pos)
  local start = pos
  if s:byte(pos) == 45 then pos = pos + 1 end -- '-'
  while pos <= #s do
    local c = s:byte(pos)
    if (c >= 48 and c <= 57) or c == 46 or c == 101 or c == 69 or c == 43 or c == 45 then
      pos = pos + 1
    else break end
  end
  return tonumber(s:sub(start, pos - 1)), pos
end
decode_value = function(s, pos)
  pos = decode_whitespace(s, pos)
  local c = s:byte(pos)
  if c == 34 then -- '"'
    return decode_string(s, pos)
  elseif c == 123 then -- '{'
    pos = pos + 1
    local obj = {}
    pos = decode_whitespace(s, pos)
    if s:byte(pos) == 125 then return obj, pos + 1 end -- '}'
    while true do
      pos = decode_whitespace(s, pos)
      local key, kpos = decode_string(s, pos)
      pos = kpos
      pos = decode_whitespace(s, pos)
      if s:byte(pos) ~= 58 then error("expected ':'") end -- ':'
      pos = pos + 1
      local val
      val, pos = decode_value(s, pos)
      obj[key] = val
      pos = decode_whitespace(s, pos)
      local sep = s:byte(pos)
      if sep == 44 then pos = pos + 1 -- ','
      elseif sep == 125 then return obj, pos + 1 -- '}'
      else error("expected ',' or '}'") end
    end
  elseif c == 91 then -- '['
    pos = pos + 1
    local arr = {}
    pos = decode_whitespace(s, pos)
    if s:byte(pos) == 93 then return arr, pos + 1 end -- ']'
    local idx = 1
    while true do
      local val
      val, pos = decode_value(s, pos)
      arr[idx] = val
      idx = idx + 1
      pos = decode_whitespace(s, pos)
      local sep = s:byte(pos)
      if sep == 44 then pos = pos + 1 -- ','
      elseif sep == 93 then return arr, pos + 1 -- ']'
      else error("expected ',' or ']'") end
    end
  elseif c == 45 or (c >= 48 and c <= 57) then -- '-' or digit
    return decode_number(s, pos)
  elseif c == 116 then return true, pos + 4 -- 'true'
  elseif c == 102 then return false, pos + 5 -- 'false'
  elseif c == 110 then return nil, pos + 4 -- 'null'
  else error("unexpected character at position " .. pos) end
end
function json.decode(s)
  if not s or s == "" then return nil end
  local val = decode_value(s, 1)
  return val
end
json.encode = json_encode


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
local function wrap_segments(segs, max_width)
  -- tokenise on whitespace, keeping the trailing space attached to its token;
  -- a token continues into the next segment when it did not end on a space
  local tokens = {}
  for _, seg in ipairs(segs) do
    local text = seg.text
    local p = 1
    while p <= #text do
      local sp, ep = text:find("%S+%s*", p)
      if not sp then break end
      local last = tokens[#tokens]
      if not (last and last.open) then
        last = { pieces = {}, w = 0 }
        tokens[#tokens + 1] = last
      end
      local piece = text:sub(sp, ep)
      last.pieces[#last.pieces + 1] = { text = piece, seg = seg }
      last.w = last.w + seg.font:get_width(piece)
      last.open = not piece:match("%s$")
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

-- Blend two {r,g,b,a} colors: t=0 -> c1, t=1 -> c2. Alpha taken from c1.
local function blend(c1, c2, t)
  return {
    math.floor((c1[1] or 0) + ((c2[1] or 0) - (c1[1] or 0)) * t),
    math.floor((c1[2] or 0) + ((c2[2] or 0) - (c1[2] or 0)) * t),
    math.floor((c1[3] or 0) + ((c2[3] or 0) - (c1[3] or 0)) * t),
    c1[4] or 255,
  }
end

-- Return a copy of color c with the given alpha (0-255).
local function with_alpha(c, a)
  return { c[1] or 0, c[2] or 0, c[3] or 0, a }
end

-- Open a link from the panel: POSIX-escaped, scheme whitelisted (a message is
-- untrusted text, it arrives from the model).
local function shell_escape(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function open_url(url)
  if not (url:match("^https?://") or url:match("^mailto:") or url:match("^ftp://")) then
    core.log("拒绝打开不安全的链接: %s", url)
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

-- Advance width of a segment, including any inline-chip padding.
local function seg_advance(seg)
  return seg.font:get_width(seg.text) + (seg.pad or 0) * 2
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
      local url = text:match("^[^%s]+", i):gsub("[%.,;:!%)%]]+$", "")
      flush()
      segments[#segments + 1] = {
        text = url, font = base_font,
        color = style.accent or base_color,
        link = url:match("^www%.") and ("https://" .. url) or url,
        underline = true,
      }
      i = i + #url
    -- **bold** or __bold__
    elseif (c == 42 and text:byte(i + 1) == 42) or (c == 95 and text:byte(i + 1) == 95) then
      local delim = text:sub(i, i + 1)
      local close = text:find(delim, i + 2, true)
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
    elseif c == 95 then
      local close = text:find("_", i + 1, true)
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

-- Layout markdown text into render lines.  Each render line is:
--   { segments, h, sp, mt, mb, is_code_block, is_code_bar, is_header, indent,
--     bg, is_quote }
-- See rline_outer()/rline_text_top() for how the vertical fields add up.
local function layout_md(text, max_width)
  local rlines = {}
  local pad_x = style.padding.x
  local lh = math.floor(ai_font:get_height() * 1.32)
  local code_lh = math.floor(md_code_font:get_height() * 1.3)
  local code_bg = with_alpha(style.text, 26)
  local code_bar_bg = with_alpha(style.text, 44)
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

  local in_code_block = false
  local code_lang
  local code_bar_idx
  local code_lines
  local last_code_idx

  -- Emit one line of a fenced block.  The bar is emitted when the block opens so
  -- a copy button is available even without a language tag; it is dropped again
  -- if the block turns out to be empty (see the closing fence).
  local function emit_code_line(code_line)
    local avail_w = max_width - code_indent - pad_x
    for _, wline in ipairs(wrap_text(code_line, md_code_font, avail_w)) do
      add_rline({ { text = wline, font = md_code_font, color = style.text } },
        code_lh,
        { is_code_block = true, bg = code_bg, indent = code_indent,
          mt = (last_code_idx == nil) and code_pad_y or 0 })
      last_code_idx = #rlines
    end
    code_lines[#code_lines + 1] = code_line
  end

  for _, line in ipairs(raw_lines) do
    -- Fenced code block toggle; the part after ``` is the language tag
    local info = line:match("^%s*```%s*(.-)%s*$")
    if info then
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
        pending_gap = math.max(pending_gap, para_gap)  -- gap after the block
      else
        in_code_block = true
        code_lang = (info ~= "") and info or nil
        code_lines = {}
        last_code_idx = nil
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
  self.input_height = math.floor(style.font:get_height() * 3 + style.padding.y * 2)
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
  return style.font:get_height() + style.padding.y * 2
end

function AIView:message_area()
  local x = self.position.x
  local y = self.position.y + self:header_height()
  local w = self.size.x
  local h = self.size.y - self:header_height() - self.input_height
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
local ROLE_LABEL = { user = "你", system = "系统", error = "错误" }

local function role_label_height(role, lh)
  if not ROLE_LABEL[role] then return 0 end
  return lh + math.floor(style.padding.y * 0.5)
end

-- Wrapped render lines of a single message.  Markdown for everything the user
-- or the agent writes — user messages carry the "[当前文件] …" header and the
-- selected-code fence injected by build_message, so they need it too.  Only
-- system notices stay plain.
local function message_rlines(msg, font, lh, text_w)
  if msg.role == "system" then
    local rlines = {}
    for _, line in ipairs(wrap_text(msg.content, font, text_w)) do
      rlines[#rlines + 1] = {
        segments = { { text = line, font = font, color = style.text } },
        h = lh, indent = 0,
      }
    end
    return rlines
  end
  return layout_md(msg.content, text_w)
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
  local y = 0
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
          local rel_x = x - seg_x - (seg.pad or 0)
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
function AIView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local nbx, nby, nbw, nbh = self:new_btn_rect()
    if x >= nbx - math.floor(4 * SCALE) and x < nbx + nbw + math.floor(4 * SCALE)
       and y >= nby - math.floor(2 * SCALE) and y < nby + nbh + math.floor(2 * SCALE) then
      self:new_session()
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
  local nbx, nby, nbw, nbh = self:new_btn_rect()
  local over = x >= nbx - math.floor(4 * SCALE) and x < nbx + nbw + math.floor(4 * SCALE)
       and y >= nby - math.floor(2 * SCALE) and y < nby + nbh + math.floor(2 * SCALE)
  if over ~= self._new_btn_hover then
    self._new_btn_hover = over
    core.redraw = true
  end
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
  self._selecting = false
  self._copy_hover = nil
  self._link_hover = nil
  AIView.super.on_mouse_left(self)
end

function AIView:supports_text_input() return true end

-- Compute the screen-space caret position in the input box (used for IME).
-- Mirrors the logic in _draw_caret but returns coordinates instead of drawing.
function AIView:_caret_screen_pos()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local pad = style.padding
  local lh = style.font:get_height()
  local input_y = y + h - self.input_height
  local itext_x = x + pad.x
  local itext_y = input_y + pad.y
  -- account for streaming spinner offset
  if self.streaming then
    local spinner_r = math.floor(7 * SCALE)
    itext_x = itext_x + spinner_r * 2 + math.floor(6 * SCALE)
  end
  -- split input into lines, find which line the caret is on
  local s = self.input
  local lines = {}
  local i, n = 1, #s
  while i <= n do
    local j = i
    while j <= n and s:byte(j) ~= 10 do j = j + 1 end
    lines[#lines + 1] = s:sub(i, j - 1)
    i = j + 1
  end
  if #lines == 0 then lines = {""} end
  local target = self.caret
  local line_idx, col = 1, 1
  local acc = 0
  for li, line in ipairs(lines) do
    local line_start = acc + 1
    local line_end = acc + #line
    if target >= line_start and target <= line_end + 1 then
      line_idx, col = li, target - line_start + 1
      break
    end
    acc = acc + #line + 1
  end
  local before = (lines[line_idx] or ""):sub(1, col - 1)
  local cx = itext_x + style.font:get_width(before)
  local cy = itext_y + (line_idx - 1) * lh
  return cx, cy, lh
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
function AIView:new_btn_rect()
  local font = style.font
  local label = "＋ 新对话"
  local lw = font:get_width(label)
  local pad = style.padding
  local bx = self.position.x + self.size.x - pad.x - lw
  local by = self.position.y + pad.y
  local bw = lw
  local bh = font:get_height()
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
    if (ae.type == "text_delta" or ae.type == "thinking_delta") and ae.delta then
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

function AIView:_send_pibridge(assistant_idx, user_text)
  local cfg = config.plugins.aichat
  core.add_thread(function()
    -- 1. ensure session
    local session_id, serr = self:_ensure_session()
    if not session_id then
      self.messages[assistant_idx].role = "error"
      self.messages[assistant_idx].content = serr or "无法创建会话"
      self.streaming = false
      self._dirty = true
      core.redraw = true
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
      self.messages[assistant_idx].role = "error"
      self.messages[assistant_idx].content = "curl 启动失败: " .. tostring(proc)
      self.streaming = false
      self._dirty = true
      core.redraw = true
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
      self.messages[assistant_idx].role = "error"
      self.messages[assistant_idx].content = "请求发送失败: " .. tostring(werr)
      self.streaming = false
      self._stream_proc = nil
      self._dirty = true
      core.redraw = true
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
    self.messages[assistant_idx].role = "error"
    self.messages[assistant_idx].content =
      "No API key set. Set OPENAI_API_KEY env var or config.plugins.aichat.api_key."
    self.streaming = false
    self._dirty = true
    core.redraw = true
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
      self.messages[assistant_idx].role = "error"
      self.messages[assistant_idx].content = "Failed to start curl: " .. tostring(proc)
      self.streaming = false
      self._dirty = true
      core.redraw = true
      return
    end

    local wok, werr = pcall(function()
      proc.stdin:write(body)
      proc.stdin:close()
    end)
    if not wok then
      self.messages[assistant_idx].role = "error"
      self.messages[assistant_idx].content = "Failed to send request: " .. tostring(werr)
      self.streaming = false
      self._dirty = true
      core.redraw = true
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
function AIView:_input_wrapped(width)
  return wrap_text(self.input, style.font, width)
end

function AIView:_draw_caret(x, y, width, lh)
  local s = self.input
  local lines = {}
  local i = 1
  local n = #s
  while i <= n do
    local j = i
    while j <= n and s:byte(j) ~= 10 do j = j + 1 end
    lines[#lines + 1] = s:sub(i, j - 1)
    i = j + 1
  end
  if #lines == 0 then lines = {""} end

  local target = self.caret
  local line_idx = 1
  local col = 1
  local acc = 0
  for li, line in ipairs(lines) do
    local line_start = acc + 1
    local line_end = acc + #line
    if target >= line_start and target <= line_end + 1 then
      line_idx = li
      col = target - line_start + 1
      break
    end
    acc = acc + #line + 1
  end

  local caret_line = lines[line_idx] or ""
  local before = caret_line:sub(1, col - 1)
  local cx = x + style.font:get_width(before)
  local cy = y + (line_idx - 1) * lh
  renderer.draw_rect(cx, cy, style.caret_width, lh, style.caret or style.text)
end

function AIView:draw()
  if not self.visible then return end
  if self.size.x < 1 or self.size.y < 1 then return end
  self:layout_messages()

  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local font = style.font
  local lh = font:get_height()
  local pad = style.padding

  -- background: use the dark editor background (NOT style.background2, which is
  -- the light treeview sidebar in some themes e.g. monokai → light bg + light
  -- text = invisible messages). Blend a touch toward background2 so the panel
  -- reads as subtly distinct from the editor behind it.
  local panel_bg = blend(style.background, style.background2, 0.05)
  renderer.draw_rect(x, y, w, h, panel_bg)

  -- header
  local hh = self:header_height()
  common.draw_text(font, style.dim, "AI Chat",
    "left", x + pad.x, y + pad.y, w - pad.x * 2, lh)
  -- "新对话" button (right-aligned in header)
  local nbx, nby, nbw, nbh, nlabel = self:new_btn_rect()
  if self._new_btn_hover then
    renderer.draw_rect(nbx - math.floor(4 * SCALE), nby - math.floor(2 * SCALE),
      nbw + math.floor(8 * SCALE), nbh + math.floor(4 * SCALE),
      with_alpha(style.accent or style.text, 40))
  end
  renderer.draw_text(font, nlabel, nbx, nby,
    self._new_btn_hover and (style.accent or style.text) or style.dim)
  if self.streaming then
    -- streaming indicator sits left of the new-session button
    local sw = font:get_width("● 生成中… (Enter 停止)")
    common.draw_text(font, COLOR_OK, "● 生成中… (Enter 停止)",
      "right", x + pad.x, y + pad.y, w - pad.x * 2 - nbw - math.floor(12 * SCALE), lh)
  end
  renderer.draw_rect(x, y + hh - style.divider_size, w, style.divider_size, style.divider)

  -- message area
  local msg_x, msg_y, msg_w, msg_h = self:message_area()
  core.push_clip_rect(msg_x, msg_y, msg_w, msg_h)
  local offset_y = msg_y - self.scroll.y
  local strip_w = math.max(2, math.floor(3 * SCALE))
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
      -- Hairline between turns, drawn in the gap above a "你" block: with the
      -- role labels gone from assistant replies this is what makes the turn
      -- boundary readable at a glance.
      if blk.role == "user" and blk.gap > 0 then
        renderer.draw_rect(msg_x + pad.x, block_y - math.floor(blk.gap * 0.5),
          msg_w - pad.x * 2, style.divider_size, style.divider)
      end
      -- subtle per-message bubble: user messages get a faint selection tint,
      -- errors a faint red wash; assistant/system stay clean for contrast.
      local bubble
      if blk.role == "user" then
        bubble = with_alpha(style.selection or style.background, 70)
      elseif blk.role == "error" then
        bubble = with_alpha(COLOR_ERROR, 28)
      end
      if bubble then
        renderer.draw_rect(msg_x + math.floor(pad.x * 0.5), block_y + 1,
          msg_w - pad.x, math.max(0, blk.h - 2), bubble)
      end
      local role_color
      if blk.role == "user" then role_color = style.accent
      elseif blk.role == "error" then role_color = COLOR_ERROR
      else role_color = style.dim end
      -- The strip marks the blocks that are not plain agent output (your turn,
      -- an error).  Assistant replies get neither strip nor label.
      if blk.role == "user" or blk.role == "error" then
        renderer.draw_rect(msg_x, block_y + 2, strip_w, math.max(0, blk.h - 4), role_color)
      end
      local cum_y = block_y
      local label = ROLE_LABEL[blk.role]
      if label and blk.label_h > 0 then
        renderer.draw_text(font, label, msg_x + pad.x, block_y, role_color)
        cum_y = block_y + blk.label_h
      end
      if self.streaming and blk.role == "assistant" and blk.is_empty then
        local first = blk.rlines[1]
        renderer.draw_text(font, "▍", msg_x + pad.x,
          cum_y + (first and ((first.sp or 0) + (first.mt or 0)) or 0), COLOR_OK)
      else
        for rl_idx, rline in ipairs(blk.rlines) do
          local ly = rline_text_top(rline, cum_y)
          local sx = msg_x + pad.x + (rline.indent or 0)
          -- fenced-block background: covers the line's own padding (so the text
          -- is not flush with the edge) but not the gap in front of the block;
          -- +1 merges with the neighbouring line's rect
          if rline.bg then
            renderer.draw_rect(msg_x + math.floor(pad.x * 0.5), cum_y + (rline.sp or 0),
              msg_w - pad.x, math.max(1, (rline.mt or 0) + rline.h + (rline.mb or 0) + 1),
              rline.bg)
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
              renderer.draw_rect(sx, ly + math.floor((rline.h - chip_h) / 2),
                seg_advance(seg), chip_h, seg.bg)
            end
            -- selection highlight (drawn before text so text sits on top)
            if ns then
              local sel = self:_seg_in_selection(blk_idx, rl_idx, sg_idx, seg, ns, ne)
              if sel then
                local sel_x, sel_w
                if sel == "all" then
                  sel_x, sel_w = sx, seg_advance(seg)
                else
                  sel_x = sx + seg_pad + seg.font:get_width(seg.text:sub(1, sel[1] - 1))
                  sel_w = seg.font:get_width(seg.text:sub(sel[1], sel[2] - 1))
                end
                if sel_w > 0 then
                  renderer.draw_rect(sel_x, ly, sel_w, rline.h,
                    style.selection or style.accent)
                end
              end
            end
            renderer.draw_text(seg.font, seg.text, sx + seg_pad, ly, seg.color)
            -- link underline
            if seg.underline then
              local uw = seg.font:get_width(seg.text)
              renderer.draw_rect(sx + seg_pad,
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
            renderer.draw_rect(bx, by, bw, bh,
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

  -- input box: recessed (pure dark editor bg) so it reads as a distinct zone
  -- below the slightly-lighter message area.
  local input_y = y + h - self.input_height
  renderer.draw_rect(x, input_y, w, self.input_height, style.background)
  renderer.draw_rect(x, input_y, w, style.divider_size, style.divider)

  local itext_x = x + pad.x
  local itext_y = input_y + pad.y
  local itext_w = w - pad.x * 2

  -- Animated spinner at the left of the input box while streaming; shifts
  -- the text/placeholder right so they don't overlap.
  if self.streaming then
    local spinner_r = math.floor(7 * SCALE)
    local spinner_cx = itext_x + spinner_r
    local spinner_cy = itext_y + math.floor(lh / 2)
    draw_spinner(spinner_cx, spinner_cy, spinner_r, style.accent)
    local spinner_total = spinner_r * 2 + math.floor(6 * SCALE)
    itext_x = itext_x + spinner_total
    itext_w = itext_w - spinner_total
  end

  if self.input == "" then
    common.draw_text(font, style.dim,
      "输入消息…  Enter: 发送/停止  Shift+Enter: 换行",
      "left", itext_x, itext_y, itext_w, lh)
  else
    local lines = self:_input_wrapped(itext_w)
    for j, line in ipairs(lines) do
      renderer.draw_text(font, line, itext_x, itext_y + (j - 1) * lh, style.text)
    end
  end

  -- blink the caret (reuses lite-xl's core.blink_* system, same condition as
  -- DocView:draw): visible for the first half of each blink_period.
  if core.active_view == self then
    local T = config.blink_period or 0.8
    if config.disable_blink
       or (core.blink_timer - core.blink_start) % T < T / 2 then
      self:_draw_caret(itext_x, itext_y, itext_w, lh)
    end
  end

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
})

command.add(function()
  return core.active_view and core.active_view:is(AIView)
end, {
  ["aichat:submit"]    = function() if ai_view then ai_view:submit() end end,
  ["aichat:newline"]   = function() if ai_view then ai_view:insert_newline() end end,
  ["aichat:backspace"] = function() if ai_view then ai_view:backspace() end end,
  ["aichat:left"]      = function() if ai_view then ai_view:cursor_left() end end,
  ["aichat:right"]     = function() if ai_view then ai_view:cursor_right() end end,
  ["aichat:up"]        = function() if ai_view then ai_view:scroll_up() end end,
  ["aichat:down"]      = function() if ai_view then ai_view:scroll_down() end end,
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

-- Rounded rectangle built from axis-aligned rects only (renderer has no
-- round-rect primitive): chamfer the four corners, leaving the corner pixels
-- transparent so the content behind shows through for a soft rounded look.
local function draw_round_rect(x, y, w, h, radius, color)
  radius = math.min(radius, math.floor(w / 2), math.floor(h / 2))
  if radius < 1 then
    renderer.draw_rect(x, y, w, h, color)
    return
  end
  renderer.draw_rect(x, y + radius, w, h - radius * 2, color)
  renderer.draw_rect(x + radius, y, w - radius * 2, radius, color)
  renderer.draw_rect(x + radius, y + h - radius, w - radius * 2, radius, color)
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
