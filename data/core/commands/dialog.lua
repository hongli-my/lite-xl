local core = require "core"
local command = require "core.command"
local common = require "core.common"

-- Both the nag bar and the modal dialog expose the same API (options,
-- hovered_item, on_selected, next), so the same commands drive them.
local function dialog_view()
  local v = core.active_view
  if v and (v == core.nag_view or v == core.dialog_view) then
    return true, v
  end
  return false
end

command.add(dialog_view, {
  ["dialog:previous-entry"] = function(v)
    local hover = v.hovered_item or 1
    v:change_hovered(hover == 1 and #v.options or hover - 1)
  end,
  ["dialog:next-entry"] = function(v)
    local hover = v.hovered_item or 1
    v:change_hovered(hover == #v.options and 1 or hover + 1)
  end,
  ["dialog:select-yes"] = function(v)
    v:change_hovered(common.find_index(v.options, "default_yes") or 1)
    command.perform("dialog:select", v)
  end,
  ["dialog:select-no"] = function(v)
    v:change_hovered(common.find_index(v.options, "default_no") or #v.options)
    command.perform("dialog:select", v)
  end,
  ["dialog:select"] = function(v)
    -- the mouse may not be over any button: fall back to the default one
    local index = v.hovered_item or (v.get_default_index and v:get_default_index()) or 1
    if not v.options or not v.options[index] then return end
    v:change_hovered(index)
    local option = v.options[index]
    if v.select then
      -- the modal dialog closes itself before running the callback, so that
      -- the callback can open another view (a command view for example)
      v:select()
    else
      v.on_selected(option)
      v:next()
    end
  end
})
