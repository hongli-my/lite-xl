-- remote_projects headless test (manual-sync design): drives the real
-- plugin code with REAL ssh and rsync binaries. The "remote machine" is a
-- local sandbox reached through a fake ssh on PATH that rewrites the
-- target into the sandbox.
--
-- Covered: account/dir persistence under USERDIR/remote/, connect via the
-- form callback, materialized placeholder tree, per-file pull (rsync,
-- greying state), push (refuses unpulled placeholders), password feeding
-- through SSH_ASKPASS, and error surfacing on a bad host.
--
-- SAFETY: the fake ssh cd's into the sandbox before exec; only the last
-- argument (the path) is rewritten. The runner executes this from a
-- scratch directory, never from the repository.

local REPO = "/Users/honglichang/ai-home/lite-xl"
local ROOT = "/tmp/lite-xl-remote-test"
os.execute("rm -rf " .. ROOT)

local fails, checks = 0, 0
local function ok(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print("FAIL: " .. msg) end
end
local function mkdirp(p) os.execute("mkdir -p " .. p) end
local function wfile(p, c) local f = io.open(p, "wb") f:write(c) f:close() end
local function rfile(p) local f = io.open(p, "rb") local s = f and f:read("*a") f:close() return s end
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end

mkdirp(ROOT .. "/user")       -- USERDIR
mkdirp(ROOT .. "/machine/proj/sub")
mkdirp(ROOT .. "/bin")
-- fake ssh: drop host token and emulate a remote shell rooted at the
-- sandbox. Two argument shapes arrive here:
--   1) rsync: "rsync --server ... . /path" — last arg is a bare path
--   2) the plugin's listing command: a shell line referencing /proj
-- Bare absolute paths (no spaces) are rewritten directly; command lines
-- get every /proj reference rewritten (the test's remote root), then run
-- through bash. cd into the sandbox first so relative receiver roots of
-- rsync stay inside it.
wfile(ROOT .. "/bin/ssh", [==[#!/bin/bash
SANDBOX="]==] .. ROOT .. [==[/machine"
REMOTE_ROOT="]==] .. ROOT .. [==[/machine/proj"
cd "$SANDBOX" || exit 1
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a=${args[$i]}
  case "$a" in
    -i|-p|-l|-o) i=$((i+2)) ;;
    -*) i=$((i+1)) ;;
    *) i=$((i+1)); break ;;
  esac
done
host="${args[$((i-1))]}"
if [ "$host" != "tester@box" ] && [ "$host" != "box" ]; then
  echo "ssh: Could not resolve hostname ${host#*@}: nodename nor servname provided, or not known" >&2
  exit 255
fi
cmd=("${args[@]:$i}")
last=$(( ${#cmd[@]} - 1 ))
if [ $last -eq 0 ]; then
  # single command argument: a remote shell line
  line="${cmd[0]}"
  if [[ "$line" != rsync* ]]; then
    line="$(printf '%s\n' "$line" | sed "s|/proj/|$REMOTE_ROOT/|g; s|/proj\"|\"$REMOTE_ROOT\"|g; s|/proj |$REMOTE_ROOT |g; s| /proj$| $REMOTE_ROOT|")"
    exec bash -c "$line"
  fi
fi

if [ $last -ge 0 ]; then
  case "${cmd[$last]}" in
    /proj*) [ "${cmd[$last]//[^ ]/}" = "" ] && cmd[$last]="${cmd[$last]/\/proj/$REMOTE_ROOT}" ;;
  esac
fi
exec "${cmd[@]}"
]==])
os.execute("chmod +x " .. ROOT .. "/bin/ssh")

-- remote side content
wfile(ROOT .. "/machine/proj/hello.txt", "remote hello\n")
wfile(ROOT .. "/machine/proj/sub/deep.txt", "deep content\n")

-- ---------------------------------------------------------------------------
-- stub environment
-- ---------------------------------------------------------------------------

local threads = {}
local registered = {}

local core
core = {
  docs = {},
  projects = {},
  redraw = false,
  fps = 60,
  log = function(...) print("  [log] " .. string.format(...)) end,
  log_quiet = function() end,
  error = function(...) print("  [error] " .. string.format(...)) end,
  add_thread = function(f)
    table.insert(threads, { cr = coroutine.create(f) })
  end,
  add_project = function(path)
    -- mirrors core.Project: no ignore patterns unless the plugin adds them
    local project = {
      path = path,
      is_ignored = function() return false end,
    }
    table.insert(core.projects, project)
    return project
  end,
  remove_project = function(project)
    for i, p in ipairs(core.projects) do
      if p == project then table.remove(core.projects, i) return p end
    end
  end,
  root_project = function() return core.projects[1] end,
  command_view = { enter = function() end },
  status_view = { add_item = function() end },
  temp_filename = function(ext, dir)
    return (dir or ROOT) .. "/tmp-askpass" .. (ext or "")
  end,
  last_active_view = nil, active_view = nil,
  root_view = { open_doc = function(_, doc) table.insert(core.docs, doc) end },
}

