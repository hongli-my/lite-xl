-- mod-version:4
-- Shared Nerd Font file-icon lookup, extracted from the treeview so that the
-- quick-open palette, the tabs and the context menus can render the same
-- glyphs as the sidebar.  Pure data + functions: requiring it has no side
-- effects beyond possibly loading the icon font.
--
-- Usage:
--   local file_icons = require "plugins.file_icons"
--   local char, font, color = file_icons.lookup(name, is_dir, expanded)

local style = require "core.style"
local common = require "core.common"

-- Load Nerd Font directly to ensure icons work regardless of init.lua
-- configuration (MACOS_RESOURCES only exists in macOS bundle builds; reading
-- it directly, rather than through rawget, would abort this plugin outside
-- of them, because the core enables strict globals).
local nerd_font = style.nerd_font
if not nerd_font then
  local resources = rawget(_G, "MACOS_RESOURCES") or DATADIR
  local font_path = resources .. "/fonts/JetBrainsMonoNerdFontMono-Regular.ttf"
  local ok, font = pcall(renderer.font.load, font_path, 15 * SCALE,
    { antialiasing = "grayscale", hinting = "full" })
  if ok then
    nerd_font = font
    style.nerd_font = font
  end
end

-- Nerd Font file icon mappings (unicode codepoints)
-- https://www.nerdfonts.com/cheat-sheet
local icons = {
  -- dirs (using Font Awesome icons which are stable across Nerd Font versions)
  dir_closed = "\u{f07b}",
  dir_open   = "\u{f07c}",
  -- by extension
  lua    = "\u{e620}",
  py     = "\u{e73c}",
  js     = "\u{e74e}",
  ts     = "\u{e628}",
  html   = "\u{e736}",
  css    = "\u{e749}",
  json   = "\u{e60b}",
  md     = "\u{e609}",
  txt    = "\u{f15c}",
  xml    = "\u{e736}",
  yaml   = "\u{e60b}",
  yml    = "\u{e60b}",
  toml   = "\u{e60b}",
  sh     = "\u{e615}",
  bash   = "\u{e615}",
  zsh    = "\u{e615}",
  fish   = "\u{e615}",
  c      = "\u{e61e}",
  h      = "\u{e61e}",
  cpp    = "\u{e61d}",
  hpp    = "\u{e61d}",
  cc     = "\u{e61d}",
  go     = "\u{e627}",
  rs     = "\u{e7a8}",
  java   = "\u{e738}",
  rb     = "\u{e739}",
  php    = "\u{e73d}",
  swift  = "\u{e755}",
  kt     = "\u{e634}",
  sql    = "\u{e70e}",
  git    = "\u{e702}",
  docker = "\u{e650}",
  lock   = "\u{f023}",
  img    = "\u{e60d}",
  png    = "\u{e60d}",
  jpg    = "\u{e60d}",
  svg    = "\u{e60d}",
  gif    = "\u{e60d}",
  conf   = "\u{e615}",
  cfg    = "\u{e615}",
  ini    = "\u{e615}",
  log    = "\u{f15c}",
  -- by filename
  Makefile      = "\u{e673}",
  Dockerfile    = "\u{e650}",
  README        = "\u{e609}",
  LICENSE       = "\u{f023}",
  [".gitignore"]  = "\u{e702}",
  [".env"]        = "\u{e615}",
  [".gitmodules"] = "\u{e702}",
}
local default_icon = "\u{f15b}"

-- File icon colors for a Sublime-Text-like file icon experience
-- Each entry is a color table {r, g, b, a}
local icon_colors = {
  -- dirs
  dir_closed = { common.color "#555555" },
  dir_open   = { common.color "#555555" },
  -- Web / markup
  html   = { common.color "#e44d26" },
  css    = { common.color "#264de4" },
  js     = { common.color "#f7df1e" },
  ts     = { common.color "#3178c6" },
  json   = { common.color "#f7df1e" },
  xml    = { common.color "#ff6600" },
  svg    = { common.color "#ff9900" },
  -- Python
  py     = { common.color "#3776ab" },
  -- Lua
  lua    = { common.color "#000080" },
  -- C / C++
  c      = { common.color "#555555" },
  h      = { common.color "#a8b9cc" },
  cpp    = { common.color "#659ad2" },
  hpp    = { common.color "#659ad2" },
  cc     = { common.color "#659ad2" },
  -- Go
  go     = { common.color "#00add8" },
  -- Rust
  rs     = { common.color "#dea584" },
  -- Java
  java   = { common.color "#b07219" },
  -- Ruby
  rb     = { common.color "#cc342d" },
  -- PHP
  php    = { common.color "#4f5d95" },
  -- Swift
  swift  = { common.color "#ffac45" },
  -- Kotlin
  kt     = { common.color "#a97bff" },
  -- SQL
  sql    = { common.color "#555555" },
  -- Shell
  sh     = { common.color "#89e051" },
  bash   = { common.color "#89e051" },
  zsh    = { common.color "#89e051" },
  fish   = { common.color "#89e051" },
  -- Git
  git    = { common.color "#f05032" },
  -- Docker
  docker = { common.color "#2496ed" },
  -- Config / settings
  conf   = { common.color "#555555" },
  cfg    = { common.color "#555555" },
  ini    = { common.color "#555555" },
  toml   = { common.color "#9c4221" },
  yml    = { common.color "#cb171e" },
  yaml   = { common.color "#cb171e" },
  env    = { common.color "#f7df1e" },
  -- Markdown / text
  md     = { common.color "#555555" },
  txt    = { common.color "#555555" },
  log    = { common.color "#555555" },
  -- Images
  img    = { common.color "#a063eb" },
  png    = { common.color "#a063eb" },
  jpg    = { common.color "#a063eb" },
  gif    = { common.color "#a063eb" },
  -- Lock files
  lock   = { common.color "#de5c38" },
  -- by filename
  Makefile      = { common.color "#427819" },
  Dockerfile    = { common.color "#2496ed" },
  README        = { common.color "#555555" },
  LICENSE       = { common.color "#cb171e" },
  [".gitignore"]  = { common.color "#f05032" },
  [".env"]        = { common.color "#f7df1e" },
  [".gitmodules"] = { common.color "#f05032" },
}
local default_icon_color = { common.color "#555555" }

local function icon(name, is_dir, expanded)
  if is_dir then
    return expanded and icons.dir_open or icons.dir_closed
  end
  -- exact filename match first
  local basename = name:match("([^/]+)$") or name
  if icons[basename] then return icons[basename] end
  -- then extension
  local ext = basename:match("%.([^.]+)$")
  if ext and icons[ext] then return icons[ext] end
  return default_icon
end

local function color(name, is_dir)
  if is_dir then
    return icon_colors.dir_closed
  end
  local basename = name:match("([^/]+)$") or name
  if icon_colors[basename] then return icon_colors[basename] end
  local ext = basename:match("%.([^.]+)$")
  if ext and icon_colors[ext] then return icon_colors[ext] end
  return default_icon_color
end

---Convenience: glyph + font + colour in one call, ready for common.draw_text.
local function lookup(name, is_dir, expanded)
  local font = nerd_font or style.nerd_font or style.icon_font
  return icon(name, is_dir, expanded), font, color(name, is_dir)
end

return {
  icon = icon,
  color = color,
  lookup = lookup,
  font = function() return nerd_font or style.nerd_font or style.icon_font end,
  icons = icons,
  colors = icon_colors,
  default_icon = default_icon,
  default_color = default_icon_color,
}
