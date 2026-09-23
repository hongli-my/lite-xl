-- mod-version:2
-- Shared helpers for fork plugins (OS open, color, text metrics).
--
-- Extracted from data/plugins/aichat.lua and data/plugins/markdown_preview.lua
-- so the two markdown renderers stop carrying their own copies. Kept as a
-- separate core module (rather than appended to core.common) so that merging
-- upstream stays conflict-free, mirroring the core.fork_defaults convention.
--
-- Everything here is pure / side-effect free except open_url / open_path,
-- which shell out to the OS handler.

local style = require "core.style"
local core  = require "core"

local util = {}

-------------------------------------------------------------------------------
-- OS open helpers
-------------------------------------------------------------------------------

-- POSIX single-quote shell escape; safe against shell metacharacters.
function util.shell_escape(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Open a URL in the OS default handler.  The scheme is whitelisted because a
-- URL may come from untrusted text (e.g. a model message); refusing unknown
-- schemes prevents shell injection via crafted URLs.
function util.open_url(url)
  if not (url:match("^https?://") or url:match("^mailto:")
          or url:match("^file://") or url:match("^ftp://")) then
    core.log("Refused to open unsafe link: %s", url)
    return
  end
  if PLATFORM == "macOS" or PLATFORM == "Mac OS X" then
    os.execute("open " .. util.shell_escape(url) .. " 2>/dev/null")
  elseif PLATFORM == "Linux" then
    os.execute("xdg-open " .. util.shell_escape(url) .. " 2>/dev/null")
  elseif PLATFORM == "Windows" then
    os.execute('start "" "' .. url:gsub('"', '') .. '"')
  end
end

-- Reveal / open a local path in the OS handler (Finder / xdg-open / explorer).
function util.open_path(path)
  if PLATFORM == "macOS" or PLATFORM == "Mac OS X" then
    os.execute("open " .. util.shell_escape(path) .. " 2>/dev/null")
  elseif PLATFORM == "Linux" then
    os.execute("xdg-open " .. util.shell_escape(path) .. " 2>/dev/null")
  elseif PLATFORM == "Windows" then
    os.execute('start "" "' .. path:gsub('"', '') .. '"')
  end
end

-------------------------------------------------------------------------------
-- Color helpers
-------------------------------------------------------------------------------

-- Linear blend of two colors; alpha is taken from c1 (255 if unset).
function util.blend(c1, c2, t)
  return {
    math.floor((c1[1] or 0) + ((c2[1] or 0) - (c1[1] or 0)) * t),
    math.floor((c1[2] or 0) + ((c2[2] or 0) - (c1[2] or 0)) * t),
    math.floor((c1[3] or 0) + ((c2[3] or 0) - (c1[3] or 0)) * t),
    c1[4] or 255,
  }
end

-- Return a copy of color c with the given alpha (0-255).
function util.with_alpha(c, a)
  return { c[1] or 0, c[2] or 0, c[3] or 0, a }
end

-- Relative luminance of an {r,g,b[,a]} color in 0..1.
function util.luminance(c)
  return (c[1] * 0.299 + c[2] * 0.587 + c[3] * 0.114) / 255
end

-- Whether the current theme background is dark. Used to pick readable overlay
-- colors (code blocks, tables, ...) that adapt to light/dark themes.
function util.is_dark()
  return util.luminance(style.background) < 0.5
end

-------------------------------------------------------------------------------
-- Text metrics
-------------------------------------------------------------------------------

-- Advance the byte index `pos` to the start of the next UTF-8 code point.
local function utf8_next(s, pos)
  local p = pos + 1
  while p <= #s and s:byte(p) >= 0x80 and s:byte(p) < 0xC0 do p = p + 1 end
  return p
end

-- Truncate `text` to fit within `max_w` pixels (in `font`), appending an
-- ellipsis "…". UTF-8 aware: never splits a multi-byte character. Replaces the
-- two diverging copies that lived in aichat.lua (linear scan) and
-- markdown_preview.lua (binary search over byte sub, which could cut a
-- multi-byte char in half and report a wrong width).
function util.truncate_to_width(font, text, max_w)
  if max_w <= 0 then return "" end
  if font:get_width(text) <= max_w then return text end
  local ell = "…"
  local ell_w = font:get_width(ell)
  if max_w <= ell_w then return ell end
  local out, cur = "", 0
  local p = 1
  while p <= #text do
    local nxt = utf8_next(text, p)
    local ch = text:sub(p, nxt - 1)
    local cw = font:get_width(ch)
    if cur + cw + ell_w > max_w then break end
    out = out .. ch
    cur = cur + cw
    p = nxt
  end
  return out .. ell
end

return util