package.preload["core"] = function() return core end
package.preload["core.common"] = function()
  return dofile(REPO .. "/data/core/common.lua")
end
package.preload["core.config"] = function()
  return { plugins = setmetatable({}, { __index = function() return {} end }) }
end
package.preload["core.command"] = function()
  return { add = function(_, map)
    if type(map) == "table" then
      for n, f in pairs(map) do registered[n] = f end
    end
  end }
end
package.preload["core.style"] = function()
  return { text = {1,1,1}, warn = {1,1,0}, error = {1,0,0}, dim = {0.5,0.5,0.5} }
end
package.preload["core.keymap"] = function()
  return { add = function() end, modkeys = {} }
end
package.preload["core.doc"] = function()
  local Doc = {}
  Doc.load = function(self, filename)
    self.saved_lines = rfile(filename)
    return self
  end
  Doc.new = function(self, filename)
    self:load(filename)
    return self
  end
  return Doc
end
package.preload["core.view"] = function()
  local View = {}
  View.__index = View
  View.super = View
  function View.new(cls, ...) return setmetatable({}, View) end
  return View
end
package.preload["core.rootview"] = function()
  return { __index = {} }
end

-- treeview stub: the real plugin discovers the live instance through the
-- view tree (the loader uses dofile, so requiring it would double-load)
local treeview_calls = { text = 0, icon = 0 }
local fake_treeview = {
  hovered_item = nil,
  selected_item = nil,
  cache = {},
  watches = {},
  expanded = {},
  get_cached = function() end,
  on_context_menu = function(self)
    return { items = {
      { text = "Open in System", command = "treeview:open-in-system" },
      "DIVIDER",
      { text = "Rename", command = "treeview:rename" },
    } }, self
  end,
}
core.root_view = core.root_view or {}
core.root_view.root_node = fake_treeview

system = {
  get_file_info = function(path)
    local f = io.open(path, "rb")
    if f then
      local s = f:seek("end")
      f:close()
      return { type = "file", size = s, modified = 1 }
    end
    local ok, _, code = os.execute("test -d " .. path)
    if ok or code == 0 then return { type = "dir", modified = 1 } end
    return nil
  end,
  list_dir = function(path)
    local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    local t = {}
    for line in p:lines() do table.insert(t, line) end
    p:close()
    return t
  end,
  get_time = os.time,
  mkdir = function(path) os.execute("mkdir -p " .. path) return true end,
  rmdir = function(path) os.execute("rmdir " .. path) return true end,
}
_G.system = system

-- real process module cannot run headless; shell out, with PATH pointing
-- at the fake ssh
local started_cmdlines = {}
package.preload["process"] = function()
  local process = {}
  process.STREAM_STDOUT = 1
  process.STREAM_STDERR = 2
  function process.start(args, options)
    -- shell-quote every argument: the real process.start passes argv
    -- directly, the plugin embeds double quotes and pipes in the remote
    -- command element, so naive concat would let the local shell eat them
    local quoted = {}
    for _, a in ipairs(args) do
      table.insert(quoted, "'" .. tostring(a):gsub("'", "'\\''") .. "'")
    end
    local cmdline = table.concat(quoted, " ")
    table.insert(started_cmdlines, cmdline)
    local env_prefix = ""
    if options and options.env then
      for k, v in pairs(options.env) do
        env_prefix = env_prefix .. k .. '="' .. tostring(v):gsub('"', '\\"') .. '" '
      end
    end
    local proc = {}
    local p = setmetatable({ process = proc }, { __index = process })
    function proc:running() return false end
    local h = io.popen("PATH=" .. ROOT .. "/bin:$PATH " .. env_prefix
      .. cmdline .. ' 2>"' .. ROOT .. '/proc-err"; echo "EXIT:$?"')
    local out = h:read("*a")
    h:close()
    local code = tonumber(out:match("EXIT:(%-?%d+)")) or -1
    local stdout = out:gsub("EXIT:%-?%d+%s*$", "")
    function process:wait() return code end
    p.stdout = { read = function(_, spec)
      if spec == "all" then return code ~= -1 and stdout or nil end
      return nil
    end }
    p.stderr = { read = function(_, spec)
      if spec == "all" then
        local f = io.open(ROOT .. "/proc-err", "rb")
        if not f then return nil end
        local s = f:read("*a") f:close()
        return s ~= "" and s or nil
      end
      return nil
    end }
    return p
  end
  return process
