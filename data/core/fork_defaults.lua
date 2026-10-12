-- Defaults that are specific to this fork.
--
-- Everything the fork changes about the out-of-the-box behaviour is kept in
-- this one file, so that merging upstream stays a one-line conflict on the
-- `require "core.fork_defaults"` in data/core/init.lua instead of a diff
-- spread over style/config/colors.
--
-- It is loaded before the plugins and before the user module
-- (USERDIR/init.lua), so all of it can still be overridden from the user
-- module, and per project from .lite_project.lua.

local config = require "core.config"
local style = require "core.style"

-------------------------------------------------------------------------------
-- Theme
-------------------------------------------------------------------------------
-- Monokai palette with a light sidebar.  Use
-- `core.reload_module("colors.default")` in the user module for the upstream
-- look, or `core.reload_module("colors.<name>")` for another scheme.
require "colors.slate"

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------
-- Bordered window: the native macOS title bar (with the traffic lights)
-- stays; the custom title view is only shown borderless.
config.borderless = false

-- Do not allow scrolling past the end of the document.
config.scroll_past_end = false

-- Soft-wrap lines that are wider than the view instead of letting them run off
-- the right edge.  This is the `linewrapping` plugin's default; toggle it for
-- the current view with F10 (`line-wrapping:toggle`) and override it per
-- project from `.lite_project.lua`.
config.plugins.linewrapping = {
  enable_by_default = true,
}

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------
local is_macos = PLATFORM == "macOS" or PLATFORM == "Mac OS X"
local fonts_dir = (rawget(_G, "MACOS_RESOURCES") or DATADIR) .. "/fonts"

---Loads a font file, returning nil instead of raising when it cannot be
---loaded.  A default must not break startup just because a system font is
---missing on this machine.
---@return table|nil
local function try_font(path, size, opts)
  if not path then return nil end
  local ok, font = pcall(renderer.font.load, path, size, opts)
  if ok then return font end
end

---Returns the first font of `paths` that can be loaded.
local function first_font(paths, size, opts)
  for _, path in ipairs(paths) do
    local font = try_font(path, size, opts)
    if font then return font end
  end
end

-- The bundled fonts have no CJK glyphs, so a system font that does is appended
-- to both font groups below.
local system_fonts = is_macos and {
  "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
  "/System/Library/Fonts/PingFang.ttc",
} or PLATFORM == "Windows" and {
  "C:/Windows/Fonts/msyh.ttc",
  "C:/Windows/Fonts/simsun.ttc",
} or {
  "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
  "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
  "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
}
local cjk = first_font(system_fonts, 14 * SCALE)

-- Colour emoji: enabled on macOS only.  Apple Color Emoji is an sbix bitmap
-- font that the renderer handles directly (see FT_LOAD_COLOR in
-- src/renderer.c), while the Noto Color Emoji builds shipped on Linux are
-- OT-SVG: the bundled FreeType has no SVG renderer, so they would be drawn as
-- blank boxes.
local emoji = is_macos and first_font({
  "/System/Library/Fonts/Apple Color Emoji.ttc",
  "/Library/Fonts/Apple Color Emoji.ttc",
}, 14 * SCALE)

---Builds a font group: the bundled monospace/UI font plus the optional emoji
---and CJK fallbacks.  Colour emoji glyphs are drawn at their own bitmap size,
---so the emoji font is loaded at the same size as the text to keep it on the
---line (a larger size overlaps the neighbouring lines).
---@param opts table|nil Rendering options (antialiasing/hinting/...).
local function font_group(primary_file, size, opts)
  local group = { renderer.font.load(fonts_dir .. primary_file, size, opts) }
  if emoji then table.insert(group, emoji) end
  if cjk then table.insert(group, cjk) end
  return renderer.font.group(group)
end

-- Grayscale beats subpixel on a Retina panel (subpixel adds coloured fringes
-- there), but "full" hinting only pays off once the glyphs are big enough:
-- FreeType's auto-hinter grid-fits every glyph, and at the 14 px a 1x display
-- gets (a non-HiDPI window surface means SCALE stays 1) that nudges about
-- half of the characters by a whole pixel inside their cell and inflates the
-- curves.  Measured on JetBrains Mono at 14 px: 21 of 46 ASCII glyphs move
-- their ink by >= 0.5 px with hinting=full, 0 with hinting=slight.  A
-- proportional UI face hides that in its uneven advances, a monospace cell
-- has nowhere to hide it -- hence slight for the code font and full for the
-- UI font, where it survives as extra crispness.
-- (JetBrains Mono's 8.41 px advance still means the cell pitch alternates
-- 8/9 px because grayscale gets no subpixel positioning; a 15 * SCALE code
-- font has a whole-pixel 9 px advance if that ever becomes annoying.)
local UI_FONT_OPTS   = { antialiasing = "grayscale", hinting = "full" }
local CODE_FONT_OPTS = { antialiasing = "grayscale", hinting = "slight" }

style.font = font_group("/FiraSans-Regular.ttf", 14 * SCALE, UI_FONT_OPTS)
style.code_font = font_group("/JetBrainsMono-Regular.ttf", 14 * SCALE, CODE_FONT_OPTS)
-- the welcome screen uses a copy of the UI font: keep the fallbacks
style.big_font = style.font:copy(46 * SCALE)
-- italic face for Sublime-style preview tabs (single click in the treeview)
style.tab_preview_font = font_group("/FiraSans-Regular.ttf", 14 * SCALE,
  { antialiasing = "grayscale", hinting = "full", italic = true })

-- File type icons used by the treeview.
style.nerd_font = try_font(fonts_dir .. "/JetBrainsMonoNerdFontMono-Regular.ttf",
  16 * SCALE, { antialiasing = "grayscale", hinting = "full" })
