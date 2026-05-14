local style = require "core.style"
local common = require "core.common"

-- Sublime Text Monokai theme for Lite XL

style.background = { common.color "#272822" }    -- Docview
style.background2 = { common.color "#1e1f1c" }   -- Treeview
style.background3 = { common.color "#1e1f1c" }   -- Command view
style.text = { common.color "#f8f8f2" }
style.caret = { common.color "#f8f8f0" }
style.accent = { common.color "#a6e22e" }
style.dim = { common.color "#75715e" }
style.divider = { common.color "#1a1a16" }
style.selection = { common.color "#49483e" }
style.line_number = { common.color "#75715e" }
style.line_number2 = { common.color "#a59f8b" }  -- With cursor
style.line_highlight = { common.color "#2f2f28" }
style.scrollbar = { common.color "#49483e" }
style.scrollbar2 = { common.color "#575649" }    -- Hovered
style.scrollbar_track = { common.color "#1e1f1c" }
style.nagbar = { common.color "#FF0000" }
style.nagbar_text = { common.color "#FFFFFF" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }
style.drag_overlay = { common.color "rgba(255,255,255,0.1)" }
style.drag_overlay_tab = { common.color "#a6e22e" }
style.good = { common.color "#a6e22e" }
style.warn = { common.color "#e6db74" }
style.error = { common.color "#f92672" }
style.modified = { common.color "#66d9ef" }

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

style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style