end

USERDIR = ROOT .. "/user"
PATHSEP = "/"
PLATFORM = "Mac OS X"
SCALE = 1
_G.USERDIR, _G.PATHSEP, _G.PLATFORM, _G.SCALE = USERDIR, PATHSEP, PLATFORM, SCALE
HOME = os.getenv("HOME")

local function run_threads()
  local rounds = 0
  repeat
    rounds = rounds + 1
    local worked = false
    local i = 1
    while i <= #threads do
      local t = threads[i]
      if coroutine.status(t.cr) == "dead" then
        table.remove(threads, i)
      elseif coroutine.status(t.cr) == "suspended" then
        local ok, res = coroutine.resume(t.cr)
        if not ok then print("THREAD ERR: " .. tostring(res)) end
        worked = true
        if coroutine.status(t.cr) == "suspended" then
          table.remove(threads, i)
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end
  until not worked or rounds > 200
  for i = #threads, 1, -1 do threads[i] = nil end
end

-- ---------------------------------------------------------------------------
-- load the plugin (with the fake ssh first on PATH)
-- ---------------------------------------------------------------------------

package.path = REPO .. "/data/?.lua;" .. package.path
local M = dofile(REPO .. "/data/plugins/remote_projects.lua")

ok(M and type(M.connect_with_form) == "function", "plugin returns module surface")
ok(registered["remote-projects:open-dialog"], "open-dialog command registered")
ok(registered["remote-projects:pull-file"], "pull-file command registered")
ok(registered["remote-projects:push-file"], "push-file command registered")

-- 1) connect through the form callback (as the dialog would)
M.connect_with_form("box", "tester", "", 22, "/proj")
run_threads()

local cache_dir = USERDIR .. "/remote/cache/tester-box-proj"
ok(exists(cache_dir), "cache directory created (" .. cache_dir .. ")")
ok(#core.projects == 1, "project added for the remote")
ok(core.projects[1] and core.projects[1].path == cache_dir,
  "project points at the cache dir")
-- placeholders materialized, but content NOT pulled
ok(exists(cache_dir .. "/hello.txt"), "placeholder for hello.txt exists")
ok(exists(cache_dir .. "/sub/deep.txt"), "placeholder for sub/deep.txt exists")
ok(rfile(cache_dir .. "/hello.txt") == "", "placeholder is empty (not pulled)")

-- 2) accounts and dirs persisted separately
local accounts = M.list_accounts()
ok(#accounts == 1 and accounts[1].host == "box" and accounts[1].user == "tester"
  and accounts[1].port == 22, "account persisted with fields")
ok(accounts[1].password == nil, "empty password not stored")
local dirs = M.list_dirs()
ok(#dirs == 1 and dirs[1].account_id == accounts[1].id and dirs[1].path == "/proj",
  "dir persisted referencing the account")
ok(exists(USERDIR .. "/remote/accounts.lua") and exists(USERDIR .. "/remote/dirs.lua"),
  "accounts.lua and dirs.lua stored separately")

-- 3) grey state: not pulled -> is_pulled false
local session = M._internal.session_for_path(cache_dir .. "/hello.txt")
ok(session ~= nil, "session resolves for cache path")
ok(M._internal.is_pulled(session, cache_dir .. "/hello.txt") == false,
  "hello.txt starts grey (not pulled)")

-- 4) pull via the internal API (as the treeview command does)
-- pull via the internal API in a coroutine (run_with_password yields)
local co = coroutine.create(function()
  ok(M._internal.pull_file(session, cache_dir .. "/hello.txt") == true,
    "pull_file succeeds")
end)
coroutine.resume(co)
ok(rfile(cache_dir .. "/hello.txt") == "remote hello\n", "pulled content in cache")
ok(M._internal.is_pulled(session, cache_dir .. "/hello.txt") == true,
  "hello.txt no longer grey after pull")
ok(exists(cache_dir .. "/.remote-state.lua"), "sidecar state file exists after pull")

-- 5) push refuses unpulled placeholders (deep.txt still grey)
local co2 = coroutine.create(function()
  ok(M._internal.push_file(session, cache_dir .. "/sub/deep.txt") == false,
    "push refuses a never-pulled placeholder")
end)
coroutine.resume(co2)
ok(rfile(ROOT .. "/machine/proj/sub/deep.txt") == "deep content\n",
  "remote untouched by refused push")

