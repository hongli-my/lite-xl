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
-- Do not allow scrolling past the end of the document.
config.scroll_past_end = false

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
local cjk = first_font(system_fonts, 15 * SCALE)

-- Colour emoji: enabled on macOS only.  Apple Color Emoji is an sbix bitmap
-- font that the renderer handles directly (see FT_LOAD_COLOR in
-- src/renderer.c), while the Noto Color Emoji builds shipped on Linux are
-- OT-SVG: the bundled FreeType has no SVG renderer, so they would be drawn as
-- blank boxes.
local emoji = is_macos and first_font({
  "/System/Library/Fonts/Apple Color Emoji.ttc",
  "/Library/Fonts/Apple Color Emoji.ttc",
}, 15 * SCALE)

---Builds a font group: the bundled monospace/UI font plus the optional emoji
---and CJK fallbacks.  Colour emoji glyphs are drawn at their own bitmap size,
---so the emoji font is loaded at the same size as the text to keep it on the
---line (a larger size overlaps the neighbouring lines).
local function font_group(primary_file, size)
  local group = { renderer.font.load(fonts_dir .. primary_file, size) }
  if emoji then table.insert(group, emoji) end
  if cjk then table.insert(group, cjk) end
  return renderer.font.group(group)
end

style.font = font_group("/FiraSans-Regular.ttf", 15 * SCALE)
style.code_font = font_group("/JetBrainsMono-Regular.ttf", 15 * SCALE)
-- the welcome screen uses a copy of the UI font: keep the fallbacks
style.big_font = style.font:copy(46 * SCALE)

-- File type icons used by the treeview.
style.nerd_font = try_font(fonts_dir .. "/JetBrainsMonoNerdFontMono-Regular.ttf",
  16 * SCALE, { antialiasing = "grayscale", hinting = "full" })
