-- mod-version:4
--
-- Remote projects: open a directory living on a remote machine (SSH) and
-- browse/edit it like a local project, with fully MANUAL synchronization.
--
-- Usage:
--   打开远端目录 (remote-projects:open-dialog) fills a form: host, user,
--   password (optional — ssh-agent/key auth needs none), port, remote
--   directory. Accounts and directories are stored SEPARATELY under
--   USERDIR/remote/ (accounts.lua / dirs.lua); previously used entries are
--   offered in the form's dropdowns.
--
-- On connect the remote tree is listed once (ssh find) and materialized
-- as 0-byte placeholder files under USERDIR/remote/cache/<profile>/,
-- which is opened as a regular local project: the treeview shows the
-- whole structure, unretrieved files drawn DIMMED. A sidecar file
-- (.remote-state.lua inside the cache dir) remembers which files have
-- been pulled; pull/push happen only on explicit request:
--
--   treeview right-click 拉取 (pull)  : rsync remote file -> cache, then
--                                        the file stops being dimmed
--   treeview right-click 推送 (push)  : rsync cache file -> remote
--   opening a dimmed file             : pulls it first, transparently
--
-- Passwords, when given, are fed to ssh through a temporary SSH_ASKPASS
-- script (OpenSSH >= 8.4, SSH_ASKPASS_REQUIRE=force); no password is
-- ever passed on a command line.
--
-- The remote tree is a snapshot when connecting.  It is re-listed in the
-- background every `tree_refresh_interval` seconds (default 60; 0 disables),
-- or on demand with `remote-projects:refresh-tree` (ctrl+shift+alt+t) or
-- right-click -> 刷新远端目录.  New remote files appear as unpulled
-- placeholders; stale unpulled placeholders and empty directories are
-- removed.  Pulled files and files with local content are never deleted.

-- The plugin loader executes this file with dofile(), while other modules
-- (and the dialog) use require(). Both paths must yield the same instance,
-- otherwise the plugin runs twice and installs duplicate hooks.
if rawget(_G, "__lite_xl_remote_projects") then
  return rawget(_G, "__lite_xl_remote_projects")
end

local core = require "core"
local common = require "core.common"
local config = require "core.config"

local M -- module surface (defined at the bottom; forward declaration)
local find_treeview -- resolved later; the treeview may load after us
local install_treeview_hooks -- installed once the treeview exists
local command = require "core.command"
local keymap = require "core.keymap"
local process = require "process"
local style = require "core.style"
local Doc = require "core.doc"

config.plugins.remote_projects = common.merge({
  -- Re-list the remote tree over ssh every N seconds.  0 disables the
  -- automatic refresh; the manual command below still works.
  tree_refresh_interval = 60,
  config_spec = {
    name = "Remote Projects",
  },
}, config.plugins.remote_projects)

-- Project paths are canonicalized by core (system.absolute_path), which on
-- macOS resolves /tmp to /private/tmp. Resolve USERDIR the same way so the
-- cache paths we build match the paths the app reports for opened projects.
local USERDIR_REAL = USERDIR
if system.absolute_path then
  USERDIR_REAL = system.absolute_path(USERDIR) or USERDIR
end
local REMOTE_DIR = USERDIR_REAL .. PATHSEP .. "remote"
local CACHE_ROOT = REMOTE_DIR .. PATHSEP .. "cache"
local STATE_FILE = ".remote-state.lua"

-- ---------------------------------------------------------------------------
-- profile storage (accounts and directories are stored separately)
-- ---------------------------------------------------------------------------

local Accounts = {}
local Dirs = {}

local function read_lua_table(path)
  local f = io.open(path, "rb")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local fn, err = load(content, "@" .. path, "t", {})
  if not fn then
    core.error("[remote] cannot parse %s: %s", path, err)
    return {}
  end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then return {} end
  return t
end

local function write_lua_table(path, t)
  common.mkdirp(common.dirname(path))
  local f = io.open(path, "wb")
  if not f then
    core.error("[remote] cannot write %s", path)
    return
  end
  f:write("return " .. common.serialize(t))
  f:close()
end

