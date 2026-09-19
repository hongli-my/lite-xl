-- Fork default theme: Monokai palette with the light sidebar from
-- sublime_dark (this used to live in the user module as colors/monokai.lua).
--
-- Loaded as the default by data/core/fork_defaults.lua.  To go back to the
-- upstream colours from the user module:
--   core.reload_module("colors.default")

local style = require "core.style"
local common = require "core.common"

-- Editor (DocView) - Monokai dark background
style.background = { common.color "#272822" }

-- TreeView sidebar - light background like Sublime Text
style.background2 = { common.color "#efefef" }

-- Command view / other panels - light
style.background3 = { common.color "#f0f0f0" }

-- Text colors
style.text = { common.color "#d4d4d4" }
style.caret = { common.color "#f8f8f0" }
style.accent = { common.color "#a6e22e" }
style.dim = { common.color "#808080" }

-- Dividers between panels
style.divider = { common.color "#d4d4d4" }

-- Selection and highlights
style.selection = { common.color "#49483e" }
style.line_number = { common.color "#75715e" }
style.line_number2 = { common.color "#a59f8b" }  -- With cursor
style.line_highlight = { common.color "#2f2f28" }

-- Scrollbar
style.scrollbar = { common.color "#49483e" }
style.scrollbar2 = { common.color "#575649" }    -- Hovered
style.scrollbar_track = { common.color "#1e1f1c" }

-- Notifications / Nagbar
style.nagbar = { common.color "#FF0000" }
style.nagbar_text = { common.color "#FFFFFF" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }

-- Drag and drop
style.drag_overlay = { common.color "rgba(255,255,255,0.1)" }
style.drag_overlay_tab = { common.color "#a6e22e" }

-- Status indicators
style.good = { common.color "#a6e22e" }
style.warn = { common.color "#e6db74" }
style.error = { common.color "#f92672" }
style.modified = { common.color "#66d9ef" }

-- Sidebar specific colors (used by treeview)
style.sidebar_text = { common.color "#333333" }
style.sidebar_accent = { common.color "#2979ff" }
style.sidebar_dim = { common.color "#999999" }
style.sidebar_line_highlight = { common.color "#d6ebff" }

-- Syntax highlighting - Monokai
style.syntax["normal"] = { common.color "#f8f8f2" }
style.syntax["symbol"] = { common.color "#f8f8f2" }
style.syntax["comment"] = { common.color "#75715e" }
style.syntax["keyword"] = { common.color "#f92672" }     -- local function end if
style.syntax["keyword2"] = { common.color "#f92672" }    -- self int float
style.syntax["number"] = { common.color "#ae81ff" }
style.syntax["literal"] = { common.color "#ae81ff" }     -- true false nil
style.syntax["string"] = { common.color "#e6db74" }
style.syntax["operator"] = { common.color "#f92672" }    -- = + - / < >
style.syntax["function"] = { common.color "#a6e22e" }

-- Log levels
style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
