-- mod-version:4
-- Server Save Plugin
-- When saving files under /docs/ directory, also POST the content to OpenResty
-- server (/docs/save endpoint) for browser-based preview.
--
-- Also watches for OpenResty project directories and shows a "server mode" indicator.

local core = require "core"
local command = require "core.command"
local config = require "core.config"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local Doc = require "core.doc"
local process = require "core.process"

config.plugins.server_save = common.merge({
  -- Base server URL
  server_url = "http://localhost",
  -- Server save endpoint
  save_endpoint = "/docs/save",
  -- Document root directories to enable server mode
  doc_roots = { "/docs/", "/Users/honglichang/openresty/nginx/html/docs/" },
  -- Show server sync indicator in status bar
  show_indicator = true,
  -- Require manual confirmation for first server save
  confirm_first = true,
  -- Enable auto-reload in browser after save (uses WebSocket or polling)
  auto_reload = false,
  -- Browser reload endpoint/URL
  reload_url = nil,
}, config.plugins.server_save)

local server_mode_active = false
local has_confirmed = false

-- Check if a file is under a doc root
local function is_doc_file(filename)
  if not filename then return false end
  for _, root in ipairs(config.plugins.server_save.doc_roots) do
    if filename:sub(1, #root) == root then
      return true
    end
  end
  return false
end

-- Get relative path for the server endpoint
local function get_relative_path(filename)
  for _, root in ipairs(config.plugins.server_save.doc_roots) do
    if filename:sub(1, #root) == root then
      local rel = filename:sub(#root + 1)
      return rel
    end
  end
  return filename
end

-- Save to server via POST
local function save_to_server(doc)
  if not server_mode_active then return end
  if not doc.filename then return end
  if not is_doc_file(doc.filename) then return end

  local relative_path = get_relative_path(doc.filename)
  local text = doc:get_text(1, 1, math.huge, math.huge)

  -- Build JSON payload using Lua
  local json = string.format(
    '{"path":%q,"content":%q}',
    relative_path:gsub("\\", "\\\\"):gsub('"', '\\"'),
    text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  )

  -- Use curl to POST to server (async via process)
  local url = config.plugins.server_save.server_url
    .. config.plugins.server_save.save_endpoint

  local p = process.start({
    "curl", "-s", "-X", "POST",
    url,
    "-H", "Content-Type: application/json",
    "-d", json,
    "--max-time", "5"
  })

  -- Wait in a thread so editor doesn't block
  core.add_thread(function()
    p:wait(5)
    local stdout = p.stdout:read("all", { timeout = 3 })
    if stdout then
      if stdout:match('"success":true') then
        -- Server saved successfully
      elseif stdout:match('"success":false') or stdout:match('"error"') then
        local err = stdout:match('"message"%s*:%s*"([^"]+)"') or stdout:match('"error"%s*:%s*"([^"]+)"') or "Unknown error"
        core.log_quiet("Server save failed: %s", err)
      end
    end
    if p:returncode() ~= 0 then
      core.log_quiet("Server save curl failed with exit code %d", p:returncode())
    end
  end)
end

-- Hook into doc:save command
local function hook_save()
  local view = core.active_view
  if not view or not view:is(DocView) then return end

  local doc = view.doc
  if is_doc_file(doc.filename) then
    if not server_mode_active then
      server_mode_active = true
      core.status_view:show_message("Server save mode activated for /docs/", 3)
    end

    -- If server mode is active, save to server
    save_to_server(doc)
  end
end

-- Create a command to toggle server save mode manually
local function toggle_server_mode()
  server_mode_active = not server_mode_active
  if server_mode_active then
    core.status_view:show_message("Server save: ON", 2)
  else
    core.status_view:show_message("Server save: OFF", 2)
  end
end

-- Intercept the original doc:save to also do server save
-- We wrap it by adding a post-save hook
local orig_doc_save = command.map["doc:save"]

-- Only register our hook if doc:save exists as a command
if orig_doc_save then
  -- We add our server save after the native save
  -- The easiest way is to add a separate command that runs after save
  command.add("core.docview", {
    ["doc:server-save"] = function()
      hook_save()
    end,
  })
  
  -- Override the save command to also call our hook
  local old_perform = orig_doc_save.perform
  orig_doc_save.perform = function(...)
    if old_perform then old_perform(...) end
    hook_save()
  end
end

-- Add a manual save-to-server command
command.add("core.docview", {
  ["doc:save-to-server"] = function()
    local view = core.active_view
    if not view or not view:is(DocView) then
      core.status_view:show_message("No document open", 2)
      return
    end
    local doc = view.doc
    if not doc.filename then
      core.status_view:show_message("Save the file first", 2)
      return
    end
    if not is_doc_file(doc.filename) then
      core.status_view:show_message("Not a /docs/ file. Server save not available.", 2)
      return
    end
    if not server_mode_active then
      server_mode_active = true
    end
    save_to_server(doc)
    core.status_view:show_message("Saving to server...", 2)
  end,
})

command.add(nil, {
  ["doc:toggle-server-save"] = toggle_server_mode,
})

-- Key bindings
keymap.add({
  ["ctrl+shift+s"] = "doc:save-to-server",
  ["ctrl+alt+s"] = "doc:toggle-server-save",
})

-- Auto-detect doc root on project open
local core_run = core.run
function core.run(...)
  local result = core_run(...)
  
  -- Check if current project is a doc root
  local project = core.root_project()
  if project and project.path then
    for _, root in ipairs(config.plugins.server_save.doc_roots) do
      if project.path == root or project.path:sub(1, #root) == root then
        server_mode_active = true
        core.status_view:show_message("Server save mode: ON (documents auto-sync to server)", 4)
        break
      end
    end
  end
  
  return result
end

return {
  is_active = function() return server_mode_active end,
  toggle = toggle_server_mode,
  save = save_to_server,
}