function Accounts.path() return REMOTE_DIR .. PATHSEP .. "accounts.lua" end
function Accounts.load() return read_lua_table(Accounts.path()) end
function Accounts.save(t) write_lua_table(Accounts.path(), t) end

function Dirs.path() return REMOTE_DIR .. PATHSEP .. "dirs.lua" end
function Dirs.load() return read_lua_table(Dirs.path()) end
function Dirs.save(t) write_lua_table(Dirs.path(), t) end

---Finds or creates the account entry for the form values; the password is
---stored only when the user typed one (empty means key/agent auth).
local function upsert_account(host, user, port, password)
  local accounts = Accounts.load()
  for _, acc in ipairs(accounts) do
    if acc.host == host and acc.user == user and acc.port == port then
      if password and password ~= "" then acc.password = password end
      Accounts.save(accounts)
      return acc
    end
  end
  local acc = {
    id = #accounts == 0 and 1 or accounts[#accounts].id + 1,
    host = host, user = user, port = port,
  }
  if password and password ~= "" then acc.password = password end
  table.insert(accounts, acc)
  Accounts.save(accounts)
  return acc
end

local function upsert_dir(account_id, remote_dir)
  local dirs = Dirs.load()
  for _, d in ipairs(dirs) do
    if d.account_id == account_id and d.path == remote_dir then
      return d
    end
  end
  local d = { account_id = account_id, path = remote_dir }
  table.insert(dirs, d)
  Dirs.save(dirs)
  return d
end

local function account_by_id(id)
  for _, acc in ipairs(Accounts.load()) do
    if acc.id == id then return acc end
  end
end

-- ---------------------------------------------------------------------------
-- open sessions
-- ---------------------------------------------------------------------------

-- sessions keyed by cache dir:
-- { account = acc, remote_dir = dir, cache_path = path, project = project }
local sessions = {}

local function session_for_path(path)
  if not path then return end
  for _, session in pairs(sessions) do
    if path == session.cache_path
       or common.path_belongs_to(path, session.cache_path) then
      return session
    end
  end
end