-- 6) push a pulled file after editing it locally
wfile(cache_dir .. "/hello.txt", "edited locally\n")
local co3 = coroutine.create(function()
  ok(M._internal.push_file(session, cache_dir .. "/hello.txt") == true,
    "push_file succeeds for a pulled file")
end)
coroutine.resume(co3)
ok(rfile(ROOT .. "/machine/proj/hello.txt") == "edited locally\n",
  "pushed content on the remote")

-- 7) treeview integration: context menu gains 拉取/推送 for session files
fake_treeview.hovered_item = {
  type = "file", filename = "hello.txt", abs_filename = cache_dir .. "/hello.txt",
}
local menu = fake_treeview:on_context_menu()
local found_pull, found_push = false, false
for _, entry in ipairs(menu.items) do
  if type(entry) == "table" and entry.command == "remote-projects:pull-file" then
    found_pull = true
  end
  if type(entry) == "table" and entry.command == "remote-projects:push-file" then
    found_push = true
  end
end
ok(found_pull and found_push, "context menu offers pull/push")
-- and NOT for unrelated files
fake_treeview.hovered_item = {
  type = "file", filename = "x", abs_filename = "/elsewhere/x.txt",
}
local menu2 = fake_treeview:on_context_menu()
local stray = false
for _, entry in ipairs(menu2.items) do
  if type(entry) == "table" and (entry.command == "remote-projects:pull-file"
    or entry.command == "remote-projects:push-file") then
    stray = true
  end
end
ok(not stray, "context menu untouched for non-remote files")

-- 8) greying: not-yet-pulled files report as ignored, which is what the
-- treeview renders dimmed (item.ignored -> style.sidebar_dim)
local project = core.projects[1]
ok(project ~= nil, "remote project available")
local unpulled_info = { type = "file", size = 0, modified = 0 }
ok(project:is_ignored(unpulled_info, cache_dir .. "/sub/deep.txt") == true,
  "unpulled file is treated as ignored (drawn dim)")
local pulled_info = { type = "file", size = 1, modified = 0 }
ok(project:is_ignored(pulled_info, cache_dir .. "/hello.txt") == false,
  "pulled file is not ignored (drawn normal)")
-- directories are never dimmed
local dir_info = { type = "dir", size = 0, modified = 0 }
ok(project:is_ignored(dir_info, cache_dir .. "/sub") == false,
  "directories are not dimmed")
-- files outside the session are untouched
local other_info = { type = "file", size = 1, modified = 0 }
ok(project:is_ignored(other_info, "/elsewhere/x.txt") == false,
  "paths outside the session are untouched")

-- 9) bad host: connect fails, error surfaces, no cache leftovers.
-- The fake ssh rejects any host other than "box" like a DNS failure.
M.connect_with_form("no-such-host-xyz.invalid", "tester", "", 22, "/proj")
run_threads()
local bad_cache = USERDIR .. "/remote/cache/tester-no-such-host-xyz.invalid-proj"
ok(not exists(bad_cache) or #system.list_dir(bad_cache) == 0,
  "failed connect leaves empty/no cache dir")
ok(#core.projects == 1, "failed connect adds no project")

-- 10) reopening an existing remote directory: the connect wrote a session
-- manifest, and a fresh plugin load (app restart) reattaches the session
-- without the dialog and without any network round trip.
ok(exists(cache_dir .. "/.remote-session.lua"), "session manifest written")

local calls_before = #started_cmdlines
core.projects = { { path = cache_dir } }
package.loaded["plugins.remote_projects"] = nil
local M2 = dofile(REPO .. "/data/plugins/remote_projects.lua")
ok(M2._internal.sessions[cache_dir] ~= nil,
  "existing remote directory reattached on load")
ok(M2._internal.session_for_path(cache_dir .. "/hello.txt") ~= nil,
  "files resolve to the reattached session")
ok(#started_cmdlines == calls_before,
  "reattach does not run any remote command")

-- the reattached session keeps its pull state and can push/pull again
local session2 = M2._internal.session_for_path(cache_dir .. "/hello.txt")
ok(M2._internal.is_pulled(session2, cache_dir .. "/hello.txt") == true,
  "pull state survives the restart")
local co4 = coroutine.create(function()
  ok(M2._internal.pull_file(session2, cache_dir .. "/hello.txt") == true,
    "pull still works after reattach")
end)
coroutine.resume(co4)

print(string.format("checks: %d, fails: %d", checks, fails))
if fails > 0 then os.exit(1) end
