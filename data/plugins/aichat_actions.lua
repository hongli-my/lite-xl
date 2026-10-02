-- mod-version:4
-- aichat_actions: context-menu quick actions that send the current selection
-- to the AI panel with a prefilled prompt.
--
-- Injects a block of items into the editor's right-click menu
-- (explanation / refactor / optimise / translate / comment / test), but only
-- when there is an active selection.  Reuses the same ContextMenu.show hook
-- pattern as format_button.lua, and sends through the public "aichat:ask"
-- command so this plugin holds no reference to the AI panel internals.
--
-- IMPORTANT: ContextMenu.show filters out any item whose `command` is not a
-- registered command name (it calls command.is_valid on it).  So each action
-- must use a string command, not a closure — we register one command per
-- action below.

local core = require "core"
local command = require "core.command"
local config = require "core.config"
local ContextMenu = require "core.contextmenu"
local DocView = require "core.docview"

config.plugins.aichat_actions = config.plugins.aichat_actions or {}

-- Each entry: { text = menu label, cmd = command name, prompt = instruction }.
-- The selection text itself is appended by build_message in aichat, so the
-- prompt only states the intent.  Order here is the menu order.
local actions = {
  { text = "AI: 解释",   cmd = "aichat-actions:explain",   prompt = "解释下面这段代码的功能、设计意图和关键实现细节，用中文回答：" },
  { text = "AI: 重构",   cmd = "aichat-actions:refactor",  prompt = "重构下面这段代码以提升可读性和可维护性，保持行为不变，并说明改动点：" },
  { text = "AI: 优化",   cmd = "aichat-actions:optimize",  prompt = "分析下面这段代码的性能瓶颈并给出优化方案与优化后的代码：" },
  { text = "AI: 翻译",   cmd = "aichat-actions:translate", prompt = "将下面这段代码的注释和字符串翻译为中文，保持代码逻辑不变，输出完整代码：" },
  { text = "AI: 注释",   cmd = "aichat-actions:comment",   prompt = "为下面这段代码补充清晰准确的中文注释，保持代码逻辑不变，输出完整代码：" },
  { text = "AI: 测试",   cmd = "aichat-actions:test",      prompt = "为下面这段代码编写单元测试，覆盖主要逻辑和边界情况，说明使用的测试框架：" },
}

-- Register one command per action.  Each just forwards its prompt to aichat.
-- Predicate: only valid when the active view is a DocView with a selection,
-- so the menu items disappear (greyed out / filtered) when nothing is
-- selected — matching the condition under which we inject them.
local function has_docview_selection()
  local dv = core.active_view
  return dv and dv:is(DocView) and dv.doc and dv.doc:has_any_selection()
end

for _, a in ipairs(actions) do
  command.add(has_docview_selection, {
    [a.cmd] = function() command.perform("aichat:ask", a.prompt) end,
  })
end

-- Inject our items into every context menu shown while a DocView with a
-- selection is active.  Done by wrapping ContextMenu.show (the same approach
-- format_button.lua uses) instead of overriding DocView:on_context_menu, so
-- we compose with any other plugin that also extends the menu.
local old_show = ContextMenu.show
function ContextMenu:show(x, y, items, ...)
  local dv = core.active_view
  if dv and dv:is(DocView) and dv.doc and dv.doc:has_any_selection() then
    -- Avoid duplicating our block if the menu is reopened.
    local already = false
    for _, item in ipairs(items) do
      if item ~= ContextMenu.DIVIDER and item._aichat_action then
        already = true
        break
      end
    end
    if not already then
      table.insert(items, ContextMenu.DIVIDER)
      for _, a in ipairs(actions) do
        table.insert(items, {
          text = a.text,
          command = a.cmd,
          -- marker so we can detect our own entries on re-show
          _aichat_action = true,
        })
      end
    end
  end
  return old_show(self, x, y, items, ...)
end

return actions