local function profile_name(acc, remote_dir)
  local name = (acc.user or "") .. "@" .. acc.host .. ":" .. remote_dir
  return name:gsub("[^%w%.%-_]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
end

---Builds the ssh argument list for an account (port, askpass handled via
---env by the callers that need a password).
local function ssh_command(acc, extra)
  local args = { "ssh" }
  if acc.port and acc.port ~= "" and acc.port ~= 22 then
    table.insert(args, "-p")
    table.insert(args, tostring(acc.port))
  end
  table.insert(args, "-o")
  table.insert(args, "BatchMode=no")
  table.insert(args, "-o")
  table.insert(args, "StrictHostKeyChecking=accept-new")
  for _, v in ipairs(extra or {}) do table.insert(args, v) end
  table.insert(args, (acc.user and acc.user ~= "") and (acc.user .. "@" .. acc.host) or acc.host)
  return args
end

---Runs a command with the account's password (if any) fed through a
---temporary SSH_ASKPASS script. Must run inside a coroutine; returns
---true, stdout or nil, err.
local function run_with_password(args, acc)
  local env
  local askpass_path
  if acc.password and acc.password ~= "" then
    askpass_path = core.temp_filename(".sh", REMOTE_DIR)
    local f = io.open(askpass_path, "wb")
    if not f then return nil, "cannot create askpass script" end
    f:write('#!/bin/sh\necho ' .. string.format("%q", acc.password) .. '\n')
    f:close()
    os.execute("chmod +x " .. askpass_path)
    env = {
      SSH_ASKPASS = askpass_path,
      SSH_ASKPASS_REQUIRE = "force",
      DISPLAY = ":0",
    }
  end
  local proc = process.start(args, { env = env })
  if askpass_path then os.remove(askpass_path) end
  if not proc then return nil, "failed to start " .. args[1] end
  local out, err_buf = {}, {}
  while proc.process:running() do
    local chunk = proc.stdout:read(2048)
    if chunk and chunk ~= "" then table.insert(out, chunk) end
    local echunk = proc.stderr:read(2048)
    if echunk and echunk ~= "" then table.insert(err_buf, echunk) end
    coroutine.yield(1 / config.fps)
  end
  local tail = proc.stdout:read("all")
  if tail and tail ~= "" then table.insert(out, tail) end
  local etail = proc.stderr:read("all")
  if etail and etail ~= "" then table.insert(err_buf, etail) end
  local code = proc:wait()
  if code ~= 0 then
    local err = table.concat(err_buf, ""):gsub("^%s+", ""):gsub("%s+$", "")
    if err == "" then err = args[1] .. " exited with code " .. tostring(code) end
    return nil, err
  end
  return true, table.concat(out, "")
end

local function rsync_args(acc, src, dst)
  local ssh_opts = {}
  if acc.port and acc.port ~= "" and acc.port ~= 22 then
    table.insert(ssh_opts, "-p " .. tostring(acc.port))
  end
  table.insert(ssh_opts, "-o BatchMode=no")
  table.insert(ssh_opts, "-o StrictHostKeyChecking=accept-new")
  local args = {
    "rsync",
    "-e", "ssh " .. table.concat(ssh_opts, " "),
    src, dst,
  }
  return args
end

-- ---------------------------------------------------------------------------
-- cache state (which files have been pulled)
-- ---------------------------------------------------------------------------

local function state_path(session)
  return session.cache_path .. PATHSEP .. STATE_FILE
end

local function load_state(session)
  if session.state then return session.state end
  session.state = read_lua_table(state_path(session))
  if not session.state.files then session.state.files = {} end
  return session.state
end

local function save_state(session)
  write_lua_table(state_path(session), session.state)
end

local function is_pulled(session, abs_filename)
  local state = load_state(session)
  local rel = abs_filename:sub(#session.cache_path + 2)
  return state.files[rel] == true
end

local function mark_pulled(session, abs_filename)
  local state = load_state(session)
  local rel = abs_filename:sub(#session.cache_path + 2)
  state.files[rel] = true
  save_state(session)
end

-- ---------------------------------------------------------------------------
-- connect: list the remote tree, materialize placeholders, open project
-- ---------------------------------------------------------------------------

---Parses the "d ./path" / "f ./path" listing emitted by the remote find.
---Returns a list of { type = "d"|"f", rel = "path" } with "./" stripped.
local function parse_listing(listing)
  local entries = {}
  for line in listing:gmatch("[^\n]+") do
    local ftype, rel = line:match("^(%a)%s+(.+)$")
    if ftype and rel then
      rel = rel:gsub("^%./", "")
      if rel == "." then rel = "" end
      if rel ~= "" then
        entries[#entries + 1] = { type = ftype, rel = rel }
      end
    end
  end
  return entries
end

---Creates missing placeholders/directories for the parsed listing.
---Returns the number of newly created entries.
local function materialize_entries(session, entries)
  common.mkdirp(session.cache_path)
  local created = 0
  for _, e in ipairs(entries) do
    local target = session.cache_path .. PATHSEP .. e.rel:gsub("/", PATHSEP)
    if e.type == "d" then
      if common.mkdirp(target) then created = created + 1 end
    else
      common.mkdirp(common.dirname(target))
      if not system.get_file_info(target) then
        local f = io.open(target, "wb")
        if f then
          f:close()
          created = created + 1
        end
      end
    end
  end
  return created
end

local function materialize(session, listing)
  return materialize_entries(session, parse_listing(listing))
end

---Makes the treeview (and the find-file index) treat not-yet-pulled files
---as ignored: the treeview draws ignored entries dimmed and shows them
---because show_ignored defaults to true.
local function install_project_hooks(session)
  local project = session.project
  if not project or project._remote_hooks then return end
  project._remote_hooks = true
  if install_treeview_hooks then install_treeview_hooks() end
  local base_is_ignored = project.is_ignored
  project.is_ignored = function(self, info, path)
    if info and info.type == "file" and path
       and common.path_belongs_to(path, session.cache_path)
       and not is_pulled(session, path) then
      info.filename = path
      return true
    end
    return base_is_ignored(self, info, path)
  end
end

local function refresh_treeview()
  local treeview = find_treeview and find_treeview()
  if treeview then treeview.cache = {} end
  core.redraw = true
end

local SESSION_FILE = ".remote-session.lua"

---Remembers which remote a cache directory belongs to, so reopening the
---directory later (app restart, recents, sidebar) restores the session
---without going through the connect dialog again.
local function write_session_manifest(session)
  write_lua_table(session.cache_path .. PATHSEP .. SESSION_FILE, {
    account_id = session.account.id,
    remote_dir = session.remote_dir,
    profile = session.profile,
  })
end

---Rebuilds a session for an already-cached remote directory, with no
---network round trip and no dialog. Returns the session or nil.
local function attach_cached_session(cache_path, project)
  local session = sessions[cache_path]
  if session then
    if project and not session.project then session.project = project end
    return session
  end
  local manifest = read_lua_table(cache_path .. PATHSEP .. SESSION_FILE)
  if type(manifest) ~= "table" or manifest.remote_dir == nil
     or manifest.account_id == nil then
    return nil
  end
  local account = account_by_id(manifest.account_id)
  if not account then return nil end
  session = {
    account = account,
    remote_dir = manifest.remote_dir,
    cache_path = cache_path,
    profile = manifest.profile or profile_name(account, manifest.remote_dir),
  }
  -- register before adding the project: add_project may be wrapped below and
  -- would otherwise re-enter this function
  sessions[cache_path] = session
  session.project = project or core.add_project(cache_path)
  install_project_hooks(session)
  return session
end

---Attaches any project that is a known remote cache directory. Called at
---load (for projects restored from the session) and whenever a project is
---added (opening the directory from the sidebar or recents).
local function attach_existing_projects()
  for _, project in ipairs(core.projects) do
    attach_cached_session(project.path, project)
  end
end

---Runs the remote `find` and returns ok, listing-or-error.
local function list_remote_tree(session)
  local cmd = ssh_command(session.account, {})
  table.insert(cmd, string.format(
    "cd %s 2>/dev/null && find . \\( -type d -o -type f \\) -print | "
    .. "while read -r p; do if [ -d \"$p\" ]; then echo \"d $p\"; else echo \"f $p\"; fi; done",
    session.remote_dir))
  return run_with_password(cmd, session.account)
end

local function connect(account, remote_dir)
  local profile = profile_name(account, remote_dir)
  local cache_path = CACHE_ROOT .. PATHSEP .. profile
  if sessions[cache_path] then
    core.log_quiet("[remote] %s is already open", profile)
    return
  end
  local session = {
    account = account,
    remote_dir = remote_dir,
    cache_path = cache_path,
    profile = profile,
  }
  sessions[cache_path] = session
  common.mkdirp(cache_path)
  write_session_manifest(session)
  core.log_quiet("[remote] connecting to %s ...", profile)

  core.add_thread(function()
    -- 1) probe + list the remote tree
    local ok, listing = list_remote_tree(session)
    if not ok then
      sessions[cache_path] = nil
      common.rm(cache_path .. PATHSEP .. SESSION_FILE)
      core.error("[remote] cannot connect to %s: %s", profile, listing)
      return
    end
    -- 2) materialize the tree locally as placeholders
    materialize(session, listing)
    -- 3) open as a normal local project (unless it is already open)
    local existing
    for _, project in ipairs(core.projects) do
      if project.path == cache_path then existing = project break end
    end
    session.project = existing or core.add_project(cache_path)
    install_project_hooks(session)
    refresh_treeview()
    core.log_quiet("[remote] opened %s (cache: %s)", profile, cache_path)
  end)
end

---Removes cache entries that no longer exist in the remote listing.
---Only empty unpulled placeholders and empty directories are deleted: pulled
---files and files with local content are kept (the user may have edits).
local function prune_cache(session, entries)
  local keep = {}
  for _, e in ipairs(entries) do keep[e.rel] = e.type end
  local removed, kept = 0, 0

  local function walk(rel_dir)
    local abs_dir = rel_dir == "" and session.cache_path
      or (session.cache_path .. PATHSEP .. rel_dir:gsub("/", PATHSEP))
    local names = system.list_dir(abs_dir) or {}
    for _, name in ipairs(names) do
      if name ~= STATE_FILE and name ~= SESSION_FILE then
        local rel = rel_dir == "" and name or (rel_dir .. "/" .. name)
        local abs = abs_dir .. PATHSEP .. name
        local info = system.get_file_info(abs)
        if info and info.type == "dir" then
          walk(rel)
          if keep[rel] ~= "d" then
            local remaining = system.list_dir(abs) or {}
            if #remaining == 0 and common.rm(abs, false) then
              removed = removed + 1
            end
          end
        elseif info and info.type == "file" then
          if keep[rel] ~= "f" then
            if is_pulled(session, abs) then
              kept = kept + 1
            elseif (info.size or 0) > 0 then
              kept = kept + 1
            else
              if os.remove(abs) then removed = removed + 1 end
            end
          end
        end
      end
    end
  end

  walk("")
  return removed, kept
end

---Re-lists the remote tree, materializes new placeholders and prunes stale
---unpulled ones.  Must run in a coroutine (ssh).  Returns true on success.
local function refresh_session_tree(session)
  if not session or session.refreshing then return false end
  if sessions[session.cache_path] ~= session then return false end
  session.refreshing = true
  local ok, listing = list_remote_tree(session)
  if not ok then
    session.refreshing = false
    if not session.refresh_error_logged then
      session.refresh_error_logged = true
      core.log_quiet("[remote] refresh failed for %s: %s", session.profile, listing)
    end
    return false
  end
  if sessions[session.cache_path] ~= session then
    session.refreshing = false
    return false
  end
  local entries = parse_listing(listing)
  local created = materialize_entries(session, entries)
  local removed, kept = prune_cache(session, entries)
  session.refreshing = false
  session.refresh_error_logged = nil
  if created > 0 or removed > 0 then refresh_treeview() end
  if created > 0 or removed > 0 or kept > 0 then
    core.log_quiet("[remote] refreshed %s (%d new, %d removed, %d kept local)",
      session.profile, created, removed, kept)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- per-file pull / push
-- ---------------------------------------------------------------------------

local function pull_file(session, abs_filename)
  local rel = abs_filename:sub(#session.cache_path + 2)
  local remote = session.account.user .. "@" .. session.account.host
    .. ":" .. session.remote_dir .. "/" .. rel
  local ok, err = run_with_password(
    rsync_args(session.account, remote, abs_filename), session.account)
  if not ok then
    core.error("[remote] pull failed for %s: %s", rel, err)
    return false
  end
  mark_pulled(session, abs_filename)
  refresh_treeview()
  core.log_quiet("[remote] pulled %s", rel)
  return true
end

local function push_file(session, abs_filename)
  local rel = abs_filename:sub(#session.cache_path + 2)
  if not is_pulled(session, abs_filename) then
    core.error("[remote] %s was never pulled; refusing to push a placeholder", rel)
    return false
  end
  local remote = session.account.user .. "@" .. session.account.host
    .. ":" .. session.remote_dir .. "/" .. rel
  local ok, err = run_with_password(
    rsync_args(session.account, abs_filename, remote), session.account)
  if not ok then
    core.error("[remote] push failed for %s: %s", rel, err)
    return false
  end
  core.log_quiet("[remote] pushed %s", rel)
  return true
end

-- opening a dimmed file pulls it first, transparently
local doc_load = Doc.load
function Doc:load(filename)
  local session = session_for_path(filename)
  if session and not is_pulled(session, filename) then
    -- must run in the editor thread: Doc:load is called synchronously from
    -- Doc:new; do a blocking pull of the single small file instead
    local co = coroutine.running()
    if co then
      pull_file(session, filename)
    else
      -- called outside a thread (e.g. core.open_doc from a command): spawn
      -- a thread that pulls then re-opens the doc
      core.add_thread(function()
        if pull_file(session, filename) then
          core.root_view:open_doc(core.open_doc(filename))
        end
      end)
      error("[remote] pulling " .. common.basename(filename) .. " …", 0)
    end
  end
  return doc_load(self, filename)
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

command.add(nil, {
  ["remote-projects:open-dialog"] = function()
    local RemoteDialog = require "plugins.remote_dialog"
    RemoteDialog.show(function(host, user, password, port, dir)
      M.connect_with_form(host, user, password, port, dir)
    end)
  end,

  ["remote-projects:disconnect"] = function()
    local items = {}
    for _, session in pairs(sessions) do
      table.insert(items, session.profile)
    end
    if #items == 0 then
      core.log_quiet("[remote] no remote directory is open")
      return
    end
    core.command_view:enter("Disconnect Remote", {
      submit = function(text, item)
        local profile = item and item.text or text
        local cache_path = CACHE_ROOT .. PATHSEP .. profile
        local session = sessions[cache_path]
        if not session then
          core.error("[remote] %s is not open", profile)
          return
        end
        sessions[cache_path] = nil
        if session.project then core.remove_project(session.project) end
        refresh_treeview()
        core.log_quiet("[remote] disconnected from %s (cache kept: %s)",
          profile, cache_path)
      end,
      suggest = function(text)
        return common.fuzzy_match(items, text) or {}
      end,
    })
  end,

  ["remote-projects:refresh-tree"] = function()
    local p = core.root_project and core.root_project()
    local session = p and session_for_path(p.path)
    local targets = {}
    if session then
      targets[1] = session
    else
      for _, s in pairs(sessions) do targets[#targets + 1] = s end
    end
    if #targets == 0 then
      core.log_quiet("[remote] no remote directory is open")
      return
    end
    core.add_thread(function()
      for _, s in ipairs(targets) do
        if sessions[s.cache_path] == s then refresh_session_tree(s) end
      end
    end)
  end,

  ["remote-projects:forget-cache"] = function()
    local items = {}
    for _, session in pairs(sessions) do
      table.insert(items, session.profile)
    end
    if #items == 0 then
      core.log("[remote] no remote directory is open")
      return
    end
    core.command_view:enter("Forget Remote (deletes the local cache)", {
      submit = function(text, item)
        local profile = item and item.text or text
        local cache_path = CACHE_ROOT .. PATHSEP .. profile
        local session = sessions[cache_path]
        if not session then
          core.error("[remote] %s is not open", profile)
          return
        end
        sessions[cache_path] = nil
        if session.project then core.remove_project(session.project) end
        common.rm(cache_path, true)
        refresh_treeview()
        core.log_quiet("[remote] forgot %s and deleted its cache", profile)
      end,
      suggest = function(text)
        return common.fuzzy_match(items, text) or {}
      end,
    })
  end,
})

-- ---------------------------------------------------------------------------
-- reopening saved remote directories without the connect dialog
-- ---------------------------------------------------------------------------

-- projects restored from the previous session are already in core.projects
attach_existing_projects()

-- and any project opened later (sidebar, recents, open-directory) that is a
-- known cache directory gets its session back automatically
local core_add_project = core.add_project
function core.add_project(project)
  local added = core_add_project(project)
  if type(added) == "table" and type(added.path) == "string" then
    attach_cached_session(added.path, added)
  end
  return added
end

-- ---------------------------------------------------------------------------
-- treeview integration
--
-- The plugin loader uses dofile(), so requiring "plugins.treeview" here
-- would execute that file a second time (a second sidebar node, duplicated
-- key bindings, duplicated patched methods). Instead the live instance is
-- discovered in the view tree and its methods are patched in place.
-- ---------------------------------------------------------------------------

find_treeview = function()
  local found
  local function walk(node)
    if not node or found then return end
    if type(node.get_cached) == "function" and node.watches and node.expanded then
      found = node
      return
    end
    -- views live in node.views, splits in node.a / node.b
    if node.a then
      walk(node.a)
      walk(node.b)
    end
    if node.views then
      for _, view in ipairs(node.views) do walk(view) end
    end
  end
  walk(core.root_view and core.root_view.root_node)
  return found
end

local function treeitem(treeview)
  return treeview.hovered_item or treeview.selected_item
end

local treeview_hooks_installed = false

install_treeview_hooks = function()
  if treeview_hooks_installed then return true end
  local treeview = find_treeview()
  if not treeview then return false end
  treeview_hooks_installed = true

  local old_menu = treeview.on_context_menu
  function treeview:on_context_menu()
    local args = { old_menu(self) }
    local cmds = args[1]
    local item = self.hovered_item or self.selected_item
    if cmds and item and session_for_path(item.abs_filename) then
      local items = cmds.items
      if items then
        if item.type == "file" then
          -- insert after the leading entry + divider (positions 1-2)
          table.move(items, 3, #items, 5)
          items[3] = { text = "拉取 (Pull)", icon = "\u{25BC}",
            command = "remote-projects:pull-file" }
          items[4] = { text = "推送 (Push)", icon = "\u{25B2}",
            command = "remote-projects:push-file" }
        end
        items[#items + 1] = { text = "刷新远端目录 (Refresh Remote Tree)",
          icon = "\u{25CB}", command = "remote-projects:refresh-this-tree" }
      end
    end
    return table.unpack(args)
  end

  return true
end

if not install_treeview_hooks() then
  -- the treeview may load after this plugin (plugins load in name order):
  -- watch for it and install the hooks as soon as it appears
  core.add_thread(function()
    for _ = 1, 200 do
      if install_treeview_hooks() then return end
      coroutine.yield(0.05)
    end
  end)
end

command.add(function()
  local treeview = find_treeview()
  local item = treeview and treeitem(treeview)
  return item ~= nil and item.type == "file"
    and session_for_path(item.abs_filename) ~= nil, item
end, {
  ["remote-projects:pull-file"] = function(item)
    local session = session_for_path(item.abs_filename)
    core.add_thread(function() pull_file(session, item.abs_filename) end)
  end,

  ["remote-projects:push-file"] = function(item)
    local session = session_for_path(item.abs_filename)
    core.add_thread(function() push_file(session, item.abs_filename) end)
  end,
})

command.add(function()
  local treeview = find_treeview()
  local item = treeview and treeitem(treeview)
  return item ~= nil and session_for_path(item.abs_filename) ~= nil, item
end, {
  ["remote-projects:refresh-this-tree"] = function(item)
    local session = session_for_path(item.abs_filename)
    core.add_thread(function() refresh_session_tree(session) end)
  end,
})

keymap.add({
  ["ctrl+shift+alt+r"] = "remote-projects:open-dialog",
  ["ctrl+shift+alt+t"] = "remote-projects:refresh-tree",
})

-- Sync once shortly after startup (for sessions attached from the previous
-- run, whose cache may be stale) and then on the periodic schedule.
core.add_thread(function()
  coroutine.yield(2)
  local interval = tonumber(config.plugins.remote_projects.tree_refresh_interval) or 0
  if interval <= 0 then return end
  local list = {}
  for _, s in pairs(sessions) do list[#list + 1] = s end
  for _, s in ipairs(list) do
    if sessions[s.cache_path] == s then refresh_session_tree(s) end
  end
end)

-- Re-list the remote tree periodically so files created/deleted/renamed on
-- the remote show up without a reconnect.  The manual command above works
-- even when this is disabled (set tree_refresh_interval = 0).
core.add_thread(function()
  while true do
    local interval = tonumber(config.plugins.remote_projects.tree_refresh_interval) or 0
    if interval <= 0 then
      coroutine.yield(1)
    else
      coroutine.yield(interval)
      local list = {}
      for _, s in pairs(sessions) do list[#list + 1] = s end
      for _, s in ipairs(list) do
        if sessions[s.cache_path] == s then refresh_session_tree(s) end
      end
    end
  end
end)

-- module surface used by remote_dialog (dropdown sources) and tests
M = {
  list_accounts = function() return Accounts.load() end,
  list_dirs = function() return Dirs.load() end,
  -- helper for the dialog's on_connect callback
  connect_with_form = function(host, user, password, port, dir)
    local account = upsert_account(host, user, port, password)
    upsert_dir(account.id, dir)
    connect(account, dir)
  end,
  -- exposed for tests
  _internal = {
    materialize = materialize,
    sessions = sessions,
    session_for_path = session_for_path,
    pull_file = pull_file,
    push_file = push_file,
    list_remote_tree = list_remote_tree,
    parse_listing = parse_listing,
    materialize_entries = materialize_entries,
    prune_cache = prune_cache,
    refresh_session_tree = refresh_session_tree,
    is_pulled = is_pulled,
    profile_name = profile_name,
    upsert_account = upsert_account,
    upsert_dir = upsert_dir,
    ssh_command = ssh_command,
    run_with_password = run_with_password,
    Accounts = Accounts,
    Dirs = Dirs,
  },
}

rawset(_G, "__lite_xl_remote_projects", M)

return M
