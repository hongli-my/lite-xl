local style = require "core.style"
local common = require "core.common"

-- Sublime Text inspired dark theme for Lite XL
-- Features a light sidebar with dark editor, similar to Sublime Text's default look

-- Load Nerd Font for file icons if available
if not style.nerd_font then
  local font_path = DATADIR .. "/fonts/JetBrainsMonoNerdFontMono-Regular.ttf"
  local ok, font = pcall(renderer.font.load, font_path, 15 * SCALE, {antialiasing="grayscale", hinting="full"})
  if ok then
    style.nerd_font = font
  end
end

-- Editor (DocView) - dark background
style.background = { common.color "#1e1e1e" }

-- TreeView sidebar - light background like Sublime Text
style.background2 = { common.color "#efefef" }

-- Command view / other panels
style.background3 = { common.color "#f0f0f0" }

-- Text colors
style.text = { common.color "#d4d4d4" }
style.caret = { common.color "#528bff" }
style.accent = { common.color "#2979ff" }
style.dim = { common.color "#808080" }

-- Dividers between panels
style.divider = { common.color "#d4d4d4" }

-- Selection and highlights
style.selection = { common.color "#264f78" }
style.line_number = { common.color "#858585" }
style.line_number2 = { common.color "#c6c6c6" } -- With cursor
style.line_highlight = { common.color "#2a2d2e" }

-- Scrollbar
style.scrollbar = { common.color "#424242" }
style.scrollbar2 = { common.color "#686868" } -- Hovered
style.scrollbar_track = { common.color "#1e1e1e" }

-- Notifications / Nagbar
style.nagbar = { common.color "#FF0000" }
style.nagbar_text = { common.color "#FFFFFF" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }

-- Drag and drop
style.drag_overlay = { common.color "rgba(255,255,255,0.1)" }
style.drag_overlay_tab = { common.color "#528bff" }

-- Status indicators
style.good = { common.color "#72b886" }
style.warn = { common.color "#cca700" }
style.error = { common.color "#f44336" }
style.modified = { common.color "#2979ff" }

-- Sidebar specific colors (used by treeview)
style.sidebar_text = { common.color "#333333" }
style.sidebar_accent = { common.color "#2979ff" }
style.sidebar_dim = { common.color "#999999" }
style.sidebar_line_highlight = { common.color "#d6ebff" } -- light blue for light sidebar

-- Syntax highlighting - similar to Sublime Text default
style.syntax["normal"] = { common.color "#d4d4d4" }
style.syntax["symbol"] = { common.color "#d4d4d4" }
style.syntax["comment"] = { common.color "#6a9955" }
style.syntax["keyword"] = { common.color "#c586c0" }   -- import, from, def, class, etc
style.syntax["keyword2"] = { common.color "#569cd6" } -- self, int, float, etc
style.syntax["number"] = { common.color "#b5cea8" }
style.syntax["literal"] = { common.color "#569cd6" }  -- true, false, nil
style.syntax["string"] = { common.color "#ce9178" }
style.syntax["operator"] = { common.color "#d4d4d4" } -- = + - / < >
style.syntax["function"] = { common.color "#dcdcaa" }

-- Log levels
style